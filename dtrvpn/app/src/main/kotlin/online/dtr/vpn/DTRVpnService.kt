package online.dtr.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class DTRVpnService : VpnService() {

    companion object {
        const val TAG = "DTRVpnService"

        const val ACTION_START     = "online.dtr.vpn.START"
        const val ACTION_STOP      = "online.dtr.vpn.STOP"
        const val EXTRA_CONFIG     = "config"
        const val EXTRA_IPV6       = "ipv6"
        const val EXTRA_BYPASS_LAN = "bypass_lan"

        const val NOTIFICATION_CHANNEL = "dtr_vpn_service"
        const val NOTIFICATION_ID      = 1

        // Must match tunIpv4CIDR / tunDnsAddress constants in clash_ffi.go
        const val TUN_IPV4_ADDRESS = "172.19.0.1"
        const val TUN_IPV4_PREFIX  = 30
        const val TUN_DNS_ADDRESS  = "172.19.0.2"

        @Volatile var instance: DTRVpnService? = null

        init { System.loadLibrary("clash") }
    }

    // Keep PFD alive so its fd stays valid while Mihomo TUN listener is running.
    // We do NOT call detachFd() — closing tunInterface closes the fd.
    private var tunInterface: ParcelFileDescriptor? = null
    private var isRunning = false

    private val scope = CoroutineScope(Dispatchers.IO)
    private var trafficJob: Job? = null
    private var logJob: Job? = null

    private val connectivity by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network)  = onNetworkChanged()
        override fun onLost(network: Network)       = onNetworkChanged()
        override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) = onNetworkChanged()
    }

    // ── JNI ────────────────────────────────────────────────────────────────
    external fun initClash      (homeDir: String)
    external fun startClash     (config: String, fd: Int): String
    external fun stopClash      ()
    external fun isClashRunning (): Int

    // FlClashX approach: TUN is started separately via sing_tun.New() in Go,
    // NOT via mihomo config (on Android features.Android=true skips ReCreateTun).
    external fun startTun       (fd: Int): String
    external fun stopTun        ()

    external fun selectProxy    (group: String, proxy: String): String
    external fun testDelay      (proxyName: String, testUrl: String, timeoutMs: Int): Int
    external fun getProxies     (): String
    external fun getTraffic     (): String
    external fun getTotalTraffic(): String
    external fun forceGC        ()
    external fun validateConfig (config: String): String
    external fun startLog       ()
    external fun stopLog        ()
    external fun getPendingLogs (): String
    // ───────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        instance = this
        initClash(filesDir.absolutePath)
        createNotificationChannel()
        Log.d(TAG, "Service created, homeDir=${filesDir.absolutePath}")
    }

    override fun onBind(intent: android.content.Intent?): IBinder? = null

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: run {
                    Log.e(TAG, "ACTION_START: config is null")
                    return START_NOT_STICKY
                }
                val enableIpv6 = intent.getBooleanExtra(EXTRA_IPV6, false)
                val bypassLan  = intent.getBooleanExtra(EXTRA_BYPASS_LAN, true)
                startVpn(config, enableIpv6, bypassLan)
            }
            ACTION_STOP -> stopVpn()
        }
        return START_STICKY
    }

    fun startVpn(config: String, enableIpv6: Boolean = false, bypassLan: Boolean = true) {
        stopVpn()

        Log.d(TAG, "─── startVpn() ─── len=${config.length} ipv6=$enableIpv6")

        // Pre-validate config before doing anything
        val validationError = validateConfig(config)
        if (validationError.isNotEmpty()) {
            Log.e(TAG, "Config validation FAILED: $validationError")
            broadcastState("error", "Config error: $validationError")
            return
        }
        Log.d(TAG, "Config validation OK")

        try {
            val builder = Builder()
                .setSession("DTR VPN")
                .addAddress(TUN_IPV4_ADDRESS, TUN_IPV4_PREFIX)
                .addRoute("0.0.0.0", 0)
                // DNS queries to TUN_DNS_ADDRESS are hijacked by sing_tun
                // and handled by Mihomo's fake-ip engine
                .addDnsServer(TUN_DNS_ADDRESS)
                .setMtu(9000)
                // Own traffic bypasses VPN — equivalent to VpnService.protect() for all
                // sockets opened by the Go core (dialer.DefaultSocketHook in FlClashX
                // serves the same purpose, but addDisallowedApplication covers our case)
                .addDisallowedApplication(packageName)
                .allowBypass()

            if (enableIpv6) {
                try {
                    builder
                        .addAddress("fdfe:dcba:9876::1", 126)
                        .addRoute("::", 0)
                        .addDnsServer("fdfe:dcba:9876::2")
                    Log.d(TAG, "IPv6 enabled")
                } catch (e: Exception) {
                    Log.w(TAG, "IPv6 not supported: ${e.message}")
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            @Suppress("DEPRECATION")
            builder.setBlocking(false)

            tunInterface = builder.establish() ?: run {
                Log.e(TAG, "establish() returned null — VPN permission denied?")
                broadcastState("error", "Failed to create TUN interface")
                return
            }

            val fd = tunInterface!!.fd
            Log.i(TAG, "TUN fd=$fd MTU=9000 DNS=$TUN_DNS_ADDRESS IPv6=$enableIpv6")
            broadcastState("connecting", null)

            // ── Step 1: Apply proxy/rules/dns config (no TUN section) ────────
            // DNS config (fake-ip) is included in the config JSON by Dart's _buildConfig().
            // TUN is NOT in the config — on Android, mihomo skips TUN creation from config.
            val clashResult = startClash(config, fd)
            Log.i(TAG, "startClash result: $clashResult")

            if (!clashResult.contains("\"ok\":true")) {
                val err = clashResult.substringAfter("\"error\":\"", "unknown").substringBefore("\"")
                Log.e(TAG, "Mihomo startClash FAILED: $err")
                broadcastState("error", err)
                cleanup()
                return
            }

            // ── Step 2: Start TUN via sing_tun.New() directly ────────────────
            // This is the FlClashX approach. Connects the TUN fd to Mihomo's tunnel,
            // enabling packet routing through the proxy chain.
            val tunResult = startTun(fd)
            Log.i(TAG, "startTun result: $tunResult")

            if (!tunResult.contains("\"ok\":true")) {
                val err = tunResult.substringAfter("\"error\":\"", "unknown").substringBefore("\"")
                Log.e(TAG, "startTun FAILED: $err")
                broadcastState("error", "TUN error: $err")
                stopClash()
                cleanup()
                return
            }

            isRunning = true
            Log.i(TAG, "VPN started ✓ (Mihomo core + TUN listener)")
            broadcastState("connected", null)
            startForegroundService()
            startTrafficPoller()
            startLogPoller()
            registerNetworkCallback()

        } catch (e: Exception) {
            Log.e(TAG, "startVpn exception: ${e.message}", e)
            broadcastState("error", e.message ?: "Unknown error")
            cleanup()
        }
    }

    fun stopVpn() {
        unregisterNetworkCallback()
        stopTrafficPoller()
        stopLogPoller()
        if (isRunning) {
            stopLog()
            stopTun()    // close sing_tun listener first
            stopClash()  // then shutdown Mihomo
            forceGC()
            isRunning = false
        }
        cleanup()
        stopForeground()
        broadcastState("disconnected", null)
    }

    // ── Foreground notification ──────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "DTR VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN connection status"
                setShowBadge(false)
            }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    @Suppress("DEPRECATION")
    private fun startForegroundService() {
        val openIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, DTRVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setContentTitle("DTR VPN")
            .setContentText("Подключено")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_delete, "Отключить", stopIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun stopForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // ── Traffic polling ──────────────────────────────────────────────────────

    private fun startTrafficPoller() {
        stopTrafficPoller()
        trafficJob = scope.launch {
            while (isActive && isRunning) {
                try { broadcastTraffic(getTraffic()) }
                catch (e: Exception) { Log.w(TAG, "Traffic poll error: ${e.message}") }
                delay(1000)
            }
        }
    }

    private fun stopTrafficPoller() { trafficJob?.cancel(); trafficJob = null }

    private fun broadcastTraffic(json: String) {
        sendBroadcast(Intent("online.dtr.vpn.TRAFFIC").apply { putExtra("traffic", json) })
    }

    // ── Mihomo log polling ───────────────────────────────────────────────────

    private fun startLogPoller() {
        stopLogPoller()
        startLog()
        logJob = scope.launch {
            while (isActive && isRunning) {
                try {
                    val logsJson = getPendingLogs()
                    if (logsJson != "[]") broadcastMihomoLogs(logsJson)
                } catch (e: Exception) { Log.w(TAG, "Log poll error: ${e.message}") }
                delay(500)
            }
        }
    }

    private fun stopLogPoller() { logJob?.cancel(); logJob = null }

    private fun broadcastMihomoLogs(json: String) {
        sendBroadcast(Intent("online.dtr.vpn.MIHOMO_LOG").apply { putExtra("logs", json) })
    }

    // ── Network monitoring ───────────────────────────────────────────────────

    private fun registerNetworkCallback() {
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivity.registerNetworkCallback(request, networkCallback)
        } catch (e: Exception) { Log.w(TAG, "Failed to register network callback: ${e.message}") }
    }

    private fun unregisterNetworkCallback() {
        try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
    }

    private fun onNetworkChanged() {
        sendBroadcast(Intent("online.dtr.vpn.NETWORK_CHANGED"))
        Log.d(TAG, "Network changed")
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    private fun cleanup() {
        try { tunInterface?.close() } catch (e: Exception) {
            Log.w(TAG, "Error closing TUN pfd: ${e.message}")
        }
        tunInterface = null
    }

    private fun broadcastState(status: String, error: String?) {
        sendBroadcast(Intent("online.dtr.vpn.VPN_STATE").apply {
            putExtra("status", status)
            error?.let { putExtra("error", it) }
        })
    }

    override fun onTrimMemory(level: Int) { super.onTrimMemory(level); if (isRunning) forceGC() }
    override fun onDestroy() { instance = null; stopVpn(); super.onDestroy() }
    override fun onRevoke()  { stopVpn(); super.onRevoke() }
}
