import Foundation

/// §11.2.5 同一次卡死只处理一次；连续失败要退避：第一次处理后等 180 秒，之后 600 秒。
///
/// 「页面恢复」的判据是又收到了 `eventWebAlive`。reload / 重建之后一直收不到属于连续失败：
/// 退避窗口到期后要再处理一次，而不是把这次卡死永久锁住 —— §12.4「退避」验的就是这条。
///
/// 纯逻辑，不碰定时器，时间由调用方传进来。和 Android 的 `RecoveryBackoff` 一一对应。
struct RecoveryBackoff {

  enum Decision: Equatable {
    /// 现在处理。`attempt` 从 1 起；`backoff` 是这次处理之后要等多久才允许下一次。
    case recover(attempt: Int, backoff: TimeInterval)
    /// 还在退避窗口里。`firstReport` 只在本窗口第一次命中时为 true，用来给日志去重。
    case throttled(wait: TimeInterval, firstReport: Bool)
  }

  private let firstBackoff: () -> TimeInterval
  private let laterBackoff: () -> TimeInterval

  /// 自上次页面恢复以来处理过几次。
  private(set) var attempts = 0
  private var nextAllowedAt: TimeInterval = 0
  private var throttleReported = false

  init(firstBackoff: @escaping () -> TimeInterval, laterBackoff: @escaping () -> TimeInterval) {
    self.firstBackoff = firstBackoff
    self.laterBackoff = laterBackoff
  }

  /// 已经处理过、但页面还没恢复。
  var recovering: Bool { attempts > 0 }

  mutating func onStall(now: TimeInterval) -> Decision {
    if now < nextAllowedAt {
      let first = !throttleReported
      throttleReported = true
      return .throttled(wait: nextAllowedAt - now, firstReport: first)
    }
    attempts += 1
    let backoff = attempts <= 1 ? firstBackoff() : laterBackoff()
    nextAllowedAt = now + backoff
    throttleReported = false
    return .recover(attempt: attempts, backoff: backoff)
  }

  /// 收到 `eventWebAlive`：页面恢复，退避清零。返回之前是否处在恢复当中。
  @discardableResult
  mutating func onRecovered() -> Bool {
    let wasRecovering = attempts > 0
    attempts = 0
    nextAllowedAt = 0
    throttleReported = false
    return wasRecovering
  }
}
