package com.ssg.ssg_shell

/**
 * §5.4 Foreground notification suppression and badge behavior.
 *
 * - Track the most recent chatOpen chatId and clear it on the matching chatClose;
 *   suppress a notification when its chat_id matches the active conversation.
 * - Badge count equals the Web unread total; a count of zero clears it.
 *
 * Specification edge cases that are easy to miss:
 * - Web events describe page state only. Native code owns application foreground state: background entry does not emit
 *   chatClose, and returning does not repeat chatOpen. Suppression requires both foreground state and a matching chatId.
 * - Page reloads, WebView recreation, and refresh after logout do not emit chatClose;
 *   clear the tracked chatId when loading starts.
 * - Compare chatId as strings: peer uid for private chats, negative ids for groups and channels.
 */
internal class NotificationGate {

    /** Latest chatOpen chatId, cleared by the matching chatClose or page reload. */
    @Volatile
    var trackedChatId: String? = null
        private set

    @Volatile
    var badgeCount: Int = 0
        private set

    fun onChatOpen(chatId: String?) {
        trackedChatId = chatId?.takeIf { it.isNotBlank() }
    }

    fun onChatClose(chatId: String?) {
        // Conversation changes normally close the previous chat before opening the next;
        // comparing chatIds also handles reversed event order without clearing the new conversation.
        val incoming = chatId?.takeIf { it.isNotBlank() }
        if (incoming == null || incoming == trackedChatId) {
            trackedChatId = null
        }
    }

    /** Call when page loading starts. Reload does not emit chatClose; stale state would suppress a conversation the user has left. */
    fun onPageLoadStarted() {
        trackedChatId = null
    }

    fun onUnreadCount(count: Int) {
        badgeCount = count.coerceAtLeast(0)
    }

    fun setBadge(count: Int) {
        badgeCount = count.coerceAtLeast(0)
    }

    /**
     * @param appInForeground Determined by native code, not supplied by Web events.
     * @return True when the system notification should not be displayed.
     */
    fun shouldSuppress(chatId: String?, appInForeground: Boolean, enabled: Boolean): Boolean {
        if (!enabled) return false
        if (!appInForeground) return false
        val tracked = trackedChatId ?: return false
        val incoming = chatId?.takeIf { it.isNotBlank() } ?: return false
        return tracked == incoming
    }
}
