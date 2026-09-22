package dev.manishpanday.native_proxy_resolver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.Proxy as AndroidProxy
import android.net.ProxyInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Resolves the system proxy for a URL with [ProxySelector] (which Android keeps in sync with the
 * default network's proxy, including the local PAC proxy) and
 * [ConnectivityManager.getDefaultProxy], and reports network / proxy changes.
 */
class NativeProxyResolverPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private val mainHandler = Handler(Looper.getMainLooper())
    private var executor: ExecutorService? = null

    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var proxyReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "native_proxy_resolver").apply { isDaemon = true }
        }
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopWatching()
        executor?.shutdown()
        executor = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "resolve" -> {
                val url = call.argument<String>("url")
                val uri = try {
                    url?.let { URI(it) }
                } catch (e: Exception) {
                    null
                }
                if (uri == null || uri.host.isNullOrEmpty()) {
                    result.error("bad_args", "Expected an absolute 'url'", null)
                    return
                }
                val worker = executor
                if (worker == null) {
                    result.error("detached", "Plugin is detached from the engine", null)
                    return
                }
                worker.execute {
                    val reply = try {
                        resolve(uri)
                    } catch (e: Exception) {
                        mapOf(
                            "entries" to listOf(DIRECT),
                            "source" to "unknown",
                            "error" to "Android proxy lookup failed: ${e.message}",
                        )
                    }
                    mainHandler.post { result.success(reply) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Builds the channel reply for [uri]. */
    private fun resolve(uri: URI): Map<String, Any?> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val info: ProxyInfo? = connectivity?.defaultProxy
        val pacUrl = info?.pacFileUrl?.takeIf { it != Uri.EMPTY }?.toString()

        val selected = try {
            ProxySelector.getDefault()?.select(uri).orEmpty()
        } catch (e: IllegalArgumentException) {
            emptyList()
        }
        val entries = selected.mapNotNull(::toEntry)

        val reply = mutableMapOf<String, Any?>()
        if (pacUrl != null) reply["pacUrl"] = pacUrl

        // The process-wide ProxySelector already reflects the default network's proxy
        // (Android points it at its local PAC proxy when a PAC is configured).
        if (entries.any { it["type"] != "direct" }) {
            reply["entries"] = entries
            reply["source"] = if (pacUrl != null) "pac" else "manual"
            return reply
        }

        if (info == null) {
            reply["entries"] = listOf(DIRECT)
            reply["source"] = "none"
            return reply
        }

        if (pacUrl != null) {
            // PAC: Android evaluates the script in a local proxy on localhost:<port>.
            reply["source"] = "pac"
            if (info.port > 0) {
                reply["entries"] = listOf(
                    mapOf("type" to "http", "host" to (info.host ?: "localhost"), "port" to info.port),
                )
            } else {
                reply["entries"] = listOf(DIRECT)
                reply["error"] = "Android's PAC proxy service is not running yet"
            }
            return reply
        }

        val host = info.host
        if (!host.isNullOrEmpty() && info.port > 0) {
            // Static proxy the ProxySelector did not report (e.g. a bypassed host or system
            // properties not yet updated): let Dart apply the exclusion list.
            reply["proxyList"] = if (host.contains(':')) "[$host]:${info.port}" else "$host:${info.port}"
            reply["proxyBypass"] = info.exclusionList?.joinToString(",") ?: ""
            reply["source"] = "manual"
            return reply
        }

        reply["entries"] = listOf(DIRECT)
        reply["source"] = "none"
        return reply
    }

    private fun toEntry(proxy: Proxy): Map<String, Any?>? {
        if (proxy.type() == Proxy.Type.DIRECT) return DIRECT
        val address = proxy.address() as? InetSocketAddress ?: return null
        val host = address.hostString
        if (host.isNullOrEmpty() || address.port <= 0) return null
        val type = if (proxy.type() == Proxy.Type.SOCKS) "socks" else "http"
        return mapOf("type" to type, "host" to host, "port" to address.port)
    }

    // region Change events

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        startWatching()
    }

    override fun onCancel(arguments: Any?) {
        stopWatching()
        eventSink = null
    }

    private fun emit(reason: String) {
        mainHandler.post { eventSink?.success(reason) }
    }

    private fun startWatching() {
        stopWatching()
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        if (connectivity != null) {
            val baseline = connectivity.activeNetwork
            val callback = object : ConnectivityManager.NetworkCallback() {
                private var current: Network? = baseline
                private var lastProxy: ProxyInfo? = null
                private var sawLinkProperties = false

                override fun onAvailable(network: Network) {
                    if (network != current) {
                        current = network
                        emit("network")
                    }
                }

                override fun onLost(network: Network) {
                    if (network == current) current = null
                    emit("network")
                }

                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                    val proxy = linkProperties.httpProxy
                    if (sawLinkProperties && proxy != lastProxy) emit("proxy")
                    lastProxy = proxy
                    sawLinkProperties = true
                }
            }
            try {
                connectivity.registerDefaultNetworkCallback(callback)
                networkCallback = callback
            } catch (e: SecurityException) {
                // ACCESS_NETWORK_STATE missing from the merged manifest; fall back to broadcasts.
            }
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (!isInitialStickyBroadcast) emit("proxy")
            }
        }
        val filter = IntentFilter(AndroidProxy.PROXY_CHANGE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        proxyReceiver = receiver
    }

    private fun stopWatching() {
        networkCallback?.let { callback ->
            try {
                context.getSystemService(ConnectivityManager::class.java)
                    ?.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        networkCallback = null
        proxyReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (e: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        proxyReceiver = null
    }

    // endregion

    private companion object {
        const val METHOD_CHANNEL = "dev.manishpanday/native_proxy_resolver"
        const val EVENT_CHANNEL = "dev.manishpanday/native_proxy_resolver/changes"
        val DIRECT: Map<String, Any?> = mapOf("type" to "direct")
    }
}
