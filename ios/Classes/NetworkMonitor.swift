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
  /// 已经通知过 Web 的类型。断网时清空，下次恢复重新通知。
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
        // 只在「恢复」和「切换」两个边沿上通知：断网时 lastNotifiedType 会被清空，
        // Wi-Fi ↔ 蜂窝切换时类型不同。同一条网络上的路径更新（地址变化之类）不转发 ——
        // Web 每收到一次 onNetwork 都会立刻检查连接并拉取最新消息（§10.4）。
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
    // §4 其他取值归为 other。
    return .other
  }
}
