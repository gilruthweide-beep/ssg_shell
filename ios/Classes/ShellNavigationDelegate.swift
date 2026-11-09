import Foundation
import UIKit
import WebKit

/// §7.2 `WKNavigationDelegate` 回调。
///
/// 这里每一项不实现都表现为某个功能「点了没反应」或者干脆白屏，而 Web 侧看不到错误。
final class ShellNavigationDelegate: NSObject, WKNavigationDelegate {

  private let entryHost: String?

  weak var host: ShellWebViewHost?

  init(config: ShellConfig) {
    self.entryHost = config.entryHost
    super.init()
  }

  /// §7.2 外链走 `UIApplication.open`，不实现的话外链在 WebView 里打开，用户出不来。
  ///
  /// 同源 HTTPS 必须**原样放行**，不做改写、重定向或拦截。
  /// `blob:` / `data:` 的导航不是外链，不要拦 —— 那是 Web 预览媒体的通道。
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""

    if Self.passThroughSchemes.contains(scheme) {
      decisionHandler(.allow)
      return
    }

    // iframe 里的跨域资源照常加载，只管主框架和新窗口。
    let isMainFrameOrNewWindow = navigationAction.targetFrame?.isMainFrame ?? true

    if scheme == "http" || scheme == "https" {
      if !isMainFrameOrNewWindow || isInternal(url) {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
        Self.openExternal(url)
      }
      return
    }

    // tel:、mailto:、itms-apps: 等，一律交给系统。
    decisionHandler(.cancel)
    Self.openExternal(url)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    // §11.2.3 reload 是否真的生效，就看有没有走到这里。
    ShellCore.shared.onPageStarted(webView.url?.absoluteString)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ShellCore.shared.onPageFinished(webView.url?.absoluteString)
  }

  /// §7.2 首屏加载失败重试，不实现就停在白屏。
  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error, url: webView.url)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    report(error, url: webView.url)
  }

  /// §9.6 SSL 错误不要无脑信任，也不要静默失败停在白屏。
  ///
  /// 这里交回系统默认处理：证书有问题时导航会以
  /// `NSURLErrorServerCertificateUntrusted` 失败，然后走上面的 `didFail*`，
  /// 由 `ShellCore` 弹原生重试页给用户看得见的提示。
  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.performDefaultHandling, nil)
  }

  /// §7.2 内容进程被回收后要恢复，不实现就永久白屏。
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ShellCore.shared.onRenderProcessGone(crashed: true)
  }

  // ----------------------------------------------------------------- 杂项

  private func report(_ error: Error, url: URL?) {
    let nsError = error as NSError
    // 用户自己点走、或者我们在 decidePolicy 里 cancel 掉的导航不是失败。
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
    let failing = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
      ?? url?.absoluteString ?? ""
    if nsError.domain == NSURLErrorDomain,
       Self.certificateErrors.contains(nsError.code) {
      ShellCore.shared.onSslError(nsError.code)
      return
    }
    ShellCore.shared.onMainFrameLoadFailed(
      url: failing,
      description: "\(nsError.code) \(nsError.localizedDescription)"
    )
  }

  private func isInternal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    // 配置缺失时一律放行，别把自己挡在外面。
    guard let entry = entryHost else { return true }
    return host == entry || host.hasSuffix(".\(entry)")
  }

  static func openExternal(_ url: URL) {
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { ok in
        if !ok { NSLog("[SsgShell] 系统打不开 \(url.absoluteString)") }
      }
    }
  }

  private static let passThroughSchemes: Set<String> = ["blob", "data", "about", "javascript", "file"]

  private static let certificateErrors: Set<Int> = [
    NSURLErrorServerCertificateUntrusted,
    NSURLErrorServerCertificateHasBadDate,
    NSURLErrorServerCertificateHasUnknownRoot,
    NSURLErrorServerCertificateNotYetValid,
    NSURLErrorClientCertificateRejected,
    NSURLErrorClientCertificateRequired,
    NSURLErrorSecureConnectionFailed,
  ]
}
