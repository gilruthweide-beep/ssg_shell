import Foundation
import UIKit
import UserNotifications

/// §5.4 Badge updates.
///
/// iOS badge updates are exact: use the Web unread total and clear at zero.
/// Android launcher APIs vary; Xiaomi / OPPO / vivo do not support these local updates. See Android implementation notes.
enum BadgeApplier {

  static func apply(_ count: Int) {
    let safe = max(count, 0)
    if #available(iOS 16.0, *) {
      // applicationIconBadgeNumber is deprecated from iOS 17; use notification center instead.
      UNUserNotificationCenter.current().setBadgeCount(safe) { error in
        if let error {
          NSLog("[SsgShell] Badge update failed:\(error.localizedDescription)")
        }
      }
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = safe
      }
    }
  }
}
