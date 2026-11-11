package com.ssg.ssg_shell

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Test

/** §5.4 Foreground suppression and badge regression coverage for specification edge cases. */
class NotificationGateTest {

    private val gate = NotificationGate()

    @Test
    fun `suppresses the active conversation in the foreground`() {
        gate.onChatOpen("1571275627")

        assertTrue(
            gate.shouldSuppress(
                chatId = "1571275627",
                appInForeground = true,
                enabled = true,
            ),
        )
    }

    @Test
    fun `never suppresses in the background even while the chat remains tracked`() {
        gate.onChatOpen("1571275627")

        assertFalse(
            gate.shouldSuppress(
                chatId = "1571275627",
                appInForeground = false,
                enabled = true,
            ),
        )
    }

    @Test
    fun `displays notifications from the list or another conversation`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress("-100123", appInForeground = true, enabled = true))

        gate.onChatClose("1571275627")
        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = true))
    }

    @Test
    fun `closing the previous conversation preserves the newly opened one`() {
        gate.onChatOpen("A")
        // The Web application may open a new chat before closing the previous one; event order is not guaranteed.
        gate.onChatOpen("B")
        gate.onChatClose("A")

        assertEquals("B", gate.trackedChatId)
        assertTrue(gate.shouldSuppress("B", appInForeground = true, enabled = true))
    }

    @Test
    fun `page loading clears tracked state without requiring chatClose`() {
        gate.onChatOpen("1571275627")
        gate.onPageLoadStarted()

        assertNull(gate.trackedChatId)
        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = true))
    }

    @Test
    fun `does not suppress pushes without chat_id`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress(null, appInForeground = true, enabled = true))
        assertFalse(gate.shouldSuppress("", appInForeground = true, enabled = true))
    }

    @Test
    fun `disabled suppression always allows display`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = false))
    }

    @Test
    fun `badge rejects negative counts and clears at zero`() {
        gate.onUnreadCount(12)
        assertEquals(12, gate.badgeCount)

        gate.onUnreadCount(0)
        assertEquals(0, gate.badgeCount)

        gate.onUnreadCount(-3)
        assertEquals(0, gate.badgeCount)
    }
}
