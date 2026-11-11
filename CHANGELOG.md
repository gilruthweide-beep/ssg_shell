## Unreleased

- 对齐新版 §2.1：Android / iOS 原样加载完整落地 URL，渠道码可选；不再补参、重拼 query 或读取独立渠道码配置。
- 废弃并忽略 Dart 的 `channelCode` 配置，保留旧入参和 Pigeon 消息格式兼容；渠道码迁入 `entryUrl`。
- 诊断渠道码改为记录 Web 归因事件的实际值；同步示例、原生冷启动配置和渠道归因验收说明。
- 修复 §9.6：WebView 预加载完、`eventWebReady` 已经发过之后再打开容器（或关掉重开、Android 回收后重建），splash 不再干等 30 秒上限；预加载阶段的首屏加载失败会在容器挂上时补出重试页。
- 修复 §11.2.5：reload / 重建之后页面仍然卡死时，退避窗口到期会再处理（180 秒，之后 600 秒），不再永久锁死；退避期间的 `stallDetected` / `recoveryThrottled` 每个窗口只报一次。
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
