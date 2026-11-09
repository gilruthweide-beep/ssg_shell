import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// §7.3 文件选择器（iOS）。
///
/// WKWebView 自带的处理会先弹「照片图库 / 拍照或录像 / 选取文件」菜单，且没有公开接口
/// 去掉，所以附件选择由壳接管：document-start 的脚本拦住 `<input type="file">`
/// （见 `ShellInjection.fileInputScript`），这里用系统照片选择器
/// `PHPickerViewController` 顶上。只用公开 API，不 hook WebKit 私有类。
///
/// 三条规范硬要求：
/// 1. `PHPicker` 不需要相册权限 —— 不要先申请相册权限，也不要换成需要权限的自建相册。
/// 2. 格式：GIF 保持原样，其他图片（HEIC、HEIF…）一律转成 JPEG；视频保留原始 mov / mp4。
/// 3. 传输：视频可能几百 MB，**不能**整个转 base64 一次性交给页面 —— 按块读，
///    每块 base64 后不超过 2 MB，由页面逐块拉取后拼成 `Blob`。
final class FilePickerBridge: NSObject, PHPickerViewControllerDelegate {

  /// 暂存到磁盘的一个文件。`loadFileRepresentation` 回调里的临时文件在回调结束后会被
  /// 删除，所以必须先复制出来（§7.3.3）。
  private struct StagedFile {
    let url: URL
    let name: String
    let mime: String
    let size: Int
    let stagedAt: Date
  }

  /// §7.3.4 每块 base64 后不超过 2 MB：原始 1_440_000 字节（能被 3 整除，base64 不带
  /// 填充断口）编码后正好 1_920_000 个字符。
  private static let rawChunkSize = 1_440_000

  weak var host: ShellWebViewHost?

  /// 把清单交回页面（`window.__ssgFileBridge.deliver`）。
  var deliver: ((String, [[String: Any]]) -> Void)?

  private var pendingRequestId: String?
  private var staged: [String: StagedFile] = [:]
  private let lock = NSLock()

  // --------------------------------------------------------------- 拉起相册

  /// §7.3 点附件直接进入系统相册，中间不出现任何选择菜单。
  func present(requestId: String, accept: String, multiple: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let presenter = self.host?.presenter else {
        // 没有容器挂载时拉不起来。请求直接作废，页面那边的 pending 已经清掉了，
        // 下次点附件还能再来（§7.3.5）。
        NSLog("[SsgShell] 没有可用的容器，照片选择器拉不起来")
        self.deliver?(requestId, [])
        return
      }
      // 上一次请求还挂着（理论上不会，页面是串行的）：先把它作废。
      if let previous = self.pendingRequestId, previous != requestId {
        self.deliver?(previous, [])
      }
      self.pendingRequestId = requestId
      self.purgeStale()

      var configuration = PHPickerConfiguration()
      configuration.filter = Self.filter(for: accept)
      // §7.3.2 多选时不限张数（选一张也能直接确认），改头像时为 1。
      configuration.selectionLimit = multiple ? 0 : 1
      configuration.preferredAssetRepresentationMode = .current

      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      picker.modalPresentationStyle = .automatic
      presenter.present(picker, animated: true)
    }
  }

  /// §7.3.1 `filter` 按 `accept` 决定：同时有图片和视频时两者都显示；只有图片时只显示
  /// 图片；群或私聊限制发送类型时 `accept` 会收窄，照此收窄。
  static func filter(for accept: String) -> PHPickerFilter {
    let types = accept
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty && $0 != "*/*" }

    guard !types.isEmpty else { return .any(of: [.images, .videos]) }

    let hasImage = types.contains { $0.hasPrefix("image/") }
    let hasVideo = types.contains { $0.hasPrefix("video/") }
    switch (hasImage, hasVideo) {
    case (true, true): return .any(of: [.images, .videos])
    case (true, false): return .images
    case (false, true): return .videos
    // accept 里没有图片也没有视频：Web 不发文件（§6.1），按附件默认处理。
    case (false, false): return .any(of: [.images, .videos])
    }
  }

  // ------------------------------------------------- PHPickerViewControllerDelegate

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let requestId = pendingRequestId else { return }
    pendingRequestId = nil

    // §7.3.5 用户取消时不派发事件，下一次点附件要能再次拉起。
    guard !results.isEmpty else {
      deliver?(requestId, [])
      return
    }

    let group = DispatchGroup()
    // 结果要保持用户选择的顺序，所以先占位再按下标填。
    var manifest = [[String: Any]?](repeating: nil, count: results.count)
    var failures = 0

    for (index, result) in results.enumerated() {
      group.enter()
      stage(result.itemProvider) { [weak self] file in
        defer { group.leave() }
        guard let self, let file else {
          failures += 1
          return
        }
        let token = UUID().uuidString
        self.lock.lock()
        self.staged[token] = file
        self.lock.unlock()
        let chunks = max(1, Int(ceil(Double(file.size) / Double(Self.rawChunkSize))))
        manifest[index] = [
          "token": token,
          "name": file.name,
          "mime": file.mime,
          "size": file.size,
          "chunks": chunks,
        ]
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      let files = manifest.compactMap { $0 }
      self.deliver?(requestId, files)
      // §7.3.4「不要静默丢弃用户选中的文件」：真的有取不到的，明确告诉用户。
      if failures > 0 {
        self.warn("有 \(failures) 个文件读取失败，请重试或换一个文件")
      }
    }
  }

  // --------------------------------------------------------------- 落盘与转码

  /// §7.3.3 取文件并按格式要求处理，复制到自己的暂存目录。
  private func stage(_ provider: NSItemProvider, completion: @escaping (StagedFile?) -> Void) {
    let suggested = provider.suggestedName ?? "file"

    // GIF 保持原样 —— 转成 JPEG 会丢掉动画。
    if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
      copyFileRepresentation(
        provider,
        typeIdentifier: UTType.gif.identifier,
        name: Self.filename(suggested, ext: "gif"),
        mime: "image/gif",
        completion: completion
      )
      return
    }

    // 视频：取 UTType.movie，保留原始 mov 或 mp4。
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
        guard let self else { return completion(nil) }
        guard let url else {
          NSLog("[SsgShell] 取视频失败：\(error?.localizedDescription ?? "unknown")")
          return completion(nil)
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let mime = ext == "mov" ? "video/quicktime" : "video/mp4"
        completion(self.copy(url, name: Self.filename(suggested, ext: ext), mime: mime))
      }
      return
    }

    // 其他图片（HEIC、HEIF、PNG…）：交给页面的类型必须是 image/jpeg。
    // 系统能直接给 JPEG 表示时用它，给不了再用 ImageIO 解码后重新编码。
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { [weak self] url, _ in
        guard let self else { return completion(nil) }
        if let url {
          completion(self.copy(url, name: Self.filename(suggested, ext: "jpg"), mime: "image/jpeg"))
          return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
          guard let url else {
            NSLog("[SsgShell] 取图片失败：\(error?.localizedDescription ?? "unknown")")
            return completion(nil)
          }
          completion(self.transcodeToJpeg(url, name: Self.filename(suggested, ext: "jpg")))
        }
      }
      return
    }

    // Web 只收 png、jpeg、gif、mp4、mov（§7.3），别的本来也会被拒收。
    NSLog("[SsgShell] 选中的项目既不是图片也不是视频，跳过")
    completion(nil)
  }

  private func copyFileRepresentation(
    _ provider: NSItemProvider,
    typeIdentifier: String,
    name: String,
    mime: String,
    completion: @escaping (StagedFile?) -> Void
  ) {
    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
      guard let self, let url else {
        NSLog("[SsgShell] 取文件失败：\(error?.localizedDescription ?? "unknown")")
        return completion(nil)
      }
      completion(self.copy(url, name: name, mime: mime))
    }
  }

  /// `loadFileRepresentation` 的回调一结束，那个临时文件就会被删掉，必须先复制出来。
  private func copy(_ source: URL, name: String, mime: String) -> StagedFile? {
    do {
      let target = try Self.stagingDirectory().appendingPathComponent(
        UUID().uuidString + "-" + name
      )
      try FileManager.default.copyItem(at: source, to: target)
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
      return StagedFile(url: target, name: name, mime: mime, size: size ?? 0, stagedAt: Date())
    } catch {
      NSLog("[SsgShell] 暂存文件失败：\(error.localizedDescription)")
      return nil
    }
  }

  /// HEIC / HEIF 之类系统没给 JPEG 表示时的兜底：ImageIO 解码后重新编码。
  private func transcodeToJpeg(_ source: URL, name: String) -> StagedFile? {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      NSLog("[SsgShell] ImageIO 读不出图片，放弃")
      return nil
    }
    do {
      let target = try Self.stagingDirectory().appendingPathComponent(
        UUID().uuidString + "-" + name
      )
      guard let destination = CGImageDestinationCreateWithURL(
        target as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ) else {
        return nil
      }
      CGImageDestinationAddImageFromSource(
        destination,
        imageSource,
        0,
        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
      )
      guard CGImageDestinationFinalize(destination) else {
        NSLog("[SsgShell] 重新编码 JPEG 失败")
        return nil
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
      return StagedFile(url: target, name: name, mime: "image/jpeg", size: size ?? 0, stagedAt: Date())
    } catch {
      NSLog("[SsgShell] 转码落盘失败：\(error.localizedDescription)")
      return nil
    }
  }

  // ------------------------------------------------------------- 分块交付

  /// §7.3.4 页面按块来拉。返回 base64 字符串。
  func chunk(token: String, index: Int) throws -> String {
    lock.lock()
    let file = staged[token]
    lock.unlock()
    guard let file else {
      throw NSError(
        domain: "ssg_shell",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "文件已失效，请重新选择"]
      )
    }
    let offset = UInt64(index) * UInt64(Self.rawChunkSize)
    guard offset < UInt64(file.size) || (file.size == 0 && index == 0) else { return "" }

    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let data = handle.readData(ofLength: Self.rawChunkSize)
    return data.base64EncodedString()
  }

  /// 容器销毁时放掉挂着的请求，避免页面那边永远等。
  func dispose() {
    if let requestId = pendingRequestId {
      pendingRequestId = nil
      deliver?(requestId, [])
    }
  }

  // ----------------------------------------------------------------- 杂项

  private func warn(_ message: String) {
    guard let presenter = host?.presenter else { return }
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    presenter.present(alert, animated: true)
  }

  private static func filename(_ suggested: String, ext: String) -> String {
    // §7.3.4 带上原文件名，不要用临时文件名。
    // 同一个串还要当暂存文件名用，所以把路径分隔符换掉 —— 相册给的名字里偶尔带它们。
    let base = (suggested as NSString).deletingPathExtension
      .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
      .joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = base.isEmpty ? "file" : base
    return "\(safe).\(ext)"
  }

  private static func stagingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssg_shell_uploads", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// 页面拉完块之后没有「用完了」的信号，所以按时间清：下一次拉起选择器时，
  /// 把超过 10 分钟的暂存文件删掉。
  private func purgeStale() {
    let deadline = Date().addingTimeInterval(-600)
    lock.lock()
    let expired = staged.filter { $0.value.stagedAt < deadline }
    expired.keys.forEach { staged.removeValue(forKey: $0) }
    lock.unlock()
    for (_, file) in expired {
      try? FileManager.default.removeItem(at: file.url)
    }
  }
}
