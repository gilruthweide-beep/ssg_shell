package com.ssg.ssg_shell

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.os.HandlerCompat

/**
 * §11.1 Native heartbeat and §11.2 liveness monitoring with recovery reloads.
 *
 * Only native code can recover a blocked Web main thread: the interface may appear normal and accept taps
 * or scrolling while messages stop arriving or sending.
 *
 * Use native `Handler` timers. JavaScript timers inside the WebView freeze with the page (§11.1).
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

    /** §11.2.0 Start timing only after the first `eventWebAlive`. */
    private var firstAliveSeen = false
    private var lastAliveAtMs = 0L

    /** §11.2.5 Handle each stall only once; if the page has not recovered, handle it again with 180-second / 600-second backoff. */
    private val backoff = RecoveryBackoff(
        firstBackoffMs = { config().recoveryBackoffFirstMs },
        laterBackoffMs = { config().recoveryBackoffLaterMs },
    )

    /** Whether loading actually started after reload (§11.2.3). */
    private var awaitingPageStart = false

    var reloadCount = 0
        private set
    var recreateCount = 0
        private set
    var lastReloadAtMs: Long? = null
        private set

    fun lastAlive(): Long? = lastAliveAtMs.takeIf { it > 0 }

    // ---------------------------------------------------------------- Lifecycle

    /** §11.1 Start heartbeats in the foreground; §11.2.4 reset the last-alive time on foreground entry. */
    fun onForeground() {
        // The Web application stops eventWebAlive after onBackground and may take 15 seconds to emit it again;
        // without resetting the timestamp, foreground entry could cause a false timeout.
        lastAliveAtMs = System.currentTimeMillis()
        if (running) return
        running = true
        scheduleHeartbeat()
        scheduleAliveCheck()
    }

    /** §11.1 Stop heartbeats in the background; §11.2.4 pause liveness timing and detection. */
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

    // ------------------------------------------------------------------- Heartbeat

    private fun scheduleHeartbeat() {
        val period = config().heartbeatIntervalMs.coerceAtLeast(1_000)
        // Token overload is API 28+; HandlerCompat backports it for minSdk 23.
        HandlerCompat.postDelayed(
            handler,
            { if (running) { callWeb("onHeartbeat"); scheduleHeartbeat() } },
            TOKEN_HEARTBEAT,
            period,
        )
    }

    // --------------------------------------------------------------- Liveness monitoring

    private fun scheduleAliveCheck() {
        // Token overload is API 28+; HandlerCompat backports it for minSdk 23.
        HandlerCompat.postDelayed(
            handler,
            { if (running) { checkAlive(); scheduleAliveCheck() } },
            TOKEN_ALIVE,
            CHECK_PERIOD_MS,
        )
    }

    /** §3.1 `eventWebAlive` arrives every 15 seconds in the foreground. */
    fun onWebAlive() {
        val now = System.currentTimeMillis()
        firstAliveSeen = true
        lastAliveAtMs = now
        if (backoff.onAlive(now)) {
            // The first alive since the last handling. The backoff window stays: this one usually comes from the
            // freshly loaded page, and only outliving the whole window counts as recovery (see RecoveryBackoff).
            Log.i(TAG, "eventWebAlive received again after handling a stall")
            awaitingPageStart = false
            handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
        }
    }

    private fun checkAlive() {
        // §11.2.0 Never declare a stall before the first one arrives; otherwise, with native up first and the Web not yet sending,
        // it would reload every 60 seconds. Exception: a stall was handled and no alive has arrived since (recreation clears
        // firstAliveSeen). This page did send alive before, so keep watching and let the backoff window prevent a loop.
        if (!firstAliveSeen && !backoff.awaitingAlive) return
        // A reload was just issued; these 10 seconds belong to TOKEN_RELOAD_CONFIRM.
        if (awaitingPageStart) return
        val now = System.currentTimeMillis()
        val silence = now - lastAliveAtMs
        if (silence <= config().aliveTimeoutMs) return
        onStallDetected(silence)
    }

    private fun onStallDetected(silenceMs: Long) {
        val now = System.currentTimeMillis()
        val decision = backoff.onStall(now)
        if (decision is RecoveryBackoff.Decision.Throttled && !decision.firstReport) return

        emit(
            ShellEventType.STALL_DETECTED,
            "No eventWebAlive for ${silenceMs}ms",
            mapOf("silenceMs" to silenceMs.toString()),
        )
        if (decision is RecoveryBackoff.Decision.Throttled) {
            // §11.2.5 The page has not recovered since the last handling: wait for the backoff window to expire before handling again, to avoid a reload loop.
            emit(
                ShellEventType.RECOVERY_THROTTLED,
                "Backing off; next handling allowed in ${decision.waitMs}ms",
                mapOf("waitMs" to decision.waitMs.toString()),
            )
            return
        }
        decision as RecoveryBackoff.Decision.Recover

        // §11.2.6 Write a local log entry before and after each reload / recreation.
        Log.w(TAG, "Stall detected (silent ${silenceMs}ms, attempt ${decision.attempt}); reloading")
        reloadCount += 1
        lastReloadAtMs = now
        awaitingPageStart = true
        reload()
        emit(
            ShellEventType.RELOAD_ISSUED,
            "Recovery attempt ${decision.attempt}; next one no earlier than ${decision.backoffMs}ms from now",
            mapOf(
                "attempt" to decision.attempt.toString(),
                "backoffMs" to decision.backoffMs.toString(),
            ),
        )

        // §11.2.3 If loading does not start within 10 seconds of reload, destroy and recreate the WebView.
        // When the page main thread is blocked, WebKit may queue reload behind the stuck JavaScript.
        // Token overload is API 28+; HandlerCompat backports it for minSdk 23.
        HandlerCompat.postDelayed(
            handler,
            {
                if (awaitingPageStart) {
                    Log.w(TAG, "Reload did not start (no onPageStarted within ${config().reloadConfirmTimeoutMs}ms); recreating WebView")
                    awaitingPageStart = false
                    recreateCount += 1
                    recreate()
                }
            },
            TOKEN_RELOAD_CONFIRM,
            config().reloadConfirmTimeoutMs.coerceAtLeast(1_000),
        )
    }

    /** §11.2.3 Track whether reload actually started loading. */
    fun onPageStarted() {
        if (!awaitingPageStart) return
        awaitingPageStart = false
        handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
        Log.i(TAG, "Reload started (onPageStarted)")
    }

    /**
     * Reload, recreation, and refresh after logout restart Web initialization;
     * reset eventWebAlive timing too, avoiding an immediate second timeout.
     */
    fun onPageLoadStartedExternally() {
        lastAliveAtMs = System.currentTimeMillis()
    }

    /**
     * The WebView instance was replaced: start collecting alive again, but keep the backoff window.
     *
     * When the watchdog itself triggered the recreation, [checkAlive] does not stop because firstAliveSeen was cleared;
     * if the new page is still silent, handle it again once the backoff window expires (§11.2.5).
     */
    fun onWebViewRecreated() {
        firstAliveSeen = false
        lastAliveAtMs = System.currentTimeMillis()
        awaitingPageStart = false
        handler.removeCallbacksAndMessages(TOKEN_RELOAD_CONFIRM)
    }

    private companion object {
        const val TAG = "SsgShell"

        /** Poll more often than aliveTimeout to detect a timeout within five seconds. */
        const val CHECK_PERIOD_MS = 5_000L

        val TOKEN_HEARTBEAT = Any()
        val TOKEN_ALIVE = Any()
        val TOKEN_RELOAD_CONFIRM = Any()
    }
}
