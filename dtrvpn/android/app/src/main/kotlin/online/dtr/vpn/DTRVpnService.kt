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

// ── TunCallback — Java interface called by Go to protect() sockets ────────────
// Go holds a JNI global ref to this object and calls protect(fd) via
// dialer.DefaultSocketHook on every outbound socket Mihomo opens.
// Without this, Mihomo traffic loops back into the TUN → NetworkUpdateMonitor
// tries to create a netlink socket → banned on Android → crash.
interface TunCallback {
    fun protect(fd: Int)
}

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

        @Volatile var instance: DTRVpnService? = null

        init { System.loadLibrary("clash") }
    }

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

    // ── JNI ──────────────────────────────────────────────────────────────────
    external fun initClash      (homeDir: String)
    external fun startClash     (config: String, fd: Int): String
    external fun startTun       (fd: Int, cb: TunCallback): String  // cb = protect() callback
    external fun stopTun        ()
    external fun stopClash      ()
    external fun isClashRunning (): Int
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
    // ─────────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        instance = this
        initClash(filesDir.absolutePath)
        createNotificationChannel()
        Log.i(TAG, "=== DTRVpnService created ===")
        Log.i(TAG, "  homeDir=${filesDir.absolutePath}")
        Log.i(TAG, "  SDK=${Build.VERSION.SDK_INT}, model=${Build.MANUFACTURER} ${Build.MODEL}")
    }

    override fun onBind(intent: android.content.Intent?): IBinder? = null

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: run {
                    Log.e(TAG, "ACTION_START: config extra is null")
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

        val configFormat = if (config.trimStart().startsWith("{")) "JSON" else "YAML"
        Log.i(TAG, "--- startVpn() ---  format=$configFormat  len=${config.length}  ipv6=$enableIpv6")

        // Step 1: Validate config
        Log.d(TAG, "[Step 1] ValidateConfig")
        val validationError = validateConfig(config)
        if (validationError.isNotEmpty()) {
            Log.e(TAG, "[Step 1] FAILED: $validationError")
            broadcastState("error", "Config error: $validationError")
            return
        }
        Log.i(TAG, "[Step 1] OK")

        try {
            // Step 2: Build Android TUN interface
            Log.d(TAG, "[Step 2] Build TUN interface")
            val builder = Builder()
                .setSession("DTR VPN")
                .addAddress("172.19.0.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("172.19.0.2")
                .setMtu(9000)
                .addDisallowedApplication(packageName) // exclude ourselves from VPN
                .allowBypass()

            if (enableIpv6) {
                try {
                    builder
                        .addAddress("fdfe:dcba:9876::1", 126)
                        .addRoute("::", 0)
                        .addDnsServer("fdfe:dcba:9876::2")
                    Log.i(TAG, "  IPv6 enabled")
                } catch (e: Exception) {
                    Log.w(TAG, "  IPv6 not supported: ${e.message}")
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            @Suppress("DEPRECATION") builder.setBlocking(false)

            tunInterface = builder.establish()
            val fd = tunInterface?.detachFd() ?: run {
                Log.e(TAG, "[Step 2] establish() returned null — VPN permission denied?")
                broadcastState("error", "Failed to create TUN interface")
                return
            }
            Log.i(TAG, "[Step 2] TUN established: fd=$fd  MTU=9000  IPv6=$enableIpv6")
            broadcastState("connecting", null)

            // Step 3: Start Mihomo core (proxy+dns config, NO tun section in config)
            Log.d(TAG, "[Step 3] startClash")
            val clashResult = startClash(config, 0)
            Log.i(TAG, "[Step 3] startClash result: $clashResult")

            if (!clashResult.contains("\"ok\":true")) {
                val err = extractJsonError(clashResult)
                Log.e(TAG, "[Step 3] FAILED: $err")
                broadcastState("error", err)
                cleanup()
                return
            }
            Log.i(TAG, "[Step 3] Mihomo core OK")

            // Step 4: Start TUN listener in Go with protect() callback.
            // FlClashX pattern: pass a TunCallback object so Go can call
            // VpnService.protect(fd) via dialer.DefaultSocketHook on every
            // socket Mihomo opens — preventing routing loops into the TUN.
            Log.d(TAG, "[Step 4] startTun(fd=$fd)")
            val tunCallback = object : TunCallback {
                override fun protect(socketFd: Int) {
                    protect(socketFd) // VpnService.protect()
                }
            }
            val tunResult = startTun(fd, tunCallback)
            Log.i(TAG, "[Step 4] startTun result: $tunResult")

            if (!tunResult.contains("\"ok\":true")) {
                val err = extractJsonError(tunResult)
                Log.e(TAG, "[Step 4] startTun FAILED: $err")
                stopClash()
                broadcastState("error", "TUN init failed: $err")
                cleanup()
                return
            }
            Log.i(TAG, "[Step 4] TUN listener OK")

            isRunning = true
            broadcastState("connected", null)
            startForegroundService()
            startTrafficPoller()
            startLogPoller()
            registerNetworkCallback()
            Log.i(TAG, "=== VPN CONNECTED: fd=$fd  ipv6=$enableIpv6 ===")

        } catch (e: Exception) {
            Log.e(TAG, "startVpn exception: ${e.message}", e)
            broadcastState("error", e.message ?: "Unknown error")
            cleanup()
        }
    }

    fun stopVpn() {
        Log.i(TAG, "--- stopVpn() ---")
        unregisterNetworkCallback()
        stopTrafficPoller()
        stopLogPoller()
        if (isRunning) {
            stopLog()
            stopTun()
            stopClash()
            forceGC()
            isRunning = false
        }
        cleanup()
        stopForeground()
        broadcastState("disconnected", null)
        Log.i(TAG, "=== VPN STOPPED ===")
    }

    // ── Foreground notification ───────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "DTR VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "VPN connection status"; setShowBadge(false) }
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

    // ── Traffic polling ───────────────────────────────────────────────────────

    private fun startTrafficPoller() {
        stopTrafficPoller()
        trafficJob = scope.launch {
            while (isActive && isRunning) {
                try { broadcastTraffic(getTraffic()) }
                catch (e: Exception) { Log.w(TAG, "Traffic poll: ${e.message}") }
                delay(1000)
            }
        }
    }

    private fun stopTrafficPoller() { trafficJob?.cancel(); trafficJob = null }

    private fun broadcastTraffic(json: String) {
        sendBroadcast(Intent("online.dtr.vpn.TRAFFIC").apply { putExtra("traffic", json) })
    }

    // ── Mihomo log polling ────────────────────────────────────────────────────

    private fun startLogPoller() {
        stopLogPoller()
        startLog()
        logJob = scope.launch {
            while (isActive && isRunning) {
                try {
                    val logsJson = getPendingLogs()
                    if (logsJson != "[]") broadcastMihomoLogs(logsJson)
                } catch (e: Exception) { Log.w(TAG, "Log poll: ${e.message}") }
                delay(500)
            }
        }
    }

    private fun stopLogPoller() { logJob?.cancel(); logJob = null }

    private fun broadcastMihomoLogs(json: String) {
        sendBroadcast(Intent("online.dtr.vpn.MIHOMO_LOG").apply { putExtra("logs", json) })
    }

    // ── Network monitoring ────────────────────────────────────────────────────

    private fun registerNetworkCallback() {
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivity.registerNetworkCallback(request, networkCallback)
        } catch (e: Exception) { Log.w(TAG, "registerNetworkCallback: ${e.message}") }
    }

    private fun unregisterNetworkCallback() {
        try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
    }

    private fun onNetworkChanged() {
        Log.d(TAG, "Network changed")
        sendBroadcast(Intent("online.dtr.vpn.NETWORK_CHANGED"))
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────

    private fun cleanup() {
        try { tunInterface?.close() } catch (e: Exception) {
            Log.w(TAG, "Error closing TUN fd: ${e.message}")
        }
        tunInterface = null
    }

    private fun broadcastState(status: String, error: String?) {
        Log.d(TAG, "broadcastState status=$status${error?.let{" err=$it"} ?: ""}")
        sendBroadcast(Intent("online.dtr.vpn.VPN_STATE").apply {
            putExtra("status", status)
            error?.let { putExtra("error", it) }
        })
    }

    private fun extractJsonError(result: String): String =
        result.substringAfter("\"error\":\"", "unknown error")
              .substringBefore("\"")
              .ifEmpty { result.take(200) }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (isRunning) { Log.d(TAG, "onTrimMemory level=$level"); forceGC() }
    }

    override fun onDestroy() { instance = null; stopVpn(); super.onDestroy() }
    override fun onRevoke()  { Log.w(TAG, "VPN revoked by system"); stopVpn(); super.onRevoke() }
}
