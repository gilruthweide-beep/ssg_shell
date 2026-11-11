import Foundation

/// §11.6 Console ring buffer.
///
/// Diagnostics must display and export the latest N entries; NSLog alone is insufficient
/// on production devices without a console. Evict the oldest entry at capacity.
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

  /// §11.6 Plain-text format for exports.
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
  /// JavaScript `console.warn` maps to `warning`; other levels retain their names.
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
