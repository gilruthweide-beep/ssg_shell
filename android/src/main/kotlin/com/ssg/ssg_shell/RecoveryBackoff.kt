package com.ssg.ssg_shell

/**
 * §11.2.5 Handle each stall only once; back off on consecutive failures: wait 180 seconds after the first handling, then 600 seconds.
 *
 * Rules:
 * - After one handling, nothing is handled again until the backoff window expires, **whether or not the page sent
 *   `eventWebAlive` in the meantime**. A recreated page sends alive as soon as it loads; treating that as "recovered"
 *   and resetting the backoff would reload a page that hangs again right after a rebuild every minute, and §12.4
 *   "Backoff" would fail.
 * - If the page is still (or again) stalled when the window expires, handle it again and switch to the 600-second
 *   window. A page that never sends alive is handled again too, so the stall is never locked out permanently.
 * - Only a page that outlived the whole window and still sends alive has really recovered: the counter resets and the
 *   next stall counts as the first.
 *
 * Pure logic with no timers; the caller passes in the time.
 */
internal class RecoveryBackoff(
    private val firstBackoffMs: () -> Long,
    private val laterBackoffMs: () -> Long,
) {

    sealed interface Decision {
        /** Handle now. [attempt] starts at 1; [backoffMs] is how long to wait after this handling before the next one is allowed. */
        data class Recover(val attempt: Int, val backoffMs: Long) : Decision

        /** Still inside the backoff window. [firstReport] is true only on the first hit in this window, used to deduplicate logs. */
        data class Throttled(val waitMs: Long, val firstReport: Boolean) : Decision
    }

    /** Consecutive handlings. Resets once the page outlives a full backoff window. */
    var attempts = 0
        private set

    /** Handled, and no `eventWebAlive` has arrived since. */
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

    /** `eventWebAlive` received. Returns whether this is the first one since the last handling. */
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
