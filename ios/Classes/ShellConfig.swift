import Foundation

/// Shell runtime configuration.
///
/// Merge two configuration sources in priority order:
///  1. ShellConfigDto supplied by Dart through initialize.
///  2. Host Info.plist SSGShell* keys.
///
/// Both are required because §9.6 starts loading the Web application immediately on B-side cold starts,
/// before Flutter can supply configuration. Use Info.plist values with persisted cache values
/// to restore the previous state without waiting for Dart (§9.6).
struct ShellConfig {

  /// §2.1 Complete landing URL, loaded unchanged; the Web application reads its optional channel code.
  var entryUrl: String = ""
  /// Ignored legacy compatibility field; it does not affect URL loading or attribution.
  var channelCode: String = ""
  /// §1.1 / §2.2 Shell version.
  var shellVersion: String = ""
  /// §9.6 B-side switch.
  var bSideEnabled: Bool = false

  var splashTimeout: TimeInterval = 30
  var heartbeatInterval: TimeInterval = 20
  var aliveTimeout: TimeInterval = 60
  var reloadConfirmTimeout: TimeInterval = 10
  var recoveryBackoffFirst: TimeInterval = 180
  var recoveryBackoffLater: TimeInterval = 600
  var networkDebounce: TimeInterval = 1.5
  var suppressForegroundNotifications: Bool = true
  var manageBadge: Bool = true
  var minKernelVersion: Int = 92
  var recommendedKernelVersion: Int = 110
  var consoleBufferSize: Int = 300
  var backgroundColorArgb: UInt32 = 0xFFFF_FFFF
  var forwardConsole: Bool = true

  // ------------------------------------------------------------------ URL

  /// §2.1 Use the landing URL directly without parsing or rebuilding its query.
  func resolvedUrl() -> URL? {
    guard !entryUrl.isEmpty else { return nil }
    return URL(string: entryUrl)
  }

  /// §7.2 Host used to distinguish internal navigation from external links.
  var entryHost: String? {
    URLComponents(string: entryUrl)?.host?.lowercased()
  }

  // --------------------------------------------------------------- Configuration sources

  /// Read Info.plist with persisted cache values before Dart is available (§9.6).
  static func fromDisk() -> ShellConfig {
    let bundle = Bundle.main
    let defaults = UserDefaults.standard
    var config = ShellConfig()
    // The persisted complete landing URL takes priority, including its optional channel code.
    config.entryUrl = defaults.string(forKey: keyEntryUrl)
      ?? (bundle.object(forInfoDictionaryKey: metaEntryUrl) as? String) ?? ""
    let version = defaults.string(forKey: keyShellVersion)
      ?? plistString(bundle, metaShellVersion)
    config.shellVersion = (version?.isEmpty == false ? version! : appVersion())
    // §9.6 Default to disabled without a cache; do not open B side before it has been enabled.
    config.bSideEnabled = defaults.bool(forKey: keyBSide)
    return config
  }

  static func fromDto(_ dto: ShellConfigDto) -> ShellConfig {
    var config = ShellConfig()
    config.entryUrl = dto.entryUrl
    config.shellVersion = dto.shellVersion.isEmpty ? appVersion() : dto.shellVersion
    config.bSideEnabled = dto.bSideEnabled
    config.splashTimeout = TimeInterval(dto.splashTimeoutMs) / 1000
    config.heartbeatInterval = TimeInterval(dto.heartbeatIntervalMs) / 1000
    config.aliveTimeout = TimeInterval(dto.aliveTimeoutMs) / 1000
    config.reloadConfirmTimeout = TimeInterval(dto.reloadConfirmTimeoutMs) / 1000
    config.recoveryBackoffFirst = TimeInterval(dto.recoveryBackoffFirstMs) / 1000
    config.recoveryBackoffLater = TimeInterval(dto.recoveryBackoffLaterMs) / 1000
    config.networkDebounce = TimeInterval(dto.networkDebounceMs) / 1000
    config.suppressForegroundNotifications = dto.suppressForegroundNotifications
    config.manageBadge = dto.manageBadge
    config.minKernelVersion = Int(dto.minKernelVersion)
    config.recommendedKernelVersion = Int(dto.recommendedKernelVersion)
    config.consoleBufferSize = Int(dto.consoleBufferSize)
    config.backgroundColorArgb = UInt32(bitPattern: Int32(truncatingIfNeeded: dto.backgroundColorArgb))
    config.forwardConsole = dto.forwardConsole
    return config
  }

  func persist() {
    let defaults = UserDefaults.standard
    defaults.set(entryUrl, forKey: Self.keyEntryUrl)
    defaults.set(shellVersion, forKey: Self.keyShellVersion)
    defaults.set(bSideEnabled, forKey: Self.keyBSide)
  }

  static func persistBSide(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: keyBSide)
  }

  /// §8.4 Performance 1 on iOS: create the WebView and begin loading at process startup.
  static var autoPreload: Bool {
    (Bundle.main.object(forInfoDictionaryKey: metaAutoPreload) as? Bool) ?? false
  }

  /// iOS equivalent of §9.6.
  ///
  /// Android can declare ImActivity as LAUNCHER, making the Web application the first cold-start screen.
  /// iOS has no equivalent declarative entry point, so this switch presents the container during plugin registration
  /// before the first frame, showing only the system launch screen and matching native splash rather than the Flutter page.
  static var autoOpenIm: Bool {
    (Bundle.main.object(forInfoDictionaryKey: metaAutoOpenIm) as? Bool) ?? false
  }

  // --------------------------------------------------------------- Constants

  private static let metaEntryUrl = "SSGShellEntryUrl"
  private static let metaShellVersion = "SSGShellVersion"
  private static let metaAutoPreload = "SSGShellAutoPreload"
  private static let metaAutoOpenIm = "SSGShellAutoOpenIm"

  private static let keyEntryUrl = "ssg_shell.entryUrl"
  private static let keyShellVersion = "ssg_shell.shellVersion"
  private static let keyBSide = "ssg_shell.bSideEnabled"

  private static func plistString(_ bundle: Bundle, _ key: String) -> String? {
    (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces)
  }

  private static func appVersion() -> String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return (short?.isEmpty == false) ? short! : "0.0.0"
  }
}
