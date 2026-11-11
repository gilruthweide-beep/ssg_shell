/// Native application shell: WebView injection, event bridge, OneSignal deep links, and unresponsive-page recovery.
///
/// Pigeon generates the interface (`pigeons/ssg_shell_api.dart`), with matching behavior on Android and iOS.
/// Section numbers refer to the native shell integration specification.
library;

export 'src/push.dart' show parsePushData;
export 'src/shell_config.dart' show ShellConfig;
export 'src/ssg_shell.dart' show SsgShell;

// Public wire data types. Generated codecs and other Pigeon internals are not exported.
export 'src/messages.g.dart'
    show
        ConsoleLevel,
        ConsoleRecord,
        KernelInfo,
        KernelVerdict,
        NetworkType,
        NotificationPermission,
        OpenChatRequest,
        PushDecision,
        PushMessage,
        ShellDiagnostics,
        ShellEvent,
        ShellEventType,
        ShellInfo,
        ShellPlatform,
        WebEvent,
        WebEventName;
