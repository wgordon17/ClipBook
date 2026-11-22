import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class FilePreviewCache: @unchecked Sendable {
  private struct SourceSignature: Equatable {
    let modificationTime: TimeInterval
    let fileSize: Int64
  }

  private struct Metadata: Codable, Sendable {
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

  private struct InFlightEntry: Sendable {
    let id: UInt64
    let canonicalPath: String
    let startGlobalEpoch: UInt64
    let startPathEpoch: UInt64
  }

  private final class CachedPreviewEntry: NSObject {
    let image: NSImage
    let metadata: Metadata
    let globalEpoch: UInt64
    let pathEpoch: UInt64

    init(image: NSImage, metadata: Metadata, globalEpoch: UInt64, pathEpoch: UInt64) {
      self.image = image
      self.metadata = metadata
      self.globalEpoch = globalEpoch
      self.pathEpoch = pathEpoch
    }
  }

  private enum StagedCommitOutcome {
    case committed
    case abortedKeepBothStaged
    case metadataRenameFailed(scrubbedImageURL: URL)
  }

  private static let maxAuxiliaryCacheEntries = 4_096

  private let directory: URL
  private let fileManager: FileManager
  private let generationQueue = DispatchQueue(label: "com.clipbook.file-preview-cache", qos: .utility)
  private let pendingLock = NSLock()
  private let imageCache: NSCache<NSString, CachedPreviewEntry> = {
    let cache = NSCache<NSString, CachedPreviewEntry>()
    cache.totalCostLimit = 64 * 1024 * 1024
    cache.countLimit = 1_024
    return cache
  }()
  private var globalEpoch: UInt64 = 0
  private var pathEpochs: [String: UInt64] = [:]
  private var nextGenerationID: UInt64 = 0
  private var inFlightByKey: [String: InFlightEntry] = [:]
  private var displaySizeCache: [String: CachedDisplaySize] = [:]
  private var imageFileCache: [String: Bool] = [:]
  private var canonicalPathCache: [String: String] = [:]

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
    guard let canonicalFilePath = resolveImageCanonicalPath(filePath) else {
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
    let pathExtension = URL(fileURLWithPath: filePath).pathExtension
    if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
      return type.conforms(to: .image)
    }

    let canonicalFilePath = cachedCanonicalPath(for: filePath)
    return isExtensionlessImageFile(canonicalFilePath: canonicalFilePath)
  }

  private func resolveImageCanonicalPath(_ filePath: String) -> String? {
    let pathExtension = URL(fileURLWithPath: filePath).pathExtension
    if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
      guard type.conforms(to: .image) else {
        return nil
      }
      return cachedCanonicalPath(for: filePath)
    }

    let canonicalFilePath = cachedCanonicalPath(for: filePath)
    guard isExtensionlessImageFile(canonicalFilePath: canonicalFilePath) else {
      return nil
    }
    return canonicalFilePath
  }

  private func cachedCanonicalPath(for rawPath: String) -> String {
    if let cached = pendingLock.withLock({ canonicalPathCache[rawPath] }) {
      return cached
    }
    let resolved = Self.canonicalPath(rawPath)
    pendingLock.withLock {
      if canonicalPathCache.count >= Self.maxAuxiliaryCacheEntries {
        canonicalPathCache.removeAll(keepingCapacity: false)
      }
      canonicalPathCache[rawPath] = resolved
    }
    return resolved
  }

  private func isExtensionlessImageFile(canonicalFilePath: String) -> Bool {
    if let isImage = pendingLock.withLock({ imageFileCache[canonicalFilePath] }) {
      return isImage
    }

    let fileURL = URL(fileURLWithPath: canonicalFilePath)
    guard let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType else {
      // A missing file is not remembered as a non-image: it may appear later.
      return false
    }
    let isImage = type.conforms(to: .image)
    pendingLock.withLock {
      if imageFileCache.count >= Self.maxAuxiliaryCacheEntries {
        imageFileCache.removeAll(keepingCapacity: false)
      }
      imageFileCache[canonicalFilePath] = isImage
    }
    return isImage
  }

  func displaySizeForImageFile(at filePath: String) -> CGSize? {
    guard let canonicalFilePath = resolveImageCanonicalPath(filePath),
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
      if displaySizeCache.count >= Self.maxAuxiliaryCacheEntries {
        displaySizeCache.removeAll(keepingCapacity: false)
      }
      displaySizeCache[canonicalFilePath] = CachedDisplaySize(signature: signature, size: size)
    }
    return size
  }

  func removePreviews(forFilePaths filePaths: Set<String>) {
    guard !filePaths.isEmpty else {
      return
    }

    let canonicalPaths = Set(filePaths.map(Self.canonicalPath))
    var urlsToScrub: [URL] = []
    pendingLock.withLock {
      canonicalPathCache.removeAll(keepingCapacity: false)
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
      stageCacheEntriesForScrubLocked(into: &urlsToScrub) { metadata in
        canonicalPaths.contains(metadata.sourcePath)
          || canonicalPaths.contains(Self.canonicalPath(metadata.sourcePath))
          || filePaths.contains(metadata.sourcePath)
      }
    }
    ImageAssetStore.secureUnlinkBatch(urlsToScrub)
  }

  func prune(keepingFilePaths filePaths: Set<String>) {
    prune(keepingFilePaths: { filePaths })
  }

  func prune(keepingFilePaths makeFilePaths: () -> Set<String>) {
    let hasWork: Bool = pendingLock.withLock {
      if !inFlightByKey.isEmpty {
        return true
      }
      guard let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ) else {
        return false
      }
      return !entries.isEmpty
    }
    guard hasWork else {
      return
    }

    let rawKeptPaths = makeFilePaths()
    let canonicalKeptPaths = Set(rawKeptPaths.map(Self.canonicalPath))
    var urlsToScrub: [URL] = []

    pendingLock.withLock {
      canonicalPathCache.removeAll(keepingCapacity: false)
      for (_, entry) in inFlightByKey where !canonicalKeptPaths.contains(entry.canonicalPath) {
        pathEpochs[entry.canonicalPath, default: 0] &+= 1
        displaySizeCache.removeValue(forKey: entry.canonicalPath)
        imageFileCache.removeValue(forKey: entry.canonicalPath)
      }
      compactPathEpochsIfNeeded()

      guard let entryURLs = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ), !entryURLs.isEmpty else {
        return
      }

      for entryURL in entryURLs where entryURL.lastPathComponent.hasPrefix(".scrubbing-") {
        urlsToScrub.append(entryURL)
      }

      let removedJSONKeys = stageCacheEntriesForScrubLocked(in: entryURLs, into: &urlsToScrub) { metadata in
        let canonicalMeta = Self.canonicalPath(metadata.sourcePath)
        return !canonicalKeptPaths.contains(canonicalMeta) && !rawKeptPaths.contains(metadata.sourcePath)
      }

      // Stage any orphaned .png files lacking a surviving .json metadata entry.
      let survivingJSONKeys = Set(
        entryURLs
          .filter { $0.pathExtension.lowercased() == "json" }
          .map { $0.deletingPathExtension().lastPathComponent }
      ).subtracting(removedJSONKeys)
      for url in entryURLs where url.pathExtension.lowercased() == "png" && !url.lastPathComponent.hasPrefix(".scrubbing-") {
        let key = url.deletingPathExtension().lastPathComponent
        if !survivingJSONKeys.contains(key) && !removedJSONKeys.contains(key) {
          stageForScrubLocked(url, into: &urlsToScrub)
          imageCache.removeObject(forKey: key as NSString)
        }
      }
    }

    ImageAssetStore.secureUnlinkBatch(urlsToScrub)
  }

  func removeAll() {
    var urlsToScrub: [URL] = []
    pendingLock.withLock {
      globalEpoch &+= 1
      pathEpochs.removeAll()
      displaySizeCache.removeAll()
      imageFileCache.removeAll()
      canonicalPathCache.removeAll()
      imageCache.removeAllObjects()

      if let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        for entry in entries {
          stageForScrubLocked(entry, into: &urlsToScrub)
        }
      }
    }
    ImageAssetStore.secureUnlinkBatch(urlsToScrub)
    _ = Darwin.rmdir(directory.path)
  }

  private func cachedImage(canonicalFilePath: String, targetSize: CGSize, key: String) -> NSImage? {
    guard let signature = sourceSignature(forFileAt: canonicalFilePath) else {
      return nil
    }

    let (startGlobalEpoch, startPathEpoch, memoryHit): (UInt64, UInt64, CachedPreviewEntry?) = pendingLock.withLock {
      (
        globalEpoch,
        pathEpochs[canonicalFilePath] ?? 0,
        imageCache.object(forKey: key as NSString)
      )
    }

    if let memoryHit,
       memoryHit.globalEpoch == startGlobalEpoch,
       memoryHit.pathEpoch == startPathEpoch,
       memoryHit.metadata.matches(canonicalSourcePath: canonicalFilePath, signature: signature, targetSize: targetSize) {
      return memoryHit.image
    }

    guard let metadata = readMetadata(key: key),
          metadata.matches(canonicalSourcePath: canonicalFilePath, signature: signature, targetSize: targetSize),
          let image = NSImage(contentsOf: imageURL(forKey: key)) else {
      return nil
    }

    let cost = Self.estimatedByteCost(of: image, targetSize: targetSize)
    return pendingLock.withLock {
      guard globalEpoch == startGlobalEpoch,
            (pathEpochs[canonicalFilePath] ?? 0) == startPathEpoch else {
        return nil
      }
      let cachedEntry = CachedPreviewEntry(
        image: image,
        metadata: metadata,
        globalEpoch: startGlobalEpoch,
        pathEpoch: startPathEpoch
      )
      imageCache.setObject(cachedEntry, forKey: key as NSString, cost: cost)
      return image
    }
  }

  private static func estimatedByteCost(of image: NSImage, targetSize: CGSize) -> Int {
    if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
      return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }
    let width = max(1, Int(targetSize.width.rounded()) * 2)
    let height = max(1, Int(targetSize.height.rounded()) * 2)
    return width * height * 4
  }

  private func scheduleImageThumbnailGeneration(
    canonicalFilePath: String,
    targetSize: CGSize,
    signature: SourceSignature,
    key: String,
    completion: @escaping @MainActor (NSImage) -> Void
  ) {
    guard let entry = registerInFlightGeneration(forKey: key, canonicalFilePath: canonicalFilePath) else {
      return
    }

    let fileURL = URL(fileURLWithPath: canonicalFilePath)
    let maximumPixelSize = max(Int(max(targetSize.width, targetSize.height).rounded()), 1) * 2
    let metadata = Metadata(
      sourcePath: canonicalFilePath,
      modificationTime: signature.modificationTime,
      fileSize: signature.fileSize,
      targetWidth: Int(targetSize.width.rounded()),
      targetHeight: Int(targetSize.height.rounded())
    )

    generationQueue.async { [weak self] in
      guard let self else {
        return
      }
      defer { self.endGeneration(forKey: key, id: entry.id) }

      guard self.isGenerationValid(entry),
            let pngData = Self.renderThumbnailPNGData(from: fileURL, maximumPixelSize: maximumPixelSize),
            let image = NSImage(data: pngData),
            self.isGenerationValid(entry),
            self.commitStagedThumbnailAtomically(
              pngData: pngData,
              metadata: metadata,
              image: image,
              key: key,
              entry: entry
            ) else {
        return
      }

      self.deliverGeneratedThumbnail(image, for: entry, completion: completion)
    }
  }

  private func commitStagedThumbnailAtomically(
    pngData: Data,
    metadata: Metadata,
    image: NSImage,
    key: String,
    entry: InFlightEntry
  ) -> Bool {
    var stagedImageURL: URL?
    var stagedMetadataURL: URL?
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let tempImageURL = try Self.stageTempFile0600(pngData, for: imageURL(forKey: key), in: directory)
      stagedImageURL = tempImageURL
      let metadataData = try JSONEncoder().encode(metadata)
      let tempMetadataURL = try Self.stageTempFile0600(metadataData, for: metadataURL(forKey: key), in: directory)
      stagedMetadataURL = tempMetadataURL

      let cost = Self.estimatedByteCost(
        of: image,
        targetSize: CGSize(width: metadata.targetWidth, height: metadata.targetHeight)
      )
      let outcome = pendingLock.withLock {
        publishStagedThumbnailLocked(
          stagedImageURL: tempImageURL,
          stagedMetadataURL: tempMetadataURL,
          image: image,
          metadata: metadata,
          cost: cost,
          key: key,
          entry: entry
        )
      }
      switch outcome {
      case .committed:
        return true
      case .abortedKeepBothStaged:
        cleanupUncommittedStagedFiles(imageURL: tempImageURL, metadataURL: tempMetadataURL)
        return false
      case .metadataRenameFailed(let scrubbedImageURL):
        ImageAssetStore.secureUnlink(at: scrubbedImageURL)
        cleanupUncommittedStagedFiles(imageURL: nil, metadataURL: tempMetadataURL)
        return false
      }
    } catch {
      cleanupUncommittedStagedFiles(imageURL: stagedImageURL, metadataURL: stagedMetadataURL)
      return false
    }
  }

  private func publishStagedThumbnailLocked(
    stagedImageURL: URL,
    stagedMetadataURL: URL,
    image: NSImage,
    metadata: Metadata,
    cost: Int,
    key: String,
    entry: InFlightEntry
  ) -> StagedCommitOutcome {
    guard isGenerationValidLocked(entry) else {
      return .abortedKeepBothStaged
    }
    let targetImageURL = imageURL(forKey: key)
    let targetMetadataURL = metadataURL(forKey: key)
    guard Darwin.rename(stagedImageURL.path, targetImageURL.path) == 0 else {
      return .abortedKeepBothStaged
    }
    guard Darwin.rename(stagedMetadataURL.path, targetMetadataURL.path) == 0 else {
      let scrubURL = directory.appendingPathComponent(".scrubbing-\(UUID().uuidString)", isDirectory: false)
      let failedImageURL = Darwin.rename(targetImageURL.path, scrubURL.path) == 0 ? scrubURL : targetImageURL
      return .metadataRenameFailed(scrubbedImageURL: failedImageURL)
    }
    let cachedEntry = CachedPreviewEntry(
      image: image,
      metadata: metadata,
      globalEpoch: entry.startGlobalEpoch,
      pathEpoch: entry.startPathEpoch
    )
    imageCache.setObject(cachedEntry, forKey: key as NSString, cost: cost)
    return .committed
  }

  private func cleanupUncommittedStagedFiles(imageURL: URL?, metadataURL: URL?) {
    var urls: [URL] = []
    if let imageURL {
      urls.append(imageURL)
    }
    if let metadataURL {
      urls.append(metadataURL)
    }
    if !urls.isEmpty {
      ImageAssetStore.secureUnlinkBatch(urls)
    }
    _ = Darwin.rmdir(directory.path)
  }

  private func deliverGeneratedThumbnail(
    _ image: NSImage,
    for entry: InFlightEntry,
    completion: @escaping @MainActor (NSImage) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isGenerationValid(entry) else {
          return
        }
        completion(image)
      }
    }
  }

  private func isGenerationValid(_ entry: InFlightEntry) -> Bool {
    pendingLock.withLock {
      isGenerationValidLocked(entry)
    }
  }

  private func isGenerationValidLocked(_ entry: InFlightEntry) -> Bool {
    globalEpoch == entry.startGlobalEpoch && (pathEpochs[entry.canonicalPath] ?? 0) == entry.startPathEpoch
  }

  private func fallbackImage(forFileAt filePath: String) -> NSImage {
    NSWorkspace.shared.icon(forFile: filePath)
  }

  private static func stageTempFile0600(_ data: Data, for destinationURL: URL, in directoryURL: URL) throws -> URL {
    let tempURL = directoryURL.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)",
      isDirectory: false
    )
    try ImageAssetStore.writeExclusivePrivateFile(data, to: tempURL)
    return tempURL
  }

  private static func renderThumbnailPNGData(from fileURL: URL, maximumPixelSize: Int) -> Data? {
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
    ImageAssetStore.resolvedFilePath(path)
  }

  private func cacheKey(canonicalFilePath: String, targetSize: CGSize) -> String {
    let rawKey = [
      canonicalFilePath,
      String(Int(targetSize.width.rounded())),
      String(Int(targetSize.height.rounded()))
    ].joined(separator: "\n")
    return ContentDigest.sha256(Data(rawKey.utf8))
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

    return try? JSONDecoder().decode(Metadata.self, from: data)
  }

  private func stageForScrubLocked(_ url: URL, into urlsToScrub: inout [URL]) {
    if url.lastPathComponent.hasPrefix(".scrubbing-") {
      urlsToScrub.append(url)
      return
    }
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else {
      return
    }
    let scrubURL = directory.appendingPathComponent(".scrubbing-\(UUID().uuidString)", isDirectory: false)
    if Darwin.rename(url.path, scrubURL.path) == 0 {
      urlsToScrub.append(scrubURL)
    } else {
      urlsToScrub.append(url)
    }
  }

  @discardableResult
  private func stageCacheEntriesForScrubLocked(
    into urlsToScrub: inout [URL],
    where shouldRemove: (Metadata) -> Bool
  ) -> Set<String> {
    guard let metadataURLs = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return []
    }

    return stageCacheEntriesForScrubLocked(in: metadataURLs, into: &urlsToScrub, where: shouldRemove)
  }

  @discardableResult
  private func stageCacheEntriesForScrubLocked(
    in metadataURLs: [URL],
    into urlsToScrub: inout [URL],
    where shouldRemove: (Metadata) -> Bool
  ) -> Set<String> {
    var removedKeys = Set<String>()
    let decoder = JSONDecoder()
    for metadataURL in metadataURLs where metadataURL.pathExtension == "json" {
      guard let data = try? Data(contentsOf: metadataURL),
            let metadata = try? decoder.decode(Metadata.self, from: data),
            shouldRemove(metadata) else {
        continue
      }

      let canonicalMetaPath = Self.canonicalPath(metadata.sourcePath)
      pathEpochs[canonicalMetaPath, default: 0] &+= 1
      let key = metadataURL.deletingPathExtension().lastPathComponent
      removedKeys.insert(key)
      stageForScrubLocked(metadataURL, into: &urlsToScrub)
      stageForScrubLocked(imageURL(forKey: key), into: &urlsToScrub)
      imageCache.removeObject(forKey: key as NSString)
      displaySizeCache.removeValue(forKey: metadata.sourcePath)
      displaySizeCache.removeValue(forKey: canonicalMetaPath)
      imageFileCache.removeValue(forKey: metadata.sourcePath)
      imageFileCache.removeValue(forKey: canonicalMetaPath)
    }
    return removedKeys
  }

  private func compactPathEpochsIfNeeded() {
    if pathEpochs.count > 16_384 {
      globalEpoch &+= 1
      pathEpochs.removeAll(keepingCapacity: false)
    }
  }

  private func registerInFlightGeneration(
    forKey key: String,
    canonicalFilePath: String
  ) -> InFlightEntry? {
    pendingLock.withLock {
      let currentPathEpoch = pathEpochs[canonicalFilePath] ?? 0
      if let existing = inFlightByKey[key],
         existing.startGlobalEpoch == globalEpoch,
         existing.startPathEpoch == currentPathEpoch {
        return nil
      }
      nextGenerationID &+= 1
      let entry = InFlightEntry(
        id: nextGenerationID,
        canonicalPath: canonicalFilePath,
        startGlobalEpoch: globalEpoch,
        startPathEpoch: currentPathEpoch
      )
      inFlightByKey[key] = entry
      return entry
    }
  }

  private func endGeneration(forKey key: String, id: UInt64) {
    pendingLock.withLock {
      if inFlightByKey[key]?.id == id {
        inFlightByKey.removeValue(forKey: key)
      }
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
