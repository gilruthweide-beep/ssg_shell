package com.ssg.ssg_shell

/**
 * §5.4 体验细则：前台抑制与角标。
 *
 * - 前台抑制：原生记住最近一次 `chatOpen` 的 `chatId`，收到 `chatClose` 时清空；
 *   推送的 `chat_id` 等于它就不展示。
 * - 角标：角标数 = Web 给的未读总数，`count` 为 `0` 时清零。
 *
 * 几个容易写错的地方，都是规范里点名的：
 * - 这些事件只表示 Web 页面里的状态。App 是否在前台由原生自己判断：切到后台不会发
 *   `chatClose`，回前台也不会重发 `chatOpen`。所以抑制判断必须「前台 **且** chatId 命中」。
 * - 页面重新加载（reload、重建 WebView、被踢下线后刷新）时不会发 `chatClose`，
 *   原生在页面开始加载时要清空记住的 chatId。
 * - `chatId` 统一按字符串比较：私聊为对方 uid，群和频道为负数 id。
 */
internal class NotificationGate {

    /** 最近一次 `chatOpen` 的 chatId，`chatClose` 或页面重载时清空。 */
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
        // 切到其他会话时 Web 会先发旧会话的 chatClose、再发新会话的 chatOpen；
        // 顺序反过来的话按 chatId 比对就不会误清掉新会话。
        val incoming = chatId?.takeIf { it.isNotBlank() }
        if (incoming == null || incoming == trackedChatId) {
            trackedChatId = null
        }
    }

    /** 页面开始加载时调。重载不发 `chatClose`，不清会一直抑制一个已经离开的会话。 */
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
     * @param appInForeground 由原生自己判断，Web 事件里没有这个信息。
     * @return true 表示不要展示系统通知。
     */
    fun shouldSuppress(chatId: String?, appInForeground: Boolean, enabled: Boolean): Boolean {
        if (!enabled) return false
        if (!appInForeground) return false
        val tracked = trackedChatId ?: return false
        val incoming = chatId?.takeIf { it.isNotBlank() } ?: return false
        return tracked == incoming
    }
}
