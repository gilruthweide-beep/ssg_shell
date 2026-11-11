import Foundation
import UIKit
import WebKit

/// §10.5 / §10.6 IM 的 WKWebView 由进程级单例创建和持有，容器只负责挂上和取下。
///
/// - §10.5 只开一个实例：Web 用 BroadcastChannel 在同源页面之间选举主实例，第二个同域
///   WebView 可能被选为从实例 —— 界面看着完全正常，但不建长连接。
/// - §10.6 实例长活：不在切后台、锁屏、切 Tab 时销毁。重建 = 重新加载整个 Web =
///   重建长连接 + 重拉历史。
final class ImWebViewHolder {

  static let shared = ImWebViewHolder()

  private init() {}

  private(set) var webView: WKWebView?

  /// 当前挂载的容器提供的能力，没挂载时为 nil。
  weak var host: ShellWebViewHost? {
    didSet {
      filePicker.host = host
      navigationDelegate?.host = host
      uiDelegate?.host = host
    }
  }

  /// §1.3 iOS 的 `WKUserScript(injectionTime: .atDocumentStart)` 没有「不支持」这档，
  /// 建出来就一定在首个脚本之前执行，所以这里恒为 true。
  let documentStartInjected = true

  let filePicker = FilePickerBridge()

  // WKWebView 只弱引用这几个 delegate，得由这里持住。
  private var router: ScriptMessageRouter?
  private var navigationDelegate: ShellNavigationDelegate?
  private var uiDelegate: ShellUIDelegate?

  var isCreated: Bool { webView != nil }

  // ----------------------------------------------------------------- 创建

  /// 幂等。已存在就直接返回，不重建（§10.6「不要每次进入重建 WebView」）。
  @discardableResult
  func get(config: ShellConfig) -> WKWebView {
    if let webView { return webView }

    let info = ShellInjection.shellInfo(shellVersion: config.shellVersion)
    let configuration = WKWebViewConfiguration()

    // §8.1 数据存储必须是 default()：用 nonPersistent() 等于每次启动都是新设备。
    // §8.3 这里也刻意**不**调 removeData(ofTypes:) —— 清存储会让用户被登出、
    // 本地消息缓存全失、eventRegister 的「每设备一次」标记被抹掉。
    configuration.websiteDataStore = .default()
    // §8.2 运行环境。
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    // §7.1 对齐：window.open 交给 createWebViewWith 处理。
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    // §2.2 WebKit 会把它**追加**在默认 UA 后面，不是整段替换。
    configuration.applicationNameForUserAgent =
      ShellInjection.applicationNameForUserAgent(shellVersion: config.shellVersion)
    // §2.2 Web 与服务端按 UA 里的 `iPhone` / `iPad` 判平台。iPad 上 WKWebView 默认按
    // 桌面站点请求，UA 会变成 `Macintosh`、不带 `iPad`，所以固定成移动版。
    configuration.defaultWebpagePreferences.preferredContentMode = .mobile

    let controller = configuration.userContentController
    // §1.2 必须在页面任何脚本执行之前完成注入：Web 侧有一组常量在模块加载那一刻求值。
    controller.addUserScript(
      WKUserScript(
        source: ShellInjection.injectionScript(info),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    // §7.3 接管 <input type="file">，不能落回 WebKit 的默认菜单。
    controller.addUserScript(
      WKUserScript(
        source: ShellInjection.fileInputScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    if config.forwardConsole {
      // §11.6 WKWebView 没有 onConsoleMessage，只能包一层 console。
      controller.addUserScript(
        WKUserScript(
          source: ShellInjection.consoleScript,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true
        )
      )
    }

    let router = ScriptMessageRouter(filePicker: filePicker)
    self.router = router
    // §3.2 十个 handler 全部注册，未注册的会抛异常，Web 已捕获但事件会丢。
    for name in ShellInjection.eventHandlers {
      controller.add(router, name: name)
    }
    controller.add(router, name: ShellInjection.consoleHandler)
    controller.add(router, name: ShellInjection.filePickHandler)
    // §7.3.4 页面逐块拉文件内容，要带回复的那种 handler。
    controller.addScriptMessageHandler(
      router,
      contentWorld: .page,
      name: ShellInjection.fileChunkHandler
    )

    let web = WKWebView(frame: .zero, configuration: configuration)
    let navigation = ShellNavigationDelegate(config: config)
    let ui = ShellUIDelegate(config: config)
    navigation.host = host
    ui.host = host
    navigationDelegate = navigation
    uiDelegate = ui
    web.navigationDelegate = navigation
    web.uiDelegate = ui

    // §9.4 WebView 放进安全区后页面内 env(safe-area-inset-*) 必须为 0，
    // 所以这里不要再让它自己加 contentInset。
    web.scrollView.contentInsetAdjustmentBehavior = .never
    // §9.5 避免整页橡皮筋把聊天界面拉出来。
    web.scrollView.bounces = false
    web.scrollView.alwaysBounceVertical = false
    web.scrollView.showsHorizontalScrollIndicator = false
    // §9.2 键盘由 Web 处理：frame 保持不变，原生不做偏移，也不动 contentInset。
    web.scrollView.keyboardDismissMode = .none
    // §9.3 页面已声明 user-scalable=no，这里只要别放大就行。
    web.allowsBackForwardNavigationGestures = false
    web.allowsLinkPreview = false
    // 背景色与首屏一致：启动、键盘弹收、容器切换时边缘不会闪出黑色。
    let background = UIColor(argb: config.backgroundColorArgb)
    web.backgroundColor = background
    web.scrollView.backgroundColor = background
    web.isOpaque = false

    filePicker.host = host
    filePicker.deliver = { [weak self] requestId, files in
      self?.deliverFiles(requestId: requestId, files: files)
    }

    webView = web

    if let url = config.resolvedUrl() {
      // §9.6 WebView 在启动后立即开始加载入口地址，不等其他初始化做完。
      web.load(URLRequest(url: url))
    } else {
      NSLog("[SsgShell] entryUrl 为空或不合法，WebView 已创建但没有加载任何地址")
    }
    return web
  }

  // --------------------------------------------------------------- Native → Web

  /// §4 `window.__ssgShell` 由 Web 在启动流程中创建，页面加载早期不存在，
  /// 每次重新加载会重建 —— 调用前必须判空，不存在时跳过，不要重试轰炸。
  func callWeb(_ method: String, arg: String? = nil) {
    guard let webView else { return }
    let call = arg == nil ? "\(method)()" : "\(method)(\(arg!))"
    let js = "window.__ssgShell && window.__ssgShell.\(call)"
    DispatchQueue.main.async {
      webView.evaluateJavaScript(js) { _, error in
        if let error = error as NSError?, error.code != WKError.javaScriptResultTypeIsUnsupported.rawValue {
          NSLog("[SsgShell] callWeb(\(method)) 失败：\(error.localizedDescription)")
        }
      }
    }
  }

  func evaluate(_ js: String, completion: ((String?) -> Void)? = nil) {
    guard let webView else {
      completion?(nil)
      return
    }
    DispatchQueue.main.async {
      webView.evaluateJavaScript(js) { value, _ in
        completion?(Self.describe(value))
      }
    }
  }

  /// §7.3.4 把清单交回页面，页面随后逐块来拉。
  private func deliverFiles(requestId: String, files: [[String: Any]]) {
    guard let webView else { return }
    let payload: String
    if let data = try? JSONSerialization.data(withJSONObject: files),
       let json = String(data: data, encoding: .utf8) {
      payload = json
    } else {
      payload = "[]"
    }
    let js = "window.__ssgFileBridge && window.__ssgFileBridge.deliver('\(requestId)', \(Self.jsSafe(payload)))"
    DispatchQueue.main.async {
      webView.evaluateJavaScript(js) { _, error in
        if let error {
          NSLog("[SsgShell] 交回文件清单失败：\(error.localizedDescription)")
        }
      }
    }
  }

  // ----------------------------------------------------------------- 生命周期

  /// §10.2 iOS 这边不需要手动翻可见性：WKWebView 的 `document.hidden` 跟着
  /// 视图层级和 App 状态自己翻，`visibilitychange` 是免费的第二条通道。
  /// Android 那边必须显式调 `onPause()` / `onResume()` 才会翻。
  ///
  /// §10.3 也不要去冻结定时器 —— iOS 没有 `pauseTimers()` 这种 API，这正好。
  func onResumeWeb() {}

  func onPauseWeb() {}

  func reload() {
    DispatchQueue.main.async { [weak self] in
      self?.webView?.reload()
    }
  }

  var currentUrl: String { webView?.url?.absoluteString ?? "" }

  /// UA 要从实例上问，因为它由 WebKit 拼好（默认 UA + applicationNameForUserAgent）。
  private(set) var cachedUserAgent: String = ""

  func refreshUserAgent() {
    evaluate("navigator.userAgent") { [weak self] value in
      guard let value, !value.isEmpty else { return }
      self?.cachedUserAgent = value
    }
  }

  /// §11.2.3 iOS 每个 WKWebView 的 WebContent 进程随实例销毁，直接重建即可
  /// （Android 必须先结束共用的渲染进程）。
  @discardableResult
  func recreate(config: ShellConfig) -> WKWebView {
    destroy()
    let fresh = get(config: config)
    host?.onWebViewReplaced(fresh)
    return fresh
  }

  /// 只在重建路径上调。
  ///
  /// §8.3：这里刻意**不**调 `WKWebsiteDataStore.removeData(ofTypes:)`，也不往页面注入
  /// JS 清 `caches` 或注销 Service Worker。「启动时清一次缓存保证干净」是禁止的做法。
  private func destroy() {
    guard let web = webView else { return }
    webView = nil
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
    web.removeFromSuperview()
    let controller = web.configuration.userContentController
    controller.removeAllUserScripts()
    for name in ShellInjection.eventHandlers {
      controller.removeScriptMessageHandler(forName: name)
    }
    controller.removeScriptMessageHandler(forName: ShellInjection.consoleHandler)
    controller.removeScriptMessageHandler(forName: ShellInjection.filePickHandler)
    controller.removeScriptMessageHandler(
      forName: ShellInjection.fileChunkHandler,
      contentWorld: .page
    )
    router = nil
    navigationDelegate = nil
    uiDelegate = nil
  }

  /// JSON 字面量要塞进 `evaluateJavaScript` 的源码里，而 U+2028 / U+2029 在 JSON 里
  /// 合法、在 JS 源码里是换行 —— 不转义的话一个带这种字符的文件名就能让整段脚本语法错误。
  static func jsSafe(_ json: String) -> String {
    json
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  static func describe(_ value: Any?) -> String {
    switch value {
    case .none, is NSNull: return ""
    case let text as String: return text
    case let number as NSNumber:
      // JS 的 true / false 过线后是布尔型的 NSNumber，stringValue 会给出 "1" / "0"。
      // Android 的 evaluateJavascript 给的是 "true" / "false"，两端要一致 ——
      // §1.3 的注入自检就是拿这个串和 "false" 比，不处理的话 iOS 上永远报未生效。
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      return number.stringValue
    default:
      if let value,
         let data = try? JSONSerialization.data(
          withJSONObject: value,
          options: [.fragmentsAllowed]
         ),
         let text = String(data: data, encoding: .utf8) {
        return text
      }
      return String(describing: value)
    }
  }
}

extension UIColor {
  /// 配置里的颜色是 ARGB（和 Android 一边一致），`UIColor` 要拆开。
  convenience init(argb: UInt32) {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255
    let red = CGFloat((argb >> 16) & 0xFF) / 255
    let green = CGFloat((argb >> 8) & 0xFF) / 255
    let blue = CGFloat(argb & 0xFF) / 255
    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }
}
