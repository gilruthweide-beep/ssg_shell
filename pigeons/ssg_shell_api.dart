// 马甲包对接规范 v1.0.2 的 Pigeon 契约。
//
// 这个文件是双端唯一的接口来源：改这里 → `dart run pigeon --input pigeons/ssg_shell_api.dart`
// → Dart / Kotlin / Swift 三份代码同时更新。不要手改 *.g.dart / Messages.g.kt / Messages.g.swift。
//
// 条款编号对应 /docs/马甲包对接规范.md 的章节。

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/ssg/ssg_shell/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.ssg.ssg_shell'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'ssg_shell',
  ),
)
// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------

/// §1.1 `platform`，只接受这两个取值。
enum ShellPlatform { android, ios }

/// §4 `onNetwork(type)` 的取值。`none` 不会转发给 Web（会被忽略），
/// 保留它只是为了让原生侧的网络状态可以完整表达。
enum NetworkType { wifi, cellular, ethernet, other, none }

/// §3.1 的十个事件。`unknown` 用于 Web 将来新增事件时的前向兼容：
/// 原始字符串仍然保留在 [WebEvent.rawName] 里。
enum WebEventName {
  webReady,
  register,
  login,
  logout,
  messageSent,
  webAlive,
  chatOpen,
  chatClose,
  chatRead,
  unreadCount,
  unknown,
}

/// §11.6 console 转发的级别。
enum ConsoleLevel { debug, log, info, warning, error }

/// §6.2 通知权限。`permanentlyDenied` 时要走 §6.2 的二次引导。
enum NotificationPermission {
  notDetermined,
  granted,
  denied,
  permanentlyDenied,
  notSupported,
}

/// §8.1 / §11.7 内核版本判定。
enum KernelVerdict { ok, belowRecommended, belowMinimum, unknown }

/// 原生侧发生的事情，由 [SsgShellFlutterApi.onShellEvent] 上抛给 Dart。
enum ShellEventType {
  /// §4 `onForeground()` 已调用。
  foreground,

  /// §4 `onBackground()` 已调用。
  background,

  /// §10.4 去抖之后、确认网络可用才发；`network` 字段带类型。
  networkChanged,

  /// §11.4 已向 Web 转发 `onMemoryWarning()`。
  memoryWarning,

  /// §9.6 收到 `eventWebReady`，splash 已撤。
  splashDismissed,

  /// §9.6 splash 到达上限（默认 30 秒）被强制撤除。
  splashTimedOut,

  /// §9.6 首屏加载失败，已切到原生重试页。
  loadFailed,

  /// §7.1 `onRenderProcessGone` / `webViewWebContentProcessDidTerminate`。
  renderProcessGone,

  /// §11.2 判定卡死。
  stallDetected,

  /// §11.2 已执行 `reload()`。
  reloadIssued,

  /// §11.2 reload 无效，已销毁重建 WebView。
  webViewRecreated,

  /// §11.2.5 处于退避窗口内，本次卡死不处理。
  recoveryThrottled,

  /// IM 容器已显示。
  imOpened,

  /// IM 容器已关闭 / 退到后台。
  imClosed,

  /// §11.6 Web 的一条 console 输出。
  consoleMessage,

  /// §1.3 注入自检结果；`extra['isWebBrowser']` 为 `'false'` 才算通过。
  injectionChecked,

  /// §5.3 深链已交给 Web（`extra['chatId']`）。
  deepLinkDelivered,

  /// §5.3 深链被暂存，等 `eventWebReady`。
  deepLinkQueued,
}

// ---------------------------------------------------------------------------
// 数据类
// ---------------------------------------------------------------------------

/// 壳的全部可调参数。默认值在 Dart 侧的 `ShellConfig` 工厂里给，
/// 原生侧只负责照单执行。
class ShellConfigDto {
  ShellConfigDto({
    required this.entryUrl,
    required this.channelCode,
    required this.shellVersion,
    required this.bSideEnabled,
    required this.splashTimeoutMs,
    required this.heartbeatIntervalMs,
    required this.aliveTimeoutMs,
    required this.reloadConfirmTimeoutMs,
    required this.recoveryBackoffFirstMs,
    required this.recoveryBackoffLaterMs,
    required this.networkDebounceMs,
    required this.suppressForegroundNotifications,
    required this.manageBadge,
    required this.minKernelVersion,
    required this.recommendedKernelVersion,
    required this.consoleBufferSize,
    required this.backgroundColorArgb,
    required this.forwardConsole,
    required this.webViewFullscreen,
  });

  /// §2.1 入口地址，不含 `channelCode`，由原生拼。
  String entryUrl;

  /// §2.1 渠道码，空串表示放弃归因。
  String channelCode;

  /// §1.1 / §2.2 壳版本，同时进 `__SSG_SHELL__` 和 UA。
  String shellVersion;

  /// §9.6 B 面开关。原生会把它缓存到本地，下次冷启动不等 Dart。
  bool bSideEnabled;

  /// §9.6 splash 上限，建议 30000。
  int splashTimeoutMs;

  /// §11.1 原生心跳周期，规范值 20000。
  int heartbeatIntervalMs;

  /// §11.2 多久没收到 `eventWebAlive` 判定卡死，规范值 60000。
  int aliveTimeoutMs;

  /// §11.2.3 reload 后多久没开始加载就重建，规范值 10000。
  int reloadConfirmTimeoutMs;

  /// §11.2.5 第一次处理后的退避，规范值 180000。
  int recoveryBackoffFirstMs;

  /// §11.2.5 之后的退避，规范值 600000。
  int recoveryBackoffLaterMs;

  /// §10.4 网络回调去抖，规范区间 1000~2000。
  int networkDebounceMs;

  /// §5.4 前台抑制开关。
  bool suppressForegroundNotifications;

  /// §5.4 是否由插件按 `unreadCount` 设角标。
  bool manageBadge;

  /// §8.1 硬性下限，92。
  int minKernelVersion;

  /// §8.1 推荐值，110。
  int recommendedKernelVersion;

  /// §11.6 console 环形缓冲条数。
  int consoleBufferSize;

  /// §8.4 / §9.4 WebView 与窗口背景色，规范要求白色 0xFFFFFFFF。
  int backgroundColorArgb;

  /// §11.6 是否把 Web 的 console 转发到原生日志与 Dart。
  bool forwardConsole;

  /// WebView 铺满整个窗口，不摆进安全区。
  ///
  /// **这是对 §9.4 的偏离**，默认关。规范要求原生把 WebView 摆在状态栏 / 刘海 / 灵动岛
  /// 以下、Home 指示条（Android 为导航栏）以上，页面里读 `env(safe-area-inset-*)` 必须
  /// 为 0 —— §12.2 的「安全区」自测就是看这个。打开它之后那一项不再成立，页面要自己
  /// 按 `env()` 留白。
  ///
  /// 键盘不受影响：打开它时原生仍然消费 ime 的 inset（§9.2 要求输入框紧贴键盘、
  /// 完整可见），只是不再消费 systemBars 和 displayCutout。
  bool webViewFullscreen;
}

/// §1.1 实际注入到 `window.__SSG_SHELL__` 的六个字段。
class ShellInfo {
  ShellInfo({
    required this.platform,
    required this.bundleId,
    required this.shellVersion,
    required this.webviewVersion,
    required this.deviceModel,
    required this.osVersion,
  });

  ShellPlatform platform;
  String bundleId;
  String shellVersion;
  String webviewVersion;
  String deviceModel;
  String osVersion;
}

/// §3.1 一条 Web → Native 事件。
///
/// 规范规定 params 全是字符串，所以原始内容完整保留在 [params] 里；
/// 常用字段额外做了类型化，避免每个调用点自己解析。
class WebEvent {
  WebEvent({
    required this.name,
    required this.rawName,
    required this.receivedAtMs,
    required this.params,
    this.uid,
    this.channelCode,
    this.chatId,
    this.unreadCount,
    this.webTimestamp,
  });

  WebEventName name;

  /// Web 原样发来的 `eventName`。
  String rawName;

  /// 原生收到的时刻（原生时钟，毫秒）。
  int receivedAtMs;

  /// 原样的 `params`。
  Map<String, String> params;

  String? uid;
  String? channelCode;
  String? chatId;

  /// `unreadCount` 事件的 `count`，已解析成数字。
  int? unreadCount;

  /// Web 给的 `timestamp`（字符串，可能不是数字）。
  String? webTimestamp;
}

/// §5.3 打开会话。
class OpenChatRequest {
  OpenChatRequest({required this.chatId, this.messageId});

  /// 字符串形式：私聊为对方 uid，群和频道为负数 id。
  String chatId;

  /// 可省略；省略时只打开会话，不定位消息。
  String? messageId;
}

/// §5.3 OneSignal 下发的 `data`。字段名兼容 `chat_id` / `chatId` 两种写法，
/// 解析在 Dart 侧的 `parsePushData()` 里做（`lib/src/push.dart`）。
class PushMessage {
  PushMessage({this.chatId, this.messageId, this.fromId, required this.data});

  String? chatId;
  String? messageId;
  String? fromId;
  Map<String, String> data;
}

/// [SsgShellHostApi.handlePushReceived] 的结果。
class PushDecision {
  PushDecision({
    required this.suppressNotification,
    required this.nudgedWeb,
    required this.appInForeground,
    required this.reason,
  });

  /// §5.4 true 表示用户正停在这个会话里，不要展示系统通知。
  bool suppressNotification;

  /// §11.3 true 表示已调过一次 `onNetwork()` 把 Web 捅醒。
  bool nudgedWeb;

  bool appInForeground;

  /// 给日志用的人类可读理由。
  String reason;
}

/// §8.1 / §11.7 内核信息。
class KernelInfo {
  KernelInfo({
    required this.verdict,
    required this.versionName,
    required this.majorVersion,
    required this.packageName,
  });

  KernelVerdict verdict;

  /// 完整版本号，如 `120.0.6099.230`；取不到时为空串。
  String versionName;

  /// 主版本号，取不到时为 -1。
  int majorVersion;

  /// Android 为 WebView 实现包名（`com.google.android.webview` 等）；iOS 为空串。
  String packageName;
}

/// §11.6 一条 console 记录。
class ConsoleRecord {
  ConsoleRecord({
    required this.level,
    required this.message,
    required this.atMs,
    this.source,
    this.line,
  });

  ConsoleLevel level;
  String message;
  int atMs;
  String? source;
  int? line;
}

/// §11.6 隐藏诊断入口要展示 / 导出的全部内容。
class ShellDiagnostics {
  ShellDiagnostics({
    required this.shellInfo,
    required this.entryUrl,
    required this.currentUrl,
    required this.userAgent,
    required this.channelCode,
    required this.injectionOk,
    required this.imRunning,
    required this.appInForeground,
    required this.reloadCount,
    required this.recreateCount,
    required this.badgeCount,
    required this.kernel,
    required this.consoleTail,
    this.lastReloadAtMs,
    this.lastWebReadyAtMs,
    this.lastWebAliveAtMs,
    this.trackedChatId,
  });

  ShellInfo shellInfo;
  String entryUrl;
  String currentUrl;
  String userAgent;
  String channelCode;

  /// §1.3 自检：`document.documentElement.classList.contains('is-web-browser') === false`。
  bool injectionOk;

  bool imRunning;
  bool appInForeground;
  int reloadCount;
  int recreateCount;

  /// §5.4 当前角标数。
  int badgeCount;

  KernelInfo kernel;

  /// §11.6 最近 N 条 console。
  List<ConsoleRecord> consoleTail;

  int? lastReloadAtMs;
  int? lastWebReadyAtMs;
  int? lastWebAliveAtMs;

  /// §5.4 原生记住的最近一次 `chatOpen` 的 chatId。
  String? trackedChatId;
}

/// 原生侧事件。
class ShellEvent {
  ShellEvent({
    required this.type,
    required this.atMs,
    required this.extra,
    this.message,
    this.network,
    this.console,
  });

  ShellEventType type;
  int atMs;
  Map<String, String> extra;
  String? message;
  NetworkType? network;
  ConsoleRecord? console;
}

// ---------------------------------------------------------------------------
// Dart → Native
// ---------------------------------------------------------------------------

@HostApi()
abstract class SsgShellHostApi {
  /// 必须最先调。原生据此落盘配置（§9.6 的 B 面缓存也在这里更新），
  /// 并按 §1.1 组装 `__SSG_SHELL__`。重复调用会覆盖配置，但不会重建 WebView。
  ShellInfo initialize(ShellConfigDto config);

  /// §8.4 体验与性能 1：提前创建 WebView 并开始加载入口地址。
  /// B 面未开启时是空操作。幂等。
  void preload();

  /// 打开 IM 容器：Android `startActivity(ImActivity)`，iOS present 全屏 VC。
  /// 已经在前台时是空操作。
  void openIm();

  /// 关闭 IM 容器。按 §10.6，**不会**销毁 WebView 实例。
  void closeIm();

  bool isImRunning();

  /// §9.6 更新 B 面开关并落盘，下次冷启动原生直接按缓存走，不等 Dart。
  void setBSideEnabled(bool enabled);

  bool isBSideEnabled();

  /// §5.3 打开会话。Web 还没发 `eventWebReady` 时自动暂存，就绪后补发，
  /// 只调一次，不重试。
  void openChat(OpenChatRequest request);

  /// §5.4 + §11.3 推送到达时调。返回「要不要展示通知」以及有没有捅醒 Web。
  /// 原生自己判断前台状态，Dart 不需要传。
  PushDecision handlePushReceived(PushMessage message);

  /// §5.3 通知被点击时调。会按需 `openIm()` 并把参数排队，等 `eventWebReady`。
  void handlePushOpened(PushMessage message);

  /// §10.4 / §11.3 手动调一次 `onNetwork(type)`。`none` 会被丢弃。
  void nudgeNetwork(NetworkType type);

  /// §11.2 手动触发兜底 reload（调试与诊断入口用）。
  void reloadWeb();

  /// §11.2.3 手动销毁重建 WebView（Android 会先结束渲染进程）。
  void recreateWebView();

  /// §5.4 设角标。`manageBadge` 为 true 时插件已自动按 `unreadCount` 设，
  /// 这里留给需要自己接管的场合。
  void setBadgeCount(int count);

  ShellDiagnostics getDiagnostics();

  /// §11.6 导出成可复制的纯文本。
  String exportDiagnostics();

  /// §8.1 / §11.7 读内核版本。
  KernelInfo getKernelInfo();

  NotificationPermission getNotificationPermission();

  /// §6.2 只在收到 `eventLogin` 之后调。启动期调用会被原生拒掉并返回当前状态。
  @async
  NotificationPermission requestNotificationPermission();

  /// §6.2 权限被永久拒绝后的二次引导：拉起系统设置页。
  void openSystemSettings();

  /// §10.3 Android 申请电池优化白名单（规范要求不在首启弹）。iOS 空操作返回 true。
  @async
  bool requestBatteryOptimizationExemption();

  bool isBatteryOptimizationIgnored();

  /// §1.3 跑一次注入自检，读 `is-web-browser` class。
  @async
  bool verifyInjection();

  /// 调试用：在 Web 里执行一段 JS 并返回结果字符串。
  /// 禁止用它清存储（§8.3），插件会拦掉已知的清理调用。
  @async
  String evaluateJavaScript(String script);
}

// ---------------------------------------------------------------------------
// Native → Dart
// ---------------------------------------------------------------------------

@FlutterApi()
abstract class SsgShellFlutterApi {
  /// §3.1 的十个事件，原生收到后原样上抛。
  void onWebEvent(WebEvent event);

  /// 原生侧的生命周期、恢复动作、console 转发。
  void onShellEvent(ShellEvent event);
}
