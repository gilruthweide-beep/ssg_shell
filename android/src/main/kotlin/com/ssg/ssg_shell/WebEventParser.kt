package com.ssg.ssg_shell

import org.json.JSONObject

/**
 * §3.1 Payload parsing.
 *
 * Accept all three payload shapes observed in production:
 *  - `{"eventName":"login","params":{...}}` (the specification example).
 *  - Parameter contents only, with the event inferred from the handler (`postMessage("eventLogin", "{...}")`).
 *  - The entire payload is the params object.
 *
 * Although the specification requires string parameters, the Web application may send count as a number.
 * Use `optString` consistently to obtain decimal text for numeric values too.
 */
internal object WebEventParser {

    /** Map handler names to event names, for example eventWebReady → webReady. */
    fun handlerToEventName(handler: String): String {
        if (!handler.startsWith("event") || handler.length <= "event".length) return handler
        val rest = handler.substring("event".length)
        return rest[0].lowercaseChar() + rest.substring(1)
    }

    fun nameOf(raw: String): WebEventName = when (raw) {
        "webReady" -> WebEventName.WEB_READY
        "register" -> WebEventName.REGISTER
        "login" -> WebEventName.LOGIN
        "logout" -> WebEventName.LOGOUT
        "messageSent" -> WebEventName.MESSAGE_SENT
        "webAlive" -> WebEventName.WEB_ALIVE
        "chatOpen" -> WebEventName.CHAT_OPEN
        "chatClose" -> WebEventName.CHAT_CLOSE
        "chatRead" -> WebEventName.CHAT_READ
        "unreadCount" -> WebEventName.UNREAD_COUNT
        else -> WebEventName.UNKNOWN
    }

    /**
     * @param handlerName The iOS message handler name or first argument of Android's two-argument overload;
     *                    pass null for the one-argument overload, which must infer the event from the payload.
     */
    fun parse(handlerName: String?, payload: String?): WebEvent? {
        val json = payload?.let { runCatching { JSONObject(it) }.getOrNull() }
        val fromPayload = json?.optString("eventName").orEmpty()
        val raw = when {
            fromPayload.isNotBlank() -> fromPayload
            handlerName != null -> handlerToEventName(handlerName)
            else -> return null
        }

        // Parameters may be nested under "params" or supplied directly at the top level.
        val params = json?.optJSONObject("params") ?: json
        val flat = LinkedHashMap<String, String>()
        params?.keys()?.forEach { key ->
            if (key == "eventName" || key == "params") return@forEach
            if (params.isNull(key)) return@forEach
            flat[key] = params.optString(key)
        }

        return WebEvent(
            name = nameOf(raw),
            rawName = raw,
            receivedAtMs = System.currentTimeMillis(),
            params = flat,
            uid = flat["uid"]?.takeIf { it.isNotBlank() },
            channelCode = flat["channelCode"]?.takeIf { it.isNotBlank() },
            chatId = flat["chatId"]?.takeIf { it.isNotBlank() },
            unreadCount = flat["count"]?.trim()?.toLongOrNull(),
            webTimestamp = flat["timestamp"]?.takeIf { it.isNotBlank() },
        )
    }
}
