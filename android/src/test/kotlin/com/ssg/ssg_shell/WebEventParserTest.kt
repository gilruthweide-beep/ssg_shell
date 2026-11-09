package com.ssg.ssg_shell

import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.Test

/**
 * §3.1 payload 解析。线上能收到三种形状，都得吃下去。
 *
 * 纯 JVM 测试：只用到 org.json，不需要 Android 沙箱。
 */
class WebEventParserTest {

    @Test
    fun `规范示例的形状`() {
        val event = WebEventParser.parse(
            "eventLogin",
            """{"eventName":"login","params":{"channelCode":"ch001","uid":"1571277787","timestamp":"1762000000000"}}""",
        )

        requireNotNull(event)
        assertEquals(WebEventName.LOGIN, event.name)
        assertEquals("login", event.rawName)
        assertEquals("1571277787", event.uid)
        assertEquals("ch001", event.channelCode)
        assertEquals("1762000000000", event.webTimestamp)
    }

    @Test
    fun `事件名从 handler 名推断`() {
        val event = WebEventParser.parse("eventWebReady", """{"timestamp":"1762000000000"}""")

        requireNotNull(event)
        assertEquals(WebEventName.WEB_READY, event.name)
        assertEquals("webReady", event.rawName)
    }

    @Test
    fun `payload 就是 params 本身`() {
        val event = WebEventParser.parse("eventChatOpen", """{"chatId":"-100123"}""")

        requireNotNull(event)
        assertEquals(WebEventName.CHAT_OPEN, event.name)
        assertEquals("-100123", event.chatId)
    }

    @Test
    fun `count 是数字时也能解析成数字`() {
        val numeric = WebEventParser.parse("eventUnreadCount", """{"params":{"count":7}}""")
        val text = WebEventParser.parse("eventUnreadCount", """{"params":{"count":"7"}}""")

        assertEquals(7L, numeric?.unreadCount)
        assertEquals(7L, text?.unreadCount)
    }

    @Test
    fun `Web 将来新增的事件不丢，原始名留在 rawName 里`() {
        val event = WebEventParser.parse(null, """{"eventName":"somethingNew","params":{"a":"1"}}""")

        requireNotNull(event)
        assertEquals(WebEventName.UNKNOWN, event.name)
        assertEquals("somethingNew", event.rawName)
        assertEquals("1", event.params["a"])
    }

    @Test
    fun `单参版本且 payload 里没有 eventName 时只能放弃`() {
        assertNull(WebEventParser.parse(null, """{"uid":"1"}"""))
    }

    @Test
    fun `payload 不是 JSON 时按 handler 名兜住`() {
        val event = WebEventParser.parse("eventWebAlive", "not json")

        requireNotNull(event)
        assertEquals(WebEventName.WEB_ALIVE, event.name)
        assertEquals(emptyMap(), event.params)
    }

    @Test
    fun `十个 handler 名都能映射到对应事件`() {
        val expected = mapOf(
            "eventWebReady" to WebEventName.WEB_READY,
            "eventRegister" to WebEventName.REGISTER,
            "eventLogin" to WebEventName.LOGIN,
            "eventLogout" to WebEventName.LOGOUT,
            "eventMessageSent" to WebEventName.MESSAGE_SENT,
            "eventWebAlive" to WebEventName.WEB_ALIVE,
            "eventChatOpen" to WebEventName.CHAT_OPEN,
            "eventChatClose" to WebEventName.CHAT_CLOSE,
            "eventChatRead" to WebEventName.CHAT_READ,
            "eventUnreadCount" to WebEventName.UNREAD_COUNT,
        )

        expected.forEach { (handler, name) ->
            assertEquals(name, WebEventParser.nameOf(WebEventParser.handlerToEventName(handler)), handler)
        }
    }
}
