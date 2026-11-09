import Foundation
import WebKit

/// §3.2 Web → Native 的收口。
///
/// Web 调 `window.webkit.messageHandlers.<handler>.postMessage(payload)`，payload 是 JS
/// 对象（原生侧为 `NSDictionary`），不是 JSON 字符串。§3.1 的十个 handler 必须全注册 ——
/// 未注册的会抛异常，Web 已捕获但事件会丢。
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {

  private let filePicker: FilePickerBridge

  init(filePicker: FilePickerBridge) {
    self.filePicker = filePicker
    super.init()
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    switch message.name {
    case ShellInjection.consoleHandler:
      handleConsole(message.body)

    case ShellInjection.filePickHandler:
      handleFilePick(message.body)

    default:
      // §3.1 的十个事件。
      guard let event = WebEventParser.parse(handlerName: message.name, body: message.body) else {
        NSLog("[SsgShell] 解析不出事件：\(message.name)")
        return
      }
      ShellCore.shared.onWebEvent(event)
    }
  }

  /// §7.3.4 页面逐块来拉文件内容。带回复的 handler 在页面侧就是一个 Promise。
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.name == ShellInjection.fileChunkHandler else {
      replyHandler(nil, "未知的 handler：\(message.name)")
      return
    }
    guard let body = message.body as? [String: Any],
          let token = body["token"] as? String,
          let index = (body["index"] as? NSNumber)?.intValue
    else {
      replyHandler(nil, "参数不对，要 { token, index }")
      return
    }
    // 读文件别占主线程：大视频一块 1.4 MB，连着拉几百块会卡住界面。
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        replyHandler(nil, "壳已销毁")
        return
      }
      do {
        let base64 = try self.filePicker.chunk(token: token, index: index)
        replyHandler(base64, nil)
      } catch {
        replyHandler(nil, error.localizedDescription)
      }
    }
  }

  // --------------------------------------------------------------- 分支实现

  private func handleConsole(_ body: Any?) {
    guard let dict = body as? [String: Any] else { return }
    let level = ConsoleLevel.fromWire((dict["level"] as? String) ?? "log")
    let message = (dict["message"] as? String) ?? ""
    let source = (dict["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let line = (dict["line"] as? NSNumber)?.int64Value ?? 0
    ShellCore.shared.onConsoleMessage(
      level: level,
      message: message,
      source: source,
      line: line
    )
  }

  private func handleFilePick(_ body: Any?) {
    guard let dict = body as? [String: Any],
          let requestId = dict["requestId"] as? String
    else {
      NSLog("[SsgShell] 文件选择请求缺 requestId")
      return
    }
    filePicker.present(
      requestId: requestId,
      accept: (dict["accept"] as? String) ?? "",
      multiple: (dict["multiple"] as? Bool) ?? false
    )
  }
}
