# ssg_shell_example

壳的 A 面调试台。一屏放下规范里各条通道，联调时逐条点过去确认。

```bash
flutter run
```

屏上四块：

- **`__SSG_SHELL__`（§1.1）** —— `initialize` 回来的六个字段，加内核判定。缺 `bundleId` 的设备收不到推送，这里一眼能看出来。
- **容器** —— B 面开关（§9.6，会落盘）、开 / 关 IM、预加载、注入自检（§1.3）。
- **推送与深链（§5）** —— 模拟推送到达（看前台抑制和 §11.3 的捅醒结果）和点击通知（走 §5.3 的排队）。
- **假死防护（§11）** —— 手动 reload、重建 WebView、`onNetwork`、诊断导出（§11.6）。

下面的事件流同时显示 §3.1 的十个 Web 事件和原生侧的 `ShellEventType`，和原生日志里应该一一对应（§12.2）。

## 入口地址

现在指向 `https://www.google.com/` —— 一个真的能加载出来的页面，拿来验壳本身够用：

- 容器起得来、§2.2 的 UA 后缀在不在、§2.1 的 `channelCode` 拼没拼上
- §9.4 安全区（WebView 在状态栏以下、Home 条以上）、§9.2 键盘弹收、§9.3 字体不跟系统放大
- §9.1 返回键先回退页面历史、§7.1 外链走系统浏览器（点搜索结果就是跨域，会跳出去）
- §11.2 手动 reload / 重建 WebView、§11.6 诊断导出

**但它不是 IM Web**，所以这几项在 google.com 上永远不会有：§3.1 的十个事件、§1.3 的注入自检
（`is-web-browser` 这个 class 是 Web 侧判定的结果）、§11.2 的 `eventWebAlive`、§5 的深链。
要验这些就得换成真实入口地址，三处一起换：

- `lib/main.dart` 顶上的 `kEntryUrl`（§8.1 必须 HTTPS）
- Android：`android/app/src/main/AndroidManifest.xml` 里的 `com.ssg.shell.ENTRY_URL`
- iOS：`ios/Runner/Info.plist` 里的 `SSGShellEntryUrl`

后两处不能省 —— §9.6 要求 B 面开启时冷启动直接加载 Web，那条路径上读的是原生配置，不等 Dart。

示例的另一半只在真机上才有意义：模拟器没有推送、没有麦克风、相册里也没东西。

## 不在示例范围内的

OneSignal SDK 的集成（§5.1 里「原生」那一列）。示例只演示把推送 `data` 交给插件之后发生什么 —— 绑定 `external_id`、收通知、处理点击要宿主自己接 SDK。
