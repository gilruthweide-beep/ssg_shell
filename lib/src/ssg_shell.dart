import 'dart:async';

import 'package:flutter/foundation.dart';

import 'messages.g.dart';
import 'push.dart';
import 'shell_config.dart';

/// Dart facade for the native application shell.
///
/// The native layer owns the shell state machine. Under §8.4 Performance 2, `ImActivity` or the iOS container may be
/// the first screen on a cold start, before Flutter starts, while the §11.1 heartbeat and §11.2 liveness monitor
/// must already be running. Dart only supplies configuration, forwards calls, and exposes native events as streams.
///
/// ```dart
/// await SsgShell.instance.initialize(const ShellConfig(
///   entryUrl: 'https://im.example.com/?channelcode=ch001',
/// ));
///
/// SsgShell.instance.on(WebEventName.login).listen((e) => bindOneSignal(e.uid!));
/// await SsgShell.instance.openIm();
/// ```
class SsgShell implements SsgShellFlutterApi {
  SsgShell._({SsgShellHostApi? host}) : _host = host ?? SsgShellHostApi();

  static final SsgShell instance = SsgShell._();

  /// Testing: replace the platform boundary.
  @visibleForTesting
  factory SsgShell.withHost(SsgShellHostApi host) => SsgShell._(host: host);

  final SsgShellHostApi _host;

  final StreamController<WebEvent> _webEvents =
      StreamController<WebEvent>.broadcast();
  final StreamController<ShellEvent> _shellEvents =
      StreamController<ShellEvent>.broadcast();

  bool _wired = false;

  /// Web events arriving while [initialize] is in progress are held first; see [_releaseHeld].
  bool _holding = false;
  final List<WebEvent> _held = <WebEvent>[];

  bool _requestNotificationAfterLogin = true;
  bool _notificationRequested = false;

  ShellConfig? _config;
  ShellInfo? _shellInfo;

  bool _webReady = false;
  bool _loggedIn = false;
  String? _uid;
  String? _activeChatId;
  int _unreadCount = 0;

  // ------------------------------------------------------------------ Read-only state

  /// Forward all ten §3.1 Web events unchanged.
  Stream<WebEvent> get webEvents => _webEvents.stream;

  /// Native lifecycle events, recovery actions, and console forwarding ([ShellEventType]).
  Stream<ShellEvent> get shellEvents => _shellEvents.stream;

  /// Subscribe to a single Web event type.
  Stream<WebEvent> on(WebEventName name) =>
      _webEvents.stream.where((event) => event.name == name);

  /// Subscribe to a single native event type.
  Stream<ShellEvent> onShell(ShellEventType type) =>
      _shellEvents.stream.where((event) => event.type == type);

  ShellConfig? get config => _config;

  /// §1.1 The six fields injected into `window.__SSG_SHELL__`, available after [initialize].
  ShellInfo? get shellInfo => _shellInfo;

  /// §3.1 `webReady` was received: the first screen is visible and ready for `openChat`.
  bool get isWebReady => _webReady;

  /// §5.1 Login state maintained by `login` / `logout` events.
  bool get isLoggedIn => _loggedIn;

  /// The current IM uid, used unchanged as OneSignal's `external_id` (§5.1).
  String? get uid => _uid;

  /// §5.4 The active conversation, also tracked natively for foreground notification suppression.
  String? get activeChatId => _activeChatId;

  /// §5.4 Total unread count, excluding muted conversations.
  int get unreadCount => _unreadCount;

  // -------------------------------------------------------------------- Initialization

  /// Call first to persist configuration (including the §9.6 B-side cache) and build `__SSG_SHELL__` for §1.1.
  ///
  /// When [requestNotificationAfterLogin] is true, request notification permission once after the first
  /// `eventLogin`, matching §6.2. Asking before login leads to high denial rates,
  /// and most systems restrict subsequent permission prompts.
  ///
  /// When [autoPreload] is true, [preload] is called right after. Earlier native-side preloading (creating the
  /// WebView at process start, §8.4 Performance 1) is controlled by the Manifest `AUTO_PRELOAD` meta-data, not here.
  ///
  /// With native preloading, the Web may have already sent `webReady` / `login` /
  /// `unreadCount` / `chatOpen` before Dart came online. These stateful events are replayed during this call
  /// and enter [webEvents] only after it returns, so listeners must be attached either before the call or
  /// synchronously right after `await initialize(...)`, with no other `await` in between.
  Future<ShellInfo> initialize(
    ShellConfig config, {
    bool requestNotificationAfterLogin = true,
    bool autoPreload = true,
  }) async {
    assert(config.entryUrl.isNotEmpty, 'entryUrl must not be empty (§2.1)');
    assert(
      config.isSecureEntry,
      'entryUrl must use HTTPS (§8.1): when isSecureContext is false, Service Worker registration fails and'
      ' media loading and caching are limited. Current value:${config.entryUrl}',
    );
    _wire();
    _config = config;
    _requestNotificationAfterLogin = requestNotificationAfterLogin;
    _holding = true;
    try {
      // If the B side switch is omitted, keep the value persisted by native code instead of overwriting it with a default.
      final persistedBSide =
          config.bSideEnabled == null && await _host.isBSideEnabled();
      final info = await _host.initialize(
        config.toDto(persistedBSide: persistedBSide),
      );
      _shellInfo = info;
      if (autoPreload) await _host.preload();
      return info;
    } finally {
      if (_held.isEmpty || _webEvents.hasListener) {
        _releaseHeld();
      } else {
        // No listener yet: schedule for the next event-loop task so listeners the caller attaches synchronously after `await`
        // are in place before the events are released.
        Timer.run(_releaseHeld);
      }
    }
  }

  void _releaseHeld() {
    _holding = false;
    final held = List<WebEvent>.of(_held);
    _held.clear();
    if (_webEvents.isClosed) return;
    held.forEach(_webEvents.add);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    SsgShellFlutterApi.setUp(this);
  }

  /// Release streams. A single shell normally lives for the application lifetime, so this is rarely needed.
  Future<void> dispose() async {
    SsgShellFlutterApi.setUp(null);
    _wired = false;
    await _webEvents.close();
    await _shellEvents.close();
  }

  // ----------------------------------------------------------------- Container control

  /// §8.4 Performance 1: create the WebView and load the landing URL in advance; no-op when B side is disabled.
  Future<void> preload() => _host.preload();

  /// Open the IM container (Android starts `ImActivity`; iOS presents a fullscreen view controller).
  Future<void> openIm() => _host.openIm();

  /// Close the IM container without destroying the WebView instance (§10.6).
  Future<void> closeIm() => _host.closeIm();

  Future<bool> isImRunning() => _host.isImRunning();

  /// §9.6 Persist the B-side switch so the next native cold start uses the cache without waiting for Dart.
  Future<void> setBSideEnabled(bool enabled) => _host.setBSideEnabled(enabled);

  Future<bool> isBSideEnabled() => _host.isBSideEnabled();

  // ----------------------------------------------------------------- Deep links / push

  /// §5.3 Open a conversation. Native code queues the request until `eventWebReady` if necessary.
  ///
  /// Call once: the Web application waits up to 20 seconds for conversation data before navigating, so native retries are unnecessary.
  Future<void> openChat(String chatId, {String? messageId}) =>
      _host.openChat(OpenChatRequest(chatId: chatId, messageId: messageId));

  /// §5.4 + §11.3 Call when a push **arrives**, supplying OneSignal's `additionalData` map unchanged.
  ///
  /// The result indicates whether to display the notification (suppress it for the active conversation), and whether native code
  /// called `onNetwork()` to wake the Web connection after a foreground push indicated a stale connection.
  Future<PushDecision> handlePushReceived(Map<Object?, Object?>? data) =>
      _host.handlePushReceived(parsePushData(data));

  /// §5.3 Call when a notification **is clicked**. Native code opens IM as needed and queues the payload until `eventWebReady`.
  Future<void> handlePushOpened(Map<Object?, Object?>? data) =>
      _host.handlePushOpened(parsePushData(data));

  /// §5.4 Set the badge manually. With `manageBadge` enabled, the plugin already updates it from `unreadCount`.
  Future<void> setBadgeCount(int count) => _host.setBadgeCount(count);

  // ----------------------------------------------------------------- Connection liveness

  /// §10.4 / §11.3 Manually call `onNetwork(type)` once. Discard `none`, which the Web application would ignore.
  Future<void> nudgeNetwork(NetworkType type) => _host.nudgeNetwork(type);

  /// §11.2 Trigger a recovery reload manually.
  Future<void> reloadWeb() => _host.reloadWeb();

  /// §11.2.3 Destroy and recreate the WebView manually; Android terminates the renderer first.
  Future<void> recreateWebView() => _host.recreateWebView();

  // ----------------------------------------------------------------- Permissions

  Future<NotificationPermission> getNotificationPermission() =>
      _host.getNotificationPermission();

  /// §6.2 Call only after `eventLogin`. Native code rejects startup requests and returns the current permission state.
  Future<NotificationPermission> requestNotificationPermission() =>
      _host.requestNotificationPermission();

  /// §6.2 Open system settings to guide the user after permission is permanently denied.
  Future<void> openSystemSettings() => _host.openSystemSettings();

  /// §10.3 Request battery optimization exemption outside the first launch. Offer it from settings
  /// or when the user reports missing messages.
  Future<bool> requestBatteryOptimizationExemption() =>
      _host.requestBatteryOptimizationExemption();

  Future<bool> isBatteryOptimizationIgnored() =>
      _host.isBatteryOptimizationIgnored();

  // ----------------------------------------------------------------- Diagnostics

  /// §11.6 Complete contents for the hidden diagnostics screen.
  Future<ShellDiagnostics> getDiagnostics() => _host.getDiagnostics();

  /// §11.6 Export diagnostics as copyable plain text.
  Future<String> exportDiagnostics() => _host.exportDiagnostics();

  /// §8.1 / §11.7 Engine version. Versions below 92 produce [KernelVerdict.belowMinimum]
  /// in [KernelInfo.verdict]. Under §11.7, show update guidance once without blocking startup.
  Future<KernelInfo> getKernelInfo() => _host.getKernelInfo();

  /// §1.3 Injection check: read `document.documentElement.classList.contains('is-web-browser')`.
  /// It must be false. A true result fails regardless of the contents of `__SSG_SHELL__`.
  Future<bool> verifyInjection() => _host.verifyInjection();

  /// Debugging only. Do not clear storage (§8.3); native code throws for known storage-clearing calls.
  Future<String> evaluateJavaScript(String script) =>
      _host.evaluateJavaScript(script);

  // --------------------------------------------------- SsgShellFlutterApi

  @override
  void onWebEvent(WebEvent event) {
    switch (event.name) {
      case WebEventName.webReady:
        _webReady = true;
      case WebEventName.login:
        final uid = event.uid;
        if (uid != null && uid.trim().isNotEmpty) {
          _loggedIn = true;
          _uid = uid;
          _maybeRequestNotification();
        }
      case WebEventName.logout:
        _loggedIn = false;
        _uid = null;
        _activeChatId = null;
        _unreadCount = 0;
      case WebEventName.chatOpen:
        _activeChatId = event.chatId;
      case WebEventName.chatClose:
        // When changing conversations, the Web application can emit chatOpen before the previous chatClose;
        // clear the active conversation only when the close event matches it.
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
    if (_holding) {
      _held.add(event);
      return;
    }
    if (!_webEvents.isClosed) _webEvents.add(event);
  }

  @override
  void onShellEvent(ShellEvent event) {
    if (event.type == ShellEventType.foreground && _loggedIn) {
      _maybeRequestNotification();
    }
    // The Web application does not emit chatClose on reload, recreation, or refresh after logout.
    // Native code clears the tracked chatId when loading starts (§5.4); clear the Dart copy too.
    if (event.type == ShellEventType.reloadIssued ||
        event.type == ShellEventType.webViewRecreated ||
        event.type == ShellEventType.renderProcessGone) {
      _webReady = false;
      _activeChatId = null;
    }
    if (!_shellEvents.isClosed) _shellEvents.add(event);
  }

  /// §6.2 Request notification permission only after `eventLogin`, and only once.
  void _maybeRequestNotification() {
    if (!_requestNotificationAfterLogin ||
        _notificationRequested ||
        !_loggedIn) {
      return;
    }
    _notificationRequested = true;
    Future<void>(() async {
      if (!_loggedIn) {
        _notificationRequested = false;
        return;
      }
      final current = await _host.getNotificationPermission();
      if (!_loggedIn) {
        _notificationRequested = false;
        return;
      }
      if (current == NotificationPermission.granted) return;
      // Native code decides between the system prompt and Settings guidance
      // (denied, permanently denied, or the app-wide switch turned off), so a
      // user who once declined is not left silently without push. This runs at
      // most once per process: denied results do not reset the flag below.
      final result = await _host.requestNotificationPermission();
      // No foreground Activity (or a logout racing this request) can leave the
      // permission undecided. Retry after login on a later foreground event.
      if (result == NotificationPermission.notDetermined) {
        _notificationRequested = false;
      }
    }).catchError((Object error) {
      _notificationRequested = false;
      debugPrint('SsgShell: Notification permission request failed $error');
    });
  }
}
