import AppKit
import Darwin
import Foundation
import ImageIO

/// Decodes history image assets off the main thread, downsampled to the box a
/// row shows them in, and keeps the results in memory so a row scrolled back
/// into view gets its picture at once. Decoding a full-size screenshot on the
/// main thread for every row that scrolls in is what made image rows stutter.
nonisolated final class ImageAssetThumbnailLoader: @unchecked Sendable {
  static let shared = ImageAssetThumbnailLoader()

  private let cache = NSCache<NSString, NSImage>()
  private let decodeQueue = DispatchQueue(
    label: "com.clipbook.image-asset-thumbnails",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let lock = NSLock()
  private var pendingCompletions: [String: [@MainActor (NSImage?) -> Void]] = [:]
  private var cachedKeysByPath: [String: Set<String>] = [:]
  private var globalEpoch: UInt64 = 0
  private var evictionEpoch: UInt64 = 0
  private var pathEvictionEpochs: [String: UInt64] = [:]
  private var directoryEvictionEpochs: [String: UInt64] = [:]

  init(memoryLimit: Int = 128 * 1024 * 1024) {
    cache.totalCostLimit = memoryLimit
  }

  /// Thumbnail sizes are rounded up to a step so a small change of the table
  /// width reuses the decoded picture instead of decoding it again.
  static func maximumPixelSize(forDisplaySize displaySize: CGSize, scale: CGFloat) -> Int {
    let step: CGFloat = 128
    let pixels = max(displaySize.width, displaySize.height) * max(scale, 1)
    return Int(max(step, (pixels / step).rounded(.up) * step))
  }

  /// Returns the cached thumbnail when there is one. Otherwise it starts
  /// decoding in the background, returns nil, and calls `completion` on the
  /// main thread with the result (nil when the file cannot be read).
  func thumbnail(
    for url: URL,
    maximumPixelSize: Int,
    completion: @escaping @MainActor (NSImage?) -> Void
  ) -> NSImage? {
    let normalizedPath = Self.normalizedFilePath(url.path)
    let key = "\(normalizedPath)\n\(maximumPixelSize)"
    if let image = cache.object(forKey: key as NSString) {
      return image
    }

    enum LookupOutcome {
      case cached(NSImage)
      case joinedPending
      case startDecode(globalEpoch: UInt64, startEvictionEpoch: UInt64)
    }

    let outcome: LookupOutcome = lock.withLock {
      if let image = cache.object(forKey: key as NSString) {
        return .cached(image)
      }
      if pendingCompletions[key] != nil {
        pendingCompletions[key]?.append(completion)
        return .joinedPending
      }

      pendingCompletions[key] = [completion]
      return .startDecode(globalEpoch: globalEpoch, startEvictionEpoch: evictionEpoch)
    }

    switch outcome {
    case .cached(let image):
      return image
    case .joinedPending:
      return nil
    case .startDecode(let startGlobalEpoch, let startEvictionEpoch):
      decodeQueue.async { [weak self] in
        let decodedImage = Self.decodeThumbnail(at: url, maximumPixelSize: maximumPixelSize)
        guard let self else {
          return
        }

        let (completions, imageToDeliver): ([@MainActor (NSImage?) -> Void], NSImage?) = self.lock.withLock {
          let wasEvicted = self.isEvicted(
            normalizedPath: normalizedPath,
            sinceGlobalEpoch: startGlobalEpoch,
            sinceEvictionEpoch: startEvictionEpoch
          )
          if !wasEvicted, let decodedImage {
            self.cache.setObject(decodedImage, forKey: key as NSString, cost: Self.cost(of: decodedImage))
            self.cachedKeysByPath[normalizedPath, default: []].insert(key)
          }
          let waiting = self.pendingCompletions.removeValue(forKey: key) ?? []
          return (waiting, wasEvicted ? nil : decodedImage)
        }

        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            completions.forEach { $0(imageToDeliver) }
          }
        }
      }
      return nil
    }
  }

  func removeThumbnails(forPath path: String) {
    guard !path.isEmpty else {
      return
    }
    let normalizedPath = Self.normalizedFilePath(path)
    lock.withLock {
      evictionEpoch &+= 1
      pathEvictionEpochs[normalizedPath] = evictionEpoch
      if let keys = cachedKeysByPath.removeValue(forKey: normalizedPath) {
        for key in keys {
          cache.removeObject(forKey: key as NSString)
        }
      }
      compactEpochTablesIfNeeded()
    }
  }

  func removeThumbnails(inDirectory directoryURL: URL) {
    let normalizedDirPath = Self.normalizedDirectoryPath(directoryURL)
    guard !normalizedDirPath.isEmpty else {
      return
    }
    let prefix = normalizedDirPath.hasSuffix("/") ? normalizedDirPath : normalizedDirPath + "/"
    lock.withLock {
      evictionEpoch &+= 1
      directoryEvictionEpochs[prefix] = evictionEpoch
      let matchingPaths = cachedKeysByPath.keys.filter { $0.hasPrefix(prefix) }
      for path in matchingPaths {
        if let keys = cachedKeysByPath.removeValue(forKey: path) {
          for key in keys {
            cache.removeObject(forKey: key as NSString)
          }
        }
      }
      compactEpochTablesIfNeeded()
    }
  }

  func removeAll() {
    lock.withLock {
      globalEpoch &+= 1
      evictionEpoch &+= 1
      cachedKeysByPath.removeAll()
      pathEvictionEpochs.removeAll()
      directoryEvictionEpochs.removeAll()
      cache.removeAllObjects()
    }
  }

  private func isEvicted(
    normalizedPath: String,
    sinceGlobalEpoch: UInt64,
    sinceEvictionEpoch: UInt64
  ) -> Bool {
    if globalEpoch != sinceGlobalEpoch {
      return true
    }
    if let pathEpoch = pathEvictionEpochs[normalizedPath], pathEpoch > sinceEvictionEpoch {
      return true
    }
    for (dirPrefix, dirEpoch) in directoryEvictionEpochs
    where dirEpoch > sinceEvictionEpoch && normalizedPath.hasPrefix(dirPrefix) {
      return true
    }
    return false
  }

  private func compactEpochTablesIfNeeded() {
    if pathEvictionEpochs.count + directoryEvictionEpochs.count > 16_384 {
      globalEpoch &+= 1
      pathEvictionEpochs.removeAll(keepingCapacity: false)
      directoryEvictionEpochs.removeAll(keepingCapacity: false)
    }
  }

  private static func normalizedFilePath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: false)
    var st = stat()
    if stat(url.path, &st) == 0 {
      return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    let parentDir = canonicalDirectoryURL(url.deletingLastPathComponent())
    return parentDir
      .appendingPathComponent(url.lastPathComponent, isDirectory: false)
      .standardizedFileURL
      .path
  }

  private static func normalizedDirectoryPath(_ directoryURL: URL) -> String {
    canonicalDirectoryURL(directoryURL).path
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

  private static func decodeThumbnail(at url: URL, maximumPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }

    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
    ] as CFDictionary
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      return nil
    }

    // The point size follows the file's DPI, the same way `NSImage(contentsOf:)`
    // sizes a picture, so a retina screenshot keeps the size it had before.
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let dpiWidth = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
    let dpiHeight = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0
    let pointSize = CGSize(
      width: CGFloat(thumbnail.width) * (dpiWidth > 0 ? 72 / dpiWidth : 1),
      height: CGFloat(thumbnail.height) * (dpiHeight > 0 ? 72 / dpiHeight : 1)
    )
    return NSImage(cgImage: thumbnail, size: pointSize)
  }

  private static func cost(of image: NSImage) -> Int {
    guard let representation = image.representations.first else {
      return 0
    }

    return representation.pixelsWide * representation.pixelsHigh * 4
  }
}

private nonisolated extension NSLock {
  func withLock<Result>(_ action: () -> Result) -> Result {
    lock()
    defer { unlock() }
    return action()
  }
}
