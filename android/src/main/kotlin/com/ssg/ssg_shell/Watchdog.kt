package com.ssg.ssg_shell

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * §11.1 原生心跳 + §11.2 存活监测与兜底 reload。
 *
 * 这是唯一能从主线程彻底卡死里恢复的机制 —— 那种状态下只有原生看得见：界面正常、能点
 * 能滑，但消息不进不出。
 *
 * 全部用原生 `Handler` 定时器。用 WebView 里的 JS 定时器会被一起冻住，等于没做（§11.1）。
 */
internal class Watchdog(
    private val config: () -> ShellConfig,
    private val callWeb: (String) -> Unit,
    private val reload: () -> Unit,
    private val recreate: () -> Unit,
    private val emit: (ShellEventType, String?, Map<String, String>) -> Unit,
) {

    private val handler = Handler(Looper.getMainLooper())

    private var running = false

    /** §11.2.0 收到第一条 `eventWebAlive` 之后才开始计时。 */
    private var firstAliveSeen = false
    private var lastAliveAtMs = 0L

    /** §11.2.5 同一次卡死只处理一次，页面恢复后才允许下一次。 */
    private var recoveryInProgress = false
    private var recoveryAttempts = 0
    private var nextRecoveryAllowedAtMs = 0L

    /** reload 之后有没有真的开始加载（§11.2.3）。 */
    private var awaitingPageStart = false

    var reloadCount = 0
        private set
    var recreateCount = 0
        private set
    var lastReloadAtMs: Long? = null
        private set

    fun lastAlive(): Long? = lastAliveAtMs.takeIf { it > 0 }

    // ---------------------------------------------------------------- 生命周期

    /** §11.1 进前台：心跳开始；§11.2.4 回前台把「最后收到时间」重置为当前。 */
    fun onForeground() {
        // Web 在 onBackground 后停发 eventWebAlive，回前台要等下一个 15 秒周期，
        // 不重置会被误判卡死。
        lastAliveAtMs = System.currentTimeMillis()
        if (running) return
        running = true
        scheduleHeartbeat()
        scheduleAliveCheck()
    }

    /** §11.1 进后台：心跳停止；§11.2.4 后台期间不计时、不判定。 */
    fun onBackground() {
        running = false
        handler.removeCallbacksAndMessages(TOKEN_HEARTBEAT)
        handler.removeCallbacksAndMessages(TOKEN_ALIVE)
        handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
        awaitingPageStart = false
    }

    fun dispose() {
        onBackground()
    }

    // ------------------------------------------------------------------- 心跳

    private fun scheduleHeartbeat() {
        val period = config().heartbeatIntervalMs.coerceAtLeast(1_000)
        handler.postDelayed(
            { if (running) { callWeb("onHeartbeat"); scheduleHeartbeat() } },
            TOKEN_HEARTBEAT,
            period,
        )
    }

    // --------------------------------------------------------------- 存活监测

    private fun scheduleAliveCheck() {
        handler.postDelayed(
            { if (running) { checkAlive(); scheduleAliveCheck() } },
            TOKEN_ALIVE,
            CHECK_PERIOD_MS,
        )
    }

    /** §3.1 `eventWebAlive`：前台每 15 秒一次。 */
    fun onWebAlive() {
        val now = System.currentTimeMillis()
        firstAliveSeen = true
        lastAliveAtMs = now
        if (recoveryInProgress) {
            // 页面恢复了，解除「同一次卡死」的锁并清掉退避计数。
            Log.i(TAG, "页面已恢复（收到 eventWebAlive），解除恢复锁")
            recoveryInProgress = false
            recoveryAttempts = 0
            nextRecoveryAllowedAtMs = 0
            awaitingPageStart = false
            handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
        }
    }

    private fun checkAlive() {
        // §11.2.0 收到第一条之前永远不判定卡死，否则原生先上线、Web 还没发，
        // 会每 60 秒 reload 一次。
        if (!firstAliveSeen) return
        val now = System.currentTimeMillis()
        val silence = now - lastAliveAtMs
        if (silence <= config().aliveTimeoutMs) return
        onStallDetected(silence)
    }

    private fun onStallDetected(silenceMs: Long) {
        val now = System.currentTimeMillis()
        emit(
            ShellEventType.STALL_DETECTED,
            "已 ${silenceMs}ms 未收到 eventWebAlive",
            mapOf("silenceMs" to silenceMs.toString()),
        )

        if (recoveryInProgress) return // §11.2.5 同一次卡死只处理一次
        if (now < nextRecoveryAllowedAtMs) {
            // §11.2.5 连续失败要退避，不能进 reload 循环。
            emit(
                ShellEventType.RECOVERY_THROTTLED,
                "退避中，${nextRecoveryAllowedAtMs - now}ms 后才允许下一次处理",
                mapOf("waitMs" to (nextRecoveryAllowedAtMs - now).toString()),
            )
            return
        }

        recoveryInProgress = true
        recoveryAttempts += 1
        // §11.2.5 第一次处理后等 180 秒，之后 600 秒。
        val backoff = if (recoveryAttempts <= 1) {
            config().recoveryBackoffFirstMs
        } else {
            config().recoveryBackoffLaterMs
        }
        nextRecoveryAllowedAtMs = now + backoff

        // §11.2.6 reload / 重建前后各记一条本地日志。
        Log.w(TAG, "判定卡死（静默 ${silenceMs}ms，第 $recoveryAttempts 次），执行 reload")
        reloadCount += 1
        lastReloadAtMs = now
        awaitingPageStart = true
        reload()
        emit(
            ShellEventType.RELOAD_ISSUED,
            "第 $recoveryAttempts 次恢复，下次最早 ${backoff}ms 后",
            mapOf(
                "attempt" to recoveryAttempts.toString(),
                "backoffMs" to backoff.toString(),
            ),
        )

        // §11.2.3 reload 后 10 秒内页面没有开始加载 → 销毁并重建。
        // 页面主线程卡死时 WebKit 会把 reload 排在卡住的 JS 后面，reload 不生效。
        handler.postDelayed(
            {
                if (awaitingPageStart) {
                    Log.w(TAG, "reload 未生效（${config().reloadConfirmTimeoutMs}ms 内没有 onPageStarted），重建 WebView")
                    awaitingPageStart = false
                    recreateCount += 1
                    recreate()
                }
            },
            TOKEN_RELOAD_CONFIRM,
            config().reloadConfirmTimeoutMs.coerceAtLeast(1_000),
        )
    }

    /** §11.2.3 判断 reload 到底有没有生效。 */
    fun onPageStarted() {
        if (!awaitingPageStart) return
        awaitingPageStart = false
        handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
        Log.i(TAG, "reload 已生效（onPageStarted）")
    }

    /**
     * 页面被重新加载（reload、重建、被踢下线后刷新）时，Web 会重新走一遍初始化，
     * `eventWebAlive` 的计时要跟着重置，否则刚 reload 完就又判定一次卡死。
     */
    fun onPageLoadStartedExternally() {
        lastAliveAtMs = System.currentTimeMillis()
    }

    /** WebView 实例被换掉：重新开始攒 alive，但保留退避窗口。 */
    fun onWebViewRecreated() {
        firstAliveSeen = false
        lastAliveAtMs = System.currentTimeMillis()
        awaitingPageStart = false
        handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
    }

    /**
     * 带 token 的延迟投递，用于按 token 精确取消。
     *
     * `Handler.postDelayed(Runnable, Object, long)` 要 API 28，这里 minSdk 是 23，
     * 所以走 API 1 就有的 `postAtTime`。
     */
    private fun Handler.postDelayed(action: () -> Unit, token: Any, delayMs: Long) {
        postAtTime({ action() }, token, SystemClock.uptimeMillis() + delayMs)
    }

    private companion object {
        const val TAG = "SsgShell"

        /** 判定周期。比 aliveTimeout 细，保证超时后最多 5 秒内被发现。 */
        const val CHECK_PERIOD_MS = 5_000L

        val TOKEN_HEARTBEAT = Any()
        val TOKEN_ALIVE = Any()
        val TOKEN_RELOAD_CONFIRM = Any()
    }
}
