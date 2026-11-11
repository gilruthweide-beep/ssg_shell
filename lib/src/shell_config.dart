import 'messages.g.dart';

/// Shell runtime configuration.
///
/// Defaults from the specification are defined here; native code uses the supplied values
/// without adding its own defaults. Use [Duration] here and convert to milliseconds at the Pigeon boundary.
class ShellConfig {
  const ShellConfig({
    required this.entryUrl,
    @Deprecated('Put channelcode in entryUrl; this value is ignored.')
    this.channelCode = '',
    this.shellVersion = '',
    this.bSideEnabled,
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
    @Deprecated('Not implemented on either platform; this value is ignored.')
    this.webViewFullscreen = false,
  });

  /// §2.1 Complete landing URL, loaded unchanged.
  ///
  /// The channel code is optional. Include it directly in the URL when attribution is needed, for example
  /// `https://im.example.com/?channelcode=ch001`. The shell does not add, remove, or rebuild query parameters;
  /// the Web application owns parameter casing, values, and storage.
  ///
  /// §8.1 HTTPS is required: Service Worker registration fails when `isSecureContext === false`,
  /// and media loading and caching fall back to reduced functionality.
  final String entryUrl;

  /// Legacy compatibility field; ignored for URL loading and channel attribution.
  ///
  /// Pass the optional channel code through [entryUrl]. URLs without one are also valid.
  @Deprecated('Put channelcode in entryUrl; this value is ignored.')
  final String channelCode;

  /// §1.1 / §2.2 Shell version used in `__SSG_SHELL__` and the user-agent suffix.
  /// When empty, native code uses the host's `versionName` / `CFBundleShortVersionString`.
  final String shellVersion;

  /// §9.6 B side switch. Native code persists it, and the next cold start uses the cached value directly without waiting for Dart,
  /// so "deciding the B side switch" never appears to the user as a waiting screen.
  ///
  /// Omitting it (null) means **keep the already persisted value**, which is off if never set. This way calling
  /// `initialize()` as usual on every launch does not overwrite the result saved by [SsgShell.setBSideEnabled].
  /// Passing true / false makes this value authoritative and persists it.
  final bool? bSideEnabled;

  /// §9.6 Maximum splash duration. `eventWebReady` may never arrive on an unsupported engine
  /// or script-loading error page. Remove the splash at the deadline to reveal the page or native retry UI.
  final Duration splashTimeout;

  /// §11.1 Native heartbeat interval. The specification requires a native timer every 20 seconds.
  final Duration heartbeatInterval;

  /// §11.2 Treat the page as unresponsive after 60 seconds without `eventWebAlive`.
  final Duration aliveTimeout;

  /// §11.2.3 Recreate the WebView if loading has not started within 10 seconds after reload.
  final Duration reloadConfirmTimeout;

  /// §11.2.5 Initial recovery backoff: 180 seconds.
  final Duration recoveryBackoffFirst;

  /// §11.2.5 Subsequent recovery backoff: 600 seconds.
  final Duration recoveryBackoffLater;

  /// §10.4 Debounce network callbacks by 1–2 seconds instead of forwarding every system callback.
  final Duration networkDebounce;

  /// §5.4 Suppress foreground notifications while the user is viewing the matching conversation.
  final bool suppressForegroundNotifications;

  /// §5.4 Automatically update the badge from `unreadCount`. Disable to manage it through [SsgShell.setBadgeCount].
  final bool manageBadge;

  /// §8.1 Minimum supported engine version: 92. Earlier versions lack APIs such as `crypto.randomUUID`.
  final int minKernelVersion;

  /// §8.1 Recommended version: 110. Versions between these limits produce diagnostics without prompting the user.
  final int recommendedKernelVersion;

  /// §11.6 Number of console entries retained in the ring buffer for diagnostic exports.
  final int consoleBufferSize;

  /// §9.4 Window and WebView background. The specification requires white safe areas with dark icons
  /// for the status bar and bottom navigation area, including login screens and dark mode.
  final int backgroundColorArgb;

  /// §11.6 Forward Web console output to native logs and Dart.
  final bool forwardConsole;

  /// Not implemented; both platforms ignore this value: the WebView always stays within the safe area per §9.4.
  ///
  /// The field is kept only to avoid changing the Pigeon message format.
  @Deprecated('Not implemented on either platform; this value is ignored.')
  final bool webViewFullscreen;

  /// §8.1 HTTPS check. Local development URLs such as `http://localhost` are allowed.
  bool get isSecureEntry {
    final uri = Uri.tryParse(entryUrl);
    if (uri == null) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '10.0.2.2');
  }

  /// [persistedBSide] is the B side switch already persisted by native code, used only when [bSideEnabled] is omitted.
  ShellConfigDto toDto({bool persistedBSide = false}) => ShellConfigDto(
    entryUrl: entryUrl,
    // Keep the old Pigeon field position to avoid changing the message format; native code no longer uses it.
    channelCode: '',
    shellVersion: shellVersion,
    bSideEnabled: bSideEnabled ?? persistedBSide,
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
    // Keep the Pigeon field position; native code does not read it.
    webViewFullscreen: false,
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
    @Deprecated('Not implemented on either platform; this value is ignored.')
    bool? webViewFullscreen,
  }) => ShellConfig(
    entryUrl: entryUrl ?? this.entryUrl,
    // Only keeps a copy of the old field; neither the URL nor the Pigeon config uses it.
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
    recommendedKernelVersion:
        recommendedKernelVersion ?? this.recommendedKernelVersion,
    consoleBufferSize: consoleBufferSize ?? this.consoleBufferSize,
    backgroundColorArgb: backgroundColorArgb ?? this.backgroundColorArgb,
    forwardConsole: forwardConsole ?? this.forwardConsole,
    // ignore: deprecated_member_use_from_same_package
    webViewFullscreen: webViewFullscreen ?? this.webViewFullscreen,
  );

  @override
  String toString() =>
      'ShellConfig(entryUrl: $entryUrl, '
      'shellVersion: $shellVersion, bSideEnabled: $bSideEnabled)';
}
