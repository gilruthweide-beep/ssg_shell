import Foundation
import WebKit

/// §3.2 Web → Native entry point.
///
/// The Web application calls window.webkit.messageHandlers.<handler>.postMessage(payload) with a JavaScript
/// The payload is an object (NSDictionary natively), not a JSON string. Register all ten §3.1 handlers;
/// missing handlers throw errors caught by the Web application, but events are lost.
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
      // All ten §3.1 events.
      guard let event = WebEventParser.parse(handlerName: message.name, body: message.body) else {
        NSLog("[SsgShell] Unable to parse event:\(message.name)")
        return
      }
      ShellCore.shared.onWebEvent(event)
    }
  }

  /// §7.3.4 The page requests file contents by chunk. A reply-capable handler becomes a page-side Promise.
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.name == ShellInjection.fileChunkHandler else {
      replyHandler(nil, "Unknown handler:\(message.name)")
      return
    }
    guard let body = message.body as? [String: Any],
          let token = body["token"] as? String,
          let index = (body["index"] as? NSNumber)?.intValue
    else {
      replyHandler(nil, "Invalid arguments; expected { token, index }")
      return
    }
    // Read files off the main thread; hundreds of consecutive 1.4 MB video chunks would block the UI.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        replyHandler(nil, "Shell has been destroyed")
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

  // --------------------------------------------------------------- Event handling

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
    // §7.3.4 The page could not assemble some of the files native already read.
    if let dict = body as? [String: Any], let failed = (dict["deliveryFailed"] as? NSNumber)?.intValue, failed > 0 {
      filePicker.reportDeliveryFailure(count: failed)
      return
    }
    guard let dict = body as? [String: Any],
          let requestId = dict["requestId"] as? String
    else {
      NSLog("[SsgShell] File selection request is missing requestId")
      return
    }
    filePicker.present(
      requestId: requestId,
      accept: (dict["accept"] as? String) ?? "",
      multiple: (dict["multiple"] as? Bool) ?? false
    )
  }
}
