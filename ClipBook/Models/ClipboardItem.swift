import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import os

nonisolated struct LinkPreviewDetails: Codable, Hashable, Sendable {
    var url: String
    var title: String?
    var description: String?
    var imagePath: String?
    var faviconPath: String?
    var fetchedAt: Date

    var hasVisibleDetails: Bool {
        title != nil || description != nil || imagePath != nil || faviconPath != nil
    }
}

/// The SHA-256 of content, in hex. It tells two copies of the same HTML or
/// image apart from different ones without keeping the content at hand.
nonisolated enum ContentDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum ClipboardContentScope: Comparable, Sendable {
    case body
    case preview
    case full
}

// What an image is read for when it is captured: the text it shows, and the
// payload of the QR code it carries. Both are read from the same image in
// one pass, because an image can hold either, both or neither.
nonisolated struct RecognizedImageContent: Equatable, Sendable {
    static let empty = RecognizedImageContent(text: nil, qrCodeText: nil)

    var text: String?
    var qrCodeText: String?
}

nonisolated struct ClipboardItem: Identifiable, Codable, Hashable, Sendable {
    static let textPreviewBodyLimit = 8_096
    static let textPreviewMaxUTF16Length = 16_384

    private static let maxLeadingWhitespaceScanUTF16Length = 8_388_608
    private static let whitespaceOnlyPreviewUTF16Limit = 4_000
    private static let whitespaceOnlyPreviewCharacterLimit = 2_000
    private static let searchRevisionCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private static func nextSearchRevision() -> UInt64 {
        searchRevisionCounter.withLock { counter in
            counter &+= 1
            if counter == 0 {
                counter = 1
            }
            return counter
        }
    }

    private nonisolated enum FormattingLoadState: Sendable {
        case unloaded
        case previewOnly
        case full
    }

    var id: UUID
    var kind: ClipboardKind {
        didSet {
            storedContentKey = nil
            syncDerivedMetadataForHeaderMutation()
        }
    }
    var title: String? {
        didSet {
            searchRevision = Self.nextSearchRevision()
            syncDerivedMetadataForHeaderMutation()
        }
    }
    var text: String? {
        didSet {
            storedContentKey = nil
            searchRevision = Self.nextSearchRevision()
            syncDerivedMetadata(textModified: true, formattingModified: false)
        }
    }
    // The payload of the QR code found in an image, read when the item is
    // captured. It is kept next to `text`, which holds the text the image was
    // read with OCR, because an image can carry both.
    var qrCodeText: String? {
        didSet {
            searchRevision = Self.nextSearchRevision()
            hasQRCodeText = Self.computeHasNonWhitespaceText(qrCodeText)
            syncRestSecretForQRCodeMutation()
        }
    }
    // The formatting of rich text. The store keeps it apart from the rest of
    // the item and leaves it out of the items it reads, since most of a
    // history's memory went to formatting that only pasting, dragging,
    // previewing and export use.
    private(set) var rtfData: Data?
    private(set) var html: String?
    /// Whether the item has formatting, loaded in this value or only stored.
    private(set) var hasFormatting: Bool
    /// The SHA-256 of the HTML, which tells two copies of the same text with
    /// different formatting apart when the HTML is not loaded.
    private(set) var htmlDigest: String?
    private var formattingLoadState: FormattingLoadState = .full
    /// The digest of the image file's bytes. A copy of an image already in
    /// the history matches it and reuses that item instead of becoming a new one.
    var imageDigest: String? {
        didSet {
            storedContentKey = nil
        }
    }
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var assetPath: String? {
        didSet {
            storedContentKey = nil
        }
    }
    var filePaths: [String] {
        didSet {
            storedContentKey = nil
            searchRevision = Self.nextSearchRevision()
            syncDerivedMetadataForHeaderMutation()
        }
    }
    var sourceAppName: String? {
        didSet {
            searchRevision = Self.nextSearchRevision()
        }
    }
    var sourceBundleIdentifier: String?
    var copiedAt: Date
    var firstCopiedAt: Date
    var byteSize: Int
    /// Starring an item keeps it for good, so it no longer expires.
    var isFavorite: Bool {
        didSet {
            if isFavorite {
                expiresAt = nil
            }
        }
    }
    /// Tagging an item keeps it for good, so it no longer expires.
    var tags: [Int] {
        didSet {
            if !tags.isEmpty {
                expiresAt = nil
            }
            // An item taken out of a tag loses its place there, so tagging it
            // again puts it back among the items that were never arranged.
            if tagOrders.keys.contains(where: { !tags.contains($0) }) {
                tagOrders = tagOrders.filter { tags.contains($0.key) }
            }
            searchRevision = Self.nextSearchRevision()
        }
    }
    var searchText: String
    var copyCount: Int
    var linkPreviewDetails: LinkPreviewDetails? {
        didSet {
            searchRevision = Self.nextSearchRevision()
        }
    }
    var copySequenceID: Date?
    var copySequenceOrder: Int?
    /// The item's place among the favorites pinned to the top of the history,
    /// given when the user drags favorites into an order. A favorite that was
    /// never arranged has none and follows the history's own sort instead.
    var favoriteOrder: Int?
    /// The item's place among the items of each of its tags, by tag ID, given
    /// when the user drags the items of a tag into an order. A tag the items
    /// were never arranged in has no entry, and the item follows the history's
    /// own sort there instead.
    var tagOrders: [Int: Int] = [:]
    /// Whether the user asked to hide the content of the item in the history,
    /// or to show it although it looks like a secret. None leaves it to the
    /// app to tell.
    var sensitivity: ItemSensitivity?
    /// When the item is deleted for good, or nil when it stays until the
    /// history's own limits remove it. Confidential and sensitive content can
    /// be kept for a limited time only. Starring or tagging the item keeps it.
    var expiresAt: Date?
    /// When the item was moved to the Trash, or nil while it is in the
    /// history. The store keeps it in a column of its own rather than in the
    /// payload, so it is not among the coding keys.
    var deletedAt: Date? = nil

    private(set) var isContentLoaded: Bool = true
    private(set) var textPreview: String?
    private(set) var characterCount: Int = 0
    private(set) var containsPreviewSecret: Bool = false
    private(set) var containsRestSecret: Bool = false
    private(set) var hasRecognizedText: Bool = false
    private(set) var hasQRCodeText: Bool = false
    private(set) var isSVGText: Bool = false
    private(set) var isCorruptPlaceholder: Bool = false
    var storedContentKey: Data? = nil
    private(set) var searchRevision: UInt64

    init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        title: String? = nil,
        text: String? = nil,
        qrCodeText: String? = nil,
        rtfData: Data? = nil,
        html: String? = nil,
        assetPath: String? = nil,
        imageDigest: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        filePaths: [String] = [],
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        copiedAt: Date = Date(),
        firstCopiedAt: Date? = nil,
        byteSize: Int = 0,
        isFavorite: Bool = false,
        tags: [Int] = [],
        searchText: String? = nil,
        copyCount: Int = 0,
        linkPreviewDetails: LinkPreviewDetails? = nil,
        copySequenceID: Date? = nil,
        copySequenceOrder: Int? = nil,
        favoriteOrder: Int? = nil,
        tagOrders: [Int: Int] = [:],
        sensitivity: ItemSensitivity? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.qrCodeText = qrCodeText
        self.rtfData = rtfData
        self.html = html
        self.hasFormatting = rtfData != nil || html != nil
        self.htmlDigest = Self.digest(ofHTML: html)
        self.formattingLoadState = .full
        self.imageDigest = imageDigest
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.assetPath = assetPath
        self.filePaths = filePaths
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.copiedAt = copiedAt
        self.firstCopiedAt = firstCopiedAt ?? copiedAt
        self.byteSize = byteSize
        self.isFavorite = isFavorite
        self.tags = tags
        self.searchText = searchText ?? ClipboardItem.makeSearchText(
            title: title,
            text: text,
            filePaths: filePaths,
            tagNames: [],
            sourceAppName: sourceAppName,
            linkPreviewDetails: linkPreviewDetails,
            qrCodeText: qrCodeText
        )
        self.copyCount = copyCount
        self.linkPreviewDetails = linkPreviewDetails
        self.copySequenceID = copySequenceID
        self.copySequenceOrder = copySequenceOrder
        self.favoriteOrder = favoriteOrder
        self.tagOrders = tagOrders.filter { tags.contains($0.key) }
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.deletedAt = nil
        self.isContentLoaded = true
        self.storedContentKey = nil
        self.searchRevision = Self.nextSearchRevision()
        self.hasQRCodeText = Self.computeHasNonWhitespaceText(qrCodeText)
        syncDerivedMetadata(textModified: true, formattingModified: true)
    }

    private init(
        rawID id: UUID,
        kind: ClipboardKind,
        title: String?,
        text: String?,
        qrCodeText: String?,
        rtfData: Data?,
        html: String?,
        hasFormatting: Bool,
        htmlDigest: String?,
        formattingLoadState: FormattingLoadState,
        imageDigest: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        assetPath: String?,
        filePaths: [String],
        sourceAppName: String?,
        sourceBundleIdentifier: String?,
        copiedAt: Date,
        firstCopiedAt: Date,
        byteSize: Int,
        isFavorite: Bool,
        tags: [Int],
        searchText: String,
        copyCount: Int,
        linkPreviewDetails: LinkPreviewDetails?,
        copySequenceID: Date?,
        copySequenceOrder: Int?,
        favoriteOrder: Int?,
        tagOrders: [Int: Int],
        sensitivity: ItemSensitivity?,
        expiresAt: Date?,
        deletedAt: Date?,
        isContentLoaded: Bool,
        textPreview: String?,
        characterCount: Int,
        containsPreviewSecret: Bool,
        containsRestSecret: Bool,
        hasRecognizedText: Bool,
        hasQRCodeText: Bool,
        isSVGText: Bool,
        isCorruptPlaceholder: Bool = false,
        storedContentKey: Data?,
        searchRevision: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.qrCodeText = qrCodeText
        self.rtfData = rtfData
        self.html = html
        self.hasFormatting = hasFormatting
        self.htmlDigest = htmlDigest
        self.formattingLoadState = formattingLoadState
        self.imageDigest = imageDigest
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.assetPath = assetPath
        self.filePaths = filePaths
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.copiedAt = copiedAt
        self.firstCopiedAt = firstCopiedAt
        self.byteSize = byteSize
        self.isFavorite = isFavorite
        self.tags = tags
        self.searchText = searchText
        self.copyCount = copyCount
        self.linkPreviewDetails = linkPreviewDetails
        self.copySequenceID = copySequenceID
        self.copySequenceOrder = copySequenceOrder
        self.favoriteOrder = favoriteOrder
        self.tagOrders = tagOrders
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.deletedAt = deletedAt
        self.isContentLoaded = isContentLoaded
        self.textPreview = textPreview
        self.characterCount = characterCount
        self.containsPreviewSecret = containsPreviewSecret
        self.containsRestSecret = containsRestSecret
        self.hasRecognizedText = hasRecognizedText
        self.hasQRCodeText = hasQRCodeText
        self.isSVGText = isSVGText
        self.isCorruptPlaceholder = isCorruptPlaceholder
        self.storedContentKey = storedContentKey
        self.searchRevision = searchRevision
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case text
        case qrCodeText
        case rtfData
        case html
        case hasFormatting
        case htmlDigest
        case imageDigest
        case assetPath
        case filePaths
        case sourceAppName
        case sourceBundleIdentifier
        case copiedAt
        case firstCopiedAt
        case byteSize
        case isFavorite
        case tags
        case searchText
        case copyCount
        case linkPreviewDetails
        case copySequenceID
        case copySequenceOrder
        case favoriteOrder
        case tagOrders
        case sensitivity
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ClipboardKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        qrCodeText = try container.decodeIfPresent(String.self, forKey: .qrCodeText)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        html = try container.decodeIfPresent(String.self, forKey: .html)
        // Items stored before the formatting moved out of the payload carry it
        // here and have neither of these.
        let decodedHasFormatting = try container.decodeIfPresent(Bool.self, forKey: .hasFormatting)
            ?? (rtfData != nil || html != nil)
        hasFormatting = decodedHasFormatting
        htmlDigest = try container.decodeIfPresent(String.self, forKey: .htmlDigest)
            ?? Self.digest(ofHTML: html)
        formattingLoadState = (decodedHasFormatting && rtfData == nil && html == nil) ? .unloaded : .full
        imageDigest = try container.decodeIfPresent(String.self, forKey: .imageDigest)
        imageWidth = nil
        imageHeight = nil
        assetPath = try container.decodeIfPresent(String.self, forKey: .assetPath)
        filePaths = try container.decode([String].self, forKey: .filePaths)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        firstCopiedAt = try container.decodeIfPresent(Date.self, forKey: .firstCopiedAt) ?? copiedAt
        byteSize = try container.decode(Int.self, forKey: .byteSize)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        tags = (try? container.decode([Int].self, forKey: .tags)) ?? []
        searchText = try container.decode(String.self, forKey: .searchText)
        copyCount = try container.decode(Int.self, forKey: .copyCount)
        linkPreviewDetails = try container.decodeIfPresent(LinkPreviewDetails.self, forKey: .linkPreviewDetails)
        copySequenceID = try container.decodeIfPresent(Date.self, forKey: .copySequenceID)
        copySequenceOrder = try container.decodeIfPresent(Int.self, forKey: .copySequenceOrder)
        favoriteOrder = try container.decodeIfPresent(Int.self, forKey: .favoriteOrder)
        // Absent from items stored before the items of a tag could be arranged.
        tagOrders = (try? container.decodeIfPresent([Int: Int].self, forKey: .tagOrders)) ?? [:]
        // Read leniently, so a value written by a later version is ignored
        // instead of making the item unreadable.
        sensitivity = (try? container.decodeIfPresent(String.self, forKey: .sensitivity))
            .flatMap { $0 }
            .flatMap(ItemSensitivity.init(rawValue:))
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        deletedAt = nil
        isContentLoaded = true
        storedContentKey = nil
        searchRevision = Self.nextSearchRevision()
        hasQRCodeText = Self.computeHasNonWhitespaceText(qrCodeText)
        syncDerivedMetadata(textModified: true, formattingModified: true)
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.text == rhs.text
            && lhs.qrCodeText == rhs.qrCodeText
            && lhs.rtfData == rhs.rtfData
            && lhs.html == rhs.html
            && lhs.hasFormatting == rhs.hasFormatting
            && lhs.htmlDigest == rhs.htmlDigest
            && lhs.formattingLoadState == rhs.formattingLoadState
            && lhs.imageDigest == rhs.imageDigest
            && lhs.imageWidth == rhs.imageWidth
            && lhs.imageHeight == rhs.imageHeight
            && lhs.assetPath == rhs.assetPath
            && lhs.filePaths == rhs.filePaths
            && lhs.sourceAppName == rhs.sourceAppName
            && lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier
            && lhs.copiedAt == rhs.copiedAt
            && lhs.firstCopiedAt == rhs.firstCopiedAt
            && lhs.byteSize == rhs.byteSize
            && lhs.isFavorite == rhs.isFavorite
            && lhs.tags == rhs.tags
            && lhs.searchText == rhs.searchText
            && lhs.copyCount == rhs.copyCount
            && lhs.linkPreviewDetails == rhs.linkPreviewDetails
            && lhs.copySequenceID == rhs.copySequenceID
            && lhs.copySequenceOrder == rhs.copySequenceOrder
            && lhs.favoriteOrder == rhs.favoriteOrder
            && lhs.tagOrders == rhs.tagOrders
            && lhs.sensitivity == rhs.sensitivity
            && lhs.expiresAt == rhs.expiresAt
            && lhs.deletedAt == rhs.deletedAt
            && lhs.isContentLoaded == rhs.isContentLoaded
            && lhs.textPreview == rhs.textPreview
            && lhs.characterCount == rhs.characterCount
            && lhs.containsPreviewSecret == rhs.containsPreviewSecret
            && lhs.containsRestSecret == rhs.containsRestSecret
            && lhs.hasRecognizedText == rhs.hasRecognizedText
            && lhs.hasQRCodeText == rhs.hasQRCodeText
            && lhs.isSVGText == rhs.isSVGText
            && lhs.isCorruptPlaceholder == rhs.isCorruptPlaceholder
            && lhs.storedContentKey == rhs.storedContentKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(title)
        hasher.combine(text)
        hasher.combine(qrCodeText)
        hasher.combine(rtfData)
        hasher.combine(html)
        hasher.combine(hasFormatting)
        hasher.combine(htmlDigest)
        hasher.combine(formattingLoadState)
        hasher.combine(imageDigest)
        hasher.combine(imageWidth)
        hasher.combine(imageHeight)
        hasher.combine(assetPath)
        hasher.combine(filePaths)
        hasher.combine(sourceAppName)
        hasher.combine(sourceBundleIdentifier)
        hasher.combine(copiedAt)
        hasher.combine(firstCopiedAt)
        hasher.combine(byteSize)
        hasher.combine(isFavorite)
        hasher.combine(tags)
        hasher.combine(searchText)
        hasher.combine(copyCount)
        hasher.combine(linkPreviewDetails)
        hasher.combine(copySequenceID)
        hasher.combine(copySequenceOrder)
        hasher.combine(favoriteOrder)
        hasher.combine(tagOrders)
        hasher.combine(sensitivity)
        hasher.combine(expiresAt)
        hasher.combine(deletedAt)
        hasher.combine(isContentLoaded)
        hasher.combine(textPreview)
        hasher.combine(characterCount)
        hasher.combine(containsPreviewSecret)
        hasher.combine(containsRestSecret)
        hasher.combine(hasRecognizedText)
        hasher.combine(hasQRCodeText)
        hasher.combine(isSVGText)
        hasher.combine(isCorruptPlaceholder)
        hasher.combine(storedContentKey)
    }

    // MARK: - Preview & Header Lifecycle

    static func makeTextPreview(from text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }

        let scalars = text.unicodeScalars
        var cursor = scalars.startIndex
        var skippedUTF16 = 0
        var sawLineBreak = false

        while cursor < scalars.endIndex, skippedUTF16 < maxLeadingWhitespaceScanUTF16Length {
            let scalar = scalars[cursor]
            guard scalar.properties.isWhitespace else {
                break
            }
            switch scalar.value {
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                sawLineBreak = true
            default:
                break
            }
            skippedUTF16 += scalar.utf16.count
            scalars.formIndex(after: &cursor)
        }

        if cursor == scalars.endIndex || scalars[cursor].properties.isWhitespace {
            let slice = scalarBoundedSlice(
                text[text.startIndex...],
                maxUTF16Length: whitespaceOnlyPreviewUTF16Limit
            )
            return String(slice.prefix(whitespaceOnlyPreviewCharacterLimit))
        }

        let boundedBody = scalarBoundedSlice(
            text[cursor...],
            maxUTF16Length: textPreviewMaxUTF16Length
        )
        let body = String(boundedBody.prefix(textPreviewBodyLimit))
        if cursor == scalars.startIndex {
            return body
        }
        if sawLineBreak {
            return "\n" + body
        }
        return String(scalars[scalars.startIndex]) + body
    }

    private static func scalarBoundedSlice(_ substring: Substring, maxUTF16Length: Int) -> Substring {
        substring.scalarBoundedUTF16Prefix(maxUTF16Length)
    }

    var hasCompleteTextPreview: Bool {
        if isContentLoaded {
            return true
        }
        if hasFormatting && textPreview == nil {
            return false
        }
        guard let textPreview else {
            return characterCount == 0
        }
        return textPreview.first?.isWhitespace != true
            && textPreview.count == characterCount
            && textPreview.utf16.count < Self.textPreviewMaxUTF16Length - 2
    }

    static func fromStoredHeader(
        id: UUID,
        kind: ClipboardKind,
        title: String?,
        textPreview: String?,
        characterCount: Int,
        containsPreviewSecret: Bool,
        containsRestSecret: Bool,
        hasRecognizedText: Bool,
        hasQRCodeText: Bool,
        isSVGText: Bool,
        hasFormatting: Bool,
        htmlDigest: String?,
        imageDigest: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        assetPath: String?,
        filePaths: [String],
        sourceAppName: String?,
        sourceBundleIdentifier: String?,
        copiedAt: Date,
        firstCopiedAt: Date,
        byteSize: Int,
        isFavorite: Bool,
        tags: [Int],
        tagOrders: [Int: Int] = [:],
        copyCount: Int,
        linkPreviewDetails: LinkPreviewDetails?,
        copySequenceID: Date?,
        copySequenceOrder: Int?,
        favoriteOrder: Int?,
        sensitivity: ItemSensitivity?,
        expiresAt: Date?,
        deletedAt: Date?,
        storedContentKey: Data?,
        isCorruptPlaceholder: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            rawID: id,
            kind: kind,
            title: title,
            text: nil,
            qrCodeText: nil,
            rtfData: nil,
            html: nil,
            hasFormatting: hasFormatting,
            htmlDigest: htmlDigest,
            formattingLoadState: hasFormatting ? .unloaded : .full,
            imageDigest: imageDigest,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            assetPath: assetPath,
            filePaths: filePaths,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: byteSize,
            isFavorite: isFavorite,
            tags: tags,
            searchText: "",
            copyCount: copyCount,
            linkPreviewDetails: linkPreviewDetails,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            tagOrders: tagOrders.filter { tags.contains($0.key) },
            sensitivity: sensitivity,
            expiresAt: expiresAt,
            deletedAt: deletedAt,
            isContentLoaded: false,
            textPreview: textPreview,
            characterCount: characterCount,
            containsPreviewSecret: containsPreviewSecret,
            containsRestSecret: containsRestSecret,
            hasRecognizedText: hasRecognizedText,
            hasQRCodeText: hasQRCodeText,
            isSVGText: isSVGText,
            isCorruptPlaceholder: isCorruptPlaceholder,
            storedContentKey: storedContentKey,
            searchRevision: Self.nextSearchRevision()
        )
    }

    func unloadingContent() -> ClipboardItem {
        ClipboardItem(
            rawID: id,
            kind: kind,
            title: title,
            text: nil,
            qrCodeText: nil,
            rtfData: nil,
            html: nil,
            hasFormatting: hasFormatting,
            htmlDigest: htmlDigest,
            formattingLoadState: hasFormatting ? .unloaded : .full,
            imageDigest: imageDigest,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            assetPath: assetPath,
            filePaths: filePaths,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: byteSize,
            isFavorite: isFavorite,
            tags: tags,
            searchText: "",
            copyCount: copyCount,
            linkPreviewDetails: linkPreviewDetails,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            tagOrders: tagOrders,
            sensitivity: sensitivity,
            expiresAt: expiresAt,
            deletedAt: deletedAt,
            isContentLoaded: false,
            textPreview: textPreview,
            characterCount: characterCount,
            containsPreviewSecret: containsPreviewSecret,
            containsRestSecret: containsRestSecret,
            hasRecognizedText: hasRecognizedText,
            hasQRCodeText: hasQRCodeText,
            isSVGText: isSVGText,
            isCorruptPlaceholder: isCorruptPlaceholder,
            storedContentKey: storedContentKey,
            searchRevision: searchRevision
        )
    }

    func withLoadedContent(
        text: String?,
        qrCodeText: String?,
        html: String? = nil,
        rtfData: Data? = nil,
        scope: ClipboardContentScope = .full,
        tagNames: [String]? = nil,
        recomputesDerivedMetadata: Bool = true
    ) -> ClipboardItem {
        let resolvedHTML: String?
        let resolvedRTFData: Data?
        let resolvedHasFormatting: Bool
        let resolvedHTMLDigest: String?
        let resolvedFormattingLoadState: FormattingLoadState

        switch scope {
        case .body:
            resolvedHTML = self.html
            resolvedRTFData = self.rtfData
            resolvedHasFormatting = self.hasFormatting
            resolvedHTMLDigest = self.htmlDigest
            resolvedFormattingLoadState = self.formattingLoadState
        case .preview:
            resolvedRTFData = rtfData ?? self.rtfData
            resolvedHTML = html ?? self.html
            resolvedFormattingLoadState = (self.formattingLoadState == .full || resolvedHTML != nil)
                ? .full
                : .previewOnly
            resolvedHasFormatting = self.hasFormatting
            resolvedHTMLDigest = self.htmlDigest
        case .full:
            resolvedHTML = html
            resolvedRTFData = rtfData
            resolvedFormattingLoadState = .full
            resolvedHasFormatting = html != nil || rtfData != nil
            resolvedHTMLDigest = (html?.isEmpty == false)
                ? (self.htmlDigest ?? Self.digest(ofHTML: html))
                : nil
        }

        let resolvedSearchText: String
        if let tagNames {
            resolvedSearchText = Self.makeSearchText(
                title: title,
                text: text,
                filePaths: kind == .image ? [] : filePaths,
                tagNames: tagNames,
                sourceAppName: sourceAppName,
                linkPreviewDetails: linkPreviewDetails,
                qrCodeText: qrCodeText
            )
        } else {
            resolvedSearchText = self.searchText
        }

        var updated = ClipboardItem(
            rawID: id,
            kind: kind,
            title: title,
            text: text,
            qrCodeText: qrCodeText,
            rtfData: resolvedRTFData,
            html: resolvedHTML,
            hasFormatting: resolvedHasFormatting,
            htmlDigest: resolvedHTMLDigest,
            formattingLoadState: resolvedFormattingLoadState,
            imageDigest: imageDigest,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            assetPath: assetPath,
            filePaths: filePaths,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: byteSize,
            isFavorite: isFavorite,
            tags: tags,
            searchText: resolvedSearchText,
            copyCount: copyCount,
            linkPreviewDetails: linkPreviewDetails,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            tagOrders: tagOrders,
            sensitivity: sensitivity,
            expiresAt: expiresAt,
            deletedAt: deletedAt,
            isContentLoaded: true,
            textPreview: textPreview,
            characterCount: characterCount,
            containsPreviewSecret: containsPreviewSecret,
            containsRestSecret: containsRestSecret,
            hasRecognizedText: hasRecognizedText,
            hasQRCodeText: recomputesDerivedMetadata ? Self.computeHasNonWhitespaceText(qrCodeText) : hasQRCodeText,
            isSVGText: isSVGText,
            isCorruptPlaceholder: isCorruptPlaceholder,
            storedContentKey: storedContentKey,
            searchRevision: searchRevision
        )
        if recomputesDerivedMetadata {
            updated.syncDerivedMetadata(textModified: true, formattingModified: scope == .full)
        }
        return updated
    }

    private static func computeHasNonWhitespaceText(_ value: String?) -> Bool {
        value?.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) == true
    }

    private mutating func syncLoadedSecretFlags() {
        if !kind.canHoldSensitiveContent {
            containsPreviewSecret = false
        } else if (text?.isEmpty ?? true) && hasFormatting && !isFormattingLoaded {
            containsPreviewSecret = containsPreviewSecret || SensitiveContent.livePreviewSecretExists(in: self)
        } else {
            containsPreviewSecret = SensitiveContent.livePreviewSecretExists(in: self)
        }

        let bodySecret = SensitiveContent.detectsBodySecretAtRest(
            kind: kind,
            text: text,
            qrCodeText: qrCodeText,
            html: html,
            rtfData: rtfData
        )
        if hasFormatting && !isFormattingLoaded {
            containsRestSecret = containsRestSecret || bodySecret
        } else {
            containsRestSecret = bodySecret
        }
    }

    private mutating func syncDerivedMetadata(textModified: Bool, formattingModified: Bool) {
        if textModified {
            isContentLoaded = true
            textPreview = Self.makeTextPreview(from: text)
            characterCount = text?.count ?? 0
            hasRecognizedText = Self.computeHasNonWhitespaceText(text)
            isSVGText = (kind == .text || kind == .richText) && (text.map(SVGImageRenderer.isSVGMarkup) ?? false)
        }

        if isContentLoaded {
            syncLoadedSecretFlags()
        } else if formattingModified {
            let hasNonEmptyFormatting = !(html?.isEmpty ?? true) || !(rtfData?.isEmpty ?? true)
            if hasNonEmptyFormatting,
               SensitiveContent.detectsBodySecretAtRest(
                   kind: kind,
                   text: nil,
                   qrCodeText: nil,
                   html: html,
                   rtfData: rtfData
               ) {
                containsRestSecret = true
            }
            if !(html?.isEmpty ?? true),
               textPreview == nil,
               characterCount == 0,
               SensitiveContent.livePreviewSecretExists(in: self) {
                containsPreviewSecret = true
            }
        }
    }

    private mutating func syncDerivedMetadataForHeaderMutation() {
        if isContentLoaded {
            isSVGText = (kind == .text || kind == .richText) && (text.map(SVGImageRenderer.isSVGMarkup) ?? false)
            syncLoadedSecretFlags()
        } else {
            if kind != .text && kind != .richText {
                isSVGText = false
            }
            if !kind.canHoldSensitiveContent {
                containsPreviewSecret = false
            } else if characterCount == 0 && textPreview == nil && !hasFormatting && filePaths.isEmpty {
                containsPreviewSecret = SensitiveContent.livePreviewSecretExists(in: self)
            }
        }
    }

    private mutating func syncRestSecretForQRCodeMutation() {
        if isContentLoaded && (!hasFormatting || isFormattingLoaded) {
            containsRestSecret = SensitiveContent.detectsBodySecretAtRest(
                kind: kind,
                text: text,
                qrCodeText: qrCodeText,
                html: html,
                rtfData: rtfData
            )
        } else if SensitiveContent.detectsBodySecretAtRest(
            kind: kind,
            text: nil,
            qrCodeText: qrCodeText,
            html: nil,
            rtfData: nil
        ) {
            containsRestSecret = true
        }
    }

    /// Whether the item is kept for good whatever its content: the user
    /// starred or tagged it.
    var isKeptByUser: Bool {
        isFavorite || !tags.isEmpty
    }

    /// Whether this value holds the full formatting, rather than only knowing
    /// the store has some or holding preview-only RTF.
    var isFormattingLoaded: Bool {
        formattingLoadState == .full && (rtfData != nil || html != nil)
    }

    var isPreviewFormattingLoaded: Bool {
        !hasFormatting || formattingLoadState != .unloaded
    }

    /// Replaces the formatting, or removes it when both are nil.
    mutating func setFormatting(html: String?, rtfData: Data?) {
        self.html = html
        self.rtfData = rtfData
        formattingLoadState = .full
        hasFormatting = html != nil || rtfData != nil
        htmlDigest = Self.digest(ofHTML: html)
        storedContentKey = nil
        syncDerivedMetadata(textModified: false, formattingModified: true)
    }

    mutating func removeFormatting() {
        setFormatting(html: nil, rtfData: nil)
    }

    private static func digest(ofHTML html: String?) -> String? {
        guard let html, !html.isEmpty else {
            return nil
        }

        return ContentDigest.sha256(Data(html.utf8))
    }

    var itemTitle: String? {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var hasSourceApp: Bool {
        sourceBundleIdentifier != nil || sourceAppName != nil
    }

    var hasTextContent: Bool {
        isContentLoaded
            ? !(text?.isEmpty ?? true)
            : (characterCount > 0 || !(textPreview?.isEmpty ?? true))
    }

    @MainActor
    var displayTitle: String {
        if let itemTitle {
            return itemTitle
        }

        return contentTitle
    }

    @MainActor
    var contentTitle: String {
        if kind == .image {
            return imageDisplayTitle
        }

        switch kind {
        case .file:
            return filePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
        case .color:
            return (isContentLoaded ? text : textPreview) ?? "Color"
        default:
            return previewText.components(separatedBy: .newlines).first?.nilIfEmpty ?? kind.title
        }
    }

    @MainActor
    var previewText: String {
        rawPreviewText ?? kind.title
    }

    var scannablePreviewText: String {
        rawPreviewText ?? ""
    }

    private var rawPreviewText: String? {
        // Single-file image items store recognized OCR text in `text` for search,
        // while their preview text remains the file path.
        if kind == .file, !filePaths.isEmpty {
            return filePaths.joined(separator: "\n")
        }
        if let text, !text.isEmpty {
            return text
        }
        if !isContentLoaded, let textPreview, !textPreview.isEmpty {
            return textPreview
        }
        if let html, !html.isEmpty {
            return html
        }
        if !filePaths.isEmpty {
            return filePaths.joined(separator: "\n")
        }
        return title
    }

    var assetURL: URL? {
        assetPath.map(URL.init(fileURLWithPath:))
    }

    /// The files ClipBook stored for the item: its image and the pictures of
    /// its link preview. The files an item of copied files lists are the
    /// user's own and are not among them.
    var storedFilePaths: [String] {
        [assetPath, linkPreviewDetails?.imagePath, linkPreviewDetails?.faviconPath].compactMap { $0 }
    }

    var hasEncryptedImageAsset: Bool {
        kind == .image && assetPath?.lowercased().hasSuffix(".enc") == true
    }

    var hasUnverifiedEncryptedImageAsset: Bool {
        hasEncryptedImageAsset && sensitivity != .notSensitive
    }

    var quickLookURL: URL? {
        if hasEncryptedImageAsset {
            return nil
        }
        if let assetURL {
            return assetURL
        }
        return filePaths.first.map(URL.init(fileURLWithPath:))
    }

    var isMultipleFileItem: Bool {
        kind == .file && filePaths.count > 1
    }

    var isMissingSingleFileItem: Bool {
        kind == .file && filePaths.count == 1 && !FileManager.default.fileExists(atPath: filePaths[0])
    }

    var isImageFileItem: Bool {
        kind == .file && !filePaths.isEmpty && filePaths.allSatisfy { Self.isImageFile(at: $0) }
    }

    var firstFileIsImage: Bool {
        guard let filePath = filePaths.first else {
            return false
        }

        return Self.isImageFile(at: filePath)
    }

    var canCopyTextFromImage: Bool {
        guard !isMultipleFileItem,
              kind == .image || (kind == .file && firstFileIsImage) else {
            return false
        }
        if isContentLoaded {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !text.isEmpty
        }
        return hasRecognizedText
    }

    // The QR code is read from the same kinds of items the image text is read
    // from, so an image and an image file both offer it.
    var canCopyTextFromQRCode: Bool {
        guard !isMultipleFileItem,
              kind == .image || (kind == .file && firstFileIsImage) else {
            return false
        }
        if isContentLoaded {
            guard let qrCodeText = qrCodeText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !qrCodeText.isEmpty
        }
        return hasQRCodeText
    }

    var browserURL: URL? {
        guard kind == .link else {
            return nil
        }
        let candidate = isContentLoaded ? text : (hasCompleteTextPreview ? textPreview : nil)
        guard let candidate else {
            return nil
        }

        return Self.linkURL(from: candidate)
    }

    // The one address a text holds, if that is all it holds. A URL carries no
    // whitespace of its own, and the parser percent-encodes spaces, tabs and
    // newlines rather than rejecting them, so a list of addresses written one
    // per line would otherwise be read as a single link to the first host.
    static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let disallowedCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: disallowedCharacters) == nil,
              let url = URL(string: trimmed),
              url.scheme != nil,
              url.host != nil else {
            return nil
        }

        return url
    }

    var contentKeyComponents: (canonicalContent: String, htmlDigest: String?) {
        if kind == .link, let browserURL {
            return (Self.normalizedLinkContentKey(for: browserURL), nil)
        }

        if kind == .file, !filePaths.isEmpty {
            return (Self.normalizedFileContentKey(for: filePaths), nil)
        }

        // An image is told apart by the bytes of its file, so copying the same
        // image again counts on the item it already has. An image stored before
        // images had a digest is told apart by its file.
        if kind == .image, let imageKey = imageDigest ?? assetPath {
            return (imageKey, nil)
        }

        // Formatting is not searchable, but it still tells two copies of the
        // same text apart, so a differently styled copy stays its own item.
        // The digest stands in for the HTML, which is usually not loaded.
        return (text ?? "", htmlDigest)
    }

    /// What tells two captures of the same content apart. It is built from the
    /// content alone, never from the search text: the search text also carries
    /// the source app, tag names and link preview details, which the store
    /// adds to an item once it is in the history. A key that included them
    /// would change after the first match, and the next copy of the same
    /// content would start a second item instead of counting on the first.
    var contentKey: String {
        let components = contentKeyComponents
        if let htmlDigest = components.htmlDigest {
            return components.canonicalContent + "\n" + htmlDigest
        }
        return components.canonicalContent
    }

    /// Whether the two items hold the same content, as their `contentKey`
    /// tells, without building the key of a text item for the comparison.
    func hasSameContent(as other: ClipboardItem) -> Bool {
        guard kind == other.kind else {
            return false
        }

        if let storedContentKey, let otherStoredContentKey = other.storedContentKey {
            return storedContentKey == otherStoredContentKey
        }

        if isContentLoaded && other.isContentLoaded {
            switch kind {
            case .link, .file, .image:
                return contentKey == other.contentKey
            default:
                return htmlDigest == other.htmlDigest && (text ?? "") == (other.text ?? "")
            }
        }

        switch kind {
        case .link:
            guard let lhsURL = browserURL, let rhsURL = other.browserURL else {
                return id == other.id
            }
            return Self.normalizedLinkContentKey(for: lhsURL) == Self.normalizedLinkContentKey(for: rhsURL)
        case .file:
            let lhsKey = Self.normalizedFileContentKey(for: filePaths)
            let rhsKey = Self.normalizedFileContentKey(for: other.filePaths)
            guard !lhsKey.isEmpty, !rhsKey.isEmpty else {
                return id == other.id
            }
            return lhsKey == rhsKey
        case .image:
            guard let lhsKey = imageDigest ?? assetPath,
                  let rhsKey = other.imageDigest ?? other.assetPath else {
                return id == other.id
            }
            return lhsKey == rhsKey
        default:
            guard htmlDigest == other.htmlDigest,
                  characterCount == other.characterCount else {
                return false
            }
            guard hasCompleteTextPreview && other.hasCompleteTextPreview else {
                return id == other.id
            }
            let lhsText = isContentLoaded ? (text ?? "") : (textPreview ?? "")
            let rhsText = other.isContentLoaded ? (other.text ?? "") : (other.textPreview ?? "")
            return lhsText == rhsText
        }
    }

    nonisolated static func pixelDimensions(of imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    var imageDimensions: (width: Int, height: Int)? {
        guard kind == .image else {
            return nil
        }
        if let imageWidth, let imageHeight {
            return (imageWidth, imageHeight)
        }
        guard let assetURL else {
            return nil
        }
        if hasEncryptedImageAsset {
            guard let data = try? ImageAssetStore.readAssetData(
                at: assetURL,
                role: .image,
                ownerClipID: id,
                requiresEncryption: SensitiveContent.requiresEncryptedAsset(for: self, role: .image)
            ) else {
                return nil
            }
            return Self.pixelDimensions(of: data)
        }
        guard let source = CGImageSourceCreateWithURL(assetURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }

        return (width, height)
    }

    private var imageDisplayTitle: String {
        guard let imageDimensions else {
            return "Image"
        }

        return "Image (\(imageDimensions.width)x\(imageDimensions.height))"
    }

    static func isImageFile(at filePath: String) -> Bool {
        let fileURL = URL(fileURLWithPath: filePath)

        // Prefer the extension-based check because it does not touch the disk,
        // which matters when filtering the whole history.
        let pathExtension = fileURL.pathExtension
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
            return type.conforms(to: .image)
        }

        guard let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }

        return type.conforms(to: .image)
    }

    func rebuildingSearchText(tagNames: [String]) -> ClipboardItem {
        var updated = self
        updated.searchRevision = Self.nextSearchRevision()
        if isContentLoaded {
            updated.searchText = Self.makeSearchText(
                title: title,
                text: text,
                filePaths: kind == .image ? [] : filePaths,
                tagNames: tagNames,
                sourceAppName: sourceAppName,
                linkPreviewDetails: linkPreviewDetails,
                qrCodeText: qrCodeText
            )
        } else {
            updated.searchText = ""
        }
        return updated
    }

    nonisolated func headerFallbackSearchText(tagNamesByID: [Tag.ID: String]) -> String {
        Self.makeSearchText(
            title: title,
            text: textPreview,
            filePaths: kind == .image ? [] : filePaths,
            tagNames: tags.compactMap { tagNamesByID[$0] },
            sourceAppName: sourceAppName,
            linkPreviewDetails: linkPreviewDetails
        )
    }

    /// Only the plain text of an item is searchable. The HTML of a rich text
    /// item is left out on purpose: its markup would match queries the user
    /// cannot see in the item.
    static func makeSearchText(
        title: String?,
        text: String?,
        filePaths: [String],
        tagNames: [String],
        sourceAppName: String?,
        linkPreviewDetails: LinkPreviewDetails? = nil,
        qrCodeText: String? = nil
    ) -> String {
        [
            title,
            text,
            qrCodeText,
            linkPreviewDetails?.title,
            linkPreviewDetails?.description,
            filePaths.joined(separator: " "),
            tagNames.joined(separator: " "),
            sourceAppName
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func normalizedLinkContentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func normalizedFileContentKey(for filePaths: [String]) -> String {
        filePaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .joined(separator: "\n")
    }
}
