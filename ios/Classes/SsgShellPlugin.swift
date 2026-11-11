import Flutter
import UIKit

/// iOS implementation of the Pigeon contract.
///
/// This layer forwards calls; the process-level ShellCore owns state. Under §9.6,
/// B-side cold starts load the Web application before the engine starts, while the §11.1 heartbeat
/// and §11.2 liveness monitor must already be active. Plugin detachment must not stop them.
public class SsgShellPlugin: NSObject, FlutterPlugin, SsgShellHostApi {

  private let flutterApi: SsgShellFlutterApi

  /// Stateful events missed before Dart came online are replayed only on its first `initialize()`; after that everything is real-time.
  private var stickyReplayed = false

  private init(flutterApi: SsgShellFlutterApi) {
    self.flutterApi = flutterApi
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let flutterApi = SsgShellFlutterApi(binaryMessenger: registrar.messenger())
    let instance = SsgShellPlugin(flutterApi: flutterApi)
    SsgShellHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    ShellCore.shared.attach()
    ShellCore.shared.setDartApi(flutterApi)
    // The registrar holds only a weak reference to the plugin instance; publishing it keeps it alive past this method.
    registrar.publish(instance)

    // §8.4 Performance 1 / §9.6: initialize during AppDelegate plugin registration before the first frame;
    // starting the WebView engine early saves hundreds of milliseconds on a cold start.
    // Both switches default to false; without explicit Info.plist values, Dart controls timing.
    if ShellConfig.autoPreload {
      ShellCore.shared.preload()
    }
    if ShellConfig.autoOpenIm, ShellCore.shared.isBSideEnabled() {
      ShellCore.shared.openIm()
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    SsgShellHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    // Stop Dart events after engine destruction while the shell continues running.
    ShellCore.shared.setDartApi(nil)
  }

  // --------------------------------------------------------- SsgShellHostApi

  func initialize(config: ShellConfigDto) throws -> ShellInfo {
    let info = ShellCore.shared.initialize(config)
    // Reaching here means Dart has attached its receiver. The replay must go out before the return value.
    if !stickyReplayed {
      stickyReplayed = true
      ShellCore.shared.replaySticky(to: flutterApi)
    }
    return info
  }

  func preload() throws {
    ShellCore.shared.preload()
  }

  func openIm() throws {
    ShellCore.shared.openIm()
  }

  func closeIm() throws {
    ShellCore.shared.closeIm()
  }

  func isImRunning() throws -> Bool {
    ShellCore.shared.imRunning
  }

  func setBSideEnabled(enabled: Bool) throws {
    ShellCore.shared.setBSideEnabled(enabled)
  }

  func isBSideEnabled() throws -> Bool {
    ShellCore.shared.isBSideEnabled()
  }

  func openChat(request: OpenChatRequest) throws {
    ShellCore.shared.openChat(request)
  }

  func handlePushReceived(message: PushMessage) throws -> PushDecision {
    ShellCore.shared.handlePushReceived(message)
  }

  func handlePushOpened(message: PushMessage) throws {
    ShellCore.shared.handlePushOpened(message)
  }

  func nudgeNetwork(type: NetworkType) throws {
    ShellCore.shared.nudgeNetwork(type)
  }

  func reloadWeb() throws {
    ShellCore.shared.reloadWeb()
  }

  func recreateWebView() throws {
    ShellCore.shared.recreateWebView()
  }

  func setBadgeCount(count: Int64) throws {
    ShellCore.shared.setBadgeCount(Int(count))
  }

  func getDiagnostics() throws -> ShellDiagnostics {
    ShellCore.shared.diagnostics()
  }

  func exportDiagnostics() throws -> String {
    ShellCore.shared.exportDiagnostics()
  }

  func getKernelInfo() throws -> KernelInfo {
    ShellCore.shared.kernelInfo()
  }

  func getNotificationPermission() throws -> NotificationPermission {
    PermissionCoordinator.notificationState
  }

  /// §6.2 Call only after eventLogin; reject startup requests and return the current state.
  func requestNotificationPermission(
    completion: @escaping (Result<NotificationPermission, Error>) -> Void
  ) {
    PermissionCoordinator.requestNotification(
      hasLoggedIn: { ShellCore.shared.hasLoggedIn() },
      completion: { completion(.success($0)) }
    )
  }

  func openSystemSettings() throws {
    PermissionCoordinator.openAppSettings()
  }

  /// §10.3 Battery optimization exemption is an Android Doze concept; return true without action on iOS.
  func requestBatteryOptimizationExemption(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(true))
  }

  func isBatteryOptimizationIgnored() throws -> Bool {
    true
  }

  func verifyInjection(completion: @escaping (Result<Bool, Error>) -> Void) {
    ShellCore.shared.verifyInjection { completion(.success($0)) }
  }

  func evaluateJavaScript(script: String, completion: @escaping (Result<String, Error>) -> Void) {
    ShellCore.shared.evaluateJavaScript(script, completion: completion)
  }
}
