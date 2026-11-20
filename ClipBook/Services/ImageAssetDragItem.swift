import AppKit
import Darwin
import Foundation

/// Drag payload for a captured image. The stored PNG asset is offered three
/// ways at once: as PNG and TIFF data, so image-aware destinations such as
/// editors and chats can take the pixels directly; and as the URL of a copy of
/// the PNG with a readable name, so Finder, Mail and file pickers receive a
/// real file, and Chromium and Electron apps such as Figma, which import
/// images dropped as files, take it too.
///
/// Both the lazy pasteboard data provider and the temporary named PNG file
/// authenticate and decrypt through owner-bound `ImageAssetStore.readAssetData`
/// so `Images/<id>.enc` stays encrypted on disk while drop destinations receive
/// valid PNG bytes.
enum ImageAssetDragItem {
  static func make(
    assetURL: URL,
    fileName: String,
    ownerClipID: UUID,
    requiresEncryption: Bool = false
  ) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    // Image data comes first so destinations that read whichever type the
    // pasteboard lists earliest prefer the pixels over the file.
    item.setDataProvider(
      ImageAssetDataProvider(
        assetURL: assetURL,
        ownerClipID: ownerClipID,
        requiresEncryption: requiresEncryption
      ),
      forTypes: [.png, .tiff]
    )
    if let fileURL = ImageDragFiles.makeCopy(
      of: assetURL,
      named: fileName,
      ownerClipID: ownerClipID,
      requiresEncryption: requiresEncryption
    ) {
      item.setString(fileURL.absoluteString, forType: .fileURL)
    }
    if requiresEncryption {
      item.setData(Data(), forType: PasteboardReader.concealedType)
    }
    return item
  }
}

/// Reads and authenticates the asset only when a destination asks for its data,
/// and converts it to TIFF only for destinations that want TIFF.
private final class ImageAssetDataProvider: NSObject, NSPasteboardItemDataProvider {
  private let assetURL: URL
  private let ownerClipID: UUID
  private let requiresEncryption: Bool

  init(assetURL: URL, ownerClipID: UUID, requiresEncryption: Bool) {
    self.assetURL = assetURL
    self.ownerClipID = ownerClipID
    self.requiresEncryption = requiresEncryption
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    guard let pngData = try? ImageAssetStore.readAssetData(
      at: assetURL,
      role: .image,
      ownerClipID: ownerClipID,
      requiresEncryption: requiresEncryption
    ) else {
      return
    }

    switch type {
    case .png:
      item.setData(pngData, forType: .png)
    case .tiff:
      if let tiffData = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
        item.setData(tiffData, forType: .tiff)
      }
    default:
      break
    }
  }
}

/// Named copies of image assets handed out as files when images are dragged.
/// Each copy gets a `0o700` folder of its own under a `0o700` backup-excluded
/// `Dragged Images` directory, and every file (including dot-prefixed user
/// titles) is zero-fill scrubbed via `ImageAssetStore.secureUnlink` on expiry,
/// item deletion, post-OCR purge, encryption upgrades, history clear, or close.
nonisolated enum ImageDragFiles {
  private static let maximumAge: TimeInterval = 60 * 60
  private static let lock = NSLock()

  static var directory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Dragged Images", isDirectory: true)
  }

  static func makeCopy(
    of assetURL: URL,
    named fileName: String,
    ownerClipID: UUID,
    requiresEncryption: Bool = false
  ) -> URL? {
    removeExpiredCopies()

    guard let pngData = try? ImageAssetStore.readAssetData(
      at: assetURL,
      role: .image,
      ownerClipID: ownerClipID,
      requiresEncryption: requiresEncryption
    ) else {
      return nil
    }

    let safeLeaf = sanitizedLeafFileName(fileName)
    guard !safeLeaf.isEmpty else {
      return nil
    }

    lock.lock()
    defer { lock.unlock() }

    guard var rootDirectory = ensureHardenedRootDirectoryLocked() else {
      return nil
    }
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? rootDirectory.setResourceValues(resourceValues)

    let folder = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    guard Darwin.mkdir(folder.path, mode_t(0o700)) == 0 else {
      return nil
    }
    _ = Darwin.chmod(folder.path, mode_t(0o700))

    let url = folder.appendingPathComponent(safeLeaf, isDirectory: false)
    let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else {
      scrubAndRemoveLocked(at: folder)
      return nil
    }

    var fdOpen = true
    do {
      _ = Darwin.fchmod(fd, mode_t(0o600))
      try pngData.withUnsafeBytes { rawBuffer in
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
      return url
    } catch {
      if fdOpen {
        _ = Darwin.close(fd)
      }
      scrubAndRemoveLocked(at: folder)
      return nil
    }
  }

  static func removeExpiredCopies(now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }

    let root = directory
    var st = stat()
    guard Darwin.lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
      return
    }

    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
      options: []
    ) else {
      return
    }

    let cutoff = now.addingTimeInterval(-maximumAge)
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
      let timestamp = values?.creationDate ?? values?.contentModificationDate
      if let timestamp, timestamp < cutoff {
        scrubAndRemoveLocked(at: entry)
      }
    }
  }

  static func removeAll() {
    lock.lock()
    defer { lock.unlock() }

    let root = directory
    var st = stat()
    guard Darwin.lstat(root.path, &st) == 0 else {
      return
    }
    scrubAndRemoveLocked(at: root)
  }

  private static func ensureHardenedRootDirectoryLocked() -> URL? {
    let fileManager = FileManager.default
    let root = directory

    var st = stat()
    if Darwin.lstat(root.path, &st) == 0 {
      if (st.st_mode & S_IFMT) != S_IFDIR {
        ImageAssetStore.secureUnlink(at: root)
      }
    }

    do {
      try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return nil
    }

    var verifyStat = stat()
    guard Darwin.lstat(root.path, &verifyStat) == 0,
          (verifyStat.st_mode & S_IFMT) == S_IFDIR else {
      return nil
    }

    _ = Darwin.chmod(root.path, mode_t(0o700))
    return root
  }

  private static func scrubAndRemoveLocked(at targetURL: URL) {
    var st = stat()
    guard Darwin.lstat(targetURL.path, &st) == 0 else {
      return
    }

    if (st.st_mode & S_IFMT) == S_IFDIR {
      if let children = try? FileManager.default.contentsOfDirectory(
        at: targetURL,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        for child in children {
          scrubAndRemoveLocked(at: child)
        }
      }
      _ = Darwin.rmdir(targetURL.path)
      if Darwin.lstat(targetURL.path, &st) == 0 {
        try? FileManager.default.removeItem(at: targetURL)
      }
    } else {
      ImageAssetStore.secureUnlink(at: targetURL)
    }
  }

  private static func sanitizedLeafFileName(_ fileName: String) -> String {
    let cleaned = fileName
      .components(separatedBy: CharacterSet(charactersIn: "/\0"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned == "." || cleaned == ".." {
      return "Image.png"
    }
    return cleaned
  }
}
