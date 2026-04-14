package online.dtr.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL   = "online.dtr.vpn/mihomo"
    private val EVENT_CHANNEL    = "online.dtr.vpn/vpn_state"
    private val TRAFFIC_CHANNEL  = "online.dtr.vpn/traffic"
    private val MIHOMO_LOG_CHANNEL = "online.dtr.vpn/mihomo_log"  // ← NEW

    private var vpnStateSink:   EventChannel.EventSink? = null
    private var trafficSink:    EventChannel.EventSink? = null
    private var mihomoLogSink:  EventChannel.EventSink? = null     // ← NEW

    private val VPN_PERMISSION_REQUEST = 100
    private var pendingConfig: String? = null

    // ── BroadcastReceivers ────────────────────────────────────────────────────

    private val vpnStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val status = intent?.getStringExtra("status") ?: return
            val error  = intent.getStringExtra("error")
            val map = mutableMapOf<String, Any>("status" to status)
            error?.let { map["error"] = it }
            runOnUiThread { vpnStateSink?.success(map) }
        }
    }

    private val trafficReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val json = intent?.getStringExtra("traffic") ?: return
            runOnUiThread { trafficSink?.success(json) }
        }
    }

    private val networkReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            runOnUiThread {
                vpnStateSink?.success(mapOf("status" to "network_changed"))
            }
        }
    }

    // ← NEW: Mihomo internal logs receiver
    private val mihomoLogReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val json = intent?.getStringExtra("logs") ?: return
            runOnUiThread { mihomoLogSink?.success(json) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Method Channel ─────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "connect" -> {
                        val config = call.argument<String>("config") ?: run {
                            result.error("NO_CONFIG", "config is null", null)
                            return@setMethodCallHandler
                        }
                        val enableIpv6 = call.argument<Boolean>("enableIpv6") ?: false
                        pendingConfig = config

                        val permIntent = VpnService.prepare(this)
                        if (permIntent != null) {
                            startActivityForResult(permIntent, VPN_PERMISSION_REQUEST)
                        } else {
                            doConnect(config, enableIpv6)
                        }
                        result.success(true)
                    }

                    "disconnect" -> {
                        startService(Intent(this, DTRVpnService::class.java).apply {
                            action = DTRVpnService.ACTION_STOP
                        })
                        result.success(null)
                    }

                    "isRunning" -> result.success(DTRVpnService.instance != null)

                    "selectProxy" -> {
                        val group = call.argument<String>("group") ?: ""
                        val proxy = call.argument<String>("proxy") ?: ""
                        result.success(DTRVpnService.instance?.selectProxy(group, proxy))
                    }

                    "testDelay" -> {
                        val proxy   = call.argument<String>("proxy") ?: ""
                        val url     = call.argument<String>("url") ?: "https://www.gstatic.com/generate_204"
                        val timeout = call.argument<Int>("timeout") ?: 3000
                        val ms = DTRVpnService.instance?.testDelay(proxy, url, timeout) ?: -1
                        result.success(ms)
                    }

                    "getProxies" -> {
                        result.success(DTRVpnService.instance?.getProxies() ?: "[]")
                    }

                    "getTraffic" -> {
                        result.success(DTRVpnService.instance?.getTraffic() ?: "{\"up\":0,\"down\":0}")
                    }

                    "getTotalTraffic" -> {
                        result.success(DTRVpnService.instance?.getTotalTraffic() ?: "{\"up\":0,\"down\":0}")
                    }

                    "forceGC" -> {
                        DTRVpnService.instance?.forceGC()
                        result.success(null)
                    }

                    // ← NEW: validate config without starting VPN
                    "validateConfig" -> {
                        val config = call.argument<String>("config") ?: ""
                        val err = DTRVpnService.instance?.validateConfig(config) ?: ""
                        result.success(err)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── VPN State Event Channel ────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    vpnStateSink = sink
                    val filter = IntentFilter().apply {
                        addAction("online.dtr.vpn.VPN_STATE")
                        addAction("online.dtr.vpn.NETWORK_CHANGED")
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(vpnStateReceiver, filter, RECEIVER_NOT_EXPORTED)
                        registerReceiver(networkReceiver, IntentFilter("online.dtr.vpn.NETWORK_CHANGED"), RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(vpnStateReceiver, filter)
                        registerReceiver(networkReceiver, IntentFilter("online.dtr.vpn.NETWORK_CHANGED"))
                    }
                }
                override fun onCancel(args: Any?) {
                    vpnStateSink = null
                    safeUnregister(vpnStateReceiver)
                    safeUnregister(networkReceiver)
                }
            })

        // ── Traffic Event Channel ──────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, TRAFFIC_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    trafficSink = sink
                    val filter = IntentFilter("online.dtr.vpn.TRAFFIC")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(trafficReceiver, filter, RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(trafficReceiver, filter)
                    }
                }
                override fun onCancel(args: Any?) {
                    trafficSink = null
                    safeUnregister(trafficReceiver)
                }
            })

        // ← NEW: Mihomo Log Event Channel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, MIHOMO_LOG_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    mihomoLogSink = sink
                    val filter = IntentFilter("online.dtr.vpn.MIHOMO_LOG")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(mihomoLogReceiver, filter, RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(mihomoLogReceiver, filter)
                    }
                }
                override fun onCancel(args: Any?) {
                    mihomoLogSink = null
                    safeUnregister(mihomoLogReceiver)
                }
            })
    }

    private fun doConnect(config: String, enableIpv6: Boolean = false) {
        startService(Intent(this, DTRVpnService::class.java).apply {
            action = DTRVpnService.ACTION_START
            putExtra(DTRVpnService.EXTRA_CONFIG, config)
            putExtra(DTRVpnService.EXTRA_IPV6, enableIpv6)
        })
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST && resultCode == RESULT_OK) {
            pendingConfig?.let { doConnect(it) }
            pendingConfig = null
        }
    }

    private fun safeUnregister(receiver: BroadcastReceiver) {
        try { unregisterReceiver(receiver) } catch (_: Exception) {}
    }

    override fun onDestroy() {
        safeUnregister(vpnStateReceiver)
        safeUnregister(trafficReceiver)
        safeUnregister(networkReceiver)
        safeUnregister(mihomoLogReceiver)
        super.onDestroy()
    }
}
