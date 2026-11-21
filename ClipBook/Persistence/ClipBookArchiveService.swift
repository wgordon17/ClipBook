import CryptoKit
import Darwin
import Foundation
import Security

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

nonisolated final class ClipBookArchiveService: Sendable {
    static let plainFormatVersion = 1
    static let encryptedFormatVersion = 2

    let supportDirectory: URL
    let kdfIterations: Int
    let allowTestIterations: Bool

    nonisolated enum MissingFileBehavior: Sendable {
        case returnNil
        case throwMissingFile
        case throwCorruptedArchive
    }

    nonisolated struct ArchiveEncryptionContext: Sendable {
        let archiveID: UUID
        let keys: ClipBookArchiveDerivedKeys
        let manifestDigest: Data
    }

    nonisolated struct ImportedAssetPayload: Sendable {
        let bytes: Data
        let preferredExtension: String?
    }

    private nonisolated struct ExportedAssetReference: Sendable {
        let relativePath: String
        let plainExtension: String?
    }

    private nonisolated struct BackedUpFile: Sendable {
        let originalURL: URL
        let backupURL: URL
    }

    private nonisolated struct PendingExportEncryption: Sendable {
        let archiveID: UUID
        let salt: Data
        let keys: ClipBookArchiveDerivedKeys
    }

    init(
        supportDirectory: URL,
        kdfIterations: Int = HistoryCrypto.productionKDFIterations,
        allowTestIterations: Bool = false
    ) {
        self.supportDirectory = supportDirectory
        self.kdfIterations = kdfIterations
        self.allowTestIterations = allowTestIterations
    }

    func inspect(at archiveURL: URL) throws -> ClipBookArchiveInspection {
        let (manifest, _) = try readValidatedManifest(at: archiveURL)
        return ClipBookArchiveInspection(
            formatVersion: manifest.formatVersion,
            isEncrypted: manifest.formatVersion == Self.encryptedFormatVersion
        )
    }

    func verifyPassphrase(_ passphrase: String, at archiveURL: URL) throws {
        let (manifest, _) = try readValidatedManifest(at: archiveURL)
        guard manifest.formatVersion == Self.encryptedFormatVersion,
              let encryption = manifest.encryption else {
            throw ClipBookArchiveError.corruptedEncryptedArchive("manifest.json")
        }

        _ = try validateAndDeriveArchiveKeys(encryption: encryption, passphrase: passphrase)
    }

    func export(
        items: [ClipboardItem],
        tags: [Tag],
        to archiveURL: URL,
        passphrase: String? = nil,
        loadItem: (ClipboardItem) throws -> ClipboardItem = { $0 },
        progress: ((ClipBookArchiveProgress) -> Void)? = nil
    ) throws {
        let encoder = Self.makeEncoder()
        let pendingEncryption = try deriveExportEncryptionKeys(for: passphrase)

        let destinationParent = archiveURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let stagingRoot = try Self.makeStagingRoot(
            appropriateFor: destinationParent,
            archiveName: archiveURL.lastPathComponent
        )
        defer {
            Self.secureRemoveDirectoryTree(at: stagingRoot)
        }

        let stagedArchiveURL = stagingRoot.appendingPathComponent(archiveURL.lastPathComponent, isDirectory: true)
        let assetsDirectory = stagedArchiveURL.appendingPathComponent("assets", isDirectory: true)
        let imagesDirectory = assetsDirectory.appendingPathComponent("images", isDirectory: true)
        let linkPreviewsDirectory = assetsDirectory.appendingPathComponent("link-previews", isDirectory: true)
        try Self.createPrivateDirectory(at: stagedArchiveURL)
        try Self.createPrivateDirectory(at: assetsDirectory)
        try Self.createPrivateDirectory(at: imagesDirectory)
        try Self.createPrivateDirectory(at: linkPreviewsDirectory)

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let exportedAt = Date()
        let encryptionContext = try writeEncryptedManifestIfNeeded(
            pendingEncryption: pendingEncryption,
            appVersion: appVersion,
            exportedAt: exportedAt,
            to: stagedArchiveURL,
            encoder: encoder
        )

        let archiveTags = tags.map { tag in
            ClipBookArchiveTag(id: String(tag.id), name: tag.name, color: tag.color)
        }
        var exportSession = ArchiveExportSession(
            service: self,
            tagNamesByID: Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) }),
            imagesDirectory: imagesDirectory,
            linkPreviewsDirectory: linkPreviewsDirectory,
            encryptionContext: encryptionContext
        )

        progress?(ClipBookArchiveProgress(completedItemCount: 0, totalItemCount: items.count))
        var archiveItems: [ClipBookArchiveItem] = []
        archiveItems.reserveCapacity(items.count)

        for rawItem in items {
            let exportedItem = try autoreleasepool { () throws -> ClipBookArchiveItem in
                let hydrated = (!rawItem.isContentLoaded || (rawItem.hasFormatting && !rawItem.isFormattingLoaded))
                    ? try loadItem(rawItem)
                    : rawItem
                return try exportSession.makeArchiveItem(from: hydrated)
            }
            archiveItems.append(exportedItem)
            progress?(ClipBookArchiveProgress(completedItemCount: archiveItems.count, totalItemCount: items.count))
        }

        try Self.writeArchiveMetadataFiles(
            tags: archiveTags,
            items: archiveItems,
            expectedAssets: exportSession.expectedAssets,
            appVersion: appVersion,
            exportedAt: exportedAt,
            encryptionContext: encryptionContext,
            to: stagedArchiveURL,
            encoder: encoder
        )

        try Self.swapStagedArchive(at: stagedArchiveURL, into: archiveURL)
    }

    func `import`(
        from archiveURL: URL,
        into historyStore: any HistoryStore,
        passphrase: String? = nil,
        progress: ((ClipBookArchiveProgress) -> Void)? = nil
    ) throws -> ClipBookArchiveImportResult {
        let fileManager = FileManager.default
        let (archiveTags, archiveItems, encryptionContext) = try loadArchiveContents(
            from: archiveURL,
            passphrase: passphrase
        )

        progress?(ClipBookArchiveProgress(completedItemCount: 0, totalItemCount: archiveItems.count))

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let rollbackDirectory = supportDirectory.appendingPathComponent(
            ".import-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try Self.createPrivateDirectory(at: rollbackDirectory)
        defer {
            Self.secureRemoveDirectoryTree(at: rollbackDirectory)
        }

        var importSession = ArchiveImportSession(
            service: self,
            archiveURL: archiveURL,
            historyStore: historyStore,
            encryptionContext: encryptionContext,
            rollbackDirectory: rollbackDirectory,
            existingImagesByStem: Self.indexExistingFilesByLowercaseStem(
                in: supportDirectory.appendingPathComponent("Images", isDirectory: true)
            ),
            existingPreviewsByStem: Self.indexExistingFilesByLowercaseStem(
                in: supportDirectory.appendingPathComponent("LinkPreviews", isDirectory: true)
            )
        )

        var importedItemIDs: Set<ClipboardItem.ID> = []
        var importedItemCount = 0

        do {
            try historyStore.performInTransaction {
                for archiveTag in archiveTags {
                    let tag = try historyStore.createTag(name: archiveTag.name, color: archiveTag.color)
                    importSession.tagIDsByArchiveID[archiveTag.id] = tag.id
                    importSession.tagNamesByID[tag.id] = tag.name
                }

                for archiveItem in archiveItems {
                    let item = try autoreleasepool { () throws -> ClipboardItem in
                        try importSession.makeClipboardItem(from: archiveItem)
                    }
                    try historyStore.upsert(item)
                    importedItemIDs.insert(item.id)
                    importedItemCount += 1
                    progress?(ClipBookArchiveProgress(completedItemCount: importedItemCount, totalItemCount: archiveItems.count))
                }

                try historyStore.restoreFromTrash(ids: Array(importedItemIDs))
            }
        } catch {
            importSession.rollbackStagedFiles(using: fileManager)
            throw error
        }

        return ClipBookArchiveImportResult(itemIDs: importedItemIDs, tagCount: archiveTags.count)
    }

    // MARK: - Export Coordination Helpers

    private func deriveExportEncryptionKeys(for passphrase: String?) throws -> PendingExportEncryption? {
        guard let passphrase else {
            return nil
        }
        let nfcPassphrase = passphrase.precomposedStringWithCanonicalMapping
        guard !nfcPassphrase.isEmpty else {
            throw ClipBookArchiveError.emptyPassphrase
        }
        var saltBytes = [UInt8](repeating: 0, count: HistoryCrypto.archiveSaltByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw ClipBookArchiveError.invalidKeyParameters
        }
        let salt = Data(saltBytes)
        let archiveID = UUID()
        do {
            let archiveKeys = try HistoryCrypto.deriveArchiveKeys(
                passphrase: nfcPassphrase,
                salt: salt,
                iterations: kdfIterations,
                archiveID: archiveID,
                allowTestIterations: allowTestIterations
            )
            return PendingExportEncryption(archiveID: archiveID, salt: salt, keys: archiveKeys)
        } catch HistoryStoreError.invalidArchiveKeyParameters {
            throw ClipBookArchiveError.invalidKeyParameters
        }
    }

    private func writeEncryptedManifestIfNeeded(
        pendingEncryption: PendingExportEncryption?,
        appVersion: String?,
        exportedAt: Date,
        to stagedArchiveURL: URL,
        encoder: JSONEncoder
    ) throws -> ArchiveEncryptionContext? {
        guard let pendingEncryption else {
            return nil
        }
        let verifier = HistoryCrypto.makeArchiveKeyVerifier(
            verifierKey: pendingEncryption.keys.verifierHMACKey,
            archiveID: pendingEncryption.archiveID
        )
        let metadata = ClipBookArchiveEncryptionMetadata(
            archiveID: pendingEncryption.archiveID,
            iterations: kdfIterations,
            saltBase64: pendingEncryption.salt.base64EncodedString(),
            keyVerifierBase64: verifier.base64EncodedString()
        )
        let manifest = ClipBookArchiveManifest(
            formatVersion: Self.encryptedFormatVersion,
            appName: "ClipBook",
            appVersion: appVersion,
            exportedAt: exportedAt,
            encryption: metadata
        )
        let rawManifestBytes = try encoder.encode(manifest)
        try Self.writePrivateFile(
            rawManifestBytes,
            to: stagedArchiveURL.appendingPathComponent("manifest.json", isDirectory: false)
        )
        return ArchiveEncryptionContext(
            archiveID: pendingEncryption.archiveID,
            keys: pendingEncryption.keys,
            manifestDigest: Data(SHA256.hash(data: rawManifestBytes))
        )
    }

    private static func writeArchiveMetadataFiles(
        tags: [ClipBookArchiveTag],
        items: [ClipBookArchiveItem],
        expectedAssets: [String: String],
        appVersion: String?,
        exportedAt: Date,
        encryptionContext: ArchiveEncryptionContext?,
        to stagedArchiveURL: URL,
        encoder: JSONEncoder
    ) throws {
        if let encryptionContext {
            let sealedTags = try HistoryCrypto.sealArchiveEntry(
                try encoder.encode(tags),
                key: encryptionContext.keys.aeadKey,
                archiveID: encryptionContext.archiveID,
                manifestDigest: encryptionContext.manifestDigest,
                relativePath: "tags.json.enc"
            )
            try writePrivateFile(
                sealedTags,
                to: stagedArchiveURL.appendingPathComponent("tags.json.enc", isDirectory: false)
            )

            let payload = ClipBookEncryptedHistoryPayload(items: items, expectedAssets: expectedAssets)
            let sealedHistory = try HistoryCrypto.sealArchiveEntry(
                try encoder.encode(payload),
                key: encryptionContext.keys.aeadKey,
                archiveID: encryptionContext.archiveID,
                manifestDigest: encryptionContext.manifestDigest,
                relativePath: "history.json.enc"
            )
            try writePrivateFile(
                sealedHistory,
                to: stagedArchiveURL.appendingPathComponent("history.json.enc", isDirectory: false),
                sync: true
            )
        } else {
            let manifest = ClipBookArchiveManifest(
                formatVersion: plainFormatVersion,
                appName: "ClipBook",
                appVersion: appVersion,
                exportedAt: exportedAt,
                encryption: nil
            )
            try writePrivateFile(
                try encoder.encode(manifest),
                to: stagedArchiveURL.appendingPathComponent("manifest.json", isDirectory: false)
            )
            try writePrivateFile(
                try encoder.encode(tags),
                to: stagedArchiveURL.appendingPathComponent("tags.json", isDirectory: false)
            )
            try writePrivateFile(
                try encoder.encode(items),
                to: stagedArchiveURL.appendingPathComponent("history.json", isDirectory: false),
                sync: true
            )
        }
    }

    private func loadArchiveContents(
        from archiveURL: URL,
        passphrase: String?
    ) throws -> (tags: [ClipBookArchiveTag], items: [ClipBookArchiveItem], encryptionContext: ArchiveEncryptionContext?) {
        let decoder = Self.makeDecoder()
        let (manifest, rawManifestBytes) = try readValidatedManifest(at: archiveURL)

        if manifest.formatVersion == Self.encryptedFormatVersion {
            guard let encryption = manifest.encryption else {
                throw ClipBookArchiveError.corruptedEncryptedArchive("manifest.json")
            }

            let archiveKeys = try validateAndDeriveArchiveKeys(encryption: encryption, passphrase: passphrase)
            let context = ArchiveEncryptionContext(
                archiveID: encryption.archiveID,
                keys: archiveKeys,
                manifestDigest: Data(SHA256.hash(data: rawManifestBytes))
            )

            let archiveTags = try readAndOpenEncryptedJSON(
                [ClipBookArchiveTag].self,
                in: archiveURL,
                relativePath: "tags.json.enc",
                context: context,
                decoder: decoder
            )
            let encryptedHistory = try readAndOpenEncryptedJSON(
                ClipBookEncryptedHistoryPayload.self,
                in: archiveURL,
                relativePath: "history.json.enc",
                context: context,
                decoder: decoder
            )
            try verifyExpectedAssetsInventory(
                expectedAssets: encryptedHistory.expectedAssets,
                items: encryptedHistory.items,
                in: archiveURL
            )
            return (archiveTags, encryptedHistory.items, context)
        }

        guard let tagsURL = try validateContainedRegularFile(
            in: archiveURL,
            relativePath: "tags.json",
            missingBehavior: .throwMissingFile
        ) else {
            throw ClipBookArchiveError.missingFile("tags.json")
        }
        guard let historyURL = try validateContainedRegularFile(
            in: archiveURL,
            relativePath: "history.json",
            missingBehavior: .throwMissingFile
        ) else {
            throw ClipBookArchiveError.missingFile("history.json")
        }

        let tagsData = try Self.readRegularFileNoFollow(at: tagsURL, relativePath: "tags.json")
        let historyData = try Self.readRegularFileNoFollow(at: historyURL, relativePath: "history.json")
        let archiveTags = try decoder.decode([ClipBookArchiveTag].self, from: tagsData)
        let archiveItems = try decoder.decode([ClipBookArchiveItem].self, from: historyData)
        return (archiveTags, archiveItems, nil)
    }

    // MARK: - Export Session

    private nonisolated struct ArchiveExportSession {
        let service: ClipBookArchiveService
        let tagNamesByID: [Tag.ID: String]
        let imagesDirectory: URL
        let linkPreviewsDirectory: URL
        let encryptionContext: ArchiveEncryptionContext?
        var expectedAssets: [String: String] = [:]
        var usedPlainFileNames: Set<String> = []

        mutating func makeArchiveItem(from item: ClipboardItem) throws -> ClipBookArchiveItem {
            let exportedImage = try exportSourceAsset(
                at: item.assetPath,
                role: .image,
                ownerClipID: item.id,
                requiresEncryption: SensitiveContent.requiresEncryptedAsset(for: item, role: .image),
                defaultStem: item.id.uuidString
            )

            let archivePreviewDetails: ClipBookArchiveLinkPreviewDetails?
            if let linkPreviewDetails = item.linkPreviewDetails {
                let exportedPreviewImage = try exportSourceAsset(
                    at: linkPreviewDetails.imagePath,
                    role: .linkPreview,
                    ownerClipID: item.id,
                    requiresEncryption: SensitiveContent.requiresEncryptedAsset(for: item, role: .linkPreview),
                    defaultStem: "\(item.id.uuidString)-preview"
                )
                let exportedFavicon = try exportSourceAsset(
                    at: linkPreviewDetails.faviconPath,
                    role: .linkFavicon,
                    ownerClipID: item.id,
                    requiresEncryption: SensitiveContent.requiresEncryptedAsset(for: item, role: .linkFavicon),
                    defaultStem: "\(item.id.uuidString)-favicon"
                )
                archivePreviewDetails = ClipBookArchiveLinkPreviewDetails(
                    url: linkPreviewDetails.url,
                    title: linkPreviewDetails.title,
                    description: linkPreviewDetails.description,
                    imagePath: exportedPreviewImage?.relativePath,
                    faviconPath: exportedFavicon?.relativePath,
                    fetchedAt: linkPreviewDetails.fetchedAt,
                    imageExtension: encryptionContext != nil ? exportedPreviewImage?.plainExtension : nil,
                    faviconExtension: encryptionContext != nil ? exportedFavicon?.plainExtension : nil
                )
            } else {
                archivePreviewDetails = nil
            }

            return ClipBookArchiveItem(
                id: item.id,
                kind: item.kind.rawValue,
                title: item.title,
                text: item.text,
                qrCodeText: item.qrCodeText,
                rtfBase64: item.rtfData?.base64EncodedString(),
                html: item.html,
                assetPath: exportedImage?.relativePath,
                assetExtension: encryptionContext != nil ? exportedImage?.plainExtension : nil,
                filePaths: item.filePaths,
                sourceAppName: item.sourceAppName,
                sourceBundleIdentifier: item.sourceBundleIdentifier,
                copiedAt: item.copiedAt,
                firstCopiedAt: item.firstCopiedAt,
                byteSize: item.byteSize,
                isFavorite: item.isFavorite,
                tagIDs: item.tags.map(String.init),
                tagNames: item.tags.compactMap { tagNamesByID[$0] },
                copyCount: item.copyCount,
                linkPreviewDetails: archivePreviewDetails,
                copySequenceID: item.copySequenceID,
                copySequenceOrder: item.copySequenceOrder,
                favoriteOrder: item.favoriteOrder,
                tagOrders: item.tagOrders.isEmpty
                    ? nil
                    : Dictionary(uniqueKeysWithValues: item.tagOrders.map { (String($0.key), $0.value) }),
                sensitivity: item.sensitivity?.rawValue
            )
        }

        mutating func exportSourceAsset(
            at path: String?,
            role: AssetRole,
            ownerClipID: UUID,
            requiresEncryption: Bool,
            defaultStem: String
        ) throws -> ExportedAssetReference? {
            guard let sourceURL = try service.validateManagedExportSourceURL(at: path, role: role) else {
                return nil
            }

            let rawBytes = try ImageAssetStore.readAssetData(
                at: sourceURL,
                role: role,
                ownerClipID: ownerClipID,
                requiresEncryption: requiresEncryption
            )
            let sanitizedExtension = ImageAssetStore.plainAssetExtension(
                preferred: sourceURL.pathExtension,
                magicBytes: rawBytes
            )
            let destination = destinationLocation(for: role)

            if let encryptionContext {
                return try writeEncryptedAsset(
                    rawBytes,
                    defaultStem: defaultStem,
                    sanitizedExtension: sanitizedExtension,
                    destinationDirectory: destination.directory,
                    archiveSubdirectory: destination.subdirectory,
                    context: encryptionContext
                )
            }

            return try writePlainAsset(
                rawBytes,
                sourceURL: sourceURL,
                defaultStem: defaultStem,
                sanitizedExtension: sanitizedExtension,
                destinationDirectory: destination.directory,
                archiveSubdirectory: destination.subdirectory
            )
        }

        private func destinationLocation(for role: AssetRole) -> (directory: URL, subdirectory: String) {
            switch role {
            case .image:
                (imagesDirectory, "images")
            case .linkPreview, .linkFavicon:
                (linkPreviewsDirectory, "link-previews")
            }
        }

        private mutating func writeEncryptedAsset(
            _ rawBytes: Data,
            defaultStem: String,
            sanitizedExtension: String,
            destinationDirectory: URL,
            archiveSubdirectory: String,
            context: ArchiveEncryptionContext
        ) throws -> ExportedAssetReference {
            let fileName = "\(defaultStem).enc"
            let relativePath = "assets/\(archiveSubdirectory)/\(fileName)"
            let sealedBytes = try HistoryCrypto.sealArchiveEntry(
                rawBytes,
                key: context.keys.aeadKey,
                archiveID: context.archiveID,
                manifestDigest: context.manifestDigest,
                relativePath: relativePath
            )
            let destinationURL = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
            try ClipBookArchiveService.writePrivateFile(sealedBytes, to: destinationURL)
            expectedAssets[relativePath] = ContentDigest.sha256(sealedBytes)
            return ExportedAssetReference(relativePath: relativePath, plainExtension: sanitizedExtension)
        }

        private mutating func writePlainAsset(
            _ rawBytes: Data,
            sourceURL: URL,
            defaultStem: String,
            sanitizedExtension: String,
            destinationDirectory: URL,
            archiveSubdirectory: String
        ) throws -> ExportedAssetReference {
            let baseStem = sourceURL.deletingPathExtension().lastPathComponent.nilIfEmpty ?? defaultStem
            var fileName = "\(baseStem).\(sanitizedExtension)"
            var disambiguator = 1
            while usedPlainFileNames.contains("\(archiveSubdirectory)/\(fileName)".lowercased()) {
                fileName = "\(baseStem)-\(disambiguator).\(sanitizedExtension)"
                disambiguator += 1
            }
            usedPlainFileNames.insert("\(archiveSubdirectory)/\(fileName)".lowercased())
            let relativePath = "assets/\(archiveSubdirectory)/\(fileName)"
            let destinationURL = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
            try ClipBookArchiveService.writePrivateFile(rawBytes, to: destinationURL)
            return ExportedAssetReference(relativePath: relativePath, plainExtension: nil)
        }
    }

    // MARK: - Import Session

    private nonisolated struct ArchiveImportSession {
        let service: ClipBookArchiveService
        let archiveURL: URL
        let historyStore: any HistoryStore
        let encryptionContext: ArchiveEncryptionContext?
        var tagIDsByArchiveID: [String: Tag.ID] = [:]
        var tagNamesByID: [Tag.ID: String] = [:]
        let rollbackDirectory: URL
        let existingImagesByStem: [String: [URL]]
        let existingPreviewsByStem: [String: [URL]]
        var backedUpRoles: Set<String> = []
        var backedUpFiles: [BackedUpFile] = []
        var writtenFilesByRoleKey: [String: URL] = [:]

        mutating func makeClipboardItem(from archiveItem: ClipBookArchiveItem) throws -> ClipboardItem {
            let payloads = try readPayloads(for: archiveItem)
            var provisionalCandidate = buildProvisionalItem(from: archiveItem, imagePayload: payloads.image)
            let shouldEncrypt = SensitiveContent.shouldEncryptAtRest(provisionalCandidate)

            provisionalCandidate.assetPath = try stageAsset(
                payload: payloads.image,
                role: .image,
                itemID: archiveItem.id,
                stem: archiveItem.id.uuidString,
                shouldEncrypt: shouldEncrypt
            )

            let stagedPreviewPath = try stageAsset(
                payload: payloads.previewImage,
                role: .linkPreview,
                itemID: archiveItem.id,
                stem: "\(archiveItem.id.uuidString)-preview",
                shouldEncrypt: shouldEncrypt
            )
            let stagedFaviconPath = try stageAsset(
                payload: payloads.favicon,
                role: .linkFavicon,
                itemID: archiveItem.id,
                stem: "\(archiveItem.id.uuidString)-favicon",
                shouldEncrypt: shouldEncrypt
            )
            if let details = archiveItem.linkPreviewDetails {
                provisionalCandidate.linkPreviewDetails = LinkPreviewDetails(
                    url: details.url,
                    title: details.title,
                    description: details.description,
                    imagePath: stagedPreviewPath,
                    faviconPath: stagedFaviconPath,
                    fetchedAt: details.fetchedAt
                )
            }

            return provisionalCandidate
        }

        mutating func stageAsset(
            payload: ImportedAssetPayload?,
            role: AssetRole,
            itemID: UUID,
            stem: String,
            shouldEncrypt: Bool
        ) throws -> String? {
            let fileManager = FileManager.default
            let roleKey = "\(role.rawValue):\(itemID.uuidString.lowercased())"
            let existingFilesByStem = (role == .image) ? existingImagesByStem : existingPreviewsByStem

            if backedUpRoles.insert(roleKey).inserted {
                if let existingURLs = existingFilesByStem[stem.lowercased()] {
                    for existingURL in existingURLs where fileManager.fileExists(atPath: existingURL.path) {
                        let backupURL = rollbackDirectory.appendingPathComponent(
                            "\(UUID().uuidString)-\(existingURL.lastPathComponent)",
                            isDirectory: false
                        )
                        try fileManager.moveItem(at: existingURL, to: backupURL)
                        backedUpFiles.append(BackedUpFile(originalURL: existingURL, backupURL: backupURL))
                    }
                }
            } else if let previouslyWrittenURL = writtenFilesByRoleKey.removeValue(forKey: roleKey) {
                ImageAssetStore.secureUnlink(at: previouslyWrittenURL)
            }

            guard let payload else {
                return nil
            }

            let writtenURL: URL
            if shouldEncrypt {
                writtenURL = try historyStore.writeManagedAsset(
                    pngData: payload.bytes,
                    role: role,
                    clipID: itemID,
                    encrypted: true
                )
            } else {
                let ext = ImageAssetStore.plainAssetExtension(
                    preferred: payload.preferredExtension,
                    magicBytes: payload.bytes
                )
                writtenURL = try historyStore.writeManagedAsset(
                    pngData: payload.bytes,
                    role: role,
                    clipID: itemID,
                    encrypted: false,
                    preferredPlainExtension: ext
                )
            }
            writtenFilesByRoleKey[roleKey] = writtenURL
            return writtenURL.path
        }

        func rollbackStagedFiles(using fileManager: FileManager) {
            for writtenURL in writtenFilesByRoleKey.values {
                ImageAssetStore.secureUnlink(at: writtenURL)
            }
            for backedUp in backedUpFiles.reversed() {
                if fileManager.fileExists(atPath: backedUp.originalURL.path) {
                    ImageAssetStore.secureUnlink(at: backedUp.originalURL)
                }
                try? fileManager.moveItem(at: backedUp.backupURL, to: backedUp.originalURL)
            }
        }

        private func readPayloads(
            for archiveItem: ClipBookArchiveItem
        ) throws -> (image: ImportedAssetPayload?, previewImage: ImportedAssetPayload?, favicon: ImportedAssetPayload?) {
            let imagePayload = try service.readArchiveAssetPayload(
                relativePath: archiveItem.assetPath,
                preferredExtension: archiveItem.assetExtension,
                in: archiveURL,
                encryptionContext: encryptionContext
            )
            guard let details = archiveItem.linkPreviewDetails else {
                return (imagePayload, nil, nil)
            }
            let previewImagePayload = try service.readArchiveAssetPayload(
                relativePath: details.imagePath,
                preferredExtension: details.imageExtension,
                in: archiveURL,
                encryptionContext: encryptionContext
            )
            let faviconPayload = try service.readArchiveAssetPayload(
                relativePath: details.faviconPath,
                preferredExtension: details.faviconExtension,
                in: archiveURL,
                encryptionContext: encryptionContext
            )
            return (imagePayload, previewImagePayload, faviconPayload)
        }

        private func buildProvisionalItem(
            from archiveItem: ClipBookArchiveItem,
            imagePayload: ImportedAssetPayload?
        ) -> ClipboardItem {
            let tagIDs = archiveItem.tagIDs.compactMap { tagIDsByArchiveID[$0] }
            var tagOrders: [Tag.ID: Int] = [:]
            for (archiveTagID, order) in archiveItem.tagOrders ?? [:] {
                if let tagID = tagIDsByArchiveID[archiveTagID] {
                    tagOrders[tagID] = order
                }
            }
            let tagNames = tagIDs.compactMap { tagNamesByID[$0] }
            let kind = ClipboardKind(rawValue: archiveItem.kind) ?? .text
            let rtfData = archiveItem.rtfBase64.flatMap { Data(base64Encoded: $0) }
            let sensitivity = archiveItem.sensitivity.flatMap(ItemSensitivity.init(rawValue:))

            let provisionalPreviewDetails = archiveItem.linkPreviewDetails.map { details in
                LinkPreviewDetails(
                    url: details.url,
                    title: details.title,
                    description: details.description,
                    imagePath: nil,
                    faviconPath: nil,
                    fetchedAt: details.fetchedAt
                )
            }

            let imageDimensions = (kind == .image) ? imagePayload.flatMap { ClipboardItem.pixelDimensions(of: $0.bytes) } : nil
            let imageDigest = (kind == .image) ? imagePayload.map { historyStore.computeImageDigest(forPNGData: $0.bytes) } : nil
            let searchText = ClipboardItem.makeSearchText(
                title: archiveItem.title,
                text: archiveItem.text,
                filePaths: archiveItem.filePaths,
                tagNames: tagNames,
                sourceAppName: archiveItem.sourceAppName,
                linkPreviewDetails: provisionalPreviewDetails,
                qrCodeText: archiveItem.qrCodeText
            )

            return ClipboardItem(
                id: archiveItem.id,
                kind: kind,
                title: archiveItem.title,
                text: archiveItem.text,
                qrCodeText: archiveItem.qrCodeText,
                rtfData: rtfData,
                html: archiveItem.html,
                assetPath: nil,
                imageDigest: imageDigest,
                imageWidth: imageDimensions?.width,
                imageHeight: imageDimensions?.height,
                filePaths: archiveItem.filePaths,
                sourceAppName: archiveItem.sourceAppName,
                sourceBundleIdentifier: archiveItem.sourceBundleIdentifier,
                copiedAt: archiveItem.copiedAt,
                firstCopiedAt: archiveItem.firstCopiedAt,
                byteSize: archiveItem.byteSize,
                isFavorite: archiveItem.isFavorite,
                tags: tagIDs,
                searchText: searchText,
                copyCount: archiveItem.copyCount,
                linkPreviewDetails: provisionalPreviewDetails,
                copySequenceID: archiveItem.copySequenceID,
                copySequenceOrder: archiveItem.copySequenceOrder,
                favoriteOrder: archiveItem.favoriteOrder,
                tagOrders: tagOrders,
                sensitivity: sensitivity
            )
        }
    }

    // MARK: - Manifest & Encryption Validation

    func readValidatedManifest(
        at archiveURL: URL
    ) throws -> (manifest: ClipBookArchiveManifest, rawBytes: Data) {
        guard let manifestURL = try validateContainedRegularFile(
            in: archiveURL,
            relativePath: "manifest.json",
            missingBehavior: .throwMissingFile
        ) else {
            throw ClipBookArchiveError.missingFile("manifest.json")
        }

        let rawBytes = try Self.readRegularFileNoFollow(at: manifestURL, relativePath: "manifest.json")
        let manifest = try Self.makeDecoder().decode(ClipBookArchiveManifest.self, from: rawBytes)
        guard (Self.plainFormatVersion...Self.encryptedFormatVersion).contains(manifest.formatVersion) else {
            throw ClipBookArchiveError.unsupportedVersion(manifest.formatVersion)
        }

        let expectsEncryption = (manifest.formatVersion == Self.encryptedFormatVersion)
        guard (manifest.encryption != nil) == expectsEncryption else {
            throw ClipBookArchiveError.corruptedEncryptedArchive("manifest.json")
        }

        return (manifest, rawBytes)
    }

    func validateEncryptionParameters(
        _ encryption: ClipBookArchiveEncryptionMetadata
    ) throws -> Data {
        let minIterations = allowTestIterations
            ? HistoryCrypto.minimumTestKDFIterations
            : HistoryCrypto.minimumProductionKDFIterations
        guard encryption.kdf == "PBKDF2-HMAC-SHA256",
              encryption.algorithm == "AES-256-GCM",
              let salt = Data(base64Encoded: encryption.saltBase64),
              salt.count == HistoryCrypto.archiveSaltByteCount,
              (minIterations...HistoryCrypto.maximumKDFIterations).contains(encryption.iterations) else {
            throw ClipBookArchiveError.invalidKeyParameters
        }
        return salt
    }

    func validateAndDeriveArchiveKeys(
        encryption: ClipBookArchiveEncryptionMetadata,
        passphrase: String?
    ) throws -> ClipBookArchiveDerivedKeys {
        let salt = try validateEncryptionParameters(encryption)
        guard let verifier = Data(base64Encoded: encryption.keyVerifierBase64),
              verifier.count == SHA256.byteCount else {
            throw ClipBookArchiveError.corruptedEncryptedArchive("manifest.json")
        }

        guard let passphrase else {
            throw ClipBookArchiveError.passphraseRequired
        }
        let nfcPassphrase = passphrase.precomposedStringWithCanonicalMapping
        guard !nfcPassphrase.isEmpty else {
            throw ClipBookArchiveError.emptyPassphrase
        }

        let archiveKeys: ClipBookArchiveDerivedKeys
        do {
            archiveKeys = try HistoryCrypto.deriveArchiveKeys(
                passphrase: nfcPassphrase,
                salt: salt,
                iterations: encryption.iterations,
                archiveID: encryption.archiveID,
                allowTestIterations: allowTestIterations
            )
        } catch HistoryStoreError.invalidArchiveKeyParameters {
            throw ClipBookArchiveError.invalidKeyParameters
        }

        guard HistoryCrypto.verifyArchiveKeyVerifier(
            verifier,
            verifierKey: archiveKeys.verifierHMACKey,
            archiveID: encryption.archiveID
        ) else {
            throw ClipBookArchiveError.incorrectPassphrase
        }
        return archiveKeys
    }

    func readAndOpenEncryptedJSON<T: Decodable>(
        _ type: T.Type,
        in archiveURL: URL,
        relativePath: String,
        context: ArchiveEncryptionContext,
        decoder: JSONDecoder
    ) throws -> T {
        guard let fileURL = try validateContainedRegularFile(
            in: archiveURL,
            relativePath: relativePath,
            missingBehavior: .throwMissingFile
        ) else {
            throw ClipBookArchiveError.missingFile(relativePath)
        }
        let sealedBytes = try Self.readRegularFileNoFollow(at: fileURL, relativePath: relativePath)
        let decryptedBytes: Data
        do {
            decryptedBytes = try HistoryCrypto.openArchiveEntry(
                sealedBytes,
                key: context.keys.aeadKey,
                archiveID: context.archiveID,
                manifestDigest: context.manifestDigest,
                relativePath: relativePath
            )
            return try decoder.decode(type, from: decryptedBytes)
        } catch {
            throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
        }
    }

    func readArchiveAssetPayload(
        relativePath: String?,
        preferredExtension: String?,
        in archiveURL: URL,
        encryptionContext: ArchiveEncryptionContext?
    ) throws -> ImportedAssetPayload? {
        guard let relativePath, !relativePath.isEmpty else {
            return nil
        }

        if let encryptionContext {
            guard let sourceURL = try validateContainedRegularFile(
                in: archiveURL,
                relativePath: relativePath,
                missingBehavior: .throwCorruptedArchive
            ) else {
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
            let sealedBytes = try Self.readRegularFileNoFollow(at: sourceURL, relativePath: relativePath)
            let decryptedBytes: Data
            do {
                decryptedBytes = try HistoryCrypto.openArchiveEntry(
                    sealedBytes,
                    key: encryptionContext.keys.aeadKey,
                    archiveID: encryptionContext.archiveID,
                    manifestDigest: encryptionContext.manifestDigest,
                    relativePath: relativePath
                )
            } catch {
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
            return ImportedAssetPayload(bytes: decryptedBytes, preferredExtension: preferredExtension)
        } else {
            guard let sourceURL = try validateContainedRegularFile(
                in: archiveURL,
                relativePath: relativePath,
                missingBehavior: .returnNil
            ) else {
                return nil
            }
            let rawBytes = try Self.readRegularFileNoFollow(at: sourceURL, relativePath: relativePath)
            let ext = URL(fileURLWithPath: relativePath).pathExtension
            return ImportedAssetPayload(bytes: rawBytes, preferredExtension: ext)
        }
    }

    func verifyExpectedAssetsInventory(
        expectedAssets: [String: String],
        items: [ClipBookArchiveItem],
        in archiveURL: URL
    ) throws {
        var referencedPaths = Set<String>()
        for item in items {
            if let assetPath = item.assetPath, !assetPath.isEmpty {
                referencedPaths.insert(assetPath)
            }
            if let details = item.linkPreviewDetails {
                if let imagePath = details.imagePath, !imagePath.isEmpty {
                    referencedPaths.insert(imagePath)
                }
                if let faviconPath = details.faviconPath, !faviconPath.isEmpty {
                    referencedPaths.insert(faviconPath)
                }
            }
        }

        guard Set(expectedAssets.keys) == referencedPaths else {
            throw ClipBookArchiveError.corruptedEncryptedArchive("expectedAssets")
        }

        for (relativePath, expectedHex) in expectedAssets {
            guard Self.isValidLowercaseSHA256Hex(expectedHex) else {
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
            guard let fileURL = try validateContainedRegularFile(
                in: archiveURL,
                relativePath: relativePath,
                missingBehavior: .throwCorruptedArchive
            ) else {
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
            let actualHex = try Self.sha256HexNoFollow(at: fileURL, relativePath: relativePath)
            guard actualHex == expectedHex else {
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
        }
    }

    // MARK: - Containment & Symlink Validation

    func validateManagedExportSourceURL(
        at path: String?,
        role: AssetRole
    ) throws -> URL? {
        guard let path, !path.isEmpty else {
            return nil
        }

        guard !path.hasSuffix("/") else {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }
        let rawSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        if rawSegments.contains(where: { $0 == "." || $0 == ".." }) {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        let expectedSubdirName = (role == .image) ? "Images" : "LinkPreviews"
        let expectedParentDir = supportDirectory.appendingPathComponent(expectedSubdirName, isDirectory: true)

        var expectedDirStat = stat()
        if Darwin.lstat(expectedParentDir.path, &expectedDirStat) == 0,
           (expectedDirStat.st_mode & S_IFMT) != S_IFDIR {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        let sourceURL = URL(fileURLWithPath: path, isDirectory: false)
        let sourceParentURL = sourceURL.deletingLastPathComponent()

        var parentStat = stat()
        if Darwin.lstat(sourceParentURL.path, &parentStat) == 0,
           (parentStat.st_mode & S_IFMT) != S_IFDIR {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        var sourceStat = stat()
        let sourceLstatResult = Darwin.lstat(sourceURL.path, &sourceStat)
        let sourceLstatErrno = errno
        if sourceLstatResult == 0, (sourceStat.st_mode & S_IFMT) == S_IFLNK {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        let canonicalSupportDir = ImageAssetStore.canonicalDirectoryURL(supportDirectory)
        let canonicalExpectedParent = canonicalSupportDir
            .appendingPathComponent(expectedSubdirName, isDirectory: true)
            .standardizedFileURL
        let canonicalActualParent = ImageAssetStore.canonicalDirectoryURL(sourceParentURL)
        guard canonicalActualParent == canonicalExpectedParent else {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        if sourceLstatResult != 0 {
            if sourceLstatErrno == ENOENT, !FileManager.default.fileExists(atPath: sourceURL.path) {
                return nil
            }
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw ClipBookArchiveError.invalidAssetPath(path)
        }

        return sourceURL
    }

    func validateContainedRegularFile(
        in archiveURL: URL,
        relativePath: String,
        missingBehavior: MissingFileBehavior
    ) throws -> URL? {
        let rawComponents = try Self.splitValidatedRelativeComponents(relativePath)

        var archiveRootStat = stat()
        if Darwin.lstat(archiveURL.path, &archiveRootStat) == 0,
           (archiveRootStat.st_mode & S_IFMT) == S_IFLNK {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }

        var currentDirectoryURL = URL(fileURLWithPath: archiveURL.path, isDirectory: true)
        var targetURL = URL(fileURLWithPath: archiveURL.path, isDirectory: false)

        for (index, rawComponent) in rawComponents.enumerated() {
            let component = String(rawComponent)
            let isLeaf = (index == rawComponents.count - 1)
            let candidateURL = currentDirectoryURL.appendingPathComponent(component, isDirectory: false)

            var componentStat = stat()
            if Darwin.lstat(candidateURL.path, &componentStat) == 0 {
                let mode = componentStat.st_mode & S_IFMT
                if isLeaf ? mode != S_IFREG : mode != S_IFDIR {
                    throw ClipBookArchiveError.invalidAssetPath(relativePath)
                }
            } else if errno != ENOENT && errno != ENOTDIR {
                throw ClipBookArchiveError.invalidAssetPath(relativePath)
            }

            if isLeaf {
                targetURL = candidateURL
            } else {
                currentDirectoryURL = currentDirectoryURL.appendingPathComponent(component, isDirectory: true)
            }
        }

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            switch missingBehavior {
            case .returnNil:
                return nil
            case .throwMissingFile:
                throw ClipBookArchiveError.missingFile(relativePath)
            case .throwCorruptedArchive:
                throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
            }
        }

        let canonicalArchiveRoot = archiveURL.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalArchivePrefix = canonicalArchiveRoot.hasSuffix("/")
            ? canonicalArchiveRoot
            : (canonicalArchiveRoot + "/")
        let resolvedTargetURL = targetURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTargetURL.path.hasPrefix(canonicalArchivePrefix) else {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }

        return resolvedTargetURL
    }

    static func splitValidatedRelativeComponents(_ relativePath: String) throws -> [Substring] {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }

        let rawComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }
        for component in rawComponents {
            if component.isEmpty || component == "." || component == ".." {
                throw ClipBookArchiveError.invalidAssetPath(relativePath)
            }
        }
        return rawComponents
    }

    // MARK: - Low-Level Filesystem & Formatting Utilities

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeStagingRoot(appropriateFor destinationParent: URL, archiveName: String) throws -> URL {
        let fileManager = FileManager.default
        if let replacementDir = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationParent,
            create: true
        ) {
            _ = Darwin.chmod(replacementDir.path, mode_t(0o700))
            return replacementDir
        }

        let fallbackURL = destinationParent.appendingPathComponent(
            ".\(archiveName).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        try createPrivateDirectory(at: fallbackURL)
        return fallbackURL
    }

    static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        _ = Darwin.chmod(url.path, mode_t(0o700))
    }

    static func writePrivateFile(_ data: Data, to destinationURL: URL, sync: Bool = false) throws {
        try ImageAssetStore.writeExclusivePrivateFile(data, to: destinationURL, sync: sync)
    }

    static func swapStagedArchive(at stagedArchiveURL: URL, into archiveURL: URL) throws {
        var existingStat = stat()
        let targetExists = Darwin.lstat(archiveURL.path, &existingStat) == 0
        if targetExists && (existingStat.st_mode & S_IFMT) == S_IFLNK {
            throw ClipBookArchiveError.invalidAssetPath(archiveURL.path)
        }

        let fileManager = FileManager.default
        if targetExists || fileManager.fileExists(atPath: archiveURL.path) {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: stagedArchiveURL)
        } else {
            try fileManager.moveItem(at: stagedArchiveURL, to: archiveURL)
        }
        _ = Darwin.chmod(archiveURL.path, mode_t(0o700))
    }

    static func secureRemoveDirectoryTree(at rootURL: URL) {
        ImageAssetStore.secureRemoveItem(at: rootURL)
    }

    static func readRegularFileNoFollow(at url: URL, relativePath: String) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw ClipBookArchiveError.invalidAssetPath(relativePath)
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }

        var data = Data()
        data.reserveCapacity(max(0, Int(clamping: fileStat.st_size)))

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while true {
                let bytesRead = Darwin.read(fd, baseAddress, chunkSize)
                if bytesRead > 0 {
                    data.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: bytesRead)
                } else if bytesRead == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return data
    }

    static func sha256HexNoFollow(at url: URL, relativePath: String) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw ClipBookArchiveError.invalidAssetPath(relativePath)
            }
            throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw ClipBookArchiveError.invalidAssetPath(relativePath)
        }

        var hasher = SHA256()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while true {
                let bytesRead = Darwin.read(fd, baseAddress, chunkSize)
                if bytesRead > 0 {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: baseAddress, count: bytesRead))
                } else if bytesRead == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    throw ClipBookArchiveError.corruptedEncryptedArchive(relativePath)
                }
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidLowercaseSHA256Hex(_ hex: String) -> Bool {
        guard hex.utf8.count == 64 else {
            return false
        }
        return hex.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func indexExistingFilesByLowercaseStem(in directoryURL: URL) -> [String: [URL]] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return [:]
        }

        var map: [String: [URL]] = [:]
        for entry in entries {
            let stem = entry.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty {
                map[stem, default: []].append(entry)
            }
        }
        return map
    }
}
