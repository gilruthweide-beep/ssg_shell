import Foundation
import UIKit
import WebKit

/// §10.5 / §10.6 A process-level singleton creates and owns the IM WKWebView; containers only attach and detach it.
///
/// - §10.5 Keep one instance: the Web application uses BroadcastChannel to elect a primary same-origin instance.
///   A second WebView may become secondary, showing a normal interface without opening a persistent connection.
/// - §10.6 Keep the instance alive across background entry, locking, and tab changes. Recreation reloads the entire Web app,
///   reconnects its persistent connection, and fetches history again.
final class ImWebViewHolder {

  static let shared = ImWebViewHolder()

  private init() {}

  private(set) var webView: WKWebView?

  /// Capabilities supplied by the attached container, or nil when detached.
  weak var host: ShellWebViewHost? {
    didSet {
      filePicker.host = host
      navigationDelegate?.host = host
      uiDelegate?.host = host
    }
  }

  /// §1.3 iOS always supports `WKUserScript(injectionTime: .atDocumentStart)`;
  /// it executes before the first page script, so this value is always true.
  let documentStartInjected = true

  let filePicker = FilePickerBridge()

  // WKWebView holds weak delegate references; retain them here.
  private var router: ScriptMessageRouter?
  private var navigationDelegate: ShellNavigationDelegate?
  private var uiDelegate: ShellUIDelegate?

  var isCreated: Bool { webView != nil }

  // ----------------------------------------------------------------- Creation

  /// Idempotent: return the existing instance instead of recreating it on each entry (§10.6).
  @discardableResult
  func get(config: ShellConfig) -> WKWebView {
    if let webView { return webView }

    let info = ShellInjection.shellInfo(shellVersion: config.shellVersion)
    let configuration = WKWebViewConfiguration()

    // §8.1 Use the default() data store; nonPersistent() would make every startup look like a new device.
    // §8.3 Intentionally avoid removeData(ofTypes:), which logs users out,
    // removes cached messages, and resets the once-per-device eventRegister marker.
    configuration.websiteDataStore = .default()
    // §8.2 Runtime environment.
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    // §7.1 Route window.open through createWebViewWith for matching platform behavior.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    // §2.2 WebKit appends this to the default user agent instead of replacing it.
    configuration.applicationNameForUserAgent =
      ShellInjection.applicationNameForUserAgent(shellVersion: config.shellVersion)
    // §2.2 The Web and server detect the platform by `iPhone` / `iPad` in the UA. On iPad, WKWebView by default requests
    // the desktop site and the UA becomes `Macintosh` without `iPad`, so pin it to mobile.
    configuration.defaultWebpagePreferences.preferredContentMode = .mobile

    let controller = configuration.userContentController
    // Install before the request so the first visible IM frame has CJK glyphs.
    controller.addUserScript(CjkFontFallback.userScript)
    // §1.2 Inject before any page script: Web constants are evaluated during module loading.
    controller.addUserScript(
      WKUserScript(
        source: ShellInjection.injectionScript(info),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    // §7.3 Take over <input type="file"> instead of falling back to WebKit's default menu.
    controller.addUserScript(
      WKUserScript(
        source: ShellInjection.fileInputScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    if config.forwardConsole {
      // §11.6 WKWebView has no onConsoleMessage callback, so wrap the console methods.
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
    // §3.2 Register all ten handlers; missing handlers throw errors caught by Web code, but lose events.
    for name in ShellInjection.eventHandlers {
      controller.add(router, name: name)
    }
    controller.add(router, name: ShellInjection.consoleHandler)
    controller.add(router, name: ShellInjection.filePickHandler)
    // §7.3.4 Use a reply-capable handler so the page can request file contents in chunks.
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

    // §9.4 With the WebView inside the safe area, env(safe-area-inset-*) must be zero;
    // prevent WebKit from applying an additional contentInset.
    web.scrollView.contentInsetAdjustmentBehavior = .never
    // §9.5 Prevent whole-page rubber-banding from pulling the chat interface out of place.
    web.scrollView.bounces = false
    web.scrollView.alwaysBounceVertical = false
    web.scrollView.showsHorizontalScrollIndicator = false
    // §9.2 The Web application handles the keyboard; keep the native frame and contentInset unchanged.
    web.scrollView.keyboardDismissMode = .none
    // §9.3 The page declares user-scalable=no; avoid adding native zoom.
    web.allowsBackForwardNavigationGestures = false
    web.allowsLinkPreview = false
    // Match the first-screen background to avoid dark edge flashes during startup, keyboard transitions, and container changes.
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
      // §9.6 Load the landing URL immediately after startup without waiting for other initialization.
      web.load(URLRequest(url: url))
    } else {
      NSLog("[SsgShell] entryUrl is empty or invalid; WebView was created without loading a URL")
    }
    return web
  }

  // --------------------------------------------------------------- Native → Web

  /// §4 The Web application creates `window.__ssgShell` during startup and recreates it on each page load.
  /// Check it before calling; skip missing callbacks instead of repeatedly retrying during early loading.
  func callWeb(_ method: String, arg: String? = nil) {
    guard let webView else { return }
    let call = arg == nil ? "\(method)()" : "\(method)(\(arg!))"
    let js = "window.__ssgShell && window.__ssgShell.\(call)"
    DispatchQueue.main.async {
      webView.evaluateJavaScript(js) { _, error in
        if let error = error as NSError?, error.code != WKError.javaScriptResultTypeIsUnsupported.rawValue {
          NSLog("[SsgShell] callWeb(\(method)) failed:\(error.localizedDescription)")
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

  /// §7.3.4 Return the manifest to the page, which then requests file chunks.
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
          NSLog("[SsgShell] Unable to deliver file manifest:\(error.localizedDescription)")
        }
      }
    }
  }

  // ----------------------------------------------------------------- Lifecycle

  /// §10.2 iOS updates WKWebView document.hidden automatically from view hierarchy
  /// and application state; visibilitychange provides a second foreground signal.
  /// Android requires explicit onPause() / onResume() calls to update visibility.
  ///
  /// §10.3 Keep timers running; iOS has no pauseTimers() API.
  func onResumeWeb() {}

  func onPauseWeb() {}

  func reload() {
    DispatchQueue.main.async { [weak self] in
      self?.webView?.reload()
    }
  }

  var currentUrl: String { webView?.url?.absoluteString ?? "" }

  /// Read the final user agent from the instance; WebKit combines the default with applicationNameForUserAgent.
  private(set) var cachedUserAgent: String = ""

  func refreshUserAgent() {
    evaluate("navigator.userAgent") { [weak self] value in
      guard let value, !value.isEmpty else { return }
      self?.cachedUserAgent = value
    }
  }

  /// §11.2.3 Each iOS WKWebView releases its own WebContent process when destroyed; direct recreation is enough
  /// (Android must terminate the shared renderer first).
  @discardableResult
  func recreate(config: ShellConfig) -> WKWebView {
    destroy()
    let fresh = get(config: config)
    host?.onWebViewReplaced(fresh)
    return fresh
  }

  /// Call only during recreation.
  ///
  /// §8.3 Intentionally avoid `WKWebsiteDataStore.removeData(ofTypes:)` and injected JavaScript
  /// that clears caches or unregisters Service Workers. Clearing caches at startup is prohibited.
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

  /// JSON literals embedded in evaluateJavaScript source must escape U+2028 / U+2029:
  /// they are legal JSON characters but JavaScript line separators, so an unescaped filename could break the script.
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
      // JS true / false come across the bridge as boolean NSNumbers, whose stringValue gives "1" / "0".
      // Android's evaluateJavascript gives "true" / "false"; both platforms must match:
      // the §1.3 injection check compares this string with "false", so without this iOS would always report it as not applied.
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
  /// Configuration uses Android-compatible ARGB colors; split components for UIColor.
  convenience init(argb: UInt32) {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255
    let red = CGFloat((argb >> 16) & 0xFF) / 255
    let green = CGFloat((argb >> 8) & 0xFF) / 255
    let blue = CGFloat(argb & 0xFF) / 255
    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }
}
