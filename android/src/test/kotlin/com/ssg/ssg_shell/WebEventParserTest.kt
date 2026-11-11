package com.ssg.ssg_shell

import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.Test

/**
 * §3.1 Payload parsing accepts all three observed production shapes.
 *
 * Plain JVM tests using org.json only, without an Android sandbox.
 */
class WebEventParserTest {

    @Test
    fun `parses the specification payload shape`() {
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
    fun `infers event name from handler`() {
        val event = WebEventParser.parse("eventWebReady", """{"timestamp":"1762000000000"}""")

        requireNotNull(event)
        assertEquals(WebEventName.WEB_READY, event.name)
        assertEquals("webReady", event.rawName)
    }

    @Test
    fun `accepts params directly as the payload`() {
        val event = WebEventParser.parse("eventChatOpen", """{"chatId":"-100123"}""")

        requireNotNull(event)
        assertEquals(WebEventName.CHAT_OPEN, event.name)
        assertEquals("-100123", event.chatId)
    }

    @Test
    fun `parses numeric count values`() {
        val numeric = WebEventParser.parse("eventUnreadCount", """{"params":{"count":7}}""")
        val text = WebEventParser.parse("eventUnreadCount", """{"params":{"count":"7"}}""")

        assertEquals(7L, numeric?.unreadCount)
        assertEquals(7L, text?.unreadCount)
    }

    @Test
    fun `preserves future Web event names in rawName`() {
        val event = WebEventParser.parse(null, """{"eventName":"somethingNew","params":{"a":"1"}}""")

        requireNotNull(event)
        assertEquals(WebEventName.UNKNOWN, event.name)
        assertEquals("somethingNew", event.rawName)
        assertEquals("1", event.params["a"])
    }

    @Test
    fun `ignores one-argument payloads without eventName`() {
        assertNull(WebEventParser.parse(null, """{"uid":"1"}"""))
    }

    @Test
    fun `uses handler name when payload is not JSON`() {
        val event = WebEventParser.parse("eventWebAlive", "not json")

        requireNotNull(event)
        assertEquals(WebEventName.WEB_ALIVE, event.name)
        assertEquals(emptyMap(), event.params)
    }

    @Test
    fun `maps all ten handler names to their events`() {
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
