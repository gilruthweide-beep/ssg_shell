package com.ssg.ssg_shell

import org.json.JSONObject

/**
 * §3.1 的 payload 解析。
 *
 * 线上实际能收到三种形状，都要吃下去：
 *  - `{"eventName":"login","params":{...}}`（规范示例）
 *  - 只有 `params` 内容、事件名靠 handler 名推断（`postMessage("eventLogin", "{...}")`）
 *  - 整个 payload 就是 params 本身
 *
 * params 里的值规范说全是字符串，但不保证：Web 发 `count` 时可能是数字。
 * 所以统一用 `optString` 取，数字也能拿到十进制文本。
 */
internal object WebEventParser {

    /** handler 名 → 事件名。`eventWebReady` → `webReady`。 */
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
     * @param handlerName iOS 的 message handler 名或 Android 两参版本的第一个参数；
     *                    单参版本传 null，事件名只能从 payload 里取。
     */
    fun parse(handlerName: String?, payload: String?): WebEvent? {
        val json = payload?.let { runCatching { JSONObject(it) }.getOrNull() }
        val fromPayload = json?.optString("eventName").orEmpty()
        val raw = when {
            fromPayload.isNotBlank() -> fromPayload
            handlerName != null -> handlerToEventName(handlerName)
            else -> return null
        }

        // params 可能在 "params" 下，也可能就是顶层对象。
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
