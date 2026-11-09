import Foundation

/// §5.4 体验细则：前台抑制与角标。
///
/// - 前台抑制：记住最近一次 `chatOpen` 的 `chatId`，收到 `chatClose` 时清空；
///   推送的 `chat_id` 等于它就不展示。
/// - 角标：角标数 = Web 给的未读总数，`count` 为 `0` 时清零。
///
/// 规范点名的几个坑：
/// - 这些事件只表示 Web 页面里的状态。App 是否在前台由原生自己判断：切到后台不会发
///   `chatClose`，回前台也不会重发 `chatOpen`。所以抑制判断必须「前台 **且** chatId 命中」。
/// - 页面重新加载（reload、重建、被踢下线后刷新）时不会发 `chatClose`，
///   原生在页面开始加载时要清空记住的 chatId。
/// - `chatId` 统一按字符串比较：私聊为对方 uid，群和频道为负数 id。
final class NotificationGate {

  private let lock = NSLock()
  private var tracked: String?
  private var badge: Int = 0

  var trackedChatId: String? {
    lock.lock()
    defer { lock.unlock() }
    return tracked
  }

  var badgeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return badge
  }

  func onChatOpen(_ chatId: String?) {
    let value = chatId?.isEmpty == false ? chatId : nil
    lock.lock()
    tracked = value
    lock.unlock()
  }

  func onChatClose(_ chatId: String?) {
    // 切到其他会话时两条事件的先后顺序不保证，按 chatId 比对就不会误清掉新会话。
    let incoming = chatId?.isEmpty == false ? chatId : nil
    lock.lock()
    if incoming == nil || incoming == tracked { tracked = nil }
    lock.unlock()
  }

  /// 页面开始加载时调。重载不发 `chatClose`，不清会一直抑制一个已经离开的会话。
  func onPageLoadStarted() {
    lock.lock()
    tracked = nil
    lock.unlock()
  }

  func setBadge(_ count: Int) {
    lock.lock()
    badge = max(count, 0)
    lock.unlock()
  }

  /// - Parameter appInForeground: 由原生自己判断，Web 事件里没有这个信息。
  /// - Returns: true 表示不要展示系统通知。
  func shouldSuppress(chatId: String?, appInForeground: Bool, enabled: Bool) -> Bool {
    guard enabled, appInForeground else { return false }
    guard let incoming = chatId, !incoming.isEmpty else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard let tracked else { return false }
    return tracked == incoming
  }
}
