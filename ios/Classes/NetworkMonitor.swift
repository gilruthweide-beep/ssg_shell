import Foundation
import Network

/// §10.4 网络恢复单独通知。
///
/// 回前台瞬间网络往往还没真正可用（Wi-Fi 重连、蜂窝重新附着要几秒），此时 Web 发起的
/// 重连会失败。规范的判据是「能发出请求」。
///
/// iOS 没有 Android 的 `NET_CAPABILITY_VALIDATED`，拿不到「这条路真的通了」这个信号，
/// 所以这里用 `NWPathMonitor` 的 `.satisfied` 再叠一层去抖（§10.4.3 要求 1~2 秒）作为
/// 近似：路由就绪后再等 1.5 秒才通知 Web，避免把「刚连上还没拿到 IP」的那一下转发过去。
final class NetworkMonitor {

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "ssg_shell.network")
  private let debounce: () -> TimeInterval
  private let onAvailable: (NetworkType) -> Void

  private var pending: DispatchWorkItem?
  private var lastNotifiedType: NetworkType?
  private var lastNotifiedAt: TimeInterval = 0
  private var started = false

  /// 类型没变时的最小通知间隔。
  private let minRepeat: TimeInterval = 10

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
      // §10.4.4 断网时不用调，`onNetwork('none')` 会被 Web 忽略。
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
        // 类型变了（Wi-Fi ↔ 蜂窝）一定要通知；类型没变时限一下频率。
        // 多调一次对 Web 无害（§10.4 不受重连冷却限制），只是没必要。
        let now = Date().timeIntervalSince1970
        if self.lastNotifiedType != type || now - self.lastNotifiedAt >= self.minRepeat {
          self.lastNotifiedType = type
          self.lastNotifiedAt = now
          self.onAvailable(type)
        }
      }
      self.pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  private static func type(of path: NWPath) -> NetworkType {
    if path.usesInterfaceType(.wifi) { return .wifi }
    if path.usesInterfaceType(.cellular) { return .cellular }
    if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
    // §4 其他取值归为 other。
    return .other
  }
}
