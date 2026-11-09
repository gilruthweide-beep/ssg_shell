import AVFoundation
import Foundation
import UIKit
import UserNotifications

/// §6.2 申请时机。
///
/// 规范的两条硬要求：
/// - **用到的那一刻才申请，启动阶段一律不申请。**
/// - 通知权限在**收到 `eventLogin` 之后**才申请。未登录状态弹授权拒绝率极高，
///   多数系统不允许二次申请。
///
/// 麦克风不走这里：§6.2 要求由 `getUserMedia` 触发，原生在 §7.2 的
/// `requestMediaCapturePermissionFor` 回调里再向系统申请（见 `ShellUIDelegate`）。
/// 相册也不走这里：§7.3 用 `PHPickerViewController`，不申请相册权限。
enum PermissionCoordinator {

  /// Pigeon 的 `getNotificationPermission` 是同步的，而 `UNUserNotificationCenter`
  /// 只有异步接口 —— 在主线程上等信号量会死锁，所以这里缓存最近一次读到的状态，
  /// 并在每次回前台、每次申请前后刷新。
  private static let lock = NSLock()
  private static var cached: NotificationPermission = .notDetermined

  static func refreshNotificationState(_ completion: ((NotificationPermission) -> Void)? = nil) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let state = map(settings.authorizationStatus)
      lock.lock()
      cached = state
      lock.unlock()
      completion?(state)
    }
  }

  static var notificationState: NotificationPermission {
    lock.lock()
    let value = cached
    lock.unlock()
    // 顺手刷一次，下一次读就是新的。
    refreshNotificationState()
    return value
  }

  /// §6.2 只在收到 `eventLogin` 之后调。
  ///
  /// 启动期调用会被直接拒掉：那一次弹窗的拒绝率极高，而 iOS 不允许二次申请，
  /// 等于永久放弃这台设备的推送。
  static func requestNotification(
    hasLoggedIn: @escaping () -> Bool,
    completion: @escaping (NotificationPermission) -> Void
  ) {
    refreshNotificationState { current in
      // 已授权、或已被拒（iOS 拒了就只能去设置页）都不再弹。
      if current == .granted || current == .permanentlyDenied {
        DispatchQueue.main.async { completion(current) }
        return
      }
      guard hasLoggedIn() else {
        NSLog(
          "[SsgShell] 还没收到 eventLogin，拒绝申请通知权限"
            + "（§6.2：未登录状态弹授权拒绝率极高，多数系统不允许二次申请）"
        )
        DispatchQueue.main.async { completion(current) }
        return
      }
      UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
          if let error {
            NSLog("[SsgShell] 申请通知权限失败：\(error.localizedDescription)")
          }
          refreshNotificationState { state in
            DispatchQueue.main.async {
              // APNs 的 token 注册由 OneSignal SDK 负责（§5.1 分工），壳不碰。
              completion(state)
            }
          }
        }
    }
  }

  /// §6.2 权限被永久拒绝后的二次引导由原生负责。Web 只能弹一句提示，拿不到系统设置页。
  static func openAppSettings() {
    DispatchQueue.main.async {
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    }
  }

  /// §7.2 麦克风：`getUserMedia` 触发后才向系统申请，不在启动阶段申请。
  ///
  /// `Info.plist` 缺 `NSMicrophoneUsageDescription` 时调 `getUserMedia` 会直接崩溃
  /// （§6.4），所以这里先确认文案在不在。
  static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
    guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
      NSLog("[SsgShell] Info.plist 缺 NSMicrophoneUsageDescription（§6.4），拒绝麦克风请求以免崩溃")
      completion(false)
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      // 拒过了：Web 会弹「麦克风权限被拒绝，请在系统设置中允许后重试」（§6.1），
      // 去设置页的引导由宿主在那条提示之后给（§6.2）。
      completion(false)
    }
  }

  private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return .granted
    case .denied:
      // iOS 拒绝后不允许二次申请，只能去系统设置 —— 按 §6.2 直接算永久拒绝。
      return .permanentlyDenied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .notSupported
    }
  }
}
