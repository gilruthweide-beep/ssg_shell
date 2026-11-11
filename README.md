# ssg_shell

马甲包原生壳：WebView 容器注入、事件通道、OneSignal 深链、假死防护。

接口由 Pigeon 生成，Android / iOS 行为一致。条款编号对应 [`docs/马甲包对接规范.md`](docs/马甲包对接规范.md)（Web 侧 `web1` 分支，版本 1.0.2）。

## 分工

App = 原生壳 + WebView 加载 IM Web。业务逻辑、UI、长连接、消息收发全在 Web 内。这个插件负责规范里原生那一半：

| 条款 | 做的事 | 实现 |
|---|---|---|
| §1 | `window.__SSG_SHELL__` 文档开始前注入 | `ShellInjection` |
| §2 | 落地 URL 原样加载（渠道码可选）、UA 追加 `SSGShell/<ver>` | `ShellConfig` / `ShellInjection` |
| §3 | 十个 Web → Native 事件 | `JsBridge`（Android）/ `ScriptMessageRouter`（iOS）+ `WebEventParser` |
| §4 | `onForeground` / `onBackground` / `onNetwork` / `onHeartbeat` / `onMemoryWarning` / `openChat` | `ShellCore` + `ImWebViewHolder` |
| §5 | 前台抑制、角标、深链排队 | `NotificationGate` / `BadgeApplier` / `ShellCore.openChat` |
| §6 | 权限声明与申请时机 | `AndroidManifest.xml` / `PermissionCoordinator` |
| §7 | WebView 回调、文件选择器 | `ShellWebChromeClient` / `ShellWebViewClient` / `PhotoPickerDelegate`；`ShellUIDelegate` / `ShellNavigationDelegate` / `FilePickerBridge` |
| §8 | 运行环境、不清存储、原生 View 承载 | `ImWebViewHolder` / `ImActivity` / `ImViewController` |
| §9 | 返回键、键盘、安全区、启动无多余加载 | `ImActivity` / `ImViewController` |
| §10 | 回前台信号、不冻结定时器、单实例、长活 | `ShellCore` / `ImWebViewHolder` |
| §11 | 原生心跳、存活监测与兜底 reload、推送捅醒、内存告警、诊断导出 | `Watchdog` / `ShellCore` / `ConsoleLogBuffer` |

**宿主要自己做的**：

- OneSignal SDK 集成与绑定（§5.1 分工里「原生」那一列的 SDK 部分），以及把它的两个回调接到 `handlePushReceived` / `handlePushOpened` 上。插件只告诉你「这条要不要展示」，真正拦下通知要在 OneSignal 的前台回调里 `preventDefault()`。
- §13 的应用名称和包名规则（两端包名必须不同，名称只能用那 18 个字母和汉字）。
- §11.6 的隐藏入口 UI（连点若干次之类）。插件提供 `getDiagnostics()` 和 `exportDiagnostics()`，入口放在哪是宿主的设置页的事。
- iOS 上 §6.2 通知权限被拒绝后的二次引导；插件提供 `openSystemSettings()`。Android 这一半插件自己做了：登录后通知仍未开启（拒绝了系统弹窗、已永久拒绝、API 33 以下或应用通知总开关被关）时，每个进程最多一次在 `ImActivity` 上弹「Notifications are off」引导去设置，A 面不弹。麦克风两端插件都自己做了：拒绝后再点语音会弹「去设置」的原生提示。提示默认是英文，Android 文案在 `ssg_shell_mic_denied*`、`ssg_shell_notification_off_*`、`ssg_shell_open_settings`、`ssg_shell_cancel` 字符串资源里，宿主可以覆盖或加本地化。

## 接入

### 1. Dart

```dart
import 'package:ssg_shell/ssg_shell.dart';

await SsgShell.instance.initialize(const ShellConfig(
  entryUrl: 'https://im.example.com/?channelcode=ch001', // §8.1 必须 HTTPS
));

// §3.1 的十个事件
SsgShell.instance.on(WebEventName.login).listen((event) {
  OneSignal.login(event.uid!);           // §5.2 external_id 就是 uid
});
SsgShell.instance.on(WebEventName.logout).listen((_) => OneSignal.logout());

await SsgShell.instance.openIm();
```

推送两条回调直接把 OneSignal 的 `additionalData` 原样传进来，字段名 `chat_id` / `chatId` 都兼容：

```dart
// 到达：返回值说明这条要不要展示（§5.4 前台抑制），以及有没有顺手捅醒 Web（§11.3）
final decision = await SsgShell.instance.handlePushReceived(data);
if (decision.suppressNotification) event.preventDefault();

// 点击：按需打开容器并排队，等 eventWebReady（§5.3）
await SsgShell.instance.handlePushOpened(data);
```

`ShellConfig` 的默认值就是规范值（心跳 20s、判定卡死 60s、退避 180s/600s、splash 上限 30s…），一般不用改。

**B 面开关**：`ShellConfig.bSideEnabled` 不传时沿用已经落盘的值，从没设过就是关。开关用 `setBSideEnabled()` 设，每次启动照常调 `initialize()` 不会把它冲掉；想在 `initialize` 里一并指定就显式传 true / false。B 面关着时 `preload()` 是空操作，Android 的 `ImActivity` 会转去 A 面。

**监听要早挂**：原生预加载时，Web 可能在 Dart 上线之前就发过 `login` / `webReady` / `unreadCount` / `chatOpen`。这几条会在第一次 `initialize()` 时补发，并在它返回之后才进事件流。所以监听要么在 `initialize()` 之前挂好，要么像上面那样紧跟在 `await` 后面挂，中间不要再隔别的 `await`。

§2.1 的渠道码是可选的。需要归因时，把真实渠道码放进完整落地 URL；不需要时可以直接用
`https://im.example.com/`。壳原样加载 URL，保留参数大小写、编码、重复参数和 fragment，
不补参、不删参、不用编译期常量覆盖；渠道码的读取和存储由 Web 负责。

旧的 `ShellConfig.channelCode` / `copyWith(channelCode: ...)` 已废弃且忽略，
Android 的 `com.ssg.shell.CHANNEL_CODE` 和 iOS 的 `SSGShellChannelCode` 也不再读取。
升级时请把渠道码迁入下面三处的完整入口 URL，并保持 Dart 与原生冷启动配置一致。
诊断里的 `channelCode` 来自最近一次 Web 注册、登录或发消息事件；为空也属于有效情况。

### 2. Android

`minSdk` 要 23。壳的 Activity、权限、R8 keep 规则都在插件的 Manifest 里，宿主只给配置：

```xml
<meta-data android:name="com.ssg.shell.ENTRY_URL"       android:value="https://im.example.com/?channelcode=ch001" />
<meta-data android:name="com.ssg.shell.A_SIDE_ACTIVITY" android:value="com.example.app.MainActivity" />
<meta-data android:name="com.ssg.shell.AUTO_PRELOAD"    android:value="true" />
```

**为什么要 meta-data**：§9.6 要求 B 面开启时冷启动直接加载 Web，那一刻 Flutter 引擎还没起来，拿不到 Dart 的配置。插件把配置落盘，下次冷启动按缓存走（`AUTO_PRELOAD` 打开时在 `Application.onCreate` 那一刻就建 WebView 并开始加载）。

想让 `ImActivity` 当冷启动第一个 Activity（§8.4 体验与性能 2），在宿主 Manifest 里 merge 一个 intent-filter（`<manifest>` 上要有 `xmlns:tools`），同时把原来 FlutterActivity 上的 LAUNCHER 去掉，不然桌面上会有两个图标：

```xml
<activity android:name="com.ssg.ssg_shell.ImActivity" android:exported="true" tools:node="merge">
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>
</activity>
```

B 面未开启时 `ImActivity` 会转去 `A_SIDE_ACTIVITY` 并结束自己，用户看不到中间态。

**这条路径上 Dart 怎么跑起来**：`ImActivity` 不是 FlutterActivity，冷启动直接进它时没有引擎，上面接在 Dart 里的 OneSignal 绑定、通知权限、推送点击都不会执行。所以 B 面开启、又没有任何引擎挂着插件时，`ImActivity` 会自己起一个不带界面的引擎去跑宿主的 `main()`，并以 `SsgShellPlugin.ENGINE_ID`（`"ssg_shell"`）放进 `FlutterEngineCache`。两点要注意：

- `main()` 会在没有界面的情况下执行，里面不要假设一定有 Activity。
- 之后要打开 A 面的 FlutterActivity 时，覆盖 `getCachedEngineId()` 复用这个引擎，否则会再建一个、`main()` 再跑一遍（事件两边都能收到，只是白占内存）：

```kotlin
class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String? =
        SsgShellPlugin.ENGINE_ID.takeIf { FlutterEngineCache.getInstance().contains(it) }
}
```

**电池优化白名单（§10.3）**：插件不再替宿主声明 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`（§6.3 的清单里没有它，应用市场对它有专门限制）。宿主自己声明了，`requestBatteryOptimizationExemption()` 就直接弹系统确认框；没声明时打开系统的电池优化列表页，让用户自己找到应用。

### 3. iOS

`platform :ios, '14.0'`（§7.3 的 `PHPickerViewController` 和分块交付用的 `WKScriptMessageHandlerWithReply` 都从 iOS 14 起）。

`Info.plist`：

```xml
<!-- §6.4 缺 NSMicrophoneUsageDescription 时调 getUserMedia 会直接崩溃 -->
<key>NSMicrophoneUsageDescription</key><string>用于录制并发送语音消息</string>
<key>NSPhotoLibraryUsageDescription</key><string>用于选择并发送照片和视频</string>

<key>SSGShellEntryUrl</key><string>https://im.example.com/?channelcode=ch001</string>
<key>SSGShellAutoPreload</key><true/>
<!-- §9.6 的 iOS 对应项：启动时就把容器顶上来，不先露出 Flutter 页面 -->
<key>SSGShellAutoOpenIm</key><true/>
```

Capabilities：Push Notifications、Background Modes → Remote notifications。

## 规范里明确「做不到」或不适用的

这几条不是漏掉，是规范本身或平台限制：

- **§11.7 内核引导只在 Android 生效。** iOS 的 WebKit 随系统升级，不能单独更新，`getKernelInfo()` 在 iOS 上只报版本号，不判不合格。
- **§5.4 角标在小米 / OPPO / vivo 改不了。** 这几家只认挂在通知上的角标数，必须由服务端在推送里下发。插件做了三星 / 华为等能改的那部分，iOS 侧是精确的。
- **§12.1 iOS 不检查 Service Worker。** 第三方 App 的 WKWebView 只有配了 `WKAppBoundDomains` 才启用，而那个配置会限制可访问域名，本项目不启用。
- **§10.7** iOS 后台保持长连接、Android 被厂商强杀后自启，都靠推送补齐。
- **§9.4「不开 edge-to-edge」在 targetSdk 35 上做不到。** Android 15 对 targetSdk 35 强制开启 edge-to-edge，`android:statusBarColor` 之类的属性被忽略。插件按 §9.2 和 §9.4 的要求走另一条路：在承载 WebView 的容器上把 `systemBars`、`ime`、`displayCutout` 的 insets 转成 padding 并返回 `CONSUMED`，页面里读 `env(safe-area-inset-*)` 仍然是 0，键盘高度变化仍然反映到 WebView 的布局高度。
- **§10.4 的「能发出请求」在 iOS 上是近似的。** Android 用 `NET_CAPABILITY_VALIDATED`，iOS 没有对应信号，用 `NWPathMonitor` 的 `.satisfied` 加 1.5 秒去抖顶上。

## 开发

```bash
# 改接口：pigeons/ssg_shell_api.dart 是双端唯一来源
dart run pigeon --input pigeons/ssg_shell_api.dart

flutter analyze && flutter test
cd example && flutter build apk --debug && flutter build ios --simulator --debug
```

验收按 §12 走。`example/` 是 A 面调试台：下发配置、开 IM、看十个事件、导诊断（§11.6）。
# ssg_shell
