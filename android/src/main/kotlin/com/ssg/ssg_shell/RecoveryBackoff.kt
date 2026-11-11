package com.ssg.ssg_shell

/**
 * §11.2.5 同一次卡死只处理一次；连续失败要退避：第一次处理后等 180 秒，之后 600 秒。
 *
 * 「页面恢复」的判据是又收到了 `eventWebAlive`。reload / 重建之后一直收不到属于连续失败：
 * 退避窗口到期后要再处理一次，而不是把这次卡死永久锁住 —— §12.4「退避」验的就是这条。
 *
 * 纯逻辑，不碰定时器，时间由调用方传进来。
 */
internal class RecoveryBackoff(
    private val firstBackoffMs: () -> Long,
    private val laterBackoffMs: () -> Long,
) {

    sealed interface Decision {
        /** 现在处理。[attempt] 从 1 起；[backoffMs] 是这次处理之后要等多久才允许下一次。 */
        data class Recover(val attempt: Int, val backoffMs: Long) : Decision

        /** 还在退避窗口里。[firstReport] 只在本窗口第一次命中时为 true，用来给日志去重。 */
        data class Throttled(val waitMs: Long, val firstReport: Boolean) : Decision
    }

    /** 自上次页面恢复以来处理过几次。 */
    var attempts = 0
        private set

    private var nextAllowedAtMs = 0L
    private var throttleReported = false

    /** 已经处理过、但页面还没恢复。 */
    val recovering: Boolean get() = attempts > 0

    fun onStall(nowMs: Long): Decision {
        if (nowMs < nextAllowedAtMs) {
            val first = !throttleReported
            throttleReported = true
            return Decision.Throttled(nextAllowedAtMs - nowMs, first)
        }
        attempts += 1
        val backoff = if (attempts <= 1) firstBackoffMs() else laterBackoffMs()
        nextAllowedAtMs = nowMs + backoff
        throttleReported = false
        return Decision.Recover(attempts, backoff)
    }

    /** 收到 `eventWebAlive`：页面恢复，退避清零。返回之前是否处在恢复当中。 */
    fun onRecovered(): Boolean {
        val wasRecovering = attempts > 0
        attempts = 0
        nextAllowedAtMs = 0
        throttleReported = false
        return wasRecovering
    }
}
