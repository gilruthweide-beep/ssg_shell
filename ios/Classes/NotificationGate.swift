import Foundation

/// §5.4 Foreground notification suppression and badge behavior.
///
/// - Foreground suppression: remember the latest chatOpen chatId and clear it on the matching chatClose;
///   suppress a notification when its chat_id matches the active conversation.
/// - Badge count equals the Web unread total; a count of zero clears it.
///
/// Specification pitfalls:
/// - Web events describe page state only. Native code owns application foreground state: background entry does not emit
///   chatClose, and returning does not repeat chatOpen. Suppression requires both foreground state and a matching chatId.
/// - Page reloads, recreation, and refresh after logout do not emit chatClose;
///   clear the tracked chatId when loading starts.
/// - Compare chatId as strings: peer uid for private chats, negative ids for groups and channels.
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
    // Conversation-change events can arrive in either order. Match chatIds to avoid clearing the new conversation.
    let incoming = chatId?.isEmpty == false ? chatId : nil
    lock.lock()
    if incoming == nil || incoming == tracked { tracked = nil }
    lock.unlock()
  }

  /// Call when page loading starts. Reload does not emit chatClose; stale state would suppress a conversation the user has left.
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

  /// - Parameter appInForeground: Determined by native code, not available in Web events.
  /// - Returns: True when the system notification should be suppressed.
  func shouldSuppress(chatId: String?, appInForeground: Bool, enabled: Bool) -> Bool {
    guard enabled, appInForeground else { return false }
    guard let incoming = chatId, !incoming.isEmpty else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard let tracked else { return false }
    return tracked == incoming
  }
}
