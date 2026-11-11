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
 * §10.4 网络恢复单独通知。
 *
 * 回前台瞬间网络往往还没真正可用（Wi-Fi 重连、蜂窝重新附着要几秒），此时 Web 发起的重连
 * 会失败。所以判据是「能发出请求」，不是 `ConnectivityManager` 的第一跳回调 —— 那时常常
 * 还没拿到 IP。这里用 `NET_CAPABILITY_VALIDATED` 作为「真的通了」的判据。
 *
 * 断网时不调（`onNetwork('none')` 会被 Web 忽略），也不在网络还没通时提前调：
 * 那次重试会失败，之后要等下一次重试。
 *
 * 只在「恢复」和「切换」这两个边沿上通知。同一条网络上系统会因为带宽、信号变化反复回调
 * `onCapabilitiesChanged`，而 Web 每收到一次 `onNetwork` 都会立刻检查连接并拉取最新消息
 * （§10.4），这些重复回调不能转发。
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

    /** 已经通知过 Web 的那条网络。断开或失去 VALIDATED 时清空，下次恢复重新通知。 */
    @Volatile
    private var notifiedNetwork: Network? = null

    @Volatile
    private var notifiedType: NetworkType? = null

    /** 已经排进去抖、还没发出去的那一次。同一条不重排，否则回调够密的话永远发不出去。 */
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
                // 这条网络又不通了（比如重新走认证）：撤掉还没发出去的通知，等它恢复。
                forget()
                return
            }
            // 同一条网络、同一种类型已经通知过：只是带宽之类的属性变了。
            if (network == notifiedNetwork && type == notifiedType) return
            if (network == pendingNetwork && type == pendingType) return
            // Wi-Fi ↔ 蜂窝切换也要调；去抖 1~2 秒，不要每个系统回调都转发。
            schedule(network, type)
        }

        override fun onLost(network: Network) {
            // 按能力订阅时（API 23）非默认网络断开不算断网。
            if (network != notifiedNetwork && network != pendingNetwork && !isDefault(network)) return
            currentType = NetworkType.NONE
            forget()
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                cm.registerDefaultNetworkCallback(callback)
            } else {
                // registerDefaultNetworkCallback 要 API 24，而 minSdk 是 23。
                // Android 6.0 上退到按能力订阅，精度差一点（不只报默认网络），但不至于收不到。
                cm.registerNetworkCallback(
                    NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .build(),
                    callback,
                )
            }
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

    /** API 24 起订阅的就是默认网络；API 23 是按能力订阅的，要自己筛。 */
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
        // §4 其他取值归为 other。
        else -> NetworkType.OTHER
    }

    private companion object {
        const val TAG = "SsgShell"

        val TOKEN = Any()
    }
}
