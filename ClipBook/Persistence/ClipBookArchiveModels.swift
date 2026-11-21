import Foundation

nonisolated struct ClipBookArchiveImportResult: Equatable, Sendable {
    var itemIDs: Set<ClipboardItem.ID>
    var tagCount: Int

    var itemCount: Int {
        itemIDs.count
    }
}

nonisolated struct ClipBookArchiveExportResult: Equatable, Sendable {
    var url: URL
    var itemCount: Int
    var tagCount: Int
}

nonisolated struct ClipBookArchiveProgress: Equatable, Sendable {
    var completedItemCount: Int
    var totalItemCount: Int
}

nonisolated struct ClipBookArchiveInspection: Equatable, Sendable {
    var formatVersion: Int
    var isEncrypted: Bool
}

nonisolated enum ClipBookArchiveError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case missingFile(String)
    case invalidAssetPath(String)
    case passphraseRequired
    case emptyPassphrase
    case incorrectPassphrase
    case corruptedEncryptedArchive(String)
    case invalidKeyParameters

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "ClipBook archive version \(version) is not supported."
        case .missingFile(let fileName):
            "The archive is missing \(fileName)."
        case .invalidAssetPath(let path):
            "The archive contains an invalid asset path: \(path)."
        case .passphraseRequired:
            "A passphrase is required to unlock this encrypted ClipBook archive."
        case .emptyPassphrase:
            "The archive passphrase cannot be empty."
        case .incorrectPassphrase:
            "The archive passphrase is incorrect."
        case .corruptedEncryptedArchive(let detail):
            "The encrypted ClipBook archive is damaged or was modified (\(detail))."
        case .invalidKeyParameters:
            "The archive encryption parameters are invalid or unsupported."
        }
    }
}

nonisolated struct ClipBookArchiveEncryptionMetadata: Codable, Equatable, Sendable {
    var archiveID: UUID
    var kdf: String = "PBKDF2-HMAC-SHA256"
    var algorithm: String = "AES-256-GCM"
    var iterations: Int
    var saltBase64: String
    var keyVerifierBase64: String
}

nonisolated struct ClipBookArchiveManifest: Codable, Equatable, Sendable {
    var formatVersion: Int
    var appName: String
    var appVersion: String?
    var exportedAt: Date
    var encryption: ClipBookArchiveEncryptionMetadata? = nil
}

nonisolated struct ClipBookArchiveTag: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var color: String
}

nonisolated struct ClipBookArchiveItem: Codable, Equatable, Sendable {
    var id: UUID
    var kind: String
    var title: String?
    var text: String?
    // Absent from archives written before QR codes were read, so the item is
    // imported without one rather than failing to decode.
    var qrCodeText: String?
    var rtfBase64: String?
    var html: String?
    var assetPath: String?
    var assetExtension: String? = nil
    var filePaths: [String]
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var copiedAt: Date
    var firstCopiedAt: Date
    var byteSize: Int
    var isFavorite: Bool
    var tagIDs: [String]
    var tagNames: [String]
    var copyCount: Int
    var linkPreviewDetails: ClipBookArchiveLinkPreviewDetails?
    var copySequenceID: Date?
    var copySequenceOrder: Int?
    // Absent from archives written before favorites could be arranged.
    var favoriteOrder: Int?
    // The item's place in each of its tags, by the tag's ID in the archive.
    // Absent from archives written before the items of a tag could be arranged.
    var tagOrders: [String: Int]?
    // Absent from archives written before items could be marked as sensitive.
    var sensitivity: String?
}

nonisolated struct ClipBookArchiveLinkPreviewDetails: Codable, Equatable, Sendable {
    var url: String
    var title: String?
    var description: String?
    var imagePath: String?
    var faviconPath: String?
    var fetchedAt: Date
    var imageExtension: String? = nil
    var faviconExtension: String? = nil
}

nonisolated struct ClipBookEncryptedHistoryPayload: Codable, Equatable, Sendable {
    var items: [ClipBookArchiveItem]
    var expectedAssets: [String: String]
}
