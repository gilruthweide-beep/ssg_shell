import AVFoundation
import Foundation
import UIKit
import WebKit

/// §7.2 WKUIDelegate handles window.open, microphone permission, and occasional page dialogs.
///
/// File selection is handled separately by the shell under §7.3; see FilePickerBridge and
/// ShellInjection.fileInputScript. WebKit owns fullscreen video handling,
/// with allowsInlineMediaPlayback enabling inline/fullscreen transitions.
final class ShellUIDelegate: NSObject, WKUIDelegate {

  private let entryHost: String?

  weak var host: ShellWebViewHost?

  init(config: ShellConfig) {
    self.entryHost = config.entryHost
    super.init()
  }

  /// §7.2 window.open / target="_blank": **return nil and load in the existing WebView**.
  ///
  /// Missing handling leaves links unresponsive. Open external links in the system browser and same-origin links in the current instance;
  /// a second same-origin WebView would violate §10.5 and could enter the primary-instance election.
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

  /// §7.2 Authorize microphone access on iOS 15+; missing handling prevents voice recording.
  ///
  /// §6.2 getUserMedia triggers this callback; only then request system permission.
  /// Never request it at startup.
  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    // §6.1 The Web application uses the microphone only, not audio/video calls; reject camera requests.
    guard type == .microphone else {
      decisionHandler(.deny)
      return
    }
    // Denied before this request: iOS will not prompt again, and the Web application can only show a notice.
    let alreadyDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    PermissionCoordinator.requestMicrophone { [weak self] granted in
      decisionHandler(granted ? .grant : .deny)
      // §6.2 / §12.3 After a microphone denial, native code offers Settings.
      // Do not follow up immediately after the user just declined the system prompt.
      if !granted && alreadyDenied { self?.showMicrophoneSettingsGuide() }
    }
  }

  private func showMicrophoneSettingsGuide() {
    // Only a new recording attempt shows this; never over another alert or an offscreen controller.
    guard let presenter = host?.presenter, presenter.viewIfLoaded?.window != nil,
          presenter.presentedViewController == nil else { return }
    let alert = UIAlertController(
      title: "Microphone is off",
      message: "Allow microphone access in device settings, then return and try recording again.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Open settings", style: .default) { _ in
      PermissionCoordinator.openAppSettings()
    })
    presenter.present(alert, animated: true)
  }

  // ------------------------------------------------------------- Page dialogs

  // The Web application does not depend on these dialogs, but missing handlers can leave its awaits unresolved.
  // Simple system dialogs are sufficient.

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
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
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
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
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
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
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
