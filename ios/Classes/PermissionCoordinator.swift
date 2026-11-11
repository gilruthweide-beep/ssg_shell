import AVFoundation
import Foundation
import UIKit
import UserNotifications

/// §6.2 Permission timing.
///
/// Two mandatory requirements:
/// - **Request access only when needed, never during startup.**
/// - Request notification permission **after eventLogin**. Asking before login causes high denial rates,
///   and most systems restrict subsequent permission prompts.
///
/// Microphone access is separate: §6.2 requires getUserMedia to trigger the native
/// requestMediaCapturePermissionFor callback before requesting system access (see ShellUIDelegate).
/// Photo access is separate: §7.3 uses PHPickerViewController without requesting library permission.
enum PermissionCoordinator {

  /// Pigeon's getNotificationPermission is synchronous, while UNUserNotificationCenter
  /// exposes only asynchronous APIs. Waiting on the main thread would deadlock, so cache the most recent result
  /// and refresh on foreground entry and before/after permission requests.
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
    // Refresh asynchronously so the next synchronous read sees the updated result.
    refreshNotificationState()
    return value
  }

  /// §6.2 Call only after eventLogin.
  ///
  /// Reject startup requests: denial rates are high and iOS does not allow a second system prompt,
  /// potentially losing notification access for this device permanently.
  static func requestNotification(
    hasLoggedIn: @escaping () -> Bool,
    completion: @escaping (NotificationPermission) -> Void
  ) {
    refreshNotificationState { current in
      // Do not prompt after either grant or denial; denied iOS users must use Settings.
      if current == .granted || current == .permanentlyDenied {
        DispatchQueue.main.async { completion(current) }
        return
      }
      guard hasLoggedIn() else {
        NSLog(
          "[SsgShell] Rejecting notification permission request before eventLogin"
            + " (§6.2: pre-login requests have high denial rates and systems restrict repeated prompts)"
        )
        DispatchQueue.main.async { completion(current) }
        return
      }
      UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
          if let error {
            NSLog("[SsgShell] Notification permission request failed:\(error.localizedDescription)")
          }
          refreshNotificationState { state in
            DispatchQueue.main.async {
              // The OneSignal SDK owns APNs token registration under §5.1; the shell does not register it.
              completion(state)
            }
          }
        }
    }
  }

  /// §6.2 Native code provides settings guidance after permanent denial; the Web application cannot open system settings itself.
  static func openAppSettings() {
    DispatchQueue.main.async {
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    }
  }

  /// §7.2 Request microphone permission after getUserMedia, never at startup.
  ///
  /// Missing NSMicrophoneUsageDescription in Info.plist makes getUserMedia crash (§6.4),
  /// so verify that the usage description exists first.
  static func requestMicrophone(completion: @escaping (Bool) -> Void) {
    guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
      NSLog("[SsgShell] Info.plist lacks NSMicrophoneUsageDescription (§6.4); rejecting microphone access to avoid a crash")
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
      // Denied or restricted: the Web application shows "Microphone access was denied; allow it in
      // Settings and try again" (§6.1), and `ShellUIDelegate` follows with Settings guidance (§6.2).
      completion(false)
    }
  }

  private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return .granted
    case .denied:
      // iOS cannot prompt again after denial; classify it as permanently denied and direct the user to Settings (§6.2).
      return .permanentlyDenied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .notSupported
    }
  }
}
