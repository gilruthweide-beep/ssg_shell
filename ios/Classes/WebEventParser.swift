import Foundation

/// §3.1 / §3.2 Payload parsing.
///
/// The Web application calls window.webkit.messageHandlers.<handler>.postMessage(payload) with a JavaScript
/// object (NSDictionary natively), not a JSON string. Accept these additional observed shapes as well:
///  - `{"eventName":"login","params":{...}}` (the specification example).
///  - Parameter contents only, with the event inferred from the handler.
///  - An occasional JSON string.
///
/// Parameters should be strings, but count may be numeric. Normalize numeric values to decimal text.
enum WebEventParser {

  /// Map handler names to event names, for example eventWebReady → webReady.
  static func handlerToEventName(_ handler: String) -> String {
    guard handler.hasPrefix("event"), handler.count > "event".count else { return handler }
    let rest = handler.dropFirst("event".count)
    return rest.prefix(1).lowercased() + rest.dropFirst()
  }

  static func name(of raw: String) -> WebEventName {
    switch raw {
    case "webReady": return .webReady
    case "register": return .register
    case "login": return .login
    case "logout": return .logout
    case "messageSent": return .messageSent
    case "webAlive": return .webAlive
    case "chatOpen": return .chatOpen
    case "chatClose": return .chatClose
    case "chatRead": return .chatRead
    case "unreadCount": return .unreadCount
    default: return .unknown
    }
  }

  static func parse(handlerName: String?, body: Any?) -> WebEvent? {
    let dict = dictionary(from: body)
    let fromPayload = (dict?["eventName"] as? String) ?? ""
    let raw: String
    if !fromPayload.isEmpty {
      raw = fromPayload
    } else if let handlerName {
      raw = handlerToEventName(handlerName)
    } else {
      return nil
    }

    // Parameters may be nested under "params" or supplied directly at the top level.
    let params = dictionary(from: dict?["params"]) ?? dict
    var flat: [String: String] = [:]
    params?.forEach { key, value in
      guard key != "eventName", key != "params" else { return }
      guard let text = stringify(value) else { return }
      flat[key] = text
    }

    func nonEmpty(_ key: String) -> String? {
      guard let value = flat[key], !value.isEmpty else { return nil }
      return value
    }

    return WebEvent(
      name: name(of: raw),
      rawName: raw,
      receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
      params: flat,
      uid: nonEmpty("uid"),
      channelCode: nonEmpty("channelCode"),
      chatId: nonEmpty("chatId"),
      unreadCount: nonEmpty("count").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) },
      webTimestamp: nonEmpty("timestamp")
    )
  }

  private static func dictionary(from value: Any?) -> [String: Any]? {
    if let dict = value as? [String: Any] { return dict }
    if let text = value as? String,
       let data = text.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return parsed
    }
    return nil
  }

  private static func stringify(_ value: Any) -> String? {
    switch value {
    case is NSNull: return nil
    case let text as String: return text
    case let number as NSNumber:
      // JavaScript integers arrive as NSNumber(double); description alone would produce "8842.0".
      if number === kCFBooleanTrue || number === kCFBooleanFalse {
        return number.boolValue ? "true" : "false"
      }
      let double = number.doubleValue
      if double == double.rounded(), abs(double) < 9.007_199_254_740_992e15 {
        return String(Int64(double))
      }
      return number.stringValue
    default:
      if let data = try? JSONSerialization.data(withJSONObject: value),
         let text = String(data: data, encoding: .utf8) {
        return text
      }
      return String(describing: value)
    }
  }
}
