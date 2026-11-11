package com.ssg.ssg_shell

import com.ssg.ssg_shell.DiagnosticsGesture.Action
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

/** §11.6 The hidden diagnostics entry opens only for a still three-finger hold. */
class DiagnosticsGestureTest {

    private val gesture = DiagnosticsGesture(slopPx = 30f)

    private fun points(vararg xy: Float) =
        xy.filterIndexed { i, _ -> i % 2 == 0 }.toFloatArray() to xy.filterIndexed { i, _ -> i % 2 == 1 }.toFloatArray()

    private fun down(vararg xy: Float): Action {
        val (xs, ys) = points(*xy)
        return gesture.onPointersChanged(xs, ys)
    }

    private fun move(vararg xy: Float): Action {
        val (xs, ys) = points(*xy)
        return gesture.onMove(xs, ys)
    }

    @Test
    fun `a still three-finger hold opens diagnostics`() {
        assertEquals(Action.None, down(10f, 10f))
        assertEquals(Action.None, down(10f, 10f, 50f, 10f))
        assertEquals(Action.Arm, down(10f, 10f, 50f, 10f, 90f, 10f))
        assertEquals(Action.None, move(12f, 11f, 52f, 9f, 91f, 12f))
        assertTrue(gesture.onHoldElapsed())
        assertFalse(gesture.onHoldElapsed(), "fires once per hold")
    }

    @Test
    fun `lifting a finger or adding a fourth cancels`() {
        down(10f, 10f, 50f, 10f, 90f, 10f)
        assertEquals(Action.Disarm, down(10f, 10f, 50f, 10f))
        assertFalse(gesture.onHoldElapsed())

        down(10f, 10f, 50f, 10f, 90f, 10f)
        assertEquals(Action.Disarm, down(10f, 10f, 50f, 10f, 90f, 10f, 130f, 10f))
        assertFalse(gesture.onHoldElapsed())
    }

    @Test
    fun `a three-finger scroll or pinch is not a hold`() {
        down(10f, 10f, 50f, 10f, 90f, 10f)
        assertEquals(Action.Disarm, move(10f, 60f, 50f, 60f, 90f, 60f))
        assertFalse(gesture.onHoldElapsed())
    }

    @Test
    fun `the touch stream ending cancels`() {
        down(10f, 10f, 50f, 10f, 90f, 10f)
        assertEquals(Action.Disarm, gesture.onEnd())
        assertEquals(Action.None, gesture.onEnd())
        assertFalse(gesture.onHoldElapsed())
    }

    @Test
    fun `one or two fingers never arm`() {
        assertEquals(Action.None, down(10f, 10f))
        assertEquals(Action.None, move(200f, 200f))
        assertEquals(Action.None, gesture.onEnd())
        assertFalse(gesture.onHoldElapsed())
    }
}
