import Foundation
import UIKit
import WebKit

/// §8.4 / §9.4 / §9.6 Fullscreen container for the IM WebView.
///
/// The process-level ImWebViewHolder owns the WebView; this controller only attaches,
/// detaches, and provides controller-dependent ShellWebViewHost operations: photo selection, prompts,
/// native splash, and native retry screens.
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
    // §9.6 Enter the Web application on cold starts without transition animations exposing the Flutter page underneath.
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // ----------------------------------------------------------------- Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // §9.4 Use a white background for the status bar and bottom safe area.
    view.backgroundColor = UIColor(argb: config.backgroundColorArgb)

    attach(ImWebViewHolder.shared.get(config: config))
    ImWebViewHolder.shared.host = self
    ImWebViewHolder.shared.refreshUserAgent()

    if ShellCore.shared.isWebReady {
      // eventWebReady fires only once per page load. If the WebView was preloaded, or this is a container reopened after being
      // closed, that event was sent long ago and will not come again; covering it with the splash now would just wait until the limit.
      splashUp = false
    } else {
      installSplash()
    }
    // If the initial page failed to load during preload, there was no container then; show the retry page now.
    ShellCore.shared.onHostAttached(self)
    installDiagnosticsGesture()

    if config.entryUrl.isEmpty {
      showErrorPage("Landing URL is not configured (§2.1)")
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ImWebViewHolder.shared.host = self
    // §10.2 The WebView is actually visible; ShellCore calls onForeground() and starts heartbeats.
    ShellCore.shared.setImRunning(true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ShellCore.shared.setImRunning(false)
  }

  deinit {
    // `host` is a weak reference and has already been set to nil by the time we get here; if it is not nil, a new container has taken over.
    let replaced = ImWebViewHolder.shared.host != nil
    if !replaced {
      ImWebViewHolder.shared.filePicker.dispose()
    }
    // §10.6 Only detach, do not destroy: recreating the WebView = reloading the whole Web = re-establishing the long connection + refetching history.
    // Only detach the one this container holds; when reopened right after closing, the WebView may already be attached to the new container.
    if isViewLoaded, let web = ImWebViewHolder.shared.webView, web.superview === view {
      web.removeFromSuperview()
    }
  }

  /// Use icons contrasting with the splash, then dark icons on the white Web safe area as required by §9.4.
  override var preferredStatusBarStyle: UIStatusBarStyle {
    if splashUp, let background = splashView?.backgroundColor {
      var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
      if background.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
         0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5 {
        return .lightContent
      }
    }
    return .darkContent
  }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [] }

  /// Let the page manage orientation. Rotation does not recreate this controller or affect §10.6 instance lifetime.
  override var shouldAutorotate: Bool { true }

  // ----------------------------------------------------------------- Attachment

  /// §9.4 **Place the WebView inside the safe area**, below the status bar, notch, or Dynamic Island
  /// and above the home indicator. The Web application uses env(safe-area-inset-*) for padding inside the shell,
  /// so those values must be zero; safeAreaLayoutGuide constraints provide that layout.
  ///
  /// §9.2 The Web application handles keyboard movement; avoid native frame offsets or contentInset changes,
  /// which would double the displacement.
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

  /// §9.6 Cover the loading WebView with a view matching the system launch screen;
  /// instantiate LaunchScreen directly for a continuous visual transition.
  ///
  /// Do not add other loading UI: no spinner, progress bar, or connecting message.
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
    setNeedsStatusBarAppearanceUpdate()

    // §9.6 eventWebReady may never arrive on an unsupported engine or script-loading error page,
    // so cap splash duration and then reveal the page or native retry screen.
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.splashUp else { return }
      NSLog("[SsgShell] Splash reached its \(Int(self.config.splashTimeout))s limit; removing it (§9.6)")
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
    // Use only the launch controller's view; it does not need controller lifecycle or containment.
    let snapshot = controller.view
    snapshot?.frame = UIScreen.main.bounds
    return snapshot
  }

  /// §9.6 Remove the splash as soon as eventWebReady arrives, when the first screen has already rendered;
  /// do not use a fixed-duration timer.
  func dismissSplash(_ reason: ShellEventType) {
    guard splashUp else { return }
    splashUp = false
    setNeedsStatusBarAppearanceUpdate()
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

  // --------------------------------------------------------------- Error screen

  /// §9.6 Replace initial-load failures with a native retry screen rather than WKWebView's default error page.
  func showErrorPage(_ message: String?) {
    if errorView != nil {
      errorBody?.text = message ?? "Check your connection and try again."
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
    // Remove the splash when displaying an error page so the user can see what happened.
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
    title.text = "Unable to load"
    title.font = .systemFont(ofSize: 18, weight: .medium)
    title.textColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    title.textAlignment = .center

    let body = UILabel()
    body.text = message ?? "Check your connection and try again."
    body.font = .systemFont(ofSize: 14)
    body.textColor = UIColor(red: 0.54, green: 0.54, blue: 0.56, alpha: 1)
    body.textAlignment = .center
    body.numberOfLines = 0
    errorBody = body

    let retry = UIButton(type: .system)
    retry.setTitle("Try again", for: .normal)
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
    // §8.3 Retry resource-loading failures by reloading only; preserve caches.
    let holder = ImWebViewHolder.shared
    if let web = holder.webView, web.url != nil {
      web.reload()
    } else if let url = config.resolvedUrl() {
      holder.webView?.load(URLRequest(url: url))
    }
  }

  // ------------------------------------------------- ShellWebViewHost

  /// §7.3 Present photo selection and prompts through the topmost controller;
  /// otherwise UIKit may discard the presentation request.
  var presenter: UIViewController? {
    var top: UIViewController = self
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  /// §11.2.3 Reattach the replacement WebView after recreation.
  func onWebViewReplaced(_ webView: WKWebView) {
    hideErrorPage()
    attach(webView)
  }
}

// MARK: - §11.6 Hidden diagnostics entry

extension ImViewController: UIGestureRecognizerDelegate {
  /// Hold three fingers on the IM screen for two seconds. The recognizer never cancels the page's touches.
  fileprivate func installDiagnosticsGesture() {
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(diagnosticsHold(_:)))
    hold.numberOfTouchesRequired = 3
    hold.minimumPressDuration = 2
    hold.cancelsTouchesInView = false
    hold.delegate = self
    view.addGestureRecognizer(hold)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }

  @objc private func diagnosticsHold(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began, presentedViewController == nil, view.window != nil else { return }
    // URL, UA, engine version, __SSG_SHELL__, last reload and recent console lines.
    let text = ShellCore.shared.exportDiagnostics()
    NSLog("[SsgShell] Diagnostics opened from the hidden entry (§11.6)")
    let alert = UIAlertController(title: "Diagnostics", message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
      UIPasteboard.general.string = text
    })
    alert.addAction(UIAlertAction(title: "Share", style: .default) { [weak self] _ in
      guard let self else { return }
      let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
      // iPad presents the share sheet as a popover.
      share.popoverPresentationController?.sourceView = self.view
      share.popoverPresentationController?.sourceRect = CGRect(
        x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
      self.present(share, animated: true)
    })
    alert.addAction(UIAlertAction(title: "Close", style: .cancel))
    present(alert, animated: true)
  }
}
