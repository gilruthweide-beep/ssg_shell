import Foundation
import UIKit
import WebKit

/// §7.2 `WKUIDelegate` 回调：`window.open`、麦克风授权、以及页面偶尔会用的几个弹窗。
///
/// 文件选择不走这里 —— §7.3 要求由壳接管，见 `FilePickerBridge` 与
/// `ShellInjection.fileInputScript`。全屏视频由 WebKit 自己处理，
/// `allowsInlineMediaPlayback` 开着就能进退全屏。
final class ShellUIDelegate: NSObject, WKUIDelegate {

  private let entryHost: String?

  weak var host: ShellWebViewHost?

  init(config: ShellConfig) {
    self.entryHost = config.entryHost
    super.init()
  }

  /// §7.2 `window.open` / `target="_blank"`：**返回 nil 并在当前 WebView 加载**。
  ///
  /// 不实现点链接没反应。外链交给系统浏览器，同源地址在当前实例里加载 ——
  /// 新开一个同域 WebView 会踩 §10.5（第二个实例可能被选为主实例）。
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard let url = navigationAction.request.url else { return nil }
    if isInternal(url) {
      webView.load(URLRequest(url: url))
    } else {
      ShellNavigationDelegate.openExternal(url)
    }
    return nil
  }

  /// §7.2 授予麦克风（iOS 15+）。不实现语音录不了。
  ///
  /// §6.2：由 `getUserMedia` 触发，原生**在授权回调里再**向系统申请 ——
  /// 启动阶段一律不申请。
  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    // §6.1 Web 只用麦克风：没有音视频通话，摄像头一律不给。
    guard type == .microphone else {
      decisionHandler(.deny)
      return
    }
    PermissionCoordinator.requestMicrophone { granted in
      decisionHandler(granted ? .grant : .deny)
    }
  }

  // ------------------------------------------------------------- 页面弹窗

  // Web 不依赖这三个，但不实现的话 WKWebView 会直接丢掉调用、让页面的 await 永远挂住。
  // 实现成最朴素的系统弹窗即可。

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    guard let presenter = host?.presenter else {
      completionHandler()
      return
    }
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
    presenter.present(alert, animated: true)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard let presenter = host?.presenter else {
      completionHandler(false)
      return
    }
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
    presenter.present(alert, animated: true)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    guard let presenter = host?.presenter else {
      completionHandler(nil)
      return
    }
    let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
    alert.addTextField { $0.text = defaultText }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
      completionHandler(alert.textFields?.first?.text)
    })
    presenter.present(alert, animated: true)
  }

  private func isInternal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    guard let entry = entryHost else { return true }
    return host == entry || host.hasSuffix(".\(entry)")
  }
}
