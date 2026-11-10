import Foundation

/// 壳的运行参数。
///
/// 两个来源，按优先级合并：
///  1. Dart 调 `initialize` 传下来的 `ShellConfigDto`；
///  2. 宿主 `Info.plist` 的 `SSGShell*` 键。
///
/// 之所以两套都要：§9.6 要求「已开启 B 面时，冷启动直接加载 Web」，而那一刻 Flutter
/// 引擎还没起来，拿不到 Dart 的配置，只能读 Info.plist 加一份落盘缓存
/// （§9.6「把上次的结果缓存在本地，冷启动直接按缓存走」）。
struct ShellConfig {

  /// §2.1 完整落地 URL，原样加载；渠道码可选，由 Web 读取。
  var entryUrl: String = ""
  /// 旧版兼容字段，已忽略，不参与 URL 加载或渠道归因。
  var channelCode: String = ""
  /// §1.1 / §2.2 壳版本。
  var shellVersion: String = ""
  /// §9.6 B 面开关。
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

  /// §2.1 直接使用落地 URL，不解析或重拼 query。
  func resolvedUrl() -> URL? {
    guard !entryUrl.isEmpty else { return nil }
    return URL(string: entryUrl)
  }

  /// §7.2 外链放行用的 host。
  var entryHost: String? {
    URLComponents(string: entryUrl)?.host?.lowercased()
  }

  // --------------------------------------------------------------- 来源

  /// 读 Info.plist 加落盘缓存。Dart 还没上线时就用这份（§9.6）。
  static func fromDisk() -> ShellConfig {
    let bundle = Bundle.main
    let defaults = UserDefaults.standard
    var config = ShellConfig()
    // 落盘的完整入口 URL 优先，包含宿主配置的可选渠道码。
    config.entryUrl = defaults.string(forKey: keyEntryUrl)
      ?? (bundle.object(forInfoDictionaryKey: metaEntryUrl) as? String) ?? ""
    let version = defaults.string(forKey: keyShellVersion)
      ?? plistString(bundle, metaShellVersion)
    config.shellVersion = (version?.isEmpty == false ? version! : appVersion())
    // §9.6 没有缓存时默认关：没确认过 B 面就不要抢在 A 面前面。
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

  /// §8.4 体验与性能 1 的 iOS 对应项：进程启动就建 WebView 并开始加载。
  static var autoPreload: Bool {
    (Bundle.main.object(forInfoDictionaryKey: metaAutoPreload) as? Bool) ?? false
  }

  /// §9.6 的 iOS 对应项。
  ///
  /// Android 可以直接把 `ImActivity` 配成 LAUNCHER，冷启动的第一个界面就是 Web；
  /// iOS 没有这种声明式入口，所以给一个开关：开了就在插件注册那一刻（早于首帧）把容器
  /// 顶上来，用户只会看到系统启动图和与之一致的原生 splash，不会先看到 Flutter 页面。
  static var autoOpenIm: Bool {
    (Bundle.main.object(forInfoDictionaryKey: metaAutoOpenIm) as? Bool) ?? false
  }

  // --------------------------------------------------------------- 常量

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
