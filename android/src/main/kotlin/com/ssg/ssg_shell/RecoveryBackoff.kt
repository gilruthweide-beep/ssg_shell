package com.ssg.ssg_shell

/**
 * §11.2.5 同一次卡死只处理一次；连续失败要退避：第一次处理后等 180 秒，之后 600 秒。
 *
 * 规则：
 * - 处理过一次之后，退避窗口到期之前不再处理 —— **不管这期间页面有没有发过
 *   `eventWebAlive`**。重建出来的页面一加载就会发一条 alive；拿它当「已恢复」把退避清零
 *   的话，重建后很快又卡死的页面每分钟都会被 reload 一次，§12.4「退避」也就验不过。
 * - 窗口到期时页面还卡着（或者又卡了），再处理一次，窗口换成 600 秒。一直收不到 alive
 *   也一样会再处理，不会把这次卡死永久锁住。
 * - 页面撑过了整个窗口、之后还在发 alive，才算真正恢复：计数清零，下一次卡死按第一次算。
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

    /** 连续处理了几次。页面撑过一个完整的退避窗口后清零。 */
    var attempts = 0
        private set

    /** 处理过、之后还一条 `eventWebAlive` 都没收到。 */
    var awaitingAlive = false
        private set

    private var nextAllowedAtMs = 0L
    private var throttleReported = false

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
        awaitingAlive = true
        return Decision.Recover(attempts, backoff)
    }

    /** 收到 `eventWebAlive`。返回这是不是处理之后收到的第一条。 */
    fun onAlive(nowMs: Long): Boolean {
        val firstSinceRecovery = awaitingAlive
        awaitingAlive = false
        if (attempts > 0 && nowMs >= nextAllowedAtMs) {
            attempts = 0
            nextAllowedAtMs = 0
            throttleReported = false
        }
        return firstSinceRecovery
    }
}
