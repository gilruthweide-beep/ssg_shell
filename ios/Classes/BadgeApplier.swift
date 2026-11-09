import Foundation
import UIKit
import UserNotifications

/// §5.4 角标。
///
/// iOS 这边是精确的：角标数 = Web 给的未读总数，`count` 为 `0` 时清零。
/// （Android 的 launcher 角标各家一套，小米 / OPPO / vivo 根本改不了，见那边的注释。）
enum BadgeApplier {

  static func apply(_ count: Int) {
    let safe = max(count, 0)
    if #available(iOS 16.0, *) {
      // iOS 17 起 applicationIconBadgeNumber 废弃，统一走通知中心这条。
      UNUserNotificationCenter.current().setBadgeCount(safe) { error in
        if let error {
          NSLog("[SsgShell] 设角标失败：\(error.localizedDescription)")
        }
      }
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = safe
      }
    }
  }
}
