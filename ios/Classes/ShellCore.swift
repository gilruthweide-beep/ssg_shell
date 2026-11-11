import Foundation
import UIKit
import WebKit

/// Process-level shell coordinator, independent of the Flutter engine lifetime.
///
/// This state does not live on the plugin because §9.6 requires B-side cold starts to load the Web application before Flutter starts,
/// while §11.2 liveness monitoring, §11.1 heartbeat, and §10.4 network notifications must already be active.
final class ShellCore {

  static let shared = ShellCore()

  private init() {}

  private var config = ShellConfig()

  /// Dart callback channel; nil before engine startup or after destruction, causing emits to be skipped.
  private var dart: SsgShellFlutterApi?

  private let console = ConsoleLogBuffer()
  private let gate = NotificationGate()

  private lazy var watchdog = Watchdog(
    config: { [weak self] in self?.config ?? ShellConfig() },
    callWeb: { ImWebViewHolder.shared.callWeb($0) },
    reload: { ImWebViewHolder.shared.reload() },
    recreate: { [weak self] in self?.recreateWebView() },
    emit: { [weak self] type, message, extra in self?.emit(type, message, extra) }
  )

  private var network: NetworkMonitor?

  private(set) var appInForeground = false

  /// Whether the IM container is attached to the WebView and visible.
  private(set) var imRunning = false

  /// Last calculated WebView visibility, used to notify the Web application only on changes.
  private var webVisible = false

  private var webReady = false

  /// Keep the latest of each stateful Web event. Dart cannot receive events that happened before it came online,
  /// and `login` is sent only once per uid (§3.1); if lost, OneSignal is never bound (§5.2).
  /// `replaySticky(to:)` replays them when Dart calls `initialize()`.
  private var stickyWebReady: WebEvent?
  private var stickyIdentity: WebEvent?
  private var stickyUnread: WebEvent?
  private var stickyChatOpen: WebEvent?

  /// When the initial page fails to load with no container attached (preload phase), there is nowhere to show the retry page.
  /// Record it and apply it when a container attaches (`onHostAttached`).
  private var loadFailed = false
  private var loadFailedMessage: String?

  private var reportedChannelCode = ""
  private var lastWebReadyAtMs: Int64?

  /// §5.3 Queue cold-start notification parameters until the Web application emits webReady.
  private var pendingOpenChat: OpenChatRequest?

  private var injectionOk = false

  /// §6.2 Allow notification permission requests only after `eventLogin`.
  private var loginSeen = false

  private var started = false

  private weak var container: ImViewController?

  // -------------------------------------------------------------- Initialization

  /// Called idempotently by `SsgShellPlugin.register(with:)` during AppDelegate plugin registration, before the first frame.
  func attach() {
    guard !started else { return }
    started = true
    config = ShellConfig.fromDisk()
    console.capacity = config.consoleBufferSize

    let center = NotificationCenter.default
    // §4 / §10.2 didBecomeActive covers unlocks, returning from background work,
    // and opening the application from a notification.
    center.addObserver(
      self,
      selector: #selector(onDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(onDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    // §11.4 Invoke only for didReceiveMemoryWarning, never merely on background or foreground transitions.
    // Listen directly to iOS system notifications, even with Flutter, instead of forwarding didHaveMemoryPressure.
    center.addObserver(
      self,
      selector: #selector(onMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )

    network = NetworkMonitor(
      debounce: { [weak self] in self?.config.networkDebounce ?? 1.5 },
      onAvailable: { [weak self] type in self?.deliverNetwork(type) }
    )
    network?.start()

    PermissionCoordinator.refreshNotificationState()

    // The application is often already active at process startup; deliver the initial state instead of waiting for another transition.
    if UIApplication.shared.applicationState == .active {
      setAppForeground(true)
    }
  }

  func setDartApi(_ api: SsgShellFlutterApi?) {
    dart = api
  }

  func currentConfig() -> ShellConfig { config }

  /// When Dart calls `initialize()`, replay the stateful events it missed before coming online. Must be called on the main thread
  /// before `initialize` returns; Dart relies on the "events first, return value second" order to catch them.
  func replaySticky(to api: SsgShellFlutterApi) {
    for event in [stickyWebReady, stickyIdentity, stickyUnread, stickyChatOpen] {
      guard let event else { continue }
      api.onWebEvent(event: event) { _ in }
    }
  }

  var isWebReady: Bool { webReady }

  /// When a container attaches, apply the state it missed.
  ///
  /// `eventWebReady` fires only once per page load and will not come again if sent during preload; the splash half
  /// is decided by the container reading `isWebReady` itself; this handles the retry page for an initial page load failure (§9.6).
  func onHostAttached(_ host: ShellWebViewHost) {
    if loadFailed { host.showErrorPage(loadFailedMessage) }
  }

  /// The page is about to reload (reload, recreation): all state left by the previous page is discarded.
  private func onPageReset() {
    webReady = false
    stickyWebReady = nil
    stickyChatOpen = nil
    loadFailed = false
    loadFailedMessage = nil
  }

  // ----------------------------------------------------------- HostApi

  func initialize(_ dto: ShellConfigDto) -> ShellInfo {
    let next = ShellConfig.fromDto(dto)
    if next.entryUrl != config.entryUrl { reportedChannelCode = "" }
    config = next
    console.capacity = next.consoleBufferSize
    // §9.6 Persist configuration so the next cold start uses the cache without waiting for Dart.
    next.persist()
    return ShellInjection.shellInfo(shellVersion: next.shellVersion)
  }

  /// §8.4 Performance 1 on iOS: create the WebView and begin loading early when B side is enabled.
  func preload() {
    guard config.bSideEnabled else {
      NSLog("[SsgShell] B side is disabled; skipping IM preload")
      return
    }
    guard !config.entryUrl.isEmpty else {
      NSLog("[SsgShell] entryUrl is empty; skipping preload")
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      ImWebViewHolder.shared.get(config: self.config)
    }
  }

  func openIm() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // A no-op when the container is already in the foreground.
      if let container = self.container, container.view.window != nil { return }
      guard let top = Self.topViewController() else {
        NSLog("[SsgShell] No view controller is available to present the IM container")
        return
      }
      let controller = ImViewController(config: self.config)
      self.container = controller
      top.present(controller, animated: false)
    }
  }

  /// §10.6 Close only the container without destroying the WebView instance.
  func closeIm() {
    DispatchQueue.main.async { [weak self] in
      self?.container?.dismiss(animated: false)
    }
  }

  func setBSideEnabled(_ enabled: Bool) {
    config.bSideEnabled = enabled
    ShellConfig.persistBSide(enabled)
  }

  func isBSideEnabled() -> Bool { config.bSideEnabled }

  /// §5.3 Open a conversation.
  ///
  /// Wait for `eventWebReady`: queue notification parameters while the Web application initializes on a cold start.
  /// Deliver once. The Web application waits up to 20 seconds for conversation data; native retries are unnecessary.
  func openChat(_ request: OpenChatRequest) {
    guard !request.chatId.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.webReady else {
        self.pendingOpenChat = request
        self.emit(
          .deepLinkQueued,
          "Web is not ready; queued chatId=\(request.chatId)",
          ["chatId": request.chatId]
        )
        return
      }
      self.deliverOpenChat(request)
    }
  }

  private func deliverOpenChat(_ request: OpenChatRequest) {
    var payload: [String: Any] = ["chatId": request.chatId]
    // §5.3 Optional messageId accepts a number or a string parseable by Number().
    if let raw = request.messageId, !raw.isEmpty {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if let number = Int64(trimmed) {
        payload["messageId"] = number
      } else {
        payload["messageId"] = trimmed
      }
    }
    let json: String
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
      json = text
    } else {
      json = "{\"chatId\":\"\(request.chatId)\"}"
    }
    ImWebViewHolder.shared.callWeb("openChat", arg: ImWebViewHolder.jsSafe(json))

    var extra = ["chatId": request.chatId]
    if let messageId = request.messageId { extra["messageId"] = messageId }
    emit(.deepLinkDelivered, "Delivered to Web: chatId=\(request.chatId)", extra)
  }

  /// §5.4 Foreground suppression and §11.3 push-triggered Web connection wakeup.
  func handlePushReceived(_ message: PushMessage) -> PushDecision {
    let suppress = gate.shouldSuppress(
      chatId: message.chatId,
      appInForeground: appInForeground,
      enabled: config.suppressForegroundNotifications
    )

    // §11.3 A foreground push indicates that the Web application missed a message over its persistent connection.
    // Alongside §5.4 notification suppression, call onNetwork once to wake that connection.
    var nudged = false
    if appInForeground {
      // Receiving the push confirms connectivity; use other until the network monitor catches up.
      let observed = network?.currentType ?? NetworkType.none
      let type: NetworkType = observed == .none ? .other : observed
      DispatchQueue.main.async { [weak self] in self?.deliverNetwork(type) }
      nudged = true
    }

    var reason = appInForeground ? "Foreground" : "Background"
    reason += "; tracked=\(gate.trackedChatId ?? "-")"
    reason += "; incoming=\(message.chatId ?? "-")"
    if suppress { reason += "; foreground notification suppressed" }
    if nudged { reason += "; Web connection nudged through onNetwork" }
    NSLog("[SsgShell] handlePushReceived: \(reason)")

    return PushDecision(
      suppressNotification: suppress,
      nudgedWeb: nudged,
      appInForeground: appInForeground,
      reason: reason
    )
  }

  /// §5.3 Notification click handling.
  func handlePushOpened(_ message: PushMessage) {
    if config.bSideEnabled { openIm() }
    guard let chatId = message.chatId, !chatId.isEmpty else {
      NSLog("[SsgShell] Notification click has no chat_id; opening the application only")
      return
    }
    openChat(OpenChatRequest(chatId: chatId, messageId: message.messageId))
  }

  func nudgeNetwork(_ type: NetworkType) {
    DispatchQueue.main.async { [weak self] in self?.deliverNetwork(type) }
  }

  func reloadWeb() {
    NSLog("[SsgShell] Manual reload (§11.2)")
    ImWebViewHolder.shared.reload()
  }

  /// §11.2.3 Each iOS WKWebView releases its WebContent process with the instance, so recreation is sufficient.
  func recreateWebView() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onPageReset()
      self.gate.onPageLoadStarted()
      ImWebViewHolder.shared.recreate(config: self.config)
      self.watchdog.onWebViewRecreated()
      self.emit(.webViewRecreated, "WebView instance recreated", [:])
    }
  }

  func setBadgeCount(_ count: Int) {
    gate.setBadge(count)
    BadgeApplier.apply(count)
  }

  func verifyInjection(_ completion: @escaping (Bool) -> Void) {
    // §1.3 Use the Web application's own verdict. A true result fails regardless of the contents of __SSG_SHELL__.
    let js = "document.documentElement.classList.contains('is-web-browser')"
    ImWebViewHolder.shared.evaluate(js) { [weak self] raw in
      let value = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
      let ok = value == "false"
      self?.injectionOk = ok
      self?.emit(
        .injectionChecked,
        ok ? "Injection active" : "Injection failed (is-web-browser=\(value.isEmpty ? "null" : value)); see §1.2",
        ["isWebBrowser": value.isEmpty ? "null" : value]
      )
      completion(ok)
    }
  }

  func evaluateJavaScript(_ script: String, completion: @escaping (Result<String, Error>) -> Void) {
    // §8.3 Preserve storage. Clearing it logs users out, removes cached messages, downloads media again,
    // loses diagnostic context, and resets the once-per-device eventRegister marker, inflating attribution counts.
    if let hit = Self.forbiddenJs.first(where: { script.range(of: $0, options: .caseInsensitive) != nil }) {
      completion(.failure(NSError(
        domain: "ssg_shell",
        code: 400,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Script contains prohibited storage deletion call \(hit); see §8.3. Deletion requires an explicit user action to clear data.",
        ]
      )))
      return
    }
    ImWebViewHolder.shared.evaluate(script) { raw in
      completion(.success(raw ?? ""))
    }
  }

  // ------------------------------------------------------------ Diagnostics

  /// §8.1 / §11.7 WebView engine information.
  ///
  /// §11.7 Engine-update guidance applies only to Android, where WebView is independently updatable
  /// and may be outdated on older devices. iOS updates WebKit with the OS, and the shell's iOS 14 minimum
  /// already provides the required §8.1 capabilities, so report its version without rejecting it.
  func kernelInfo() -> KernelInfo {
    let versionName = ShellInjection.webKitVersion()
    let major = Int64(versionName.split(separator: ".").first.map(String.init) ?? "") ?? -1
    return KernelInfo(
      verdict: versionName.isEmpty ? .unknown : .ok,
      versionName: versionName,
      majorVersion: major,
      // WebView implementation package on Android; empty on iOS.
      packageName: ""
    )
  }

  func diagnostics() -> ShellDiagnostics {
    ShellDiagnostics(
      shellInfo: ShellInjection.shellInfo(shellVersion: config.shellVersion),
      entryUrl: config.entryUrl,
      currentUrl: ImWebViewHolder.shared.currentUrl,
      userAgent: ImWebViewHolder.shared.cachedUserAgent,
      channelCode: reportedChannelCode,
      injectionOk: injectionOk && ImWebViewHolder.shared.documentStartInjected,
      imRunning: imRunning,
      appInForeground: appInForeground,
      reloadCount: Int64(watchdog.reloadCount),
      recreateCount: Int64(watchdog.recreateCount),
      badgeCount: Int64(gate.badgeCount),
      kernel: kernelInfo(),
      consoleTail: console.snapshot(),
      lastReloadAtMs: watchdog.lastReloadAtMs,
      lastWebReadyAtMs: lastWebReadyAtMs,
      lastWebAliveAtMs: watchdog.lastAliveAtMs,
      trackedChatId: gate.trackedChatId
    )
  }

  /// §11.6 Export the current URL, user agent, engine version, `__SSG_SHELL__`, last reload time,
  /// and most recent N console entries.
  func exportDiagnostics() -> String {
    let d = diagnostics()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    func time(_ ms: Int64?) -> String {
      guard let ms else { return "-" }
      return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    var out = ""
    out += "==== SSG Shell diagnostics ====\n"
    out += "Exported at        \(formatter.string(from: Date()))\n"
    out += "Platform            ios\n"
    out += "Bundle ID            \(d.shellInfo.bundleId)\n"
    out += "Shell version          \(d.shellInfo.shellVersion)\n"
    out += "Device model            \(d.shellInfo.deviceModel)\n"
    out += "OS version        \(d.shellInfo.osVersion)\n"
    out += "WebKit          \(d.kernel.versionName) (\(d.kernel.verdict))\n"
    out += "Landing URL        \(d.entryUrl)\n"
    out += "Current URL        \(d.currentUrl)\n"
    out += "UA              \(d.userAgent)\n"
    out += "channelCode     \(d.channelCode.isEmpty ? "(optional; not supplied by Web attribution events)" : d.channelCode)\n"
    out += "Injection check        \(d.injectionOk ? "Passed shellSrc:inject" : "Failed; see §1.2")\n"
    out += "IM attached         \(d.imRunning)\n"
    out += "App foreground        \(d.appInForeground)\n"
    out += "Last webReady   \(time(d.lastWebReadyAtMs))\n"
    out += "Last webAlive   \(time(d.lastWebAliveAtMs))\n"
    out += "Last reload     \(time(d.lastReloadAtMs))  Count \(d.reloadCount)\n"
    out += "WebView recreations    \(d.recreateCount) times\n"
    out += "Active chat        \(d.trackedChatId ?? "-")\n"
    out += "Badge            \(d.badgeCount)\n\n"
    out += "---- Last \(d.consoleTail.count) console entries ----\n"
    out += console.dump()
    return out
  }

  // ------------------------------------------------- WebView callbacks

  /// §3.1 Entry point from `ScriptMessageRouter`.
  func onWebEvent(_ event: WebEvent) {
    DispatchQueue.main.async { [weak self] in
      self?.handleWebEvent(event)
    }
  }

  private func handleWebEvent(_ event: WebEvent) {
    // §2.1 The Web application owns channel attribution; diagnostics record events without reading or rewriting the URL.
    if event.name == .register || event.name == .login || event.name == .messageSent {
      reportedChannelCode = event.params["channelCode"] ?? ""
    }
    switch event.name {
    case .webReady:
      webReady = true
      stickyWebReady = event
      lastWebReadyAtMs = event.receivedAtMs
      // §9.6 Remove the splash immediately after eventWebReady rather than waiting a fixed duration.
      ImWebViewHolder.shared.host?.dismissSplash(.splashDismissed)
      // §5.3 Deliver queued cold-start notification parameters once after readiness.
      if let queued = pendingOpenChat {
        pendingOpenChat = nil
        deliverOpenChat(queued)
      }
      // §1.3 Run the injection check when the first screen is visible without requiring a debugger.
      verifyInjection { _ in }
      ImWebViewHolder.shared.refreshUserAgent()

    case .webAlive:
      watchdog.onWebAlive()

    case .chatOpen:
      gate.onChatOpen(event.chatId)
      stickyChatOpen = gate.trackedChatId == nil ? nil : event

    case .chatClose:
      gate.onChatClose(event.chatId)
      if gate.trackedChatId == nil { stickyChatOpen = nil }

    case .unreadCount:
      stickyUnread = event
      let count = Int(event.unreadCount ?? 0)
      gate.setBadge(count)
      // §5.4 Badge count equals the Web unread total; a count of zero clears it.
      if config.manageBadge { BadgeApplier.apply(count) }

    // §6.2 Open the notification permission gate only after eventLogin;
    // Dart controls the actual prompt timing so the host can show its own introduction first.
    case .login:
      loginSeen = true
      stickyIdentity = event

    case .logout:
      loginSeen = false
      // Local patch: keep the logout as the latest identity so a logout before Dart starts
      // still reaches OneSignal.logout() and stops the previous account's pushes.
      stickyIdentity = event
      stickyChatOpen = nil
      // §5.4 The Web application emits unreadCount=0 on logout; let that event clear the badge.

    default:
      break
    }

    let api = dart
    api?.onWebEvent(event: event) { _ in /* Dart listeners are optional. */ }
  }

  func hasLoggedIn() -> Bool { loginSeen }

  func onPageStarted(_ url: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // §5.4 Page reloads do not emit chatClose; clear the tracked chatId when loading starts.
      self.gate.onPageLoadStarted()
      self.onPageReset()
      self.watchdog.onPageStarted()
      self.watchdog.onPageLoadStartedExternally()
      ImWebViewHolder.shared.host?.hideErrorPage()
    }
  }

  func onPageFinished(_ url: String?) {
    ImWebViewHolder.shared.refreshUserAgent()
  }

  func onMainFrameLoadFailed(url: String, description: String) {
    NSLog("[SsgShell] Initial page load failed \(url): \(description)")
    DispatchQueue.main.async { [weak self] in
      self?.loadFailed = true
      self?.loadFailedMessage = nil
      ImWebViewHolder.shared.host?.showErrorPage(nil)
      self?.emit(.loadFailed, description, ["url": url])
    }
  }

  func onSslError(_ code: Int) {
    DispatchQueue.main.async { [weak self] in
      let message = "Secure connection verification failed. Check your network and try again."
      self?.loadFailed = true
      self?.loadFailedMessage = message
      ImWebViewHolder.shared.host?.showErrorPage(message)
      self?.emit(.loadFailed, "SSL validation failed (code=\(code))", ["sslError": "\(code)"])
    }
  }

  /// §7.2 Reload after WebContent process termination to avoid a permanent blank page.
  func onRenderProcessGone(crashed: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.emit(
        .renderProcessGone,
        crashed ? "WebContent process was reclaimed" : "WebContent process terminated",
        ["didCrash": "\(crashed)"]
      )
      self.onPageReset()
      self.gate.onPageLoadStarted()
      // §7.2 Requires reload() here; the §11.2.3 watchdog recreates the WebView if reload fails to start.
      if let web = ImWebViewHolder.shared.webView, web.url != nil {
        web.reload()
      } else {
        self.recreateWebView()
      }
    }
  }

  func onConsoleMessage(level: ConsoleLevel, message: String, source: String?, line: Int64) {
    guard config.forwardConsole else { return }
    let record = ConsoleRecord(
      level: level,
      message: message,
      atMs: Int64(Date().timeIntervalSince1970 * 1000),
      source: source,
      line: line
    )
    console.add(record)
    // §11.6 Forward Web console output to native logs.
    NSLog("[SsgShellWeb][\(level.wire)] \(message)")
    DispatchQueue.main.async { [weak self] in
      self?.dart?.onShellEvent(
        event: ShellEvent(
          type: .consoleMessage,
          atMs: record.atMs,
          extra: [:],
          message: message,
          console: record
        )
      ) { _ in }
    }
  }

  // ------------------------------------------------------- Lifecycle

  @objc private func onDidBecomeActive() {
    setAppForeground(true)
    PermissionCoordinator.refreshNotificationState()
  }

  @objc private func onDidEnterBackground() {
    setAppForeground(false)
  }

  /// §11.4 Forward actual system memory warnings only, not ordinary background/foreground transitions.
  @objc private func onMemoryWarning() {
    DispatchQueue.main.async { [weak self] in
      ImWebViewHolder.shared.callWeb("onMemoryWarning")
      self?.emit(.memoryWarning, "didReceiveMemoryWarning", [:])
    }
  }

  private func setAppForeground(_ foreground: Bool) {
    guard appInForeground != foreground else { return }
    appInForeground = foreground
    updateWebVisibility()
  }

  func setImRunning(_ running: Bool) {
    guard imRunning != running else { return }
    imRunning = running
    emit(running ? .imOpened : .imClosed, nil, [:])
    updateWebVisibility()
  }

  /// §10.2 Foreground signaling.
  ///
  /// Use actual WebView visibility instead of application foreground state. Switching between IM and Flutter A side
  /// keeps the application in the foreground while the WebView becomes hidden, `document.hidden` becomes true,
  /// and eventWebAlive stops. Keeping §11.2 timing active would falsely detect a timeout after 60 seconds.
  private func updateWebVisibility() {
    let visible = appInForeground && imRunning
    guard visible != webVisible else { return }
    webVisible = visible
    if visible {
      // §10.2.1 Call onForeground() on every foreground transition, including unlocks, returning from background tasks,
      // and notification clicks. With injection active, returning after more than 1.5 seconds reconnects immediately.
      ImWebViewHolder.shared.onResumeWeb()
      ImWebViewHolder.shared.callWeb("onForeground")
      watchdog.onForeground()
      emit(.foreground, nil, [:])
    } else {
      ImWebViewHolder.shared.callWeb("onBackground")
      ImWebViewHolder.shared.onPauseWeb()
      watchdog.onBackground()
      emit(.background, nil, [:])
    }
  }

  private func deliverNetwork(_ type: NetworkType) {
    // §4 Do not report disconnection; none would be ignored.
    guard type != .none else { return }
    let wire: String
    switch type {
    case .wifi: wire = "wifi"
    case .cellular: wire = "cellular"
    case .ethernet: wire = "ethernet"
    default: wire = "other"
    }
    ImWebViewHolder.shared.callWeb("onNetwork", arg: "'\(wire)'")
    emit(.networkChanged, wire, ["type": wire], network: type)
  }

  func currentNetworkType() -> NetworkType { network?.currentType ?? .none }

  // ------------------------------------------------------------ Utilities

  func notifySplashDismissed(_ reason: ShellEventType) {
    emit(reason, nil, [:])
  }

  private func emit(
    _ type: ShellEventType,
    _ message: String?,
    _ extra: [String: String],
    network networkType: NetworkType? = nil
  ) {
    let event = ShellEvent(
      type: type,
      atMs: Int64(Date().timeIntervalSince1970 * 1000),
      extra: extra,
      message: message,
      network: networkType
    )
    DispatchQueue.main.async { [weak self] in
      self?.dart?.onShellEvent(event: event) { _ in }
    }
  }

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let window = scenes
      .first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow })
      ?? scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
      ?? scenes.flatMap(\.windows).first
    guard var top = window?.rootViewController else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  /// §8.3 Calls prohibited on normal execution paths.
  ///
  /// Block deletion but allow reads: the §12.1 self-test uses
  /// `await navigator.serviceWorker.getRegistration()`, which must remain available.
  private static let forbiddenJs = [
    "caches.delete",
    ".unregister(",
    "localStorage.clear",
    "sessionStorage.clear",
    "indexedDB.deleteDatabase",
  ]
}
