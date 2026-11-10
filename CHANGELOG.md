## Unreleased

- 对齐新版 §2.1：Android / iOS 原样加载完整落地 URL，渠道码可选；不再补参、重拼 query 或读取独立渠道码配置。
- 废弃并忽略 Dart 的 `channelCode` 配置，保留旧入参和 Pigeon 消息格式兼容；渠道码迁入 `entryUrl`。
- 诊断渠道码改为记录 Web 归因事件的实际值；同步示例、原生冷启动配置和渠道归因验收说明。

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
