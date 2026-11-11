import Foundation
import UIKit
import WebKit

/// 壳的大脑。进程级单例，不依赖 Flutter 引擎是否活着。
///
/// 之所以不把这些挂在插件上：按 §9.6，已开启 B 面时冷启动要直接加载 Web，那一刻引擎
/// 还没起来；而 §11.2 的存活监测、§11.1 的心跳、§10.4 的网络通知必须在那一刻就已经在跑。
final class ShellCore {

  static let shared = ShellCore()

  private init() {}

  private var config = ShellConfig()

  /// Dart 侧的回调通道。引擎没起来或已销毁时为 nil，所有 emit 自动跳过。
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

  /// IM 容器是否挂着 WebView 并可见。
  private(set) var imRunning = false

  /// 上一次计算出的「WebView 可见」状态，用于只在翻转时通知 Web。
  private var webVisible = false

  private var webReady = false

  /// 带状态含义的几条 Web 事件各留最近一条。Dart 上线之前发生的事件它收不到，
  /// 而 `login` 同一 uid 只发一次（§3.1）—— 丢了就不会再绑 OneSignal（§5.2）。
  /// Dart 调 `initialize()` 时由 `replaySticky(to:)` 补发。
  private var stickyWebReady: WebEvent?
  private var stickyLogin: WebEvent?
  private var stickyUnread: WebEvent?
  private var stickyChatOpen: WebEvent?

  /// 首屏加载失败时没有容器挂着（预加载阶段），重试页没处可盖。
  /// 记下来，容器挂上时补（`onHostAttached`）。
  private var loadFailed = false
  private var loadFailedMessage: String?

  private var reportedChannelCode = ""
  private var lastWebReadyAtMs: Int64?

  /// §5.3 冷启动点通知时 Web 还没初始化完，参数要暂存，收到 webReady 再调。
  private var pendingOpenChat: OpenChatRequest?

  private var injectionOk = false

  /// §6.2 收到 `eventLogin` 之后才允许申请通知权限。
  private var loginSeen = false

  private var started = false

  private weak var container: ImViewController?

  // -------------------------------------------------------------- 装配

  /// 由 `SsgShellPlugin.register(with:)` 调（AppDelegate 注册插件那一刻，早于首帧），幂等。
  func attach() {
    guard !started else { return }
    started = true
    config = ShellConfig.fromDisk()
    console.capacity = config.consoleBufferSize

    let center = NotificationCenter.default
    // §4 / §10.2 前后台。didBecomeActive 覆盖了锁屏解锁、从后台任务切回、
    // 从通知点进来这几种情况。
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
    // §11.4 只在 didReceiveMemoryWarning 时调；切后台、回前台都不应触发。
    // iOS 用 Flutter 时同样直接监听系统通知，不经 Flutter 的 didHaveMemoryPressure 转发。
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

    // 进程起来时 App 通常已经是 active 了，补一次，别等到下一次切回来。
    if UIApplication.shared.applicationState == .active {
      setAppForeground(true)
    }
  }

  func setDartApi(_ api: SsgShellFlutterApi?) {
    dart = api
  }

  func currentConfig() -> ShellConfig { config }

  /// Dart 调 `initialize()` 时补发它上线之前错过的状态类事件。必须在主线程、
  /// 在 `initialize` 返回之前调 —— Dart 那边靠「先到事件、后到返回值」这个顺序接住它们。
  func replaySticky(to api: SsgShellFlutterApi) {
    for event in [stickyWebReady, stickyLogin, stickyUnread, stickyChatOpen] {
      guard let event else { continue }
      api.onWebEvent(event: event) { _ in }
    }
  }

  var isWebReady: Bool { webReady }

  /// 容器挂上来时补上它错过的状态。
  ///
  /// `eventWebReady` 每次页面加载只发一次，预加载期间发过就不会再来 —— splash 的那一半
  /// 由容器自己读 `isWebReady` 决定；这里补首屏加载失败的重试页（§9.6）。
  func onHostAttached(_ host: ShellWebViewHost) {
    if loadFailed { host.showErrorPage(loadFailedMessage) }
  }

  /// 页面要重新加载了（reload、重建）：上一个页面留下的状态全部作废。
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
    // §9.6 落盘，下次冷启动直接按缓存走，不等 Dart。
    next.persist()
    return ShellInjection.shellInfo(shellVersion: next.shellVersion)
  }

  /// §8.4 体验与性能 1 的 iOS 对应项：B 面开启时提前创建 WebView 并开始加载。
  func preload() {
    guard config.bSideEnabled else {
      NSLog("[SsgShell] B 面未开启，跳过 IM 预加载")
      return
    }
    guard !config.entryUrl.isEmpty else {
      NSLog("[SsgShell] entryUrl 为空，预加载跳过")
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
      // 已经在前台时是空操作。
      if let container = self.container, container.view.window != nil { return }
      guard let top = Self.topViewController() else {
        NSLog("[SsgShell] 找不到可以 present 的 VC，IM 容器打不开")
        return
      }
      let controller = ImViewController(config: self.config)
      self.container = controller
      top.present(controller, animated: false)
    }
  }

  /// 按 §10.6 只收起容器，**不会**销毁 WebView 实例。
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

  /// §5.3 打开会话。
  ///
  /// 等 `eventWebReady` 再调：冷启动点通知时 Web 还没初始化完，需把参数暂存，收到后再调。
  /// 只调一次 —— Web 内部会等会话数据就绪（最长 20 秒）再跳转，不需要原生重试。
  func openChat(_ request: OpenChatRequest) {
    guard !request.chatId.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.webReady else {
        self.pendingOpenChat = request
        self.emit(
          .deepLinkQueued,
          "Web 未就绪，已暂存 chatId=\(request.chatId)",
          ["chatId": request.chatId]
        )
        return
      }
      self.deliverOpenChat(request)
    }
  }

  private func deliverOpenChat(_ request: OpenChatRequest) {
    var payload: [String: Any] = ["chatId": request.chatId]
    // §5.3 messageId 传数字或可被 Number() 解析的字符串，可省略。
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
    emit(.deepLinkDelivered, "已交给 Web：chatId=\(request.chatId)", extra)
  }

  /// §5.4 前台抑制 + §11.3 推送捅醒。
  func handlePushReceived(_ message: PushMessage) -> PushDecision {
    let suppress = gate.shouldSuppress(
      chatId: message.chatId,
      appInForeground: appInForeground,
      enabled: config.suppressForegroundNotifications
    )

    // §11.3 一条消息的推送到达而 App 正在前台，说明这条消息 Web 没有通过长连接收到，
    // 连接已死。除了按 §5.4 抑制通知，额外调一次 onNetwork 把 Web 捅醒。
    var nudged = false
    if appInForeground {
      // 推送都到了，网络一定是通的；监听器还没把状态翻过来时按 other 算。
      let observed = network?.currentType ?? NetworkType.none
      let type: NetworkType = observed == .none ? .other : observed
      DispatchQueue.main.async { [weak self] in self?.deliverNetwork(type) }
      nudged = true
    }

    var reason = appInForeground ? "前台" : "后台"
    reason += "；tracked=\(gate.trackedChatId ?? "-")"
    reason += "；incoming=\(message.chatId ?? "-")"
    if suppress { reason += "；命中前台抑制" }
    if nudged { reason += "；已调 onNetwork 捅醒" }
    NSLog("[SsgShell] handlePushReceived: \(reason)")

    return PushDecision(
      suppressNotification: suppress,
      nudgedWeb: nudged,
      appInForeground: appInForeground,
      reason: reason
    )
  }

  /// §5.3 通知点击。
  func handlePushOpened(_ message: PushMessage) {
    if config.bSideEnabled { openIm() }
    guard let chatId = message.chatId, !chatId.isEmpty else {
      NSLog("[SsgShell] 通知点击里没有 chat_id，只打开 App")
      return
    }
    openChat(OpenChatRequest(chatId: chatId, messageId: message.messageId))
  }

  func nudgeNetwork(_ type: NetworkType) {
    DispatchQueue.main.async { [weak self] in self?.deliverNetwork(type) }
  }

  func reloadWeb() {
    NSLog("[SsgShell] 手动 reload（§11.2）")
    ImWebViewHolder.shared.reload()
  }

  /// §11.2.3 iOS 每个 WKWebView 的 WebContent 进程随实例销毁，直接重建即可。
  func recreateWebView() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onPageReset()
      self.gate.onPageLoadStarted()
      ImWebViewHolder.shared.recreate(config: self.config)
      self.watchdog.onWebViewRecreated()
      self.emit(.webViewRecreated, "WebView 实例已重建", [:])
    }
  }

  func setBadgeCount(_ count: Int) {
    gate.setBadge(count)
    BadgeApplier.apply(count)
  }

  func verifyInjection(_ completion: @escaping (Bool) -> Void) {
    // §1.3 这是 Web 侧的判定结果。只要它是 true，无论 __SSG_SHELL__ 打印出什么都算失败。
    let js = "document.documentElement.classList.contains('is-web-browser')"
    ImWebViewHolder.shared.evaluate(js) { [weak self] raw in
      let value = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
      let ok = value == "false"
      self?.injectionOk = ok
      self?.emit(
        .injectionChecked,
        ok ? "注入生效" : "注入未生效（is-web-browser=\(value.isEmpty ? "null" : value)），见 §1.2",
        ["isWebBrowser": value.isEmpty ? "null" : value]
      )
      completion(ok)
    }
  }

  func evaluateJavaScript(_ script: String, completion: @escaping (Result<String, Error>) -> Void) {
    // §8.3 存储不要清。清存储的后果：用户被登出、本地消息缓存全失、媒体重新下载一遍、
    // 诊断上下文丢失，并且 eventRegister 的「每设备一次」标记被抹掉，渠道注册数虚高。
    if let hit = Self.forbiddenJs.first(where: { script.range(of: $0, options: .caseInsensitive) != nil }) {
      completion(.failure(NSError(
        domain: "ssg_shell",
        code: 400,
        userInfo: [
          NSLocalizedDescriptionKey:
            "脚本包含禁止的存储清理调用「\(hit)」，见 §8.3。只能由用户显式「清除数据」触发。",
        ]
      )))
      return
    }
    ImWebViewHolder.shared.evaluate(script) { raw in
      completion(.success(raw ?? ""))
    }
  }

  // ------------------------------------------------------------ 诊断

  /// §8.1 / §11.7 内核信息。
  ///
  /// §11.7 的「引导用户更新内核」是 Android 专属的：那边 WebView 是可独立更新的系统
  /// 组件，老设备上会停在很旧的版本。iOS 的 WebKit 随系统升级，壳的最低版本（iOS 14）
  /// 已经远超 §8.1 要的能力集，所以这里只报版本，不判不合格。
  func kernelInfo() -> KernelInfo {
    let versionName = ShellInjection.webKitVersion()
    let major = Int64(versionName.split(separator: ".").first.map(String.init) ?? "") ?? -1
    return KernelInfo(
      verdict: versionName.isEmpty ? .unknown : .ok,
      versionName: versionName,
      majorVersion: major,
      // Android 为 WebView 实现包名；iOS 为空串。
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

  /// §11.6 导出：当前 URL、UA、内核版本、`__SSG_SHELL__`、最近一次 reload 时间、
  /// 最近 N 条 console。
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
    out += "==== SSG Shell 诊断 ====\n"
    out += "导出时间        \(formatter.string(from: Date()))\n"
    out += "平台            ios\n"
    out += "包名            \(d.shellInfo.bundleId)\n"
    out += "壳版本          \(d.shellInfo.shellVersion)\n"
    out += "机型            \(d.shellInfo.deviceModel)\n"
    out += "系统版本        \(d.shellInfo.osVersion)\n"
    out += "WebKit          \(d.kernel.versionName) (\(d.kernel.verdict))\n"
    out += "入口地址        \(d.entryUrl)\n"
    out += "当前地址        \(d.currentUrl)\n"
    out += "UA              \(d.userAgent)\n"
    out += "channelCode     \(d.channelCode.isEmpty ? "(未提供，可选；以 Web 归因事件为准)" : d.channelCode)\n"
    out += "注入自检        \(d.injectionOk ? "通过 shellSrc:inject" : "未通过，见 §1.2")\n"
    out += "IM 挂载         \(d.imRunning)\n"
    out += "App 前台        \(d.appInForeground)\n"
    out += "最近 webReady   \(time(d.lastWebReadyAtMs))\n"
    out += "最近 webAlive   \(time(d.lastWebAliveAtMs))\n"
    out += "最近 reload     \(time(d.lastReloadAtMs))  次数 \(d.reloadCount)\n"
    out += "WebView 重建    \(d.recreateCount) 次\n"
    out += "当前会话        \(d.trackedChatId ?? "-")\n"
    out += "角标            \(d.badgeCount)\n\n"
    out += "---- 最近 \(d.consoleTail.count) 条 console ----\n"
    out += console.dump()
    return out
  }

  // ------------------------------------------------- WebView 回调入口

  /// §3.1 从 `ScriptMessageRouter` 过来。
  func onWebEvent(_ event: WebEvent) {
    DispatchQueue.main.async { [weak self] in
      self?.handleWebEvent(event)
    }
  }

  private func handleWebEvent(_ event: WebEvent) {
    // §2.1 渠道取值由 Web 负责，诊断只记录归因事件，不读取或改写 URL。
    if event.name == .register || event.name == .login || event.name == .messageSent {
      reportedChannelCode = event.params["channelCode"] ?? ""
    }
    switch event.name {
    case .webReady:
      webReady = true
      stickyWebReady = event
      lastWebReadyAtMs = event.receivedAtMs
      // §9.6 收到 eventWebReady 后立即撤 splash，不要用固定时长定时器。
      ImWebViewHolder.shared.host?.dismissSplash(.splashDismissed)
      // §5.3 冷启动点通知时暂存的参数，就绪后补发，只调一次。
      if let queued = pendingOpenChat {
        pendingOpenChat = nil
        deliverOpenChat(queued)
      }
      // §1.3 首屏可见即可自检，不用等人去连调试器。
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
      // §5.4 角标数 = Web 给的未读总数，count 为 0 时清零。
      if config.manageBadge { BadgeApplier.apply(count) }

    // §6.2 通知权限在收到 eventLogin 之后才允许申请，这里只放开闸门，
    // 真正弹窗由 Dart 侧决定时机（宿主可能要先做自己的引导页）。
    case .login:
      loginSeen = true
      stickyLogin = event

    case .logout:
      loginSeen = false
      stickyLogin = nil
      stickyChatOpen = nil
      // §5.4 退出登录时 Web 会发 unreadCount=0，这里不额外清，交给那条事件。

    default:
      break
    }

    let api = dart
    api?.onWebEvent(event: event) { _ in /* Dart 侧没挂监听不是错误 */ }
  }

  func hasLoggedIn() -> Bool { loginSeen }

  func onPageStarted(_ url: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // §5.4 页面重新加载时不会发 chatClose，原生在页面开始加载时要清空记住的 chatId。
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
    NSLog("[SsgShell] 首屏加载失败 \(url): \(description)")
    DispatchQueue.main.async { [weak self] in
      self?.loadFailed = true
      self?.loadFailedMessage = nil
      ImWebViewHolder.shared.host?.showErrorPage(nil)
      self?.emit(.loadFailed, description, ["url": url])
    }
  }

  func onSslError(_ code: Int) {
    DispatchQueue.main.async { [weak self] in
      let message = "安全连接校验失败，请检查网络环境后重试"
      self?.loadFailed = true
      self?.loadFailedMessage = message
      ImWebViewHolder.shared.host?.showErrorPage(message)
      self?.emit(.loadFailed, "SSL 校验失败（code=\(code)）", ["sslError": "\(code)"])
    }
  }

  /// §7.2 内容进程被回收：`reload()`。不实现就永久白屏。
  func onRenderProcessGone(crashed: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.emit(
        .renderProcessGone,
        crashed ? "WebContent 进程被回收" : "WebContent 进程已结束",
        ["didCrash": "\(crashed)"]
      )
      self.onPageReset()
      self.gate.onPageLoadStarted()
      // §7.2 明确要求这里 reload()。reload 不生效的情况由 §11.2.3 的看门狗接手重建。
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
    // §11.6 把 Web 的 console 落到原生日志。
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

  // ------------------------------------------------------- 生命周期

  @objc private func onDidBecomeActive() {
    setAppForeground(true)
    PermissionCoordinator.refreshNotificationState()
  }

  @objc private func onDidEnterBackground() {
    setAppForeground(false)
  }

  /// §11.4 内存告警。只在系统真的告警时调 —— 切后台、回前台都不应触发。
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

  /// §10.2 回前台信号。
  ///
  /// 判据是「WebView 真的可见」而不是「App 在前台」：IM 容器和 Flutter 的 A 面互切时
  /// App 一直在前台，但 WebView 已经不可见、Web 的 `document.hidden` 翻成 true、
  /// 停发 `eventWebAlive`。这时如果 §11.2 的计时还在跑，60 秒后会误判卡死。
  private func updateWebVisibility() {
    let visible = appInForeground && imRunning
    guard visible != webVisible else { return }
    webVisible = visible
    if visible {
      // §10.2.1 每次回前台都调 onForeground()。锁屏解锁、从后台任务切回、
      // 从通知点进来都算。注入生效后，后台停留超过 1.5 秒回前台即立刻重连。
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
    // §4 断网时不用调，传 none 会被忽略。
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

  // ------------------------------------------------------------ 杂项

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

  /// §8.3 不允许出现在任何常规路径上的调用。
  ///
  /// 只拦「清」，不拦「读」：§12.1 的自测要跑
  /// `await navigator.serviceWorker.getRegistration()`，那是读，必须放行。
  private static let forbiddenJs = [
    "caches.delete",
    ".unregister(",
    "localStorage.clear",
    "sessionStorage.clear",
    "indexedDB.deleteDatabase",
  ]
}
