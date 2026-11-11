package com.ssg.ssg_shell

/**
 * §11.6 Hidden diagnostics entry: hold exactly three fingers still on the IM screen for [HOLD_MS].
 *
 * Pure logic so it can be unit tested; [ImActivity] feeds it touch summaries and owns the timer. It only
 * observes touches and never consumes them, so the Web page keeps receiving every event.
 */
internal class DiagnosticsGesture(private val slopPx: Float) {

    enum class Action {
        /** Start (or restart) the hold timer. */
        Arm,

        /** Stop a pending hold timer. */
        Disarm,

        None,
    }

    private var armed = false
    private var startX = FloatArray(0)
    private var startY = FloatArray(0)

    /**
     * A finger went down or up. [xs] / [ys] are the positions of the pointers still down, including a new one.
     * Exactly three pointers arm the gesture; any other count disarms it.
     */
    fun onPointersChanged(xs: FloatArray, ys: FloatArray): Action {
        if (xs.size == POINTERS) {
            startX = xs.copyOf()
            startY = ys.copyOf()
            armed = true
            return Action.Arm
        }
        return disarm()
    }

    /** Pointers moved. A scroll or pinch with three fingers is not a hold. */
    fun onMove(xs: FloatArray, ys: FloatArray): Action {
        if (!armed || xs.size != startX.size) return Action.None
        for (i in xs.indices) {
            val dx = xs[i] - startX[i]
            val dy = ys[i] - startY[i]
            if (dx * dx + dy * dy > slopPx * slopPx) return disarm()
        }
        return Action.None
    }

    /** The last finger went up, or the system cancelled the touch stream. */
    fun onEnd(): Action = disarm()

    /** The hold timer fired. Returns whether the diagnostics should open now. */
    fun onHoldElapsed(): Boolean {
        val fire = armed
        armed = false
        return fire
    }

    private fun disarm(): Action {
        if (!armed) return Action.None
        armed = false
        return Action.Disarm
    }

    companion object {
        const val POINTERS = 3
        const val HOLD_MS = 2_000L
    }
}
