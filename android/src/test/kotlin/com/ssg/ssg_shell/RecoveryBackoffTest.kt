package com.ssg.ssg_shell

import com.ssg.ssg_shell.RecoveryBackoff.Decision
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

/** §11.2.5 / §12.4 "Backoff": during a persistent stall, handle again 180 seconds after the first handling, then every 600 seconds. */
class RecoveryBackoffTest {

    private val backoff = RecoveryBackoff({ 180_000L }, { 600_000L })

    @Test
    fun `first stall is handled immediately`() {
        assertEquals(Decision.Recover(attempt = 1, backoffMs = 180_000), backoff.onStall(0))
        assertTrue(backoff.awaitingAlive)
    }

    @Test
    fun `when the page never recovers handle again after 180 seconds then every 600 seconds`() {
        backoff.onStall(0)

        assertTrue(backoff.onStall(179_999) is Decision.Throttled)
        assertEquals(Decision.Recover(attempt = 2, backoffMs = 600_000), backoff.onStall(180_000))

        assertTrue(backoff.onStall(180_000 + 599_999) is Decision.Throttled)
        assertEquals(
            Decision.Recover(attempt = 3, backoffMs = 600_000),
            backoff.onStall(180_000 + 600_000),
        )
    }

    @Test
    fun `reports only once within a backoff window`() {
        backoff.onStall(0)

        assertEquals(Decision.Throttled(waitMs = 175_000, firstReport = true), backoff.onStall(5_000))
        assertEquals(Decision.Throttled(waitMs = 170_000, firstReport = false), backoff.onStall(10_000))

        // The next window reports once again.
        backoff.onStall(180_000)
        assertEquals(
            Decision.Throttled(waitMs = 595_000, firstReport = true),
            backoff.onStall(185_000),
        )
    }

    /** The §12.4 acceptance sequence: the recreated page sends alive, then hangs again. */
    @Test
    fun `a rebuilt page that sent alive and hangs again still waits out the window`() {
        backoff.onStall(0)

        assertTrue(backoff.onAlive(5_000))
        assertFalse(backoff.awaitingAlive)

        assertEquals(Decision.Throttled(waitMs = 110_000, firstReport = true), backoff.onStall(70_000))
        assertEquals(Decision.Recover(attempt = 2, backoffMs = 600_000), backoff.onStall(180_000))
    }

    @Test
    fun `a page still alive after the whole window resets so the next stall counts as the first`() {
        backoff.onStall(0)
        backoff.onAlive(5_000)
        backoff.onAlive(180_000)

        assertEquals(Decision.Recover(attempt = 1, backoffMs = 180_000), backoff.onStall(250_000))
    }

    @Test
    fun `onAlive returns false when not awaiting recovery`() {
        assertFalse(backoff.onAlive(0))

        backoff.onStall(1_000)
        assertTrue(backoff.onAlive(2_000))
        assertFalse(backoff.onAlive(17_000))
    }
}
