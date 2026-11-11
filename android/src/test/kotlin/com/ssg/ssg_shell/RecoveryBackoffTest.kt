package com.ssg.ssg_shell

import com.ssg.ssg_shell.RecoveryBackoff.Decision
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

/** §11.2.5 / §12.4「退避」：持续卡死时第一次处理后隔 180 秒再处理，之后隔 600 秒。 */
class RecoveryBackoffTest {

    private val backoff = RecoveryBackoff({ 180_000L }, { 600_000L })

    @Test
    fun `第一次卡死立刻处理`() {
        assertEquals(Decision.Recover(attempt = 1, backoffMs = 180_000), backoff.onStall(0))
        assertTrue(backoff.awaitingAlive)
    }

    @Test
    fun `页面一直没恢复时 180 秒后再处理 之后每 600 秒一次`() {
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
    fun `退避窗口内只报告一次`() {
        backoff.onStall(0)

        assertEquals(Decision.Throttled(waitMs = 175_000, firstReport = true), backoff.onStall(5_000))
        assertEquals(Decision.Throttled(waitMs = 170_000, firstReport = false), backoff.onStall(10_000))

        // 下一个窗口重新报告一次。
        backoff.onStall(180_000)
        assertEquals(
            Decision.Throttled(waitMs = 595_000, firstReport = true),
            backoff.onStall(185_000),
        )
    }

    /** §12.4 的验收流程：重建后的页面先发了 alive，随后又被卡死。 */
    @Test
    fun `重建后页面发过 alive 又卡死 仍然要等满退避窗口`() {
        backoff.onStall(0)

        assertTrue(backoff.onAlive(5_000))
        assertFalse(backoff.awaitingAlive)

        assertEquals(Decision.Throttled(waitMs = 110_000, firstReport = true), backoff.onStall(70_000))
        assertEquals(Decision.Recover(attempt = 2, backoffMs = 600_000), backoff.onStall(180_000))
    }

    @Test
    fun `页面撑过整个窗口后还活着 下一次卡死按第一次算`() {
        backoff.onStall(0)
        backoff.onAlive(5_000)
        backoff.onAlive(180_000)

        assertEquals(Decision.Recover(attempt = 1, backoffMs = 180_000), backoff.onStall(250_000))
    }

    @Test
    fun `没在等恢复时 onAlive 返回 false`() {
        assertFalse(backoff.onAlive(0))

        backoff.onStall(1_000)
        assertTrue(backoff.onAlive(2_000))
        assertFalse(backoff.onAlive(17_000))
    }
}
