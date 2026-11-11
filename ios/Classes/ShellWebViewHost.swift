import Foundation
import UIKit
import WebKit

/// Operations for which the WebView needs a `UIViewController`.
///
/// Under §10.6, the process-level `ImWebViewHolder` owns the WebView; the container only attaches and detaches it.
/// Delegate these operations to the currently attached `ImViewController` instead of binding them to the WebView.
/// The host is nil during preloading or after the IM container closes; callers provide their own fallbacks.
protocol ShellWebViewHost: AnyObject {

  /// §7.3 Presenter for `PHPickerViewController` and native prompts.
  var presenter: UIViewController? { get }

  /// §9.6 Show a native retry screen on initial-load or SSL failure instead of WebView's default error UI.
  func showErrorPage(_ message: String?)

  /// Remove the retry screen after a successful load.
  func hideErrorPage()

  /// §9.6 Remove the splash immediately after `eventWebReady`.
  func dismissSplash(_ reason: ShellEventType)

  /// §11.2.3 Reattach the replacement WebView to the container after recreation.
  func onWebViewReplaced(_ webView: WKWebView)
}
