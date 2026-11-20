import AppKit
import Foundation
import os

/// Renders text that holds an SVG document, such as markup copied from a design
/// tool or a code editor, so the history and the preview can show the picture
/// instead of the code. The item itself stays text and is still pasted as the
/// markup; only the way it is shown changes.
///
/// The markup is parsed and drawn on a queue of its own: the first SVG a launch
/// draws takes AppKit 40-60 ms to set up, which the history must not wait for.
@MainActor
final class SVGImageRenderer: @unchecked Sendable {
  nonisolated static let shared = SVGImageRenderer()

  nonisolated init() {}

  /// How bright the drawn parts of a picture are, so it can be put on a
  /// background it stays visible on: a black icon disappears on a dark row.
  nonisolated enum Tone: Sendable {
    case dark
    case medium
    case light
  }

  // Never changed once made, so it is handed from the drawing queue to the main thread.
  nonisolated final class Rendering: @unchecked Sendable {
    /// The picture itself, drawn from the markup at any size.
    let image: NSImage
    /// A small bitmap of the picture for the history rows, which redraw often.
    let thumbnail: NSImage
    let tone: Tone

    init(image: NSImage, thumbnail: NSImage, tone: Tone) {
      self.image = image
      self.thumbnail = thumbnail
      self.tone = tone
    }

    /// The background the picture is drawn on: `matchingBackground` while the
    /// picture stands out against the appearance, a solid opposite one when it
    /// would blend in.
    func backgroundColor(matching matchingBackground: NSColor) -> NSColor {
      let tone = tone
      return NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch (tone, isDark) {
        case (.dark, true):
          return SVGImageRenderer.lightBackgroundColor
        case (.light, false):
          return SVGImageRenderer.darkBackgroundColor
        default:
          return matchingBackground
        }
      }
    }
  }

  // Larger documents are left as text: they take long to parse on the main
  // thread, and are rarely something to recognise at a glance anyway.
  private nonisolated static let maximumByteCount = 512 * 1024
  // Enough to find the root element after an XML declaration, a doctype and a
  // comment or two, without scanning the whole document.
  private nonisolated static let prologueCharacterLimit = 4096
  // The thumbnail fills the 34 point type box of a row, so this covers
  // displays up to 3x.
  private nonisolated static let thumbnailMaximumPixelSize: CGFloat = 102
  private nonisolated static let thumbnailMaximumPointSize: CGFloat = 34
  private nonisolated static let lightBackgroundColor = NSColor(white: 0.94, alpha: 1)
  private nonisolated static let darkBackgroundColor = NSColor(white: 0.18, alpha: 1)

  // Text that fails to render is remembered too, so a row does not parse it
  // again every time it is shown.
  private nonisolated final class CacheEntry: Sendable {
    let rendering: Rendering?

    init(_ rendering: Rendering?) {
      self.rendering = rendering
    }
  }

  private struct PendingRender {
    let id: UInt64
    let startEpoch: UInt64
    var callbacks: [(Rendering?) -> Void]
  }

  nonisolated(unsafe) private let cache: NSCache<NSString, CacheEntry> = {
    let cache = NSCache<NSString, CacheEntry>()
    cache.countLimit = 200
    return cache
  }()
  private nonisolated let evictionEpoch = OSAllocatedUnfairLock<UInt64>(initialState: 0)
  private nonisolated static let loaders = OSAllocatedUnfairLock(
    initialState: [UUID: @Sendable (UUID) -> String?]()
  )
  // One document at a time: drawing SVG is quick once AppKit is set up, and
  // the rows ask for only the few in view.
  private nonisolated let renderQueue = DispatchQueue(label: "com.clipbook.svg-rendering", qos: .userInitiated)
  private var nextRenderID: UInt64 = 0
  private var pendingCompletions: [String: PendingRender] = [:]

  nonisolated func removeAll() {
    evictionEpoch.withLock { $0 &+= 1 }
    cache.removeAllObjects()
  }

  nonisolated static func registerTextLoader(
    _ loader: @escaping @Sendable (UUID) -> String?,
    ownerID: UUID
  ) {
    loaders.withLock { $0[ownerID] = loader }
  }

  nonisolated static func unregisterTextLoader(ownerID: UUID) {
    loaders.withLock { _ = $0.removeValue(forKey: ownerID) }
    shared.removeAll()
  }

  private nonisolated static func loadRegisteredSVGText(for id: UUID) -> String? {
    let activeLoaders = loaders.withLock { Array($0.values) }
    for loader in activeLoaders {
      if let text = loader(id) {
        return text
      }
    }
    return nil
  }

  /// The picture the item's text describes, or nil when the text is not an SVG
  /// document or it cannot be drawn. A picture not drawn yet is drawn right
  /// away, so this is for the preview, which the user opens; the history rows
  /// use `rendering(for:completion:)`.
  func rendering(for item: ClipboardItem) -> Rendering? {
    guard let key = Self.cacheKey(for: item) else {
      return nil
    }

    if let entry = cache.object(forKey: key as NSString) {
      return entry.rendering
    }

    let startEpoch = evictionEpoch.withLock { $0 }
    let inlineText = item.isContentLoaded ? item.text : nil
    guard let text = inlineText ?? Self.loadRegisteredSVGText(for: item.id) else {
      return nil
    }

    let rendering = Self.render(text)
    guard evictionEpoch.withLock({ $0 == startEpoch }) else {
      return nil
    }
    cache.setObject(CacheEntry(rendering), forKey: key as NSString)
    return rendering
  }

  /// Returns the picture the item's text describes when it is already drawn.
  /// Otherwise, for text that is an SVG document, it draws the picture in the
  /// background, returns nil, and calls `completion` on the main thread with
  /// the result, nil when the markup cannot be drawn.
  func rendering(for item: ClipboardItem, completion: @escaping (Rendering?) -> Void) -> Rendering? {
    guard let key = Self.cacheKey(for: item) else {
      return nil
    }

    if let entry = cache.object(forKey: key as NSString) {
      return entry.rendering
    }

    let startEpoch = evictionEpoch.withLock { $0 }
    if var existing = pendingCompletions[key] {
      if existing.startEpoch == startEpoch {
        existing.callbacks.append(completion)
        pendingCompletions[key] = existing
        return nil
      }
      let superseded = existing.callbacks
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          superseded.forEach { $0(nil) }
        }
      }
    }

    nextRenderID &+= 1
    let renderID = nextRenderID
    let itemID = item.id
    let inlineText = item.isContentLoaded ? item.text : nil
    pendingCompletions[key] = PendingRender(
      id: renderID,
      startEpoch: startEpoch,
      callbacks: [completion]
    )
    renderQueue.async {
      guard self.evictionEpoch.withLock({ $0 == startEpoch }) else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if self.pendingCompletions[key]?.id == renderID {
              let callbacks = self.pendingCompletions.removeValue(forKey: key)?.callbacks ?? []
              callbacks.forEach { $0(nil) }
            }
          }
        }
        return
      }
      let resolvedText = inlineText ?? Self.loadRegisteredSVGText(for: itemID)
      let rendering = resolvedText.flatMap(Self.render)
      let didObtainText = resolvedText != nil
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let isCurrentEpoch = self.evictionEpoch.withLock { $0 == startEpoch }
          if isCurrentEpoch, didObtainText {
            self.cache.setObject(CacheEntry(rendering), forKey: key as NSString)
          }
          let callbacks: [(Rendering?) -> Void]
          if self.pendingCompletions[key]?.id == renderID {
            callbacks = self.pendingCompletions.removeValue(forKey: key)?.callbacks ?? []
          } else {
            callbacks = []
          }
          let delivered = isCurrentEpoch ? rendering : nil
          callbacks.forEach { $0(delivered) }
        }
      }
    }
    return nil
  }

  // Keyed by item ID and monotonic searchRevision so unloaded rows and hydrated
  // previews share the same cache entry and edited items are drawn again.
  private static func cacheKey(for item: ClipboardItem) -> String? {
    guard (item.kind == .text || item.kind == .richText),
          item.isSVGText else {
      return nil
    }

    return "\(item.id.uuidString)-\(item.searchRevision)"
  }

  /// Whether the text is a whole SVG document: an `svg` root element, after at
  /// most an XML declaration, a doctype and comments, closed at the very end.
  /// A page or a component that only contains an SVG somewhere is not one.
  nonisolated static func isSVGMarkup(_ text: String) -> Bool {
    guard text.utf8.count <= maximumByteCount,
          let start = text.firstIndex(where: { !$0.isWhitespace }),
          let last = text.lastIndex(where: { !$0.isWhitespace }) else {
      return false
    }

    let content = text[start...last]
    guard content.first == "<", content.suffix(6).lowercased() == "</svg>" else {
      return false
    }

    let prologue = String(content.prefix(prologueCharacterLimit))
    let pattern = #"^(?:\s+|<\?xml[^>]*>|<!--[\s\S]*?-->|<!DOCTYPE[^>]*>)*<svg[\s>]"#
    return prologue.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private nonisolated static func render(_ text: String) -> Rendering? {
    guard isSVGMarkup(text),
          let image = NSImage(data: Data(text.utf8)),
          image.size.width > 0,
          image.size.height > 0,
          let (thumbnail, tone) = makeThumbnail(of: image) else {
      return nil
    }

    return Rendering(image: image, thumbnail: thumbnail, tone: tone)
  }

  // Draws the picture into a small bitmap, which also tells how bright it is.
  private nonisolated static func makeThumbnail(of image: NSImage) -> (NSImage, Tone)? {
    let scale = min(
      thumbnailMaximumPixelSize / image.size.width,
      thumbnailMaximumPixelSize / image.size.height
    )
    let width = max(1, Int((image.size.width * scale).rounded()))
    let height = max(1, Int((image.size.height * scale).rounded()))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage(), let data = context.data else {
      return nil
    }

    let tone = tone(ofPixels: data.assumingMemoryBound(to: UInt8.self), count: width * height)
    let pointScale = thumbnailMaximumPointSize / CGFloat(max(width, height))
    let thumbnail = NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(width) * pointScale, height: CGFloat(height) * pointScale)
    )
    return (thumbnail, tone)
  }

  // The average brightness of the drawn pixels, each counted by how opaque it
  // is, so the transparent background around a shape does not dilute it.
  private nonisolated static func tone(ofPixels pixels: UnsafePointer<UInt8>, count: Int) -> Tone {
    var luminance: Double = 0
    var coverage: Double = 0
    for index in 0..<count {
      let pixel = pixels + index * 4
      // The components are premultiplied, so they already carry the alpha.
      luminance += 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
      coverage += Double(pixel[3])
    }

    guard coverage > 0 else {
      return .medium
    }

    let averageLuminance = luminance / coverage
    if averageLuminance < 0.3 {
      return .dark
    }
    if averageLuminance > 0.7 {
      return .light
    }
    return .medium
  }
}
