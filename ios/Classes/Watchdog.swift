import Foundation

/// §11.1 原生心跳 + §11.2 存活监测与兜底 reload。
///
/// 这是唯一能从主线程彻底卡死里恢复的机制 —— 那种状态下只有原生看得见：界面正常、
/// 能点能滑，但消息不进不出。
///
/// 全部用原生 `Timer`（§11.1 明确要求）。用 WebView 里的 JS 定时器会被一起冻住，
/// 等于没做。
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

  /// §11.2.0 收到第一条 `eventWebAlive` 之后才开始计时。
  private var firstAliveSeen = false
  private var lastAliveAt: TimeInterval = 0

  /// §11.2.5 同一次卡死只处理一次，页面恢复后才允许下一次。
  private var recoveryInProgress = false
  private var recoveryAttempts = 0
  private var nextRecoveryAllowedAt: TimeInterval = 0

  /// reload 之后有没有真的开始加载（§11.2.3）。
  private var awaitingPageStart = false

  private(set) var reloadCount = 0
  private(set) var recreateCount = 0
  private(set) var lastReloadAtMs: Int64?

  /// 判定周期。比 aliveTimeout 细，保证超时后最多 5 秒内被发现。
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
  }

  var lastAliveAtMs: Int64? {
    lastAliveAt > 0 ? Int64(lastAliveAt * 1000) : nil
  }

  // ------------------------------------------------------------------ 生命周期

  /// §11.1 进前台：心跳开始；§11.2.4 回前台把「最后收到时间」重置为当前。
  func onForeground() {
    // Web 在 onBackground 后停发 eventWebAlive，回前台要等下一个 15 秒周期，
    // 不重置会被误判卡死。
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
    // 页面滚动、键盘动画会把 default 模式的 Timer 挤掉，心跳不能跟着漂。
    if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
    if let aliveTimer { RunLoop.main.add(aliveTimer, forMode: .common) }
  }

  /// §11.1 进后台：心跳停止；§11.2.4 后台期间不计时、不判定。
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

  // --------------------------------------------------------------- 存活监测

  /// §3.1 `eventWebAlive`：前台每 15 秒一次。
  func onWebAlive() {
    firstAliveSeen = true
    lastAliveAt = Date().timeIntervalSince1970
    guard recoveryInProgress else { return }
    // 页面恢复了，解除「同一次卡死」的锁并清掉退避计数。
    NSLog("[SsgShell] 页面已恢复（收到 eventWebAlive），解除恢复锁")
    recoveryInProgress = false
    recoveryAttempts = 0
    nextRecoveryAllowedAt = 0
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
  }

  private func checkAlive() {
    // §11.2.0 收到第一条之前永远不判定卡死，否则原生先上线、Web 还没发，
    // 会每 60 秒 reload 一次。
    guard firstAliveSeen else { return }
    let silence = Date().timeIntervalSince1970 - lastAliveAt
    guard silence > config().aliveTimeout else { return }
    onStallDetected(silence)
  }

  private func onStallDetected(_ silence: TimeInterval) {
    let now = Date().timeIntervalSince1970
    let silenceMs = Int(silence * 1000)
    emit(.stallDetected, "已 \(silenceMs)ms 未收到 eventWebAlive", ["silenceMs": "\(silenceMs)"])

    // §11.2.5 同一次卡死只处理一次。
    guard !recoveryInProgress else { return }
    if now < nextRecoveryAllowedAt {
      // §11.2.5 连续失败要退避，不能进 reload 循环。
      let waitMs = Int((nextRecoveryAllowedAt - now) * 1000)
      emit(.recoveryThrottled, "退避中，\(waitMs)ms 后才允许下一次处理", ["waitMs": "\(waitMs)"])
      return
    }

    recoveryInProgress = true
    recoveryAttempts += 1
    // §11.2.5 第一次处理后等 180 秒，之后 600 秒。
    let backoff = recoveryAttempts <= 1 ? config().recoveryBackoffFirst : config().recoveryBackoffLater
    nextRecoveryAllowedAt = now + backoff

    // §11.2.6 reload / 重建前后各记一条本地日志。
    NSLog("[SsgShell] 判定卡死（静默 \(silenceMs)ms，第 \(recoveryAttempts) 次），执行 reload")
    reloadCount += 1
    lastReloadAtMs = Int64(now * 1000)
    awaitingPageStart = true
    reload()
    emit(
      .reloadIssued,
      "第 \(recoveryAttempts) 次恢复，下次最早 \(Int(backoff * 1000))ms 后",
      ["attempt": "\(recoveryAttempts)", "backoffMs": "\(Int(backoff * 1000))"]
    )

    // §11.2.3 reload 后 10 秒内页面没有开始加载 → 销毁并重建。
    // 页面主线程卡死时 WebKit 会把 reload 排在卡住的 JS 后面，reload 不生效。
    let confirm = DispatchWorkItem { [weak self] in
      guard let self, self.awaitingPageStart else { return }
      NSLog("[SsgShell] reload 未生效（没有 didStartProvisionalNavigation），重建 WebView")
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

  /// §11.2.3 判断 reload 到底有没有生效（`didStartProvisionalNavigation`）。
  func onPageStarted() {
    guard awaitingPageStart else { return }
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
    NSLog("[SsgShell] reload 已生效（didStartProvisionalNavigation）")
  }

  /// 页面被重新加载（reload、重建、被踢下线后刷新）时，`eventWebAlive` 的计时要跟着
  /// 重置，否则刚 reload 完就又判定一次卡死。
  func onPageLoadStartedExternally() {
    lastAliveAt = Date().timeIntervalSince1970
  }

  /// WebView 实例被换掉：重新开始攒 alive，但保留退避窗口。
  func onWebViewRecreated() {
    firstAliveSeen = false
    lastAliveAt = Date().timeIntervalSince1970
    awaitingPageStart = false
    reloadConfirm?.cancel()
    reloadConfirm = nil
  }
}
