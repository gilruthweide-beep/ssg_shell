import Foundation

/// §11.6 console 环形缓冲。
///
/// 诊断入口要能「查看并导出最近 N 条 console」，所以日志不能只进 `NSLog` ——
/// 线上设备拿不到控制台。容量满了丢最旧的。
final class ConsoleLogBuffer {

  private let lock = NSLock()
  private var records: [ConsoleRecord] = []

  var capacity: Int = 300 {
    didSet { trim() }
  }

  func add(_ record: ConsoleRecord) {
    lock.lock()
    records.append(record)
    lock.unlock()
    trim()
  }

  func snapshot() -> [ConsoleRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  func clear() {
    lock.lock()
    records.removeAll()
    lock.unlock()
  }

  /// §11.6 导出用的纯文本。
  func dump() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return snapshot().map { record -> String in
      let when = formatter.string(from: Date(timeIntervalSince1970: Double(record.atMs) / 1000))
      let where_ = record.source.map { "\($0):\(record.line ?? 0)" } ?? "-"
      return "\(when) [\(record.level.wire)] \(where_) \(record.message)"
    }.joined(separator: "\n")
  }

  private func trim() {
    lock.lock()
    let limit = max(capacity, 1)
    if records.count > limit {
      records.removeFirst(records.count - limit)
    }
    lock.unlock()
  }
}

extension ConsoleLevel {
  /// JS 的 `console.warn` 对应 `warning`，其余同名。
  static func fromWire(_ raw: String) -> ConsoleLevel {
    switch raw.lowercased() {
    case "debug": return .debug
    case "info", "tip": return .info
    case "warn", "warning": return .warning
    case "error": return .error
    default: return .log
    }
  }

  var wire: String {
    switch self {
    case .debug: return "debug"
    case .log: return "log"
    case .info: return "info"
    case .warning: return "warning"
    case .error: return "error"
    }
  }
}
