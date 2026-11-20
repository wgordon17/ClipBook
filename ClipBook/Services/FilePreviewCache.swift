import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class FilePreviewCache: @unchecked Sendable {
  private struct SourceSignature: Equatable {
    let modificationTime: TimeInterval
    let fileSize: Int64
  }

  private struct Metadata: Codable {
    let sourcePath: String
    let modificationTime: TimeInterval
    let fileSize: Int64
    let targetWidth: Int
    let targetHeight: Int

    func matches(canonicalSourcePath: String, signature: SourceSignature, targetSize: CGSize) -> Bool {
      (self.sourcePath == canonicalSourcePath || FilePreviewCache.canonicalPath(self.sourcePath) == canonicalSourcePath)
        && modificationTime == signature.modificationTime
        && fileSize == signature.fileSize
        && targetWidth == Int(targetSize.width.rounded())
        && targetHeight == Int(targetSize.height.rounded())
    }
  }

  private struct CachedDisplaySize {
    let signature: SourceSignature
    let size: CGSize
  }

  private let directory: URL
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let generationQueue = DispatchQueue(label: "com.clipbook.file-preview-cache", qos: .utility)
  private let pendingLock = NSLock()
  private let imageCache = NSCache<NSString, NSImage>()
  private var globalEpoch: UInt64 = 0
  private var pathEpochs: [String: UInt64] = [:]
  private var pendingKeys: Set<String> = []
  private var inFlightPathsByKey: [String: String] = [:]
  private var displaySizeCache: [String: CachedDisplaySize] = [:]
  private var imageFileCache: [String: Bool] = [:]

  init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  func image(
    forFileAt filePath: String,
    targetSize: CGSize,
    completion: @escaping @MainActor (NSImage) -> Void
  ) -> NSImage {
    // Only picture thumbnails are worth caching. A file icon comes from the system
    // quickly, while encoding it for the disk cache takes hundreds of milliseconds
    // for every icon, since it carries every size the system has for it.
    let canonicalFilePath = Self.canonicalPath(filePath)
    guard isImageFile(at: canonicalFilePath) else {
      return fallbackImage(forFileAt: filePath)
    }

    let targetSize = normalizedTargetSize(targetSize)
    let key = cacheKey(canonicalFilePath: canonicalFilePath, targetSize: targetSize)

    if let image = cachedImage(canonicalFilePath: canonicalFilePath, targetSize: targetSize, key: key) {
      return image
    }

    let fallback = fallbackImage(forFileAt: filePath)
    guard let signature = sourceSignature(forFileAt: canonicalFilePath) else {
      return fallback
    }

    scheduleImageThumbnailGeneration(
      canonicalFilePath: canonicalFilePath,
      targetSize: targetSize,
      signature: signature,
      key: key,
      completion: completion
    )

    return fallback
  }

  // Rows ask this for every height pass and every configure, so the answer is
  // remembered per path. The extension settles it without touching the disk;
  // only a file without one is asked for its content type.
  func isImageFile(at filePath: String) -> Bool {
    let canonicalFilePath = Self.canonicalPath(filePath)
    if let isImage = pendingLock.withLock({ imageFileCache[canonicalFilePath] }) {
      return isImage
    }

    let fileURL = URL(fileURLWithPath: canonicalFilePath)
    let isImage: Bool
    let pathExtension = fileURL.pathExtension
    if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
      isImage = type.conforms(to: .image)
    } else if let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
      isImage = type.conforms(to: .image)
    } else {
      // A missing file is not remembered as a non-image: it may appear later.
      return false
    }

    pendingLock.withLock {
      imageFileCache[canonicalFilePath] = isImage
    }
    return isImage
  }

  func displaySizeForImageFile(at filePath: String) -> CGSize? {
    let canonicalFilePath = Self.canonicalPath(filePath)
    guard isImageFile(at: canonicalFilePath),
          let signature = sourceSignature(forFileAt: canonicalFilePath) else {
      return nil
    }

    if let cached = pendingLock.withLock({ displaySizeCache[canonicalFilePath] }),
       cached.signature == signature {
      return cached.size
    }

    let fileURL = URL(fileURLWithPath: canonicalFilePath)
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = cgFloatProperty(properties[kCGImagePropertyPixelWidth]),
          let height = cgFloatProperty(properties[kCGImagePropertyPixelHeight]),
          width > 0,
          height > 0 else {
      return nil
    }

    let dpiWidth = cgFloatProperty(properties[kCGImagePropertyDPIWidth])
    let dpiHeight = cgFloatProperty(properties[kCGImagePropertyDPIHeight])
    let size = CGSize(
      width: displayLength(forPixelLength: width, dpi: dpiWidth),
      height: displayLength(forPixelLength: height, dpi: dpiHeight)
    )
    pendingLock.withLock {
      displaySizeCache[canonicalFilePath] = CachedDisplaySize(signature: signature, size: size)
    }
    return size
  }

  func removePreviews(forFilePaths filePaths: Set<String>) {
    guard !filePaths.isEmpty else {
      return
    }

    let canonicalPaths = Set(filePaths.map(Self.canonicalPath))
    pendingLock.withLock {
      for path in canonicalPaths {
        pathEpochs[path, default: 0] &+= 1
        displaySizeCache.removeValue(forKey: path)
        imageFileCache.removeValue(forKey: path)
      }
      for rawPath in filePaths {
        displaySizeCache.removeValue(forKey: rawPath)
        imageFileCache.removeValue(forKey: rawPath)
      }
      compactPathEpochsIfNeeded()
      removeCacheEntriesLocked { metadata in
        canonicalPaths.contains(metadata.sourcePath)
          || canonicalPaths.contains(Self.canonicalPath(metadata.sourcePath))
          || filePaths.contains(metadata.sourcePath)
      }
    }
  }

  func prune(keepingFilePaths filePaths: Set<String>) {
    prune(keepingFilePaths: { filePaths })
  }

  func prune(keepingFilePaths makeFilePaths: () -> Set<String>) {
    let rawKeptPaths = makeFilePaths()
    let canonicalKeptPaths = Set(rawKeptPaths.map(Self.canonicalPath))

    pendingLock.withLock {
      for (_, inFlightPath) in inFlightPathsByKey where !canonicalKeptPaths.contains(inFlightPath) {
        pathEpochs[inFlightPath, default: 0] &+= 1
        displaySizeCache.removeValue(forKey: inFlightPath)
        imageFileCache.removeValue(forKey: inFlightPath)
      }
      compactPathEpochsIfNeeded()

      guard let entryURLs = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ), !entryURLs.isEmpty else {
        return
      }

      removeCacheEntriesLocked(in: entryURLs) { metadata in
        let canonicalMeta = Self.canonicalPath(metadata.sourcePath)
        return !canonicalKeptPaths.contains(canonicalMeta) && !rawKeptPaths.contains(metadata.sourcePath)
      }

      // Scrub any orphaned .png files lacking a matching .json metadata entry.
      if let remainingURLs = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        let jsonKeys = Set(
          remainingURLs
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
        )
        for url in remainingURLs where url.pathExtension.lowercased() == "png" {
          let key = url.deletingPathExtension().lastPathComponent
          if !jsonKeys.contains(key) {
            ImageAssetStore.secureUnlink(at: url)
            imageCache.removeObject(forKey: key as NSString)
          }
        }
      }
    }
  }

  func removeAll() {
    pendingLock.withLock {
      globalEpoch &+= 1
      pathEpochs.removeAll()
      pendingKeys.removeAll()
      inFlightPathsByKey.removeAll()
      displaySizeCache.removeAll()
      imageFileCache.removeAll()
      imageCache.removeAllObjects()

      if let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        for entry in entries {
          ImageAssetStore.secureUnlink(at: entry)
        }
      }
      try? fileManager.removeItem(at: directory)
    }
  }

  private func cachedImage(canonicalFilePath: String, targetSize: CGSize, key: String) -> NSImage? {
    guard let signature = sourceSignature(forFileAt: canonicalFilePath) else {
      return nil
    }

    return pendingLock.withLock {
      guard let metadata = readMetadata(key: key),
            metadata.matches(canonicalSourcePath: canonicalFilePath, signature: signature, targetSize: targetSize) else {
        return nil
      }

      if let image = imageCache.object(forKey: key as NSString) {
        return image
      }

      guard let image = NSImage(contentsOf: imageURL(forKey: key)) else {
        return nil
      }

      imageCache.setObject(image, forKey: key as NSString)
      return image
    }
  }

  private func scheduleImageThumbnailGeneration(
    canonicalFilePath: String,
    targetSize: CGSize,
    signature: SourceSignature,
    key: String,
    completion: @escaping @MainActor (NSImage) -> Void
  ) {
    let startState = beginGeneration(forKey: key, canonicalFilePath: canonicalFilePath)
    guard startState.started else {
      return
    }

    let fileURL = URL(fileURLWithPath: canonicalFilePath)
    let maximumPixelSize = max(Int(max(targetSize.width, targetSize.height).rounded()), 1) * 2
    let startGlobalEpoch = startState.globalEpoch
    let startPathEpoch = startState.pathEpoch

    generationQueue.async { [weak self] in
      guard let self else {
        return
      }

      defer { self.endGeneration(forKey: key) }

      guard let data = Self.thumbnailPNGData(from: fileURL, maximumPixelSize: maximumPixelSize),
            let image = NSImage(data: data) else {
        return
      }

      let didPersist: Bool = self.pendingLock.withLock {
        guard self.globalEpoch == startGlobalEpoch,
              (self.pathEpochs[canonicalFilePath] ?? 0) == startPathEpoch else {
          return false
        }

        do {
          try self.writeCachedImageDataLocked(
            data,
            canonicalFilePath: canonicalFilePath,
            targetSize: targetSize,
            signature: signature,
            key: key
          )
          self.imageCache.setObject(image, forKey: key as NSString)
          return true
        } catch {
          return false
        }
      }

      guard didPersist else {
        return
      }

      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else {
            return
          }
          let isStillValid = self.pendingLock.withLock {
            self.globalEpoch == startGlobalEpoch
              && (self.pathEpochs[canonicalFilePath] ?? 0) == startPathEpoch
          }
          if isStillValid {
            completion(image)
          }
        }
      }
    }
  }

  private func fallbackImage(forFileAt filePath: String) -> NSImage {
    NSWorkspace.shared.icon(forFile: filePath)
  }

  private func writeCachedImageDataLocked(
    _ data: Data,
    canonicalFilePath: String,
    targetSize: CGSize,
    signature: SourceSignature,
    key: String
  ) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.writeAtomically0600(data, to: imageURL(forKey: key), in: directory)
    let metadata = Metadata(
      sourcePath: canonicalFilePath,
      modificationTime: signature.modificationTime,
      fileSize: signature.fileSize,
      targetWidth: Int(targetSize.width.rounded()),
      targetHeight: Int(targetSize.height.rounded())
    )
    let metadataData = try encoder.encode(metadata)
    try Self.writeAtomically0600(metadataData, to: metadataURL(forKey: key), in: directory)
  }

  private static func writeAtomically0600(_ data: Data, to destinationURL: URL, in directoryURL: URL) throws {
    let tempURL = directoryURL.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)",
      isDirectory: false
    )
    let fd = Darwin.open(tempURL.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var fdOpen = true
    do {
      _ = Darwin.fchmod(fd, mode_t(0o600))
      try data.withUnsafeBytes { rawBuffer in
        guard rawBuffer.count > 0, let baseAddress = rawBuffer.baseAddress else { return }
        var writtenTotal = 0
        while writtenTotal < rawBuffer.count {
          let result = Darwin.write(fd, baseAddress.advanced(by: writtenTotal), rawBuffer.count - writtenTotal)
          if result > 0 {
            writtenTotal += result
          } else if result < 0 && errno == EINTR {
            continue
          } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        }
      }
      fdOpen = false
      guard Darwin.close(fd) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard Darwin.rename(tempURL.path, destinationURL.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      if fdOpen {
        _ = Darwin.close(fd)
      }
      ImageAssetStore.secureUnlink(at: tempURL)
      throw error
    }
  }

  private static func thumbnailPNGData(from fileURL: URL, maximumPixelSize: Int) -> Data? {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
      return nil
    }

    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCache: false,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
    ] as CFDictionary

    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      return nil
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }

    CGImageDestinationAddImage(destination, thumbnail, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    return data as Data
  }

  private func sourceSignature(forFileAt filePath: String) -> SourceSignature? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: filePath),
          let modificationDate = attributes[.modificationDate] as? Date else {
      return nil
    }

    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return SourceSignature(modificationTime: modificationDate.timeIntervalSince1970, fileSize: fileSize)
  }

  private func normalizedTargetSize(_ targetSize: CGSize) -> CGSize {
    CGSize(
      width: max(1, targetSize.width.rounded()),
      height: max(1, targetSize.height.rounded())
    )
  }

  private static func canonicalPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    var st = stat()
    if stat(url.path, &st) == 0 {
      return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    let parent = canonicalDirectoryURL(url.deletingLastPathComponent())
    return parent
      .appendingPathComponent(url.lastPathComponent, isDirectory: false)
      .standardizedFileURL
      .path
  }

  private static func canonicalDirectoryURL(_ directoryURL: URL) -> URL {
    let standardized = directoryURL.standardizedFileURL
    if standardized.path == "/" || standardized.path.isEmpty {
      return standardized
    }
    var st = stat()
    if stat(standardized.path, &st) == 0 {
      return standardized.resolvingSymlinksInPath().standardizedFileURL
    }
    let parent = canonicalDirectoryURL(standardized.deletingLastPathComponent())
    return parent
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
      .standardizedFileURL
  }

  private func cacheKey(canonicalFilePath: String, targetSize: CGSize) -> String {
    let rawKey = [
      canonicalFilePath,
      String(Int(targetSize.width.rounded())),
      String(Int(targetSize.height.rounded()))
    ].joined(separator: "\n")
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func imageURL(forKey key: String) -> URL {
    directory.appendingPathComponent("\(key).png")
  }

  private func metadataURL(forKey key: String) -> URL {
    directory.appendingPathComponent("\(key).json")
  }

  private func readMetadata(key: String) -> Metadata? {
    guard let data = try? Data(contentsOf: metadataURL(forKey: key)) else {
      return nil
    }

    return try? decoder.decode(Metadata.self, from: data)
  }

  private func removeCacheEntriesLocked(where shouldRemove: (Metadata) -> Bool) {
    guard let metadataURLs = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return
    }

    removeCacheEntriesLocked(in: metadataURLs, where: shouldRemove)
  }

  private func removeCacheEntriesLocked(in metadataURLs: [URL], where shouldRemove: (Metadata) -> Bool) {
    for metadataURL in metadataURLs where metadataURL.pathExtension == "json" {
      guard let data = try? Data(contentsOf: metadataURL),
            let metadata = try? decoder.decode(Metadata.self, from: data),
            shouldRemove(metadata) else {
        continue
      }

      let canonicalMetaPath = Self.canonicalPath(metadata.sourcePath)
      pathEpochs[canonicalMetaPath, default: 0] &+= 1
      let key = metadataURL.deletingPathExtension().lastPathComponent
      ImageAssetStore.secureUnlink(at: metadataURL)
      ImageAssetStore.secureUnlink(at: imageURL(forKey: key))
      imageCache.removeObject(forKey: key as NSString)
      displaySizeCache.removeValue(forKey: metadata.sourcePath)
      displaySizeCache.removeValue(forKey: canonicalMetaPath)
      imageFileCache.removeValue(forKey: metadata.sourcePath)
      imageFileCache.removeValue(forKey: canonicalMetaPath)
    }
  }

  private func compactPathEpochsIfNeeded() {
    if pathEpochs.count > 16_384 {
      globalEpoch &+= 1
      pathEpochs.removeAll(keepingCapacity: false)
    }
  }

  private func beginGeneration(
    forKey key: String,
    canonicalFilePath: String
  ) -> (started: Bool, globalEpoch: UInt64, pathEpoch: UInt64) {
    pendingLock.withLock {
      guard pendingKeys.insert(key).inserted else {
        return (false, 0, 0)
      }
      inFlightPathsByKey[key] = canonicalFilePath
      return (true, globalEpoch, pathEpochs[canonicalFilePath] ?? 0)
    }
  }

  private func endGeneration(forKey key: String) {
    pendingLock.withLock {
      _ = pendingKeys.remove(key)
      inFlightPathsByKey.removeValue(forKey: key)
    }
  }

  private func cgFloatProperty(_ value: Any?) -> CGFloat? {
    switch value {
    case let value as CGFloat:
      return value
    case let value as NSNumber:
      return CGFloat(truncating: value)
    case let value as Double:
      return CGFloat(value)
    case let value as Int:
      return CGFloat(value)
    default:
      return nil
    }
  }

  private func displayLength(forPixelLength pixelLength: CGFloat, dpi: CGFloat?) -> CGFloat {
    guard let dpi, dpi > 0 else {
      return pixelLength
    }

    return pixelLength * 72 / dpi
  }
}

private nonisolated extension NSLock {
  func withLock<Result>(_ action: () -> Result) -> Result {
    lock()
    defer { unlock() }
    return action()
  }
}
