## Unreleased

- §11.6：插件自带隐藏诊断入口。在 IM 界面三指按住 2 秒（Android `DiagnosticsGesture`，iOS 三指 `UILongPressGestureRecognizer`）弹出 `exportDiagnostics()` 的内容，可复制或分享；只观察触摸，不拦截网页的任何手势。
- Android：提前结束的 `ImActivity`（B 面关闭时转去 A 面的那个）如果晚于新开的 `ImActivity` 才被系统销毁，不再把挂在新容器上的共享 WebView 摘走。之前宿主在同一次启动里把 B 面由关转开时，IM 会一直白屏。`detachContext()` 也只在 WebView 的 context 仍指向被销毁的 Activity 时才还原。
- Android：`onCreateWindow` 的临时探测 WebView 处理 `onRenderProcessGone`。所有 WebView 共用一个渲染进程，看门狗结束渲染进程（§11.2.3）时它若还活着，默认返回 false 会带崩整个 App。
- iOS §7.3.4：页面侧拼装某个文件失败时，不再整批静默丢弃。其余文件照常派发 `input` / `change`，失败的个数由原生弹窗告诉用户。
- iOS §11.2.6：重建 WebView 后补一条原生日志。
- 并入宿主 App 验证过的本地补丁：
  - **崩溃修复**：Android `Watchdog` 的带 token 延迟投递改用 `HandlerCompat.postDelayed`。原来的私有扩展函数被 `Handler` 的同名成员方法遮蔽，实际调用的是 API 28 才有的重载，Android 6.0–8.1（minSdk 23）一打开 IM 就抛 `NoSuchMethodError`。
  - §5.2：启动期补发的身份改为保留最近一次 login **或 logout**（`stickyIdentity`）。Dart 上线前发生的登出也会补调 `OneSignal.logout()`，换号后不再收到上一个账号的推送。Android 上 uid 为空的 login 不算登录，也不解锁通知权限申请。
  - §5.4：Android 前台抑制要求 IM 容器在运行且 B 面开启，停在 A 面时不会因为 WebView 还停在某个会话而吞掉通知。推送路由日志区分 `openChat` 已暂存和已送达。
  - §6.2：Dart 登录后把所有未授权的通知状态交给原生一次（每个进程一次），异步调度后重新确认登录态，只有登录用户的原生请求仍未决时才在回前台重试。Android 只在 API 33+ 还能弹系统框时弹，否则（以及用户拒绝后）在 `ImActivity` 上弹「Notifications are off」引导去设置，A 面不弹。
  - 麦克风引导：iOS 弹窗标题为「Microphone is off」，不会叠在其他弹窗或不可见的控制器上；Android 每次非空的拒绝结果都给去设置入口（Chromium 可能缓存拒绝、不再回调原生），去掉 800 ms 自动拒绝定时器。
  - iOS：新增 `CjkFontFallback`，在 document-start 为 CJK 区段补本地苹方字体，页面的拉丁字体和图标字体不变；深色 LaunchScreen 盖住 WebView 期间状态栏用浅色内容，撤 splash 后恢复深色。
  - Android 构建工具对齐 AGP 8.10.1 / Kotlin 2.2.20，兼容 OneSignal 传递依赖带来的 Kotlin 2.2 标准库。
  - 运行时提示、诊断文本、源码注释、测试名和包描述统一改为英文；Pigeon 生成代码里的文档同步翻译，wire schema 和方法名不变。
- 对齐新版 §2.1：Android / iOS 原样加载完整落地 URL，渠道码可选；不再补参、重拼 query 或读取独立渠道码配置。
- 废弃并忽略 Dart 的 `channelCode` 配置，保留旧入参和 Pigeon 消息格式兼容；渠道码迁入 `entryUrl`。
- 诊断渠道码改为记录 Web 归因事件的实际值；同步示例、原生冷启动配置和渠道归因验收说明。
- 修复 §9.6：WebView 预加载完、`eventWebReady` 已经发过之后再打开容器（或关掉重开、Android 回收后重建），splash 不再干等 30 秒上限；预加载阶段的首屏加载失败会在容器挂上时补出重试页。
- 修复 §11.2.5：reload / 重建之后页面仍然卡死时，退避窗口到期会再处理（180 秒，之后 600 秒），不再永久锁死；退避期间的 `stallDetected` / `recoveryThrottled` 每个窗口只报一次。重建后的页面刚加载时发的那条 `eventWebAlive` 不再把退避清零，页面撑过整个窗口才算恢复。
- Android：`ImActivity` 当冷启动第一个 Activity 且没有引擎时，自动起一个无界面引擎跑 Dart（`SsgShellPlugin.ENGINE_ID`）；多个引擎同时挂着插件时都能收到事件。插件 Manifest 不再写死 `ImActivity` 的 `android:exported`，README 的 LAUNCHER 片段可以直接合并。
- Dart 上线前错过的 `webReady` / `login` / `unreadCount` / `chatOpen` 在第一次 `initialize()` 时补发。
- **行为变更**：`ShellConfig.bSideEnabled` 改为可空，不传时沿用已落盘的开关（从没设过为关），不再默认 true 并覆盖 `setBSideEnabled()` 的结果。
- **行为变更**：Android 插件不再声明 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`；宿主没声明时 `requestBatteryOptimizationExemption()` 打开系统的电池优化列表页。
- iOS：修复多选照片 / 视频时清单并发写入的数据竞争；容器销毁时不再误取下已经挂到新容器上的 WebView；iPad 固定移动版 UA；隐私清单补上 `UserDefaults` 声明。
- Android：去掉 WebView 的离屏 layer（§8.4 体验与性能 6）；`onNetwork` 只在网络恢复和切换时调，同一条网络上的重复回调不再转发，iOS 同步；Android 6.0 上也能收到网络回调；系统打不开的非 http(s) 链接不再落进 WebView。
- §6.2 / §12.3：麦克风已被永久拒绝后再点语音，两端弹原生「去设置」引导。
- iOS：修复 §1.3 注入自检永远报未生效（JS 的 `false` 被读成 `"0"`）；`evaluateJavaScript` 的布尔结果现在和 Android 一样是 `"true"` / `"false"`。
- `ShellConfig.webViewFullscreen` 从未实现，标记废弃并忽略。

## 1.0.2

对齐《马甲包对接规范》v1.0.2（Web `web1` 分支）。

- §1 容器注入：Android `addDocumentStartJavaScript`、iOS `.atDocumentStart` 的 `WKUserScript`；§1.3 自检在 `eventWebReady` 后自动跑一次。
- §2 入口地址拼 `channelCode`（大小写不敏感、不重复追加）、UA 追加而非替换。
- §3 / §4 十个 Web → Native 事件与六个 Native → Web 回调，两端同一套解析。
- §5 前台抑制、角标、深链排队（Web 未就绪时暂存，`eventWebReady` 后补发，只调一次）。
- §6 权限声明齐全；通知权限在收到 `eventLogin` 之后才申请，麦克风在 `getUserMedia` 触发时才申请。
- §7 WebView 回调全覆盖；文件选择器直接进系统相册，iOS 由壳接管 `<input type="file">`，HEIC 转 JPEG、大视频分块交回页面。
- §8 运行环境按表设置；任何常规路径上都不清存储；Android 由原生 Activity 承载，不走 PlatformView。
- §9 返回键先回退 Web 历史、`adjustResize`、WebView 只放在安全区内、启动只有系统启动图加一屏原生 splash。
- §10 回前台双通道、不冻结定时器、单实例、实例长活。
- §11 原生心跳（20s）、存活监测与兜底 reload（60s → reload → 10s 没动静就重建，Android 先结束渲染进程）、退避 180s/600s、推送捅醒、内存告警、console 缓冲与诊断导出。

## 0.0.1

初始脚手架。
