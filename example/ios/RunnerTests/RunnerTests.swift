import PhotosUI
import XCTest

@testable import ssg_shell

/// 壳的纯逻辑部分。和 Android 侧 `android/src/test` 里那几个测试一一对应 ——
/// 两端行为必须一致（规范要求「接口和行为以本规范为准」）。
///
/// 需要真机 / 引擎的部分（容器、PHPicker、心跳）走 §12 的人工验收。
class RunnerTests: XCTestCase {

  // -------------------------------------------------------- §1.1 / §1.2 注入

  func test注入脚本带齐六个字段() {
    let info = ShellInfo(
      platform: .ios,
      bundleId: "com.example.app",
      shellVersion: "1.2.3",
      webviewVersion: "605.1.15",
      deviceModel: "iPhone15,2",
      osVersion: "17.0"
    )
    let script = ShellInjection.injectionScript(info)

    XCTAssertTrue(script.hasPrefix("window.__SSG_SHELL__={"))
    for field in ["platform:'ios'", "bundleId:'com.example.app'", "shellVersion:'1.2.3'",
                  "webviewVersion:'605.1.15'", "deviceModel:'iPhone15,2'", "osVersion:'17.0'"] {
      XCTAssertTrue(script.contains(field), field)
    }
  }

  func test注入脚本转义单引号与尖括号() {
    let info = ShellInfo(
      platform: .ios,
      bundleId: "com.it's.app",
      shellVersion: "</script>",
      webviewVersion: "",
      deviceModel: "",
      osVersion: ""
    )
    let script = ShellInjection.injectionScript(info)

    XCTAssertTrue(script.contains("com.it\\'s.app"))
    XCTAssertFalse(script.contains("</script>"))
  }

  /// §2.2 必须追加，不能整段替换 —— Web 与服务端都有按 UA 判平台的逻辑。
  func testUA后缀的格式() {
    XCTAssertEqual(
      ShellInjection.applicationNameForUserAgent(shellVersion: "1.0.2"),
      "SSGShell/1.0.2 iOS"
    )
  }

  /// §3.2 十个 handler 一个都不能少，未注册的会让事件丢掉。
  func test十个事件handler都在() {
    XCTAssertEqual(ShellInjection.eventHandlers.count, 10)
    for name in ["eventWebReady", "eventRegister", "eventLogin", "eventLogout",
                 "eventMessageSent", "eventWebAlive", "eventChatOpen", "eventChatClose",
                 "eventChatRead", "eventUnreadCount"] {
      XCTAssertTrue(ShellInjection.eventHandlers.contains(name), name)
    }
  }

  /// §7.3.6 拦截必须覆盖所有文件输入框：点击、click()、showPicker() 三条路径。
  func test文件输入拦截脚本覆盖三条触发路径() {
    let script = ShellInjection.fileInputScript

    XCTAssertTrue(script.contains("addEventListener('click'"))
    XCTAssertTrue(script.contains("HTMLElement.prototype.click"))
    XCTAssertTrue(script.contains("showPicker"))
    // §7.3.4 以 input / change 两个冒泡事件为准交回页面。
    XCTAssertTrue(script.contains("new Event('input', { bubbles: true })"))
    XCTAssertTrue(script.contains("new Event('change', { bubbles: true })"))
  }

  // ------------------------------------------------------------- §2.1 URL

  private func config(entry: String, channel: String) -> ShellConfig {
    var config = ShellConfig()
    config.entryUrl = entry
    config.channelCode = channel
    return config
  }

  func test不带渠道码时不从旧配置补参() {
    for url in ["https://im.example.com/", "https://im.example.com/?a=1#home"] {
      XCTAssertEqual(config(entry: url, channel: "ChannelCode_google").resolvedUrl()?.absoluteString, url)
    }
  }

  func test渠道参数大小写和空值原样保留() {
    for name in ["channelcode", "channelCode", "ChannelCode", "CHANNELCODE"] {
      for value in ["fromWeb", ""] {
        let url = "https://im.example.com/?\(name)=\(value)"
        XCTAssertEqual(config(entry: url, channel: "ChannelCode_google").resolvedUrl()?.absoluteString, url)
      }
    }
  }

  func test编码重复参数和fragment原样保留() {
    let url = "https://im.example.com/?channelcode=ch%2f001&tag=a+%20b"
      + "&tag=%2526&channelcode=second#/chat?channelcode=fragment"
    for channel in ["", "ChannelCode_google"] {
      XCTAssertEqual(config(entry: url, channel: channel).resolvedUrl()?.absoluteString, url)
    }
  }

  func testfragment里的渠道码不会被补到query() {
    let url = "https://im.example.com/?redirect=%2fchat#/home?channelcode=fragment"
    XCTAssertEqual(config(entry: url, channel: "ChannelCode_google").resolvedUrl()?.absoluteString, url)
  }

  func test入口为空时不构造URL() {
    XCTAssertNil(config(entry: "", channel: "ch001").resolvedUrl())
  }

  func test入口host用于外链放行() {
    XCTAssertEqual(config(entry: "https://im.example.com/a/b", channel: "").entryHost, "im.example.com")
  }

  // ----------------------------------------------------------- §3.1 事件解析

  func test规范示例的payload形状() {
    let event = WebEventParser.parse(
      handlerName: "eventLogin",
      body: [
        "eventName": "login",
        "params": ["channelCode": "ch001", "uid": "1571277787", "timestamp": "1762000000000"],
      ]
    )

    XCTAssertEqual(event?.name, .login)
    XCTAssertEqual(event?.rawName, "login")
    XCTAssertEqual(event?.uid, "1571277787")
    XCTAssertEqual(event?.channelCode, "ch001")
    XCTAssertEqual(event?.webTimestamp, "1762000000000")
  }

  func test事件名从handler名推断() {
    let event = WebEventParser.parse(
      handlerName: "eventWebReady",
      body: ["timestamp": "1762000000000"]
    )

    XCTAssertEqual(event?.name, .webReady)
    XCTAssertEqual(event?.rawName, "webReady")
  }

  func testcount是数字时也能解析() {
    let numeric = WebEventParser.parse(handlerName: "eventUnreadCount", body: ["count": 7])
    let text = WebEventParser.parse(handlerName: "eventUnreadCount", body: ["count": "7"])

    XCTAssertEqual(numeric?.unreadCount, 7)
    XCTAssertEqual(text?.unreadCount, 7)
    // JS 的整数过线是 double，别变成 "7.0"。
    XCTAssertEqual(numeric?.params["count"], "7")
  }

  func test将来新增的事件不丢原始名() {
    let event = WebEventParser.parse(
      handlerName: nil,
      body: ["eventName": "somethingNew", "params": ["a": "1"]]
    )

    XCTAssertEqual(event?.name, .unknown)
    XCTAssertEqual(event?.rawName, "somethingNew")
    XCTAssertEqual(event?.params["a"], "1")
  }

  func test没有handler名也没有eventName时放弃() {
    XCTAssertNil(WebEventParser.parse(handlerName: nil, body: ["uid": "1"]))
  }

  func testpayload是JSON字符串时也吃得下() {
    let event = WebEventParser.parse(
      handlerName: "eventChatOpen",
      body: "{\"chatId\":\"-100123\"}"
    )

    XCTAssertEqual(event?.name, .chatOpen)
    XCTAssertEqual(event?.chatId, "-100123")
  }

  // ------------------------------------------------------- §5.4 前台抑制

  func test前台且停在该会话时抑制() {
    let gate = NotificationGate()
    gate.onChatOpen("1571275627")

    XCTAssertTrue(gate.shouldSuppress(chatId: "1571275627", appInForeground: true, enabled: true))
  }

  func test后台一律不抑制() {
    let gate = NotificationGate()
    gate.onChatOpen("1571275627")

    XCTAssertFalse(gate.shouldSuppress(chatId: "1571275627", appInForeground: false, enabled: true))
  }

  func test停在其他会话时照常展示() {
    let gate = NotificationGate()
    gate.onChatOpen("1571275627")

    XCTAssertFalse(gate.shouldSuppress(chatId: "-100123", appInForeground: true, enabled: true))
  }

  func test切会话时旧会话的chatClose不误清新会话() {
    let gate = NotificationGate()
    gate.onChatOpen("A")
    gate.onChatOpen("B")
    gate.onChatClose("A")

    XCTAssertEqual(gate.trackedChatId, "B")
  }

  func test页面重新加载要清掉tracked() {
    let gate = NotificationGate()
    gate.onChatOpen("1571275627")
    gate.onPageLoadStarted()

    XCTAssertNil(gate.trackedChatId)
    XCTAssertFalse(gate.shouldSuppress(chatId: "1571275627", appInForeground: true, enabled: true))
  }

  func test角标不接受负数() {
    let gate = NotificationGate()
    gate.setBadge(12)
    XCTAssertEqual(gate.badgeCount, 12)

    gate.setBadge(-3)
    XCTAssertEqual(gate.badgeCount, 0)
  }

  // --------------------------------------------------------- §7.3 相册过滤

  func testaccept决定相册里显示什么() {
    // 附件：图片和视频在同一个相册里选。
    XCTAssertEqual(
      FilePickerBridge.filter(for: "image/png,image/jpeg,image/gif,video/mp4,video/quicktime"),
      PHPickerFilter.any(of: [.images, .videos])
    )
    // 改头像：只有图片。
    XCTAssertEqual(
      FilePickerBridge.filter(for: "image/png,image/jpeg"),
      PHPickerFilter.images
    )
    // 群或私聊限制发送类型时 accept 会收窄，照此收窄。
    XCTAssertEqual(FilePickerBridge.filter(for: "video/mp4"), PHPickerFilter.videos)
    // accept 空着按附件默认处理。
    XCTAssertEqual(
      FilePickerBridge.filter(for: ""),
      PHPickerFilter.any(of: [.images, .videos])
    )
  }

  // -------------------------------------------------------- §11.6 console

  func testconsole级别映射() {
    XCTAssertEqual(ConsoleLevel.fromWire("warn"), .warning)
    XCTAssertEqual(ConsoleLevel.fromWire("error"), .error)
    XCTAssertEqual(ConsoleLevel.fromWire("debug"), .debug)
    XCTAssertEqual(ConsoleLevel.fromWire("info"), .info)
    XCTAssertEqual(ConsoleLevel.fromWire("什么都不是"), .log)
  }

  func testconsole环形缓冲满了丢最旧的() {
    let buffer = ConsoleLogBuffer()
    buffer.capacity = 3
    for index in 0..<5 {
      buffer.add(ConsoleRecord(level: .log, message: "m\(index)", atMs: 0, source: nil, line: nil))
    }

    let messages = buffer.snapshot().map(\.message)
    XCTAssertEqual(messages, ["m2", "m3", "m4"])
  }
}
