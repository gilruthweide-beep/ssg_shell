import Foundation

/// §11.2.5 Handle each stall only once; back off on consecutive failures: wait 180 seconds after the first handling, then 600 seconds.
///
/// Rules:
/// - After one handling, nothing is handled again until the backoff window expires, **whether or not the page sent
///   `eventWebAlive` in the meantime**. A recreated page sends alive as soon as it loads; treating that as "recovered"
///   and resetting the backoff would reload a page that hangs again right after a rebuild every minute, and §12.4
///   "Backoff" would fail.
/// - If the page is still (or again) stalled when the window expires, handle it again and switch to the 600-second
///   window. A page that never sends alive is handled again too, so the stall is never locked out permanently.
/// - Only a page that outlived the whole window and still sends alive has really recovered: the counter resets and the
///   next stall counts as the first.
///
/// Pure logic with no timers; the caller passes in the time. Mirrors Android's `RecoveryBackoff` one-to-one.
struct RecoveryBackoff {

  enum Decision: Equatable {
    /// Handle now. `attempt` starts at 1; `backoff` is how long to wait after this handling before the next one is allowed.
    case recover(attempt: Int, backoff: TimeInterval)
    /// Still inside the backoff window. `firstReport` is true only on the first hit in this window, used to deduplicate logs.
    case throttled(wait: TimeInterval, firstReport: Bool)
  }

  private let firstBackoff: () -> TimeInterval
  private let laterBackoff: () -> TimeInterval

  /// Consecutive handlings. Resets once the page outlives a full backoff window.
  private(set) var attempts = 0
  /// Handled, and no `eventWebAlive` has arrived since.
  private(set) var awaitingAlive = false

  private var nextAllowedAt: TimeInterval = 0
  private var throttleReported = false

  init(firstBackoff: @escaping () -> TimeInterval, laterBackoff: @escaping () -> TimeInterval) {
    self.firstBackoff = firstBackoff
    self.laterBackoff = laterBackoff
  }

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
    awaitingAlive = true
    return .recover(attempt: attempts, backoff: backoff)
  }

  /// `eventWebAlive` received. Returns whether this is the first one since the last handling.
  @discardableResult
  mutating func onAlive(now: TimeInterval) -> Bool {
    let firstSinceRecovery = awaitingAlive
    awaitingAlive = false
    if attempts > 0 && now >= nextAllowedAt {
      attempts = 0
      nextAllowedAt = 0
      throttleReported = false
    }
    return firstSinceRecovery
  }
}
