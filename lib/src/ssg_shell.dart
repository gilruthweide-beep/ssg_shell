import 'dart:async';

import 'package:flutter/foundation.dart';

import 'messages.g.dart';
import 'push.dart';
import 'shell_config.dart';

/// 马甲包原生壳的 Dart 门面。
///
/// 壳的状态机全在原生侧 —— 按 §8.4 体验与性能 2，`ImActivity` / iOS 的容器可以是冷启动
/// 的第一个界面，那时 Flutter 引擎还没起来，而 §11.1 的心跳、§11.2 的存活监测必须已经
/// 在跑。所以这里只做三件事：下发配置、转发调用、把原生上抛的事件变成 Stream。
///
/// ```dart
/// await SsgShell.instance.initialize(const ShellConfig(
///   entryUrl: 'https://im.example.com/',
///   channelCode: 'ch001',
/// ));
///
/// SsgShell.instance.on(WebEventName.login).listen((e) => bindOneSignal(e.uid!));
/// await SsgShell.instance.openIm();
/// ```
class SsgShell implements SsgShellFlutterApi {
  SsgShell._({SsgShellHostApi? host}) : _host = host ?? SsgShellHostApi();

  static final SsgShell instance = SsgShell._();

  /// 测试用：换掉过线的那一层。
  @visibleForTesting
  factory SsgShell.withHost(SsgShellHostApi host) => SsgShell._(host: host);

  final SsgShellHostApi _host;

  final StreamController<WebEvent> _webEvents = StreamController<WebEvent>.broadcast();
  final StreamController<ShellEvent> _shellEvents = StreamController<ShellEvent>.broadcast();

  bool _wired = false;
  bool _requestNotificationAfterLogin = true;
  bool _notificationRequested = false;

  ShellConfig? _config;
  ShellInfo? _shellInfo;

  bool _webReady = false;
  bool _loggedIn = false;
  String? _uid;
  String? _activeChatId;
  int _unreadCount = 0;

  // ------------------------------------------------------------------ 只读状态

  /// §3.1 的十个事件，原样转发。
  Stream<WebEvent> get webEvents => _webEvents.stream;

  /// 原生侧的生命周期、恢复动作、console 转发（[ShellEventType]）。
  Stream<ShellEvent> get shellEvents => _shellEvents.stream;

  /// 只订阅某一类 Web 事件。
  Stream<WebEvent> on(WebEventName name) =>
      _webEvents.stream.where((event) => event.name == name);

  /// 只订阅某一类原生事件。
  Stream<ShellEvent> onShell(ShellEventType type) =>
      _shellEvents.stream.where((event) => event.type == type);

  ShellConfig? get config => _config;

  /// §1.1 实际注入进 `window.__SSG_SHELL__` 的六个字段，[initialize] 之后才有值。
  ShellInfo? get shellInfo => _shellInfo;

  /// §3.1 收到过 `webReady`：首屏已可见、可接受 `openChat`。
  bool get isWebReady => _webReady;

  /// §5.1 当前是否登录态（由 `login` / `logout` 事件维护）。
  bool get isLoggedIn => _loggedIn;

  /// 当前登录的 IM uid，也就是 OneSignal 的 `external_id`（§5.1，无前缀无转换）。
  String? get uid => _uid;

  /// §5.4 用户正停在哪个会话。原生侧也记了一份，用于前台抑制。
  String? get activeChatId => _activeChatId;

  /// §5.4 未读总数（不含免打扰会话）。
  int get unreadCount => _unreadCount;

  // -------------------------------------------------------------------- 装配

  /// 必须最先调。会落盘配置（§9.6 的 B 面缓存）并按 §1.1 组装 `__SSG_SHELL__`。
  ///
  /// [requestNotificationAfterLogin] 为 true 时，收到第一条 `eventLogin` 后自动申请一次
  /// 通知权限 —— §6.2 的时机要求就是「收到 `eventLogin` 之后」，未登录状态弹授权拒绝率
  /// 极高，而多数系统不允许二次申请。
  ///
  /// [autoPreload] 为 true 时紧接着调一次 [preload]。原生侧更早的预加载（进程启动即建
  /// WebView，§8.4 体验与性能 1）由 Manifest 的 `AUTO_PRELOAD` meta-data 控制，不走这里。
  Future<ShellInfo> initialize(
    ShellConfig config, {
    bool requestNotificationAfterLogin = true,
    bool autoPreload = true,
  }) async {
    assert(
      config.entryUrl.isNotEmpty,
      'entryUrl 不能为空（§2.1）',
    );
    assert(
      config.isSecureEntry,
      'entryUrl 必须是 HTTPS（§8.1）：isSecureContext 为 false 时 Service Worker 注册不了，'
      '媒体加载与缓存全部降级。当前值：${config.entryUrl}',
    );
    _wire();
    _config = config;
    _requestNotificationAfterLogin = requestNotificationAfterLogin;
    final info = await _host.initialize(config.toDto());
    _shellInfo = info;
    if (autoPreload) await _host.preload();
    return info;
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    SsgShellFlutterApi.setUp(this);
  }

  /// 释放 Stream。整个 App 生命周期只有一个壳，一般不需要调。
  Future<void> dispose() async {
    SsgShellFlutterApi.setUp(null);
    _wired = false;
    await _webEvents.close();
    await _shellEvents.close();
  }

  // ----------------------------------------------------------------- 容器控制

  /// §8.4 体验与性能 1：提前创建 WebView 并开始加载入口地址。B 面未开启时是空操作。
  Future<void> preload() => _host.preload();

  /// 打开 IM 容器（Android 起 `ImActivity`，iOS present 全屏 VC）。
  Future<void> openIm() => _host.openIm();

  /// 关闭 IM 容器。按 §10.6 **不会**销毁 WebView 实例。
  Future<void> closeIm() => _host.closeIm();

  Future<bool> isImRunning() => _host.isImRunning();

  /// §9.6 B 面开关，会落盘；下次冷启动原生直接按缓存走，不等 Dart。
  Future<void> setBSideEnabled(bool enabled) => _host.setBSideEnabled(enabled);

  Future<bool> isBSideEnabled() => _host.isBSideEnabled();

  // ----------------------------------------------------------------- 深链 / 推送

  /// §5.3 打开会话。Web 还没发 `eventWebReady` 时原生会暂存，就绪后补发。
  ///
  /// 只调一次就够 —— Web 内部会等会话数据就绪（最长 20 秒）再跳转，不需要重试。
  Future<void> openChat(String chatId, {String? messageId}) =>
      _host.openChat(OpenChatRequest(chatId: chatId, messageId: messageId));

  /// §5.4 + §11.3 推送**到达**时调，传 OneSignal 的 `additionalData` 原样 map。
  ///
  /// 返回值告诉你这条通知要不要展示（用户正停在该会话里就别弹），以及原生有没有顺手
  /// 调一次 `onNetwork()` 把 Web 捅醒（前台收到推送 = 长连接已死）。
  Future<PushDecision> handlePushReceived(Map<Object?, Object?>? data) =>
      _host.handlePushReceived(parsePushData(data));

  /// §5.3 通知**被点击**时调。原生会按需打开 IM 容器并把参数排队，等 `eventWebReady`。
  Future<void> handlePushOpened(Map<Object?, Object?>? data) =>
      _host.handlePushOpened(parsePushData(data));

  /// §5.4 手动设角标。`manageBadge` 为 true 时插件已按 `unreadCount` 自动设。
  Future<void> setBadgeCount(int count) => _host.setBadgeCount(count);

  // ----------------------------------------------------------------- 保活

  /// §10.4 / §11.3 手动调一次 `onNetwork(type)`。`none` 会被丢弃（Web 会忽略）。
  Future<void> nudgeNetwork(NetworkType type) => _host.nudgeNetwork(type);

  /// §11.2 手动触发兜底 reload。
  Future<void> reloadWeb() => _host.reloadWeb();

  /// §11.2.3 手动销毁重建 WebView（Android 会先结束渲染进程）。
  Future<void> recreateWebView() => _host.recreateWebView();

  // ----------------------------------------------------------------- 权限

  Future<NotificationPermission> getNotificationPermission() =>
      _host.getNotificationPermission();

  /// §6.2 只在收到 `eventLogin` 之后调。启动期调用会被原生拒掉并返回当前状态。
  Future<NotificationPermission> requestNotificationPermission() =>
      _host.requestNotificationPermission();

  /// §6.2 权限被永久拒绝后的二次引导：拉起系统设置页。
  Future<void> openSystemSettings() => _host.openSystemSettings();

  /// §10.3 电池优化白名单。规范要求**不在首启弹** —— 放设置页引导，
  /// 或用户反馈收不到消息时再引导。
  Future<bool> requestBatteryOptimizationExemption() =>
      _host.requestBatteryOptimizationExemption();

  Future<bool> isBatteryOptimizationIgnored() => _host.isBatteryOptimizationIgnored();

  // ----------------------------------------------------------------- 诊断

  /// §11.6 隐藏入口要展示的全部内容。
  Future<ShellDiagnostics> getDiagnostics() => _host.getDiagnostics();

  /// §11.6 导出成可复制的纯文本。
  Future<String> exportDiagnostics() => _host.exportDiagnostics();

  /// §8.1 / §11.7 内核版本。低于 92 时 [KernelInfo.verdict] 为
  /// [KernelVerdict.belowMinimum]，按 §11.7 一次性提示用户更新，不要阻断启动。
  Future<KernelInfo> getKernelInfo() => _host.getKernelInfo();

  /// §1.3 注入自检：读 `document.documentElement.classList.contains('is-web-browser')`，
  /// 必须为 false。只要它是 true，无论 `__SSG_SHELL__` 打印出什么都算失败。
  Future<bool> verifyInjection() => _host.verifyInjection();

  /// 调试用。禁止用它清存储（§8.3），原生会拦掉已知的清理调用并抛错。
  Future<String> evaluateJavaScript(String script) => _host.evaluateJavaScript(script);

  // --------------------------------------------------- SsgShellFlutterApi

  @override
  void onWebEvent(WebEvent event) {
    switch (event.name) {
      case WebEventName.webReady:
        _webReady = true;
      case WebEventName.login:
        _loggedIn = true;
        _uid = event.uid ?? _uid;
        _maybeRequestNotification();
      case WebEventName.logout:
        _loggedIn = false;
        _uid = null;
        _activeChatId = null;
        _unreadCount = 0;
      case WebEventName.chatOpen:
        _activeChatId = event.chatId;
      case WebEventName.chatClose:
        // 切到别的会话时 Web 会先发 chatOpen 再发上一个的 chatClose，
        // 所以只有「关的正是当前这个」才清空。
        if (_activeChatId == event.chatId) _activeChatId = null;
      case WebEventName.unreadCount:
        _unreadCount = event.unreadCount ?? _unreadCount;
      case WebEventName.register:
      case WebEventName.messageSent:
      case WebEventName.webAlive:
      case WebEventName.chatRead:
      case WebEventName.unknown:
        break;
    }
    if (!_webEvents.isClosed) _webEvents.add(event);
  }

  @override
  void onShellEvent(ShellEvent event) {
    // 页面重新加载（reload、重建、被踢下线后刷新）时 Web 不会发 chatClose，
    // 原生在页面开始加载时会清掉记住的 chatId（§5.4），这边跟着清。
    if (event.type == ShellEventType.reloadIssued ||
        event.type == ShellEventType.webViewRecreated ||
        event.type == ShellEventType.renderProcessGone) {
      _webReady = false;
      _activeChatId = null;
    }
    if (!_shellEvents.isClosed) _shellEvents.add(event);
  }

  /// §6.2 通知权限：收到 `eventLogin` 之后才申请，且只申请一次。
  void _maybeRequestNotification() {
    if (!_requestNotificationAfterLogin || _notificationRequested) return;
    _notificationRequested = true;
    Future<void>(() async {
      final current = await _host.getNotificationPermission();
      // 已经授权、或已被永久拒绝（多数系统不允许二次申请）时不再打扰用户。
      if (current != NotificationPermission.notDetermined) return;
      await _host.requestNotificationPermission();
    }).catchError((Object error) {
      _notificationRequested = false;
      debugPrint('SsgShell: 申请通知权限失败 $error');
    });
  }
}
