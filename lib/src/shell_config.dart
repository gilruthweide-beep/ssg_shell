import 'messages.g.dart';

/// 壳的运行参数。
///
/// 规范给的数值全部作为默认值落在这里 —— 原生侧只照单执行，不自己兜默认值，
/// 所以调参只需要改这一处。时间量用 [Duration]，过线时再转成毫秒交给 Pigeon。
class ShellConfig {
  const ShellConfig({
    required this.entryUrl,
    @Deprecated('Put channelcode in entryUrl; this value is ignored.')
    this.channelCode = '',
    this.shellVersion = '',
    this.bSideEnabled = true,
    this.splashTimeout = const Duration(seconds: 30),
    this.heartbeatInterval = const Duration(seconds: 20),
    this.aliveTimeout = const Duration(seconds: 60),
    this.reloadConfirmTimeout = const Duration(seconds: 10),
    this.recoveryBackoffFirst = const Duration(seconds: 180),
    this.recoveryBackoffLater = const Duration(seconds: 600),
    this.networkDebounce = const Duration(milliseconds: 1500),
    this.suppressForegroundNotifications = true,
    this.manageBadge = true,
    this.minKernelVersion = 92,
    this.recommendedKernelVersion = 110,
    this.consoleBufferSize = 300,
    this.backgroundColorArgb = 0xFFFFFFFF,
    this.forwardConsole = true,
    this.webViewFullscreen = false,
  });

  /// §2.1 原样加载的完整落地 URL。
  ///
  /// 渠道码可选，需要归因时直接写进 URL，例如
  /// `https://im.example.com/?channelcode=ch001`。壳不补参、不删参、不重拼 query，
  /// 参数名大小写、取值和存储由 Web 负责。
  ///
  /// §8.1 必须是 HTTPS：`isSecureContext === false` 时 Service Worker 注册不了，
  /// 媒体加载与缓存全部降级。
  final String entryUrl;

  /// 旧版兼容字段，不再参与 URL 加载或渠道归因。
  ///
  /// 渠道码通过 [entryUrl] 传入；不带渠道码也是有效配置。
  @Deprecated('Put channelcode in entryUrl; this value is ignored.')
  final String channelCode;

  /// §1.1 / §2.2 壳版本，同时进 `__SSG_SHELL__` 和 UA 后缀。
  /// 留空时原生取宿主的 `versionName` / `CFBundleShortVersionString`。
  final String shellVersion;

  /// §9.6 B 面开关。原生会落盘，下次冷启动直接按缓存走，不等 Dart ——
  /// 所以「B 面开关的判断」不会以等待界面的形式出现在用户面前。
  final bool bSideEnabled;

  /// §9.6 splash 上限。`eventWebReady` 可能永远不来（内核过低的不兼容页、
  /// 脚本加载失败的重试页），到时撤掉 splash 让用户看到页面或原生重试页。
  final Duration splashTimeout;

  /// §11.1 原生心跳周期。规范值 20 秒，必须用原生定时器。
  final Duration heartbeatInterval;

  /// §11.2 多久没收到 `eventWebAlive` 判定卡死。规范值 60 秒。
  final Duration aliveTimeout;

  /// §11.2.3 reload 后多久没开始加载就重建 WebView。规范值 10 秒。
  final Duration reloadConfirmTimeout;

  /// §11.2.5 第一次处理后的退避。规范值 180 秒。
  final Duration recoveryBackoffFirst;

  /// §11.2.5 之后的退避。规范值 600 秒。
  final Duration recoveryBackoffLater;

  /// §10.4 网络回调去抖。规范区间 1~2 秒，不要每个系统回调都转发。
  final Duration networkDebounce;

  /// §5.4 前台抑制：用户正停在该会话时不弹系统通知。
  final bool suppressForegroundNotifications;

  /// §5.4 由插件按 `unreadCount` 自动设角标。关掉就自己调 [SsgShell.setBadgeCount]。
  final bool manageBadge;

  /// §8.1 内核硬性下限 92。低于它 `crypto.randomUUID` 等能力缺失。
  final int minKernelVersion;

  /// §8.1 推荐 110。介于两者之间只记一条诊断，不提示用户。
  final int recommendedKernelVersion;

  /// §11.6 console 环形缓冲条数，诊断导出时取这些。
  final int consoleBufferSize;

  /// §9.4 窗口与 WebView 背景色。规范要求白色：安全区外露出的状态栏 / 底部条
  /// 一律白底深色图标，登录页和深色模式下也一样。
  final int backgroundColorArgb;

  /// §11.6 把 Web 的 console 落到原生日志并上抛 Dart。
  final bool forwardConsole;

  /// WebView 铺满整个窗口，不摆进安全区。
  ///
  /// **默认关，因为这是对 §9.4 的偏离。** 规范要求原生把 WebView 摆在状态栏 / 刘海 /
  /// 灵动岛以下、Home 指示条（Android 为导航栏）以上，页面里读 `env(safe-area-inset-*)`
  /// 必须为 0 —— §12.2 的「安全区」自测就是看这个。打开之后那一项不再成立，改成页面
  /// 自己按 `env()` 留白（此时 `env()` 报的是真实值）。
  ///
  /// 键盘不受影响：打开时原生仍然消费 ime 的 inset（§9.2 要求输入框紧贴键盘、
  /// 完整可见），只是不再消费 systemBars 和 displayCutout。
  final bool webViewFullscreen;

  /// §8.1 HTTPS 自检。`http://localhost` 之类的本地调试地址放行。
  bool get isSecureEntry {
    final uri = Uri.tryParse(entryUrl);
    if (uri == null) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '10.0.2.2');
  }

  ShellConfigDto toDto() => ShellConfigDto(
        entryUrl: entryUrl,
        // 保留 Pigeon 的旧字段位置，避免改变消息格式；原生不再使用它。
        channelCode: '',
        shellVersion: shellVersion,
        bSideEnabled: bSideEnabled,
        splashTimeoutMs: splashTimeout.inMilliseconds,
        heartbeatIntervalMs: heartbeatInterval.inMilliseconds,
        aliveTimeoutMs: aliveTimeout.inMilliseconds,
        reloadConfirmTimeoutMs: reloadConfirmTimeout.inMilliseconds,
        recoveryBackoffFirstMs: recoveryBackoffFirst.inMilliseconds,
        recoveryBackoffLaterMs: recoveryBackoffLater.inMilliseconds,
        networkDebounceMs: networkDebounce.inMilliseconds,
        suppressForegroundNotifications: suppressForegroundNotifications,
        manageBadge: manageBadge,
        minKernelVersion: minKernelVersion,
        recommendedKernelVersion: recommendedKernelVersion,
        consoleBufferSize: consoleBufferSize,
        backgroundColorArgb: backgroundColorArgb,
        forwardConsole: forwardConsole,
        webViewFullscreen: webViewFullscreen,
      );

  ShellConfig copyWith({
    String? entryUrl,
    @Deprecated('Put channelcode in entryUrl; this value is ignored.')
    String? channelCode,
    String? shellVersion,
    bool? bSideEnabled,
    Duration? splashTimeout,
    Duration? heartbeatInterval,
    Duration? aliveTimeout,
    Duration? reloadConfirmTimeout,
    Duration? recoveryBackoffFirst,
    Duration? recoveryBackoffLater,
    Duration? networkDebounce,
    bool? suppressForegroundNotifications,
    bool? manageBadge,
    int? minKernelVersion,
    int? recommendedKernelVersion,
    int? consoleBufferSize,
    int? backgroundColorArgb,
    bool? forwardConsole,
    bool? webViewFullscreen,
  }) =>
      ShellConfig(
        entryUrl: entryUrl ?? this.entryUrl,
        // 仅保留旧字段的副本，URL 和 Pigeon 配置不会使用它。
        // ignore: deprecated_member_use_from_same_package
        channelCode: channelCode ?? this.channelCode,
        shellVersion: shellVersion ?? this.shellVersion,
        bSideEnabled: bSideEnabled ?? this.bSideEnabled,
        splashTimeout: splashTimeout ?? this.splashTimeout,
        heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
        aliveTimeout: aliveTimeout ?? this.aliveTimeout,
        reloadConfirmTimeout: reloadConfirmTimeout ?? this.reloadConfirmTimeout,
        recoveryBackoffFirst: recoveryBackoffFirst ?? this.recoveryBackoffFirst,
        recoveryBackoffLater: recoveryBackoffLater ?? this.recoveryBackoffLater,
        networkDebounce: networkDebounce ?? this.networkDebounce,
        suppressForegroundNotifications:
            suppressForegroundNotifications ?? this.suppressForegroundNotifications,
        manageBadge: manageBadge ?? this.manageBadge,
        minKernelVersion: minKernelVersion ?? this.minKernelVersion,
        recommendedKernelVersion: recommendedKernelVersion ?? this.recommendedKernelVersion,
        consoleBufferSize: consoleBufferSize ?? this.consoleBufferSize,
        backgroundColorArgb: backgroundColorArgb ?? this.backgroundColorArgb,
        forwardConsole: forwardConsole ?? this.forwardConsole,
        webViewFullscreen: webViewFullscreen ?? this.webViewFullscreen,
      );

  @override
  String toString() => 'ShellConfig(entryUrl: $entryUrl, '
      'shellVersion: $shellVersion, bSideEnabled: $bSideEnabled)';
}
