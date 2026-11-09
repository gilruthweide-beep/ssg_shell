import Foundation
import UIKit
import WebKit

/// §8.4 / §9.4 / §9.6 承载 IM WebView 的全屏容器。
///
/// WebView 不属于这个 VC —— 它由 `ImWebViewHolder` 在进程级持有，这里只负责挂上、
/// 取下，以及那些非得有 VC 才能做的事（`ShellWebViewHost`）：拉相册、弹提示、
/// 原生 splash、原生重试页。
final class ImViewController: UIViewController, ShellWebViewHost {

  private let config: ShellConfig

  private var splashView: UIView?
  private var splashUp = true
  private var splashDeadline: DispatchWorkItem?

  private var errorView: UIView?
  private var errorBody: UILabel?

  init(config: ShellConfig) {
    self.config = config
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
    // §9.6 冷启动直接进 Web，不要任何转场动画露出下面的 Flutter 页。
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) 没用到")
  }

  // ----------------------------------------------------------------- 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    // §9.4 安全区外露出的状态栏 / 底部条一律白色背景。
    view.backgroundColor = UIColor(argb: config.backgroundColorArgb)

    attach(ImWebViewHolder.shared.get(config: config))
    ImWebViewHolder.shared.host = self
    ImWebViewHolder.shared.refreshUserAgent()

    installSplash()

    if config.entryUrl.isEmpty {
      showErrorPage("入口地址未配置（§2.1）")
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ImWebViewHolder.shared.host = self
    // §10.2 WebView 真的可见了：ShellCore 据此调 onForeground() 并启动心跳。
    ShellCore.shared.setImRunning(true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ShellCore.shared.setImRunning(false)
  }

  deinit {
    if ImWebViewHolder.shared.host === self {
      ImWebViewHolder.shared.host = nil
    }
    ImWebViewHolder.shared.filePicker.dispose()
    // §10.6 只取下，不销毁：重建 WebView = 重新加载整个 Web = 重建长连接 + 重拉历史。
    ImWebViewHolder.shared.webView?.removeFromSuperview()
  }

  /// §9.4 状态栏用深色图标（白底）。登录页、深色模式下也一样，不按页面颜色取色。
  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [] }

  /// 页面自己管朝向，这里不限制；旋转不会重建 VC，所以 §10.6 的长活不受影响。
  override var shouldAutorotate: Bool { true }

  // ----------------------------------------------------------------- 挂载

  /// §9.4 **WebView 只放在安全区内**：由原生把它摆在状态栏 / 刘海 / 灵动岛以下、
  /// Home 指示条以上。Web 在壳内只按 `env(safe-area-inset-*)` 留白，所以那几个值
  /// 必须为 0 —— 约束到 `safeAreaLayoutGuide` 正好满足。
  ///
  /// §9.2 键盘由 Web 处理：这里不做 frame 偏移，也不动 `contentInset`，
  /// 原生再改一次就会叠加成两倍位移。
  private func attach(_ webView: WKWebView) {
    guard webView.superview !== view else { return }
    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(webView, at: 0)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
    ])
  }

  // ----------------------------------------------------------------- splash

  /// §9.6 用来遮住 WebView 加载期间的白屏，画面与系统启动图一致 ——
  /// 直接把 LaunchScreen 实例化出来，两者衔接起来就是同一个启动画面。
  ///
  /// 除此之外不允许出现任何加载界面：没有转圈、没有进度条、没有「正在连接」。
  private func installSplash() {
    let splash: UIView
    if let launch = Self.launchScreenView() {
      splash = launch
    } else {
      let plain = UIView()
      plain.backgroundColor = UIColor(argb: config.backgroundColorArgb)
      splash = plain
    }
    splash.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(splash)
    NSLayoutConstraint.activate([
      splash.topAnchor.constraint(equalTo: view.topAnchor),
      splash.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      splash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      splash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    splashView = splash

    // §9.6 `eventWebReady` 可能永远不来（内核过低的不兼容提示页、脚本加载失败的重试页），
    // 所以给一个上限，到时撤掉让用户看到页面或原生重试页。
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.splashUp else { return }
      NSLog("[SsgShell] splash 到达 \(Int(self.config.splashTimeout))s 上限，强制撤除（§9.6）")
      self.dismissSplash(.splashTimedOut)
    }
    splashDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + config.splashTimeout, execute: deadline)
  }

  private static func launchScreenView() -> UIView? {
    guard let name = Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String,
          !name.isEmpty
    else { return nil }
    let storyboard = UIStoryboard(name: name, bundle: .main)
    guard let controller = storyboard.instantiateInitialViewController() else { return nil }
    // 只要它的视图，VC 本身不进层级 —— 它不需要生命周期。
    let snapshot = controller.view
    snapshot?.frame = UIScreen.main.bounds
    return snapshot
  }

  /// §9.6 收到 `eventWebReady` 后立即撤 splash，此时首屏已经画好 ——
  /// 不要用固定时长定时器。
  func dismissSplash(_ reason: ShellEventType) {
    guard splashUp else { return }
    splashUp = false
    splashDeadline?.cancel()
    splashDeadline = nil
    ShellCore.shared.notifySplashDismissed(reason)
    guard let splash = splashView else { return }
    splashView = nil
    UIView.animate(
      withDuration: 0.18,
      animations: { splash.alpha = 0 },
      completion: { _ in splash.removeFromSuperview() }
    )
  }

  // --------------------------------------------------------------- 错误页

  /// §9.6 首屏加载失败接管为原生重试页，不要露出 WKWebView 的默认错误页面。
  func showErrorPage(_ message: String?) {
    if errorView != nil {
      errorBody?.text = message ?? "请检查网络后重试"
      return
    }
    let page = buildErrorPage(message)
    page.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(page)
    NSLayoutConstraint.activate([
      page.topAnchor.constraint(equalTo: view.topAnchor),
      page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    errorView = page
    // 错误页顶上来之后 splash 就该撤了，不然用户只看到启动图，不知道发生了什么。
    dismissSplash(.loadFailed)
  }

  func hideErrorPage() {
    errorView?.removeFromSuperview()
    errorView = nil
    errorBody = nil
  }

  private func buildErrorPage(_ message: String?) -> UIView {
    let container = UIView()
    container.backgroundColor = UIColor(argb: config.backgroundColorArgb)

    let title = UILabel()
    title.text = "暂时打不开"
    title.font = .systemFont(ofSize: 18, weight: .medium)
    title.textColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    title.textAlignment = .center

    let body = UILabel()
    body.text = message ?? "请检查网络后重试"
    body.font = .systemFont(ofSize: 14)
    body.textColor = UIColor(red: 0.54, green: 0.54, blue: 0.56, alpha: 1)
    body.textAlignment = .center
    body.numberOfLines = 0
    errorBody = body

    let retry = UIButton(type: .system)
    retry.setTitle("重试", for: .normal)
    retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
    retry.addTarget(self, action: #selector(onRetry), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [title, body, retry])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
    ])
    return container
  }

  @objc private func onRetry() {
    hideErrorPage()
    // §8.3 资源加载失败时的兜底只做 reload，不要顺手清缓存。
    let holder = ImWebViewHolder.shared
    if let web = holder.webView, web.url != nil {
      web.reload()
    } else if let url = config.resolvedUrl() {
      holder.webView?.load(URLRequest(url: url))
    }
  }

  // ------------------------------------------------- ShellWebViewHost

  /// §7.3 拉相册、弹提示都从这里 present。已经有东西盖在上面时交给它，
  /// 不然 present 会被 UIKit 丢掉。
  var presenter: UIViewController? {
    var top: UIViewController = self
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  /// §11.2.3 WebView 实例被换掉，重新挂上新实例。
  func onWebViewReplaced(_ webView: WKWebView) {
    hideErrorPage()
    attach(webView)
  }
}
