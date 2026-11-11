import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// §7.3 iOS photo picker.
///
/// WKWebView normally shows an intermediate photo library / camera / file menu with no public API to remove it.
/// The shell therefore intercepts <input type="file"> at document start
/// through ShellInjection.fileInputScript and presents the system photo picker,
/// PHPickerViewController. Use public APIs only, without hooking private WebKit classes.
///
/// Three mandatory requirements:
/// 1. PHPicker does not require library permission; do not request it or substitute a custom library requiring access.
/// 2. Preserve GIFs, convert other images (HEIC, HEIF, etc.) to JPEG, and retain original mov / mp4 video files.
/// 3. Videos may be hundreds of MB; **do not send the entire file as base64 at once**. Read chunks,
///    at most 2 MB after base64 encoding, for the page to assemble into a Blob.
final class FilePickerBridge: NSObject, PHPickerViewControllerDelegate {

  /// A file staged on disk. loadFileRepresentation removes its temporary file when the callback returns,
  /// so copy it into the staging directory first (§7.3.3).
  private struct StagedFile {
    let url: URL
    let name: String
    let mime: String
    let size: Int
    let stagedAt: Date
  }

  /// §7.3.4 Each encoded chunk must stay below 2 MB. A raw chunk of 1,440,000 bytes is divisible by three,
  /// avoids base64 padding boundaries, and produces exactly 1,920,000 encoded characters.
  private static let rawChunkSize = 1_440_000

  weak var host: ShellWebViewHost?

  /// Return the file manifest through window.__ssgFileBridge.deliver.
  var deliver: ((String, [[String: Any]]) -> Void)?

  private var pendingRequestId: String?
  private var staged: [String: StagedFile] = [:]
  private let lock = NSLock()

  // --------------------------------------------------------------- Opening the photo picker

  /// §7.3 Open the system photo picker directly on attachment taps without intermediate menus.
  func present(requestId: String, accept: String, multiple: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let presenter = self.host?.presenter else {
        // Without an attached container, discard the request. The page already cleared its pending state,
        // so the next attachment tap can try again (§7.3.5).
        NSLog("[SsgShell] No container is available to present the photo picker")
        self.deliver?(requestId, [])
        return
      }
      // Discard any previous pending request first, although the page normally serializes requests.
      if let previous = self.pendingRequestId, previous != requestId {
        self.deliver?(previous, [])
      }
      self.pendingRequestId = requestId
      self.purgeStale()

      var configuration = PHPickerConfiguration()
      configuration.filter = Self.filter(for: accept)
      // §7.3.2 Multiple-selection mode has no app-imposed count limit and accepts a single selection; avatars allow one image.
      configuration.selectionLimit = multiple ? 0 : 1
      configuration.preferredAssetRepresentationMode = .current

      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      picker.modalPresentationStyle = .automatic
      presenter.present(picker, animated: true)
    }
  }

  /// §7.3.1 Filter by accept: show both images and videos when both are accepted, or images only
  /// when appropriate; honor narrower group or private-chat MIME restrictions.
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
    // If accept contains neither images nor videos, use the attachment default; the Web application does not send documents (§6.1).
    case (false, false): return .any(of: [.images, .videos])
    }
  }

  // ------------------------------------------------- PHPickerViewControllerDelegate

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let requestId = pendingRequestId else { return }
    pendingRequestId = nil

    // §7.3.5 Do not dispatch selection events on cancellation; the next attachment tap must work again.
    guard !results.isEmpty else {
      deliver?(requestId, [])
      return
    }

    let group = DispatchGroup()
    // Results must keep the user's selection order, so reserve slots first and fill them by index.
    // `loadFileRepresentation` callbacks each land on a different background thread and come back concurrently for multiple selections,
    // so all reads and writes of these two variables must go through `lock`.
    var manifest = [[String: Any]?](repeating: nil, count: results.count)
    var failures = 0

    for (index, result) in results.enumerated() {
      group.enter()
      stage(result.itemProvider) { [weak self] file in
        defer { group.leave() }
        guard let self else { return }
        guard let file else {
          self.lock.lock()
          failures += 1
          self.lock.unlock()
          return
        }
        let token = UUID().uuidString
        let chunks = max(1, Int(ceil(Double(file.size) / Double(Self.rawChunkSize))))
        self.lock.lock()
        self.staged[token] = file
        manifest[index] = [
          "token": token,
          "name": file.name,
          "mime": file.mime,
          "size": file.size,
          "chunks": chunks,
        ]
        self.lock.unlock()
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let files = manifest.compactMap { $0 }
      let failed = failures
      self.lock.unlock()
      self.deliver?(requestId, files)
      // §7.3.4 "Do not silently drop files the user selected": if some truly cannot be read, tell the user explicitly.
      if failed > 0 {
        self.warn("\(failed) file(s) could not be read. Try again or choose a different file.")
      }
    }
  }

  // --------------------------------------------------------------- Staging and transcoding

  /// §7.3.3 Load files, apply format requirements, and copy them into the application's staging directory.
  private func stage(_ provider: NSItemProvider, completion: @escaping (StagedFile?) -> Void) {
    let suggested = provider.suggestedName ?? "file"

    // Preserve GIFs; converting them to JPEG would remove animation.
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

    // Video: request UTType.movie and retain the original mov or mp4.
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
        guard let self else { return completion(nil) }
        guard let url else {
          NSLog("[SsgShell] Unable to load video:\(error?.localizedDescription ?? "unknown")")
          return completion(nil)
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let mime = ext == "mov" ? "video/quicktime" : "video/mp4"
        completion(self.copy(url, name: Self.filename(suggested, ext: ext), mime: mime))
      }
      return
    }

    // Other images (HEIC, HEIF, PNG, etc.) must reach the page as image/jpeg.
    // Prefer a system-provided JPEG representation; otherwise decode and re-encode with ImageIO.
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { [weak self] url, _ in
        guard let self else { return completion(nil) }
        if let url {
          completion(self.copy(url, name: Self.filename(suggested, ext: "jpg"), mime: "image/jpeg"))
          return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
          guard let url else {
            NSLog("[SsgShell] Unable to load image:\(error?.localizedDescription ?? "unknown")")
            return completion(nil)
          }
          completion(self.transcodeToJpeg(url, name: Self.filename(suggested, ext: "jpg")))
        }
      }
      return
    }

    // The Web application accepts only png, jpeg, gif, mp4, and mov (§7.3); other formats would be rejected.
    NSLog("[SsgShell] Selected item is neither an image nor a video; skipping")
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
        NSLog("[SsgShell] Unable to load file:\(error?.localizedDescription ?? "unknown")")
        return completion(nil)
      }
      completion(self.copy(url, name: name, mime: mime))
    }
  }

  /// Copy the temporary loadFileRepresentation file before its callback returns and the file is removed.
  private func copy(_ source: URL, name: String, mime: String) -> StagedFile? {
    do {
      let target = try Self.stagingDirectory().appendingPathComponent(
        UUID().uuidString + "-" + name
      )
      try FileManager.default.copyItem(at: source, to: target)
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
      return StagedFile(url: target, name: name, mime: mime, size: size ?? 0, stagedAt: Date())
    } catch {
      NSLog("[SsgShell] Unable to stage file:\(error.localizedDescription)")
      return nil
    }
  }

  /// Use ImageIO decoding and re-encoding when the system cannot provide JPEG for HEIC / HEIF or similar inputs.
  private func transcodeToJpeg(_ source: URL, name: String) -> StagedFile? {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      NSLog("[SsgShell] ImageIO could not decode the image; skipping")
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
        NSLog("[SsgShell] JPEG re-encoding failed")
        return nil
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
      return StagedFile(url: target, name: name, mime: "image/jpeg", size: size ?? 0, stagedAt: Date())
    } catch {
      NSLog("[SsgShell] Unable to save transcoded file:\(error.localizedDescription)")
      return nil
    }
  }

  // ------------------------------------------------------------- Chunk delivery

  /// §7.3.4 The page requests individual chunks; return a base64 string.
  func chunk(token: String, index: Int) throws -> String {
    lock.lock()
    let file = staged[token]
    lock.unlock()
    guard let file else {
      throw NSError(
        domain: "ssg_shell",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "This file is no longer available. Please select it again."]
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

  /// Release pending requests on container destruction so the page does not wait forever.
  func dispose() {
    if let requestId = pendingRequestId {
      pendingRequestId = nil
      deliver?(requestId, [])
    }
  }

  /// §7.3.4 Files that were read but could not be handed to the page are reported, never dropped silently.
  func reportDeliveryFailure(count: Int) {
    NSLog("[SsgShell] \(count) selected file(s) could not be delivered to the page")
    warn("\(count) file(s) could not be added. Try again or choose a different file.")
  }

  // ----------------------------------------------------------------- Utilities

  private func warn(_ message: String) {
    guard let presenter = host?.presenter else { return }
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    presenter.present(alert, animated: true)
  }

  private static func filename(_ suggested: String, ext: String) -> String {
    // §7.3.4 Preserve the original filename instead of exposing a temporary filename.
    // Also use this value for staging, replacing any path separators in filenames supplied by the photo library.
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

  /// The page does not send a completion signal after fetching chunks. Clean up by age when opening
  /// the next picker, removing staged files older than ten minutes.
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
