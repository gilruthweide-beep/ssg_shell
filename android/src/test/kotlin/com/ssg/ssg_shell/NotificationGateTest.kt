package com.ssg.ssg_shell

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Test

/** §5.4 前台抑制与角标。规范点名的几个坑全在这里钉住。 */
class NotificationGateTest {

    private val gate = NotificationGate()

    @Test
    fun `前台且停在该会话时抑制`() {
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
    fun `后台一律不抑制 —— 切后台不会发 chatClose，tracked 还留着`() {
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
    fun `停在会话列表或其他会话时照常展示`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress("-100123", appInForeground = true, enabled = true))

        gate.onChatClose("1571275627")
        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = true))
    }

    @Test
    fun `切到其他会话时，旧会话的 chatClose 不会误清掉新会话`() {
        gate.onChatOpen("A")
        // Web 先发新会话的 chatOpen，再发旧会话的 chatClose（顺序不保证）。
        gate.onChatOpen("B")
        gate.onChatClose("A")

        assertEquals("B", gate.trackedChatId)
        assertTrue(gate.shouldSuppress("B", appInForeground = true, enabled = true))
    }

    @Test
    fun `页面重新加载要清掉 tracked —— reload 不会发 chatClose`() {
        gate.onChatOpen("1571275627")
        gate.onPageLoadStarted()

        assertNull(gate.trackedChatId)
        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = true))
    }

    @Test
    fun `推送里没有 chat_id 时不抑制`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress(null, appInForeground = true, enabled = true))
        assertFalse(gate.shouldSuppress("", appInForeground = true, enabled = true))
    }

    @Test
    fun `开关关掉就完全不抑制`() {
        gate.onChatOpen("1571275627")

        assertFalse(gate.shouldSuppress("1571275627", appInForeground = true, enabled = false))
    }

    @Test
    fun `角标不接受负数，0 表示清零`() {
        gate.onUnreadCount(12)
        assertEquals(12, gate.badgeCount)

        gate.onUnreadCount(0)
        assertEquals(0, gate.badgeCount)

        gate.onUnreadCount(-3)
        assertEquals(0, gate.badgeCount)
    }
}
