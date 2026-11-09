import Foundation
import UIKit
import WebKit

/// WebView 需要一个 `UIViewController` 才能完成的事。
///
/// WebView 本身按 §10.6 由进程级单例持有（`ImWebViewHolder`），容器只负责挂上和取下，
/// 所以这些不能写死在 WebView 里，要由当前挂着它的 `ImViewController` 实现。
/// 没有容器挂载时（预加载阶段、IM 页已关闭）为 nil，各处自行降级。
protocol ShellWebViewHost: AnyObject {

  /// §7.3 拉起 `PHPickerViewController`、以及弹各种提示要用的 presenter。
  var presenter: UIViewController? { get }

  /// §9.6 首屏加载失败 / SSL 错误 → 原生重试页，不要露出 WebView 的默认错误页面。
  func showErrorPage(_ message: String?)

  /// 加载成功后撤掉重试页。
  func hideErrorPage()

  /// §9.6 收到 `eventWebReady` 后立即撤 splash。
  func dismissSplash(_ reason: ShellEventType)

  /// §11.2.3 WebView 实例被换掉后，容器需要重新挂上新实例。
  func onWebViewReplaced(_ webView: WKWebView)
}
