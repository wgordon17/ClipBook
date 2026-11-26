import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LinkPreview: @unchecked Sendable {
  let url: URL
  let title: String?
  let description: String?
  let image: NSImage?
  let favicon: NSImage?
  /// Saved pictures of a stored preview. A row decodes them in the background at the size it
  /// shows them, so they are not read in `image` and `favicon`.
  var imageURL: URL?
  var faviconURL: URL?
  var ownerClipID: UUID? = nil
  var requiresEncryptedAssets: Bool = false
  var imagePNGData: Data? = nil
  var faviconPNGData: Data? = nil

  var hasVisibleDetails: Bool {
    title != nil || description != nil || image != nil || favicon != nil || imageURL != nil || faviconURL != nil
  }
}

extension ClipboardItem {
  /// The stored preview for a row. Reading it never touches the picture files: a page picture
  /// is often a full-size screenshot, and decoding it on the main thread for every link row
  /// that scrolled in made scrolling stutter and held megabytes per row.
  var linkPreview: LinkPreview? {
    guard kind == .link,
          let details = linkPreviewDetails,
          let url = URL(string: details.url) ?? browserURL else {
      return nil
    }

    return LinkPreview(
      url: url,
      title: details.title,
      description: details.description,
      image: nil,
      favicon: nil,
      imageURL: Self.existingFileURL(atPath: details.imagePath),
      faviconURL: Self.existingFileURL(atPath: details.faviconPath),
      ownerClipID: id,
      requiresEncryptedAssets: SensitiveContent.shouldEncryptAtRest(self)
    )
  }

  private static func existingFileURL(atPath path: String?) -> URL? {
    guard let path, FileManager.default.fileExists(atPath: path) else {
      return nil
    }

    return URL(fileURLWithPath: path)
  }
}

final class HistoryItemRowLinkView: HistoryItemRowView {
  private lazy var linkPreviewImageView = makeLinkPreviewImageView()

  override func configureContent(item: ClipboardItem, quickPasteIndex: Int?) {
    // The page title and picture of a link say what the hidden address is, so a link with
    // hidden content is shown as its address alone.
    guard showsLinkPreview, !hidesSensitiveContent,
          let linkPreview, linkPreview.hasVisibleDetails else {
      setLines(primary: makeURLPreviewField(for: item), secondary: nil)
      return
    }

    if let favicon = linkPreview.favicon {
      // Every favicon sits inside the box at the type symbol size, whatever its own size.
      configureTypeIconImage(
        favicon,
        style: .small,
        toolTip: linkPreview.url.host ?? item.kind.title
      )
    } else if let faviconURL = linkPreview.faviconURL {
      configureFavicon(at: faviconURL, for: item, toolTip: linkPreview.url.host ?? item.kind.title)
    }

    // A compact row shows the address alone, next to the favicon.
    guard !isCompact else {
      setLines(primary: makeURLPreviewField(for: item), secondary: nil)
      return
    }

    if let secondaryText = linkPreview.title ?? linkPreview.description {
      setLines(
        primary: makePrimaryLabel(text: item.contentTitle),
        secondary: makeSecondaryLabel(text: secondaryText)
      )
    } else {
      setLines(primary: makeURLPreviewField(for: item), secondary: nil)
    }

    if let image = linkPreview.image {
      linkPreviewImageView.image = image
      setTrailingView(linkPreviewImageView)
    } else if let imageURL = linkPreview.imageURL {
      configureLinkPreviewImage(at: imageURL, for: item)
      setTrailingView(linkPreviewImageView)
    }
  }

  // A cached favicon shows at once; otherwise the link symbol stays until it is decoded.
  private func configureFavicon(at url: URL, for item: ClipboardItem, toolTip: String) {
    let boxSize = CGSize(width: HistoryRow.typeIconSize, height: HistoryRow.typeIconSize)
    let maximumPixelSize = ImageAssetThumbnailLoader.maximumPixelSize(forDisplaySize: boxSize, scale: backingScale)
    let assetContext = linkPreview?.ownerClipID.map {
      ImageAssetThumbnailLoader.ManagedAssetContext(
        role: .linkFavicon,
        ownerClipID: $0,
        requiresEncryption: linkPreview?.requiresEncryptedAssets ?? false
      )
    }
    let cachedImage = ImageAssetThumbnailLoader.shared.thumbnail(
      for: url,
      maximumPixelSize: maximumPixelSize,
      assetContext: assetContext
    ) { [weak self] image in
      guard let self, self.isConfigured(for: item), !self.hidesSensitiveContent, self.showsLinkPreview, let image else {
        return
      }

      self.configureTypeIconImage(image, style: .small, toolTip: toolTip)
    }
    if let cachedImage {
      configureTypeIconImage(cachedImage, style: .small, toolTip: toolTip)
    }
  }

  // The box keeps its place while the picture is decoded, so the text does not jump. It
  // is empty until then rather than showing the picture of the item the row showed before.
  private func configureLinkPreviewImage(at url: URL, for item: ClipboardItem) {
    // The picture fills the box and is cropped to it, so a picture much taller or wider
    // than the box needs more pixels along its long side than the box itself has.
    let fillSize = CGSize(width: HistoryRow.linkPreviewImageWidth * 2, height: HistoryRow.linkPreviewImageHeight * 2)
    let maximumPixelSize = ImageAssetThumbnailLoader.maximumPixelSize(forDisplaySize: fillSize, scale: backingScale)
    let assetContext = linkPreview?.ownerClipID.map {
      ImageAssetThumbnailLoader.ManagedAssetContext(
        role: .linkPreview,
        ownerClipID: $0,
        requiresEncryption: linkPreview?.requiresEncryptedAssets ?? false
      )
    }
    linkPreviewImageView.image = ImageAssetThumbnailLoader.shared.thumbnail(
      for: url,
      maximumPixelSize: maximumPixelSize,
      assetContext: assetContext
    ) { [weak self] image in
      guard let self, self.isConfigured(for: item), !self.hidesSensitiveContent, self.showsLinkPreview, let image else {
        return
      }

      self.linkPreviewImageView.image = image
    }
  }

  private var backingScale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  // A link without a page title has both lines for its URL, wrapped at any character so
  // the lines fill the width, and cut with an ellipsis when it is longer than that.
  private func makeURLPreviewField(for item: ClipboardItem) -> NSView {
    makeTextPreviewField(text: item.contentTitle, wrappingMode: .byCharWrapping)
  }

  private func makeLinkPreviewImageView() -> NSImageView {
    let imageView = LinkPreviewAspectFillImageView()
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = HistoryRow.linkPreviewImageCornerRadius
    imageView.layer?.masksToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: HistoryRow.linkPreviewImageWidth),
      imageView.heightAnchor.constraint(equalToConstant: HistoryRow.linkPreviewImageHeight)
    ])
    return imageView
  }
}

class LinkPreviewAspectFillImageView: NSImageView {
  override func draw(_ dirtyRect: NSRect) {
    guard let image, image.size.width > 0, image.size.height > 0 else {
      super.draw(dirtyRect)
      return
    }

    let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
    let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let drawRect = NSRect(
      x: bounds.midX - drawSize.width / 2,
      y: bounds.midY - drawSize.height / 2,
      width: drawSize.width,
      height: drawSize.height
    )

    image.draw(
      in: drawRect,
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
    )
  }
}

nonisolated final class LinkPreviewFetcher: Sendable {
  private struct FetchedImagePayload: @unchecked Sendable {
    let image: NSImage
    let pngData: Data?
  }

  private static let maximumHTMLBytes = 512 * 1024
  private static let maximumPreviewImageBytes = 5 * 1024 * 1024
  private static let maximumFaviconBytes = 512 * 1024
  private static let requestTimeout: TimeInterval = 10

  private static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }

  private static let defaultSession: URLSession = makeDefaultSession()
  let session: URLSession

  init(session: URLSession = LinkPreviewFetcher.defaultSession) {
    self.session = session
  }

  @concurrent
  func fetchPreview(for url: URL) async -> LinkPreview? {
    guard let html = await fetchHTML(for: url) else {
      return nil
    }

    let metadata = LinkPreviewHTMLParser.parse(html: html, baseURL: url)
    async let previewImage = fetchPreviewImage(at: metadata.imageURL)
    async let favicon = fetchFirstImage(
      at: metadata.faviconURLs,
      maximumByteCount: Self.maximumFaviconBytes
    )

    let resolvedImage = await previewImage
    let resolvedFavicon = await favicon
    return LinkPreview(
      url: url,
      title: metadata.title,
      description: metadata.description,
      image: resolvedImage?.image,
      favicon: resolvedFavicon?.image,
      imagePNGData: resolvedImage?.pngData,
      faviconPNGData: resolvedFavicon?.pngData
    )
  }

  private func fetchPreviewImage(at url: URL?) async -> FetchedImagePayload? {
    guard let url else {
      return nil
    }

    return await Self.fetchImage(
      at: url,
      session: session,
      maximumByteCount: Self.maximumPreviewImageBytes
    )
  }

  private func fetchHTML(for url: URL) async -> String? {
    guard url.scheme == "http" || url.scheme == "https" else {
      return nil
    }

    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    request.setValue("bytes=0-\(Self.maximumHTMLBytes - 1)", forHTTPHeaderField: "Range")
    request.setValue("ClipBook/1.0", forHTTPHeaderField: "User-Agent")

    do {
      guard let (data, _) = try await Self.fetchBoundedData(
        for: request,
        session: session,
        maximumByteCount: Self.maximumHTMLBytes,
        truncateAtLimit: true
      ),
      Task.isCancelled == false else {
        return nil
      }

      return String(decoding: data, as: UTF8.self)
    } catch {
      return nil
    }
  }

  private func fetchFirstImage(at urls: [URL], maximumByteCount: Int) async -> FetchedImagePayload? {
    for url in urls {
      guard Task.isCancelled == false else {
        return nil
      }

      if let image = await Self.fetchImage(
        at: url,
        session: session,
        maximumByteCount: maximumByteCount
      ) {
        return image
      }
    }

    return nil
  }

  private static func fetchImage(
    at url: URL,
    session: URLSession,
    maximumByteCount: Int
  ) async -> FetchedImagePayload? {
    guard url.scheme == "http" || url.scheme == "https" else {
      return nil
    }

    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("ClipBook/1.0", forHTTPHeaderField: "User-Agent")

    do {
      guard let (data, _) = try await fetchBoundedData(
        for: request,
        session: session,
        maximumByteCount: maximumByteCount,
        truncateAtLimit: false
      ),
      Task.isCancelled == false,
      let image = NSImage(data: data) else {
        return nil
      }

      return FetchedImagePayload(image: image, pngData: normalizedPNGData(from: data))
    } catch {
      return nil
    }
  }

  private static func normalizedPNGData(from rawData: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
      return nil
    }
    let imageCount = CGImageSourceGetCount(source)
    guard imageCount > 0 else {
      return nil
    }
    var bestIndex = 0
    var bestArea = 0
    if imageCount > 1 {
      for index in 0..<imageCount {
        if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
           let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
          let area = width * height
          if area > bestArea {
            bestArea = area
            bestIndex = index
          }
        }
      }
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else {
      return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return output as Data
  }

  // Streams response bytes off the main actor so oversized or unending responses
  // are cancelled at the byte limit instead of buffered whole into memory.
  @concurrent
  private nonisolated static func fetchBoundedData(
    for request: URLRequest,
    session: URLSession = defaultSession,
    maximumByteCount: Int,
    truncateAtLimit: Bool
  ) async throws -> (Data, HTTPURLResponse)? {
    guard maximumByteCount >= 0 else {
      return nil
    }

    let (bytes, response) = try await session.bytes(for: request)
    defer {
      bytes.task.cancel()
    }

    guard let httpResponse = response as? HTTPURLResponse,
          (200..<400).contains(httpResponse.statusCode) else {
      return nil
    }

    if !truncateAtLimit,
       httpResponse.expectedContentLength > Int64(maximumByteCount) {
      return nil
    }

    if truncateAtLimit, maximumByteCount == 0 {
      return (Data(), httpResponse)
    }

    let initialCapacity: Int
    if httpResponse.expectedContentLength > 0 {
      initialCapacity = min(Int(clamping: httpResponse.expectedContentLength), maximumByteCount)
    } else {
      initialCapacity = min(maximumByteCount, 16 * 1024)
    }
    var data = Data()
    data.reserveCapacity(initialCapacity)

    for try await byte in bytes {
      if data.count >= maximumByteCount {
        bytes.task.cancel()
        if truncateAtLimit {
          break
        }
        return nil
      }

      data.append(byte)

      if truncateAtLimit, data.count >= maximumByteCount {
        bytes.task.cancel()
        break
      }
    }

    guard Task.isCancelled == false else {
      return nil
    }

    return (data, httpResponse)
  }
}

struct LinkPreviewMetadata {
  let title: String?
  let description: String?
  let imageURL: URL?
  let faviconURLs: [URL]
}

enum LinkPreviewHTMLParser {
  private nonisolated static let titleRegex = try! NSRegularExpression(
    pattern: #"<title\b[^>]*>(.*?)</title>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private nonisolated static let metaRegex = try! NSRegularExpression(
    pattern: #"<meta\b[^>]*>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private nonisolated static let linkRegex = try! NSRegularExpression(
    pattern: #"<link\b[^>]*>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  private nonisolated static let attributeRegex = try! NSRegularExpression(
    pattern: #"([^\s=/"'>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>]+))"#,
    options: [.caseInsensitive]
  )
  private nonisolated static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

  nonisolated static func parse(html: String, baseURL: URL) -> LinkPreviewMetadata {
    let metaTags = tags(matching: metaRegex, in: html).map(attributes(in:))
    let title = firstMetaContent(
      in: metaTags,
      matching: ["og:title", "twitter:title"]
    ) ?? htmlTitle(in: html)
    let description = firstMetaContent(
      in: metaTags,
      matching: ["og:description", "description", "twitter:description"]
    )
    let imageURL = firstMetaContent(
      in: metaTags,
      matching: ["og:image", "og:image:url", "twitter:image", "twitter:image:src"]
    ).flatMap { resolvedURL(from: $0, baseURL: baseURL) }

    return LinkPreviewMetadata(
      title: title,
      description: description,
      imageURL: imageURL,
      faviconURLs: faviconURLs(in: html, baseURL: baseURL)
    )
  }

  private nonisolated static func tags(matching regex: NSRegularExpression, in html: String) -> [String] {
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    return regex.matches(in: html, options: [], range: range).compactMap { match in
      Range(match.range, in: html).map { String(html[$0]) }
    }
  }

  private nonisolated static func attributes(in tag: String) -> [String: String] {
    // The "/" of a self-closing tag is not part of an unquoted value: <link href=/icon.png/>.
    let tag = tag.hasSuffix("/>") ? String(tag.dropLast(2)) + ">" : tag
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    return attributeRegex.matches(in: tag, options: [], range: range).reduce(into: [:]) { result, match in
      guard let nameRange = Range(match.range(at: 1), in: tag) else {
        return
      }

      let valueRange = (2...4)
        .compactMap { index -> Range<String.Index>? in
          let range = match.range(at: index)
          guard range.location != NSNotFound else {
            return nil
          }
          return Range(range, in: tag)
        }
        .first
      guard let valueRange else {
        return
      }

      result[String(tag[nameRange]).lowercased()] = cleanedText(String(tag[valueRange]))
    }
  }

  private nonisolated static func firstMetaContent(in tags: [[String: String]], matching names: [String]) -> String? {
    for name in names {
      if let content = tags.first(where: {
        $0["property"]?.lowercased() == name || $0["name"]?.lowercased() == name
      })?["content"].flatMap(nonEmptyText(_:)) {
        return content
      }
    }

    return nil
  }

  private nonisolated static func htmlTitle(in html: String) -> String? {
    guard let match = titleRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..<html.endIndex, in: html)),
          let range = Range(match.range(at: 1), in: html) else {
      return nil
    }

    return nonEmptyText(cleanedText(String(html[range])))
  }

  private nonisolated static func faviconURLs(in html: String, baseURL: URL) -> [URL] {
    let candidates = tags(matching: linkRegex, in: html)
      .map(attributes(in:))
      .compactMap { attributes -> (priority: Int, url: URL)? in
        guard let rel = attributes["rel"]?.lowercased(),
              rel.contains("icon"),
              let href = attributes["href"],
              let url = resolvedURL(from: href, baseURL: baseURL) else {
          return nil
        }

        let type = attributes["type"]?.lowercased() ?? ""
        let path = url.path.lowercased()
        let isPNG = type.contains("png") || path.hasSuffix(".png")
        let isICO = type.contains("x-icon") || path.hasSuffix(".ico")
        let priority: Int
        if rel.contains("apple-touch-icon") {
          priority = 0
        } else if isPNG {
          priority = 1
        } else if isICO {
          priority = 3
        } else {
          priority = 2
        }

        return (priority, url)
      }
      .sorted { lhs, rhs in lhs.priority < rhs.priority }
      .map(\.url)

    var urls = uniqueURLs(candidates)
    if let pngURL = resolvedURL(from: "/favicon.png", baseURL: baseURL) {
      urls.append(pngURL)
    }
    if let icoURL = resolvedURL(from: "/favicon.ico", baseURL: baseURL) {
      urls.append(icoURL)
    }
    return uniqueURLs(urls)
  }

  private nonisolated static func resolvedURL(from string: String, baseURL: URL) -> URL? {
    URL(string: string, relativeTo: baseURL)?.absoluteURL
  }

  private nonisolated static func cleanedText(_ text: String) -> String {
    let unescaped = ClipboardTextTransform.decodeHTMLEntities(text)
    let range = NSRange(unescaped.startIndex..<unescaped.endIndex, in: unescaped)
    return whitespaceRegex
      .stringByReplacingMatches(in: unescaped, options: [], range: range, withTemplate: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private nonisolated static func nonEmptyText(_ text: String) -> String? {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedText.isEmpty ? nil : trimmedText
  }

  private nonisolated static func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<URL>()
    return urls.filter { seen.insert($0).inserted }
  }
}
