package com.ssg.ssg_shell

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * §10.4 Notify network recovery separately.
 *
 * Network availability can lag foreground entry by several seconds during Wi-Fi reconnection or cellular attachment,
 * causing early reconnect attempts to fail. Require usable connectivity instead of the first ConnectivityManager callback,
 * which can precede IP assignment. Use NET_CAPABILITY_VALIDATED to establish actual availability.
 *
 * Do not call it when offline (`onNetwork('none')` is ignored by the Web), nor early before the network is usable:
 * that retry would fail and then have to wait for the next one.
 *
 * Notify only on the "restored" and "switched" edges. On the same network the system repeatedly calls
 * `onCapabilitiesChanged` as bandwidth and signal change, and the Web immediately checks its connection and fetches the latest messages on every `onNetwork`
 * (§10.4), so these repeated callbacks must not be forwarded.
 */
internal class NetworkMonitor(
    private val context: Context,
    private val debounceMs: () -> Long,
    private val onAvailable: (NetworkType) -> Unit,
) {

    private val handler = Handler(Looper.getMainLooper())
    private val manager: ConnectivityManager? =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    @Volatile
    var currentType: NetworkType = NetworkType.NONE
        private set

    /** The network the Web has already been notified about. Cleared on disconnect or loss of VALIDATED; notified again on the next restore. */
    @Volatile
    private var notifiedNetwork: Network? = null

    @Volatile
    private var notifiedType: NetworkType? = null

    /** The notification queued in the debounce but not yet sent. Not rescheduled for the same network, otherwise frequent enough callbacks would keep it from ever being sent. */
    @Volatile
    private var pendingNetwork: Network? = null

    @Volatile
    private var pendingType: NetworkType? = null
    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (!isDefault(network)) return
            val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val type = typeOf(caps)
            currentType = if (validated) type else NetworkType.NONE
            if (!validated) {
                // This network became unusable again (e.g. re-authenticating): cancel the pending notification and wait for it to recover.
                forget()
                return
            }
            // Same network and same type already notified: only properties such as bandwidth changed.
            if (network == notifiedNetwork && type == notifiedType) return
            if (network == pendingNetwork && type == pendingType) return
            // Wi-Fi ↔ cellular switches also need a call; debounce 1-2 seconds instead of forwarding every system callback.
            schedule(network, type)
        }

        override fun onLost(network: Network) {
            // With capability-based subscription (API 23), a non-default network disconnecting does not count as offline.
            if (network != notifiedNetwork && network != pendingNetwork && !isDefault(network)) return
            currentType = NetworkType.NONE
            forget()
            // No call needed when offline (§10.4.4).
        }

        override fun onUnavailable() {
            currentType = NetworkType.NONE
        }
    }

    fun start() {
        if (registered) return
        val cm = manager ?: return
        registered = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                cm.registerDefaultNetworkCallback(callback)
            } else {
                // registerDefaultNetworkCallback requires API 24, while minSdk is 23.
                // On Android 6.0 fall back to capability-based subscription: less precise (reports more than the default network), but callbacks still arrive.
                cm.registerNetworkCallback(
                    NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .build(),
                    callback,
                )
            }
            true
        }.onFailure { Log.w(TAG, "Unable to register network callback", it) }.getOrDefault(false)
        // Synchronize initial network state without emitting a callback: §10.4 requires usable connectivity,
        // and __ssgShell may not exist during startup.
        currentType = snapshotType()
    }

    fun stop() {
        if (!registered) return
        registered = false
        handler.removeCallbacksAndMessages(TOKEN)
        runCatching { manager?.unregisterNetworkCallback(callback) }
    }

    /** From API 24 the subscription is the default network itself; API 23 subscribes by capability, so filter manually. */
    private fun isDefault(network: Network): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.N || network == manager?.activeNetwork

    private fun schedule(network: Network, type: NetworkType) {
        handler.removeCallbacksAndMessages(TOKEN)
        pendingNetwork = network
        pendingType = type
        val delay = debounceMs().coerceIn(500, 5_000)
        handler.postAtTime(
            {
                pendingNetwork = null
                pendingType = null
                notifiedNetwork = network
                notifiedType = type
                onAvailable(type)
            },
            TOKEN,
            android.os.SystemClock.uptimeMillis() + delay,
        )
    }

    private fun forget() {
        pendingNetwork = null
        pendingType = null
        notifiedNetwork = null
        notifiedType = null
        handler.removeCallbacksAndMessages(TOKEN)
    }

    private fun snapshotType(): NetworkType {
        val cm = manager ?: return NetworkType.NONE
        val active = cm.activeNetwork ?: return NetworkType.NONE
        val caps = cm.getNetworkCapabilities(active) ?: return NetworkType.NONE
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return NetworkType.NONE
        return typeOf(caps)
    }

    private fun typeOf(caps: NetworkCapabilities): NetworkType = when {
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkType.WIFI
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkType.CELLULAR
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkType.ETHERNET
        // §4 Map other connection types to other.
        else -> NetworkType.OTHER
    }

    private companion object {
        const val TAG = "SsgShell"

        val TOKEN = Any()
    }
}
