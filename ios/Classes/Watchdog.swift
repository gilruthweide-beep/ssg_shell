import Foundation

/// §11.1 Native heartbeat and §11.2 liveness monitoring with recovery reloads.
///
/// Only native code can detect and recover a blocked Web main thread: the UI can appear normal
/// and still respond to taps or scrolling while messages stop arriving or sending.
///
/// Use native `Timer` instances, as §11.1 requires. JavaScript timers in the same WebView
/// would freeze together with the page and provide no protection.
final class Watchdog {

  private let config: () -> ShellConfig
  private let callWeb: (String) -> Void
  private let reload: () -> Void
  private let recreate: () -> Void
  private let emit: (ShellEventType, String?, [String: String]) -> Void

  private var heartbeatTimer: Timer?
  private var aliveTimer: Timer?
  private var reloadConfirm: DispatchWorkItem?

  private var running = false

  /// §11.2.0 Start timing only after the first `eventWebAlive`.
  private var firstAliveSeen = false
  private var lastAliveAt: TimeInterval = 0

  /// §11.2.5 Handle each stall only once; if the page has not recovered, handle it again with 180-second / 600-second backoff.
  private var backoff: RecoveryBackoff

  /// Whether loading actually started after reload (§11.2.3).
  private var awaitingPageStart = false

  private(set) var reloadCount = 0
  private(set) var recreateCount = 0
  private(set) var lastReloadAtMs: Int64?

  /// Poll more often than aliveTimeout to detect a timeout within five seconds.
  private let checkPeriod: TimeInterval = 5

  init(
    config: @escaping () -> ShellConfig,
    callWeb: @escaping (String) -> Void,
    reload: @escaping () -> Void,
    recreate: @escaping () -> Void,
    emit: @escaping (ShellEventType, String?, [String: String]) -> Void
  ) {
    self.config = config
    self.callWeb = callWeb
    self.reload = reload
    self.recreate = recreate
    self.emit = emit
    self.backoff = RecoveryBackoff(
      firstBackoff: { config().recoveryBackoffFirst },
      laterBackoff: { config().recoveryBackoffLater }
    )
  }

  var lastAliveAtMs: Int64? {
    lastAliveAt > 0 ? Int64(lastAliveAt * 1000) : nil
  }

  // ------------------------------------------------------------------ Lifecycle

  /// §11.1 Start heartbeats in the foreground; §11.2.4 reset the last-alive time on foreground entry.
  func onForeground() {
    // The Web application stops eventWebAlive after onBackground and may take 15 seconds to emit it again;
    // without resetting the timestamp, foreground entry could cause a false timeout.
    lastAliveAt = Date().timeIntervalSince1970
    guard !running else { return }
    running = true

    let period = max(config().heartbeatInterval, 1)
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
      guard let self, self.running else { return }
      self.callWeb("onHeartbeat")
    }
    aliveTimer = Timer.scheduledTimer(withTimeInterval: checkPeriod, repeats: true) { [weak self] _ in
      guard let self, self.running else { return }
      self.checkAlive()
    }
    // Scrolling and keyboard animations can delay default-mode timers; keep the heartbeat interval stable.
    if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
    if let aliveTimer { RunLoop.main.add(aliveTimer, forMode: .common) }
  }

  /// §11.1 Stop heartbeats in the background; §11.2.4 pause liveness timing and detection.
  func onBackground() {
    running = false
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
    aliveTimer?.invalidate()
    aliveTimer = nil
    reloadConfirm?.cancel()
    reloadConfirm = nil
    awaitingPageStart = false
  }

  func dispose() {
    onBackground()
  }

  // --------------------------------------------------------------- Liveness monitoring

  /// §3.1 `eventWebAlive` arrives every 15 seconds in the foreground.
  func onWebAlive() {
    firstAliveSeen = true
    lastAliveAt = Date().timeIntervalSince1970
    guard backoff.onAlive(now: lastAliveAt) else { return }
    // The first alive since the last handling. The backoff window stays: this one usually comes from the
    // freshly loaded page, and only outliving the whole window counts as recovery (see RecoveryBackoff).
    NSLog("[SsgShell] eventWebAlive received again after handling a stall")
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
  }

  private func checkAlive() {
    // §11.2.0 Never declare a stall before the first one arrives; otherwise, with native up first and the Web not yet sending,
    // it would reload every 60 seconds. Exception: a stall was handled and no alive has arrived since (recreation clears
    // firstAliveSeen). This page did send alive before, so keep watching and let the backoff window prevent a loop.
    guard firstAliveSeen || backoff.awaitingAlive else { return }
    // A reload was just issued; these 10 seconds belong to reloadConfirm.
    guard !awaitingPageStart else { return }
    let silence = Date().timeIntervalSince1970 - lastAliveAt
    guard silence > config().aliveTimeout else { return }
    onStallDetected(silence)
  }

  private func onStallDetected(_ silence: TimeInterval) {
    let now = Date().timeIntervalSince1970
    let silenceMs = Int(silence * 1000)

    let attempt: Int
    let backoffMs: Int
    switch backoff.onStall(now: now) {
    case .throttled(wait: _, firstReport: false):
      return
    case .throttled(wait: let wait, firstReport: true):
      // §11.2.5 The page has not recovered since the last handling: wait for the backoff window to expire before handling again, to avoid a reload loop.
      let waitMs = Int(wait * 1000)
      emit(.stallDetected, "No eventWebAlive for \(silenceMs)ms", ["silenceMs": "\(silenceMs)"])
      emit(.recoveryThrottled, "Backing off; next handling allowed in \(waitMs)ms", ["waitMs": "\(waitMs)"])
      return
    case .recover(attempt: let number, backoff: let wait):
      attempt = number
      backoffMs = Int(wait * 1000)
    }
    emit(.stallDetected, "No eventWebAlive for \(silenceMs)ms", ["silenceMs": "\(silenceMs)"])

    // §11.2.6 Write a local log entry before and after each reload / recreation.
    NSLog("[SsgShell] Stall detected (silent \(silenceMs)ms, attempt \(attempt)); reloading")
    reloadCount += 1
    lastReloadAtMs = Int64(now * 1000)
    awaitingPageStart = true
    reload()
    emit(
      .reloadIssued,
      "Recovery attempt \(attempt); next one no earlier than \(backoffMs)ms from now",
      ["attempt": "\(attempt)", "backoffMs": "\(backoffMs)"]
    )

    // §11.2.3 If loading does not start within 10 seconds of reload, destroy and recreate the WebView.
    // When the page main thread is blocked, WebKit may queue reload behind the stuck JavaScript.
    let confirm = DispatchWorkItem { [weak self] in
      guard let self, self.awaitingPageStart else { return }
      NSLog("[SsgShell] Reload did not start (no didStartProvisionalNavigation); recreating WebView")
      self.awaitingPageStart = false
      self.recreateCount += 1
      self.recreate()
    }
    reloadConfirm?.cancel()
    reloadConfirm = confirm
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(config().reloadConfirmTimeout, 1),
      execute: confirm
    )
  }

  /// §11.2.3 Track whether reload took effect through `didStartProvisionalNavigation`.
  func onPageStarted() {
    guard awaitingPageStart else { return }
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
    NSLog("[SsgShell] Reload started (didStartProvisionalNavigation)")
  }

  /// Reset eventWebAlive timing whenever the page reloads, is recreated, or refreshes after logout,
  /// so a just-reloaded page is not immediately declared unresponsive again.
  func onPageLoadStartedExternally() {
    lastAliveAt = Date().timeIntervalSince1970
  }

  /// The WebView instance was replaced: start collecting alive again, but keep the backoff window.
  ///
  /// When the watchdog itself triggered the recreation, `checkAlive` does not stop because firstAliveSeen was cleared;
  /// if the new page is still silent, handle it again once the backoff window expires (§11.2.5).
  func onWebViewRecreated() {
    firstAliveSeen = false
    lastAliveAt = Date().timeIntervalSince1970
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
  }
}
