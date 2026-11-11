import Foundation
import UIKit
import WebKit

/// §7.2 WKNavigationDelegate callbacks.
///
/// Missing callbacks leave features unresponsive or blank without exposing errors to the Web application.
final class ShellNavigationDelegate: NSObject, WKNavigationDelegate {

  private let entryHost: String?

  weak var host: ShellWebViewHost?

  init(config: ShellConfig) {
    self.entryHost = config.entryHost
    super.init()
  }

  /// §7.2 Delegate external links through UIApplication.open instead of trapping navigation inside the WebView.
  ///
  /// Allow same-origin HTTPS URLs unchanged, without rewriting, redirecting, or intercepting them.
  /// `blob:` / `data:` navigations support Web media previews and must not be treated as external links.
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

    // Allow cross-origin iframe resources; only handle main-frame and new-window navigation.
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

    // Delegate tel:, mailto:, itms-apps:, and similar links to the system.
    decisionHandler(.cancel)
    Self.openExternal(url)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    // §11.2.3 Reaching this callback confirms that reload actually started loading.
    ShellCore.shared.onPageStarted(webView.url?.absoluteString)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ShellCore.shared.onPageFinished(webView.url?.absoluteString)
  }

  /// §7.2 Retry initial-load failures instead of leaving a blank page.
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

  /// §9.6 Do not trust invalid SSL certificates or fail silently into a blank page.
  ///
  /// Let the system perform default certificate validation. Invalid certificates fail navigation with
  /// NSURLErrorServerCertificateUntrusted, triggering the didFail callbacks above;
  /// ShellCore then presents a native retry screen with a visible explanation.
  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.performDefaultHandling, nil)
  }

  /// §7.2 Recover after WebContent process termination instead of leaving a permanent blank page.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ShellCore.shared.onRenderProcessGone(crashed: true)
  }

  // ----------------------------------------------------------------- Utilities

  private func report(_ error: Error, url: URL?) {
    let nsError = error as NSError
    // User-cancelled navigation, or navigation cancelled in decidePolicy, is not a loading failure.
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
    // When configuration is unavailable, allow navigation to avoid blocking the application itself.
    guard let entry = entryHost else { return true }
    return host == entry || host.hasSuffix(".\(entry)")
  }

  static func openExternal(_ url: URL) {
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { ok in
        if !ok { NSLog("[SsgShell] The system cannot open \(url.absoluteString)") }
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
