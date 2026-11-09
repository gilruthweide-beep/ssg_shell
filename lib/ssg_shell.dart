/// 马甲包原生壳：WebView 容器注入、事件通道、OneSignal 深链、假死防护。
///
/// 接口由 Pigeon 生成（`pigeons/ssg_shell_api.dart`），Android / iOS 行为一致。
/// 条款编号对应 `docs/马甲包对接规范.md`。
library;

export 'src/push.dart' show parsePushData;
export 'src/shell_config.dart' show ShellConfig;
export 'src/ssg_shell.dart' show SsgShell;

// 过线的数据类型。Pigeon 生成的那份文件里还有编解码器之类的内部实现，不往外导。
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
