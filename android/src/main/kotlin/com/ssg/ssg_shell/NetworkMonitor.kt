package com.ssg.ssg_shell

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * §10.4 网络恢复单独通知。
 *
 * 回前台瞬间网络往往还没真正可用（Wi-Fi 重连、蜂窝重新附着要几秒），此时 Web 发起的重连
 * 会失败。所以判据是「能发出请求」，不是 `ConnectivityManager` 的第一跳回调 —— 那时常常
 * 还没拿到 IP。这里用 `NET_CAPABILITY_VALIDATED` 作为「真的通了」的判据。
 *
 * 断网时不调（`onNetwork('none')` 会被 Web 忽略），也不在网络还没通时提前调：
 * 那次重试会失败，之后要等下一次重试。
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

    private var lastNotifiedType: NetworkType? = null
    private var lastNotifiedAtMs = 0L
    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val type = typeOf(caps)
            currentType = if (validated) type else NetworkType.NONE
            if (!validated) return
            // Wi-Fi ↔ 蜂窝切换也要调；去抖 1~2 秒，不要每个系统回调都转发。
            schedule(type)
        }

        override fun onLost(network: Network) {
            currentType = NetworkType.NONE
            lastNotifiedType = null
            handler.removeCallbacksAndMessages(TOKEN)
            // 断网时不用调（§10.4.4）。
        }

        override fun onUnavailable() {
            currentType = NetworkType.NONE
        }
    }

    fun start() {
        if (registered) return
        val cm = manager ?: return
        registered = runCatching {
            cm.registerDefaultNetworkCallback(callback)
            true
        }.onFailure { Log.w(TAG, "注册网络回调失败", it) }.getOrDefault(false)
        // 启动时先同步一次当前状态，但不触发回调：§10.4 要求网络真正可用后才调，
        // 启动阶段 Web 还没挂出 __ssgShell。
        currentType = snapshotType()
    }

    fun stop() {
        if (!registered) return
        registered = false
        handler.removeCallbacksAndMessages(TOKEN)
        runCatching { manager?.unregisterNetworkCallback(callback) }
    }

    private fun schedule(type: NetworkType) {
        handler.removeCallbacksAndMessages(TOKEN)
        val delay = debounceMs().coerceIn(500, 5_000)
        handler.postAtTime(
            {
                // 类型变了（Wi-Fi ↔ 蜂窝）一定要通知；类型没变时限一下频率：
                // 系统在同一个网络上会反复回调 onCapabilitiesChanged，去抖只能收掉突发，
                // 收不掉持续的涓流。多调一次对 Web 无害（§10.4 不受重连冷却限制），
                // 只是没必要。
                val now = System.currentTimeMillis()
                val changed = lastNotifiedType != type
                if (changed || now - lastNotifiedAtMs >= MIN_REPEAT_MS) {
                    lastNotifiedType = type
                    lastNotifiedAtMs = now
                    onAvailable(type)
                }
            },
            TOKEN,
            android.os.SystemClock.uptimeMillis() + delay,
        )
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
        // §4 其他取值归为 other。
        else -> NetworkType.OTHER
    }

    private companion object {
        const val TAG = "SsgShell"

        /** 类型没变时的最小通知间隔。 */
        const val MIN_REPEAT_MS = 10_000L

        val TOKEN = Any()
    }
}
