import Flutter
import UIKit

/// Pigeon 契约的 iOS 实现入口。
///
/// 这里只做转发：真正的状态全在 `ShellCore`（进程级单例）。原因见 §9.6 ——
/// 已开启 B 面时冷启动要直接加载 Web，那一刻引擎还没起来，而 §11.1 的心跳、
/// §11.2 的存活监测必须已经在跑。插件被 detach（引擎销毁）也不能停掉这些。
public class SsgShellPlugin: NSObject, FlutterPlugin, SsgShellHostApi {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SsgShellPlugin()
    SsgShellHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    ShellCore.shared.attach()
    ShellCore.shared.setDartApi(SsgShellFlutterApi(binaryMessenger: registrar.messenger()))
    // 注册表只弱引用插件实例，publish 一下才活得过这个方法。
    registrar.publish(instance)

    // §8.4 体验与性能 1 / §9.6：这一步在 AppDelegate 注册插件时就跑，早于首帧 ——
    // WebView 内核首次初始化要几百毫秒，提前做能直接缩短冷启动。
    // 两个开关都默认关：没在 Info.plist 里显式打开时，时机完全交给 Dart。
    if ShellConfig.autoPreload {
      ShellCore.shared.preload()
    }
    if ShellConfig.autoOpenIm, ShellCore.shared.isBSideEnabled() {
      ShellCore.shared.openIm()
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    SsgShellHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    // 引擎没了就不要再往 Dart 发事件，但壳本身继续跑。
    ShellCore.shared.setDartApi(nil)
  }

  // --------------------------------------------------------- SsgShellHostApi

  func initialize(config: ShellConfigDto) throws -> ShellInfo {
    ShellCore.shared.initialize(config)
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

  /// §6.2 只在收到 `eventLogin` 之后调。启动期调用会被拒掉并返回当前状态。
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

  /// §10.3 电池优化白名单是 Android 的概念（Doze）。iOS 空操作返回 true。
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
