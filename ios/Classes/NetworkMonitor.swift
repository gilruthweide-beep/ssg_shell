import Foundation
import Network

/// §10.4 Notify network recovery separately.
///
/// Network connectivity may lag foreground entry by several seconds during Wi-Fi reconnection or cellular attachment,
/// causing an early Web reconnect to fail. The specification requires the connection to be usable for requests.
///
/// iOS has no direct equivalent of Android's `NET_CAPABILITY_VALIDATED` signal,
/// so approximate availability by debouncing `NWPathMonitor.satisfied` for the §10.4.3 interval of 1–2 seconds.
/// Wait 1.5 seconds after route availability to avoid reporting a connection before it has an IP address.
final class NetworkMonitor {

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "ssg_shell.network")
  private let debounce: () -> TimeInterval
  private let onAvailable: (NetworkType) -> Void

  private var pending: DispatchWorkItem?
  /// The type the Web has already been notified about. Cleared when offline; notified again on the next restore.
  private var lastNotifiedType: NetworkType?
  private var started = false

  private(set) var currentType: NetworkType = .none

  init(debounce: @escaping () -> TimeInterval, onAvailable: @escaping (NetworkType) -> Void) {
    self.debounce = debounce
    self.onAvailable = onAvailable
  }

  func start() {
    guard !started else { return }
    started = true
    monitor.pathUpdateHandler = { [weak self] path in
      self?.handle(path)
    }
    monitor.start(queue: queue)
  }

  func stop() {
    guard started else { return }
    started = false
    pending?.cancel()
    pending = nil
    monitor.cancel()
  }

  private func handle(_ path: NWPath) {
    let type = Self.type(of: path)
    guard path.status == .satisfied else {
      // §10.4.4 Do not report disconnection; the Web application ignores `onNetwork('none')`.
      currentType = .none
      DispatchQueue.main.async { [weak self] in
        self?.lastNotifiedType = nil
        self?.pending?.cancel()
        self?.pending = nil
      }
      return
    }
    currentType = type
    schedule(type)
  }

  private func schedule(_ type: NetworkType) {
    let delay = min(max(debounce(), 0.5), 5)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pending?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        // Notify only on the "restored" and "switched" edges: lastNotifiedType is cleared when offline,
        // and a Wi-Fi ↔ cellular switch changes the type. Path updates on the same network (address changes and the like) are not forwarded:
        // the Web immediately checks its connection and fetches the latest messages on every onNetwork (§10.4).
        guard self.lastNotifiedType != type else { return }
        self.lastNotifiedType = type
        self.onAvailable(type)
      }
      self.pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  private static func type(of path: NWPath) -> NetworkType {
    if path.usesInterfaceType(.wifi) { return .wifi }
    if path.usesInterfaceType(.cellular) { return .cellular }
    if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
    // §4 Map other connection types to other.
    return .other
  }
}
