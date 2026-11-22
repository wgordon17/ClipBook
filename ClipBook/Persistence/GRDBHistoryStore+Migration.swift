import Darwin
import Foundation
import GRDB

nonisolated extension GRDBHistoryStore {
    // MARK: - Two-Phase Clean-Room v0-v4 -> v5 Migrator

    private nonisolated struct LegacyStringTagsEnvelope: Decodable {
        var tags: [String]?
    }

    private nonisolated struct LegacyClipSchemaFlags {
        let legacyVersion: Int
        let hasDeletedAt: Bool
        let hasExpiresAt: Bool
        let hasHTML: Bool
        let hasRTF: Bool

        init(in legacyDB: Database, legacyVersion: Int) throws {
            let clipColumns = Set(try legacyDB.columns(in: AEADTable.clips).map(\.name))
            self.legacyVersion = legacyVersion
            self.hasDeletedAt = clipColumns.contains("deletedAt")
            self.hasExpiresAt = clipColumns.contains("expiresAt")
            self.hasHTML = clipColumns.contains("html")
            self.hasRTF = clipColumns.contains("rtf")
        }
    }

    private nonisolated final class LegacyMigrationContext {
        var validTagIDs: Set<Int> = []
        var tagIDsByLowercaseName: [String: Int] = [:]
        var stagedEncURLs: [URL] = []
        var candidateLegacySensitiveSourceURLs: Set<URL> = []
        var nonSensitiveReferencedCanonicalURLs: Set<URL> = []

        var unsharedSensitiveLegacyURLs: Set<URL> {
            candidateLegacySensitiveSourceURLs.subtracting(nonSensitiveReferencedCanonicalURLs)
        }
    }

    func migrateLegacyDatabaseToV5(keys: ClipBookDerivedKeys) throws {
        removeMigratingArtifacts()
        let unsharedSensitiveLegacyURLs = try buildAndVerifyMigratingV5Database(keys: keys)
        try cutOverAndScrubMigratedDatabase(unsharedSensitiveLegacyURLs: unsharedSensitiveLegacyURLs)
    }

    private func buildAndVerifyMigratingV5Database(keys: ClipBookDerivedKeys) throws -> Set<URL> {
        let context = LegacyMigrationContext()
        var legacyQueue: DatabaseQueue?
        var migratingQueue: DatabaseQueue?

        do {
            let openedLegacy = try openLegacySourceDatabaseForMigration()
            legacyQueue = openedLegacy

            let openedMigrating = try createMigratingDatabaseQueue()
            migratingQueue = openedMigrating
            try initializeMigratingV5Schema(in: openedMigrating)

            try populateMigratingDatabase(
                from: openedLegacy,
                into: openedMigrating,
                context: context,
                keys: keys
            )

            // Commit key_verifier_v1 and user_version = 5 only after all migrated rows succeed.
            try finalizeMigratingDatabaseMetadata(in: openedMigrating, keys: keys)

            try openedMigrating.close()
            migratingQueue = nil
            try openedLegacy.close()
            legacyQueue = nil

            if !context.stagedEncURLs.isEmpty {
                ImageAssetStore.fullFsyncBatch(context.stagedEncURLs)
            }
            try Self.fullFsyncFile(at: migratingURL)
            return context.unsharedSensitiveLegacyURLs
        } catch {
            try? migratingQueue?.close()
            try? legacyQueue?.close()
            removeMigratingArtifacts()
            for stagedURL in context.stagedEncURLs {
                ImageAssetStore.secureUnlink(at: stagedURL)
            }
            throw error
        }
    }

    private func openLegacySourceDatabaseForMigration() throws -> DatabaseQueue {
        var legacyConfig = Configuration()
        legacyConfig.foreignKeysEnabled = false
        legacyConfig.busyMode = .timeout(Self.databaseBusyTimeoutSeconds)
        legacyConfig.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                """)
        }

        let openedLegacy = try DatabaseQueue(path: databaseURL.path, configuration: legacyConfig)
        openedLegacy.writeWithoutTransaction { db in
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        }
        return openedLegacy
    }

    private func createMigratingDatabaseQueue() throws -> DatabaseQueue {
        // Create 0o600 History.v5.migrating.sqlite with journal_mode = DELETE & auto_vacuum = INCREMENTAL.
        let fd = Darwin.open(migratingURL.path, O_CREAT | O_RDWR | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw HistoryStoreError.migrationFailed("Unable to create History.v5.migrating.sqlite (errno \(errno))")
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        _ = Darwin.close(fd)

        var migratingConfig = Configuration()
        migratingConfig.foreignKeysEnabled = true
        migratingConfig.busyMode = .timeout(Self.databaseBusyTimeoutSeconds)
        migratingConfig.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                PRAGMA secure_delete = ON;
                """)
        }
        return try DatabaseQueue(path: migratingURL.path, configuration: migratingConfig)
    }

    private func initializeMigratingV5Schema(in migratingQueue: DatabaseQueue) throws {
        try migratingQueue.writeWithoutTransaction { migDB in
            try migDB.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL;")
            _ = try String.fetchOne(migDB, sql: "PRAGMA journal_mode = DELETE;")
            try migDB.inTransaction(.immediate) {
                try Self.createV5Schema(in: migDB)
                return .commit
            }
        }
    }

    private func populateMigratingDatabase(
        from legacyQueue: DatabaseQueue,
        into migratingQueue: DatabaseQueue,
        context: LegacyMigrationContext,
        keys: ClipBookDerivedKeys
    ) throws {
        try legacyQueue.read { legacyDB in
            let legacyVersion = (try Int.fetchOne(legacyDB, sql: "PRAGMA user_version")) ?? 0
            try Self.migrateLegacyTags(from: legacyDB, into: migratingQueue, context: context)

            guard try legacyDB.tableExists(AEADTable.clips) else {
                return
            }

            let schemaFlags = try LegacyClipSchemaFlags(in: legacyDB, legacyVersion: legacyVersion)
            try self.migrateLegacyClipBatches(
                from: legacyDB,
                into: migratingQueue,
                schemaFlags: schemaFlags,
                context: context,
                keys: keys
            )
        }
    }

    private static func migrateLegacyTags(
        from legacyDB: Database,
        into migratingQueue: DatabaseQueue,
        context: LegacyMigrationContext
    ) throws {
        guard try legacyDB.tableExists("tags") else {
            return
        }
        let legacyTags = try Row.fetchAll(legacyDB, sql: "SELECT id, name, color FROM tags ORDER BY id ASC")
        try migratingQueue.inTransaction(.immediate) { migDB in
            for tagRow in legacyTags {
                guard let tagID: Int = tagRow["id"],
                      let name: String = tagRow["name"],
                      let color: String = tagRow["color"] else {
                    continue
                }
                try migDB.execute(
                    sql: "INSERT OR IGNORE INTO tags (id, name, color) VALUES (?, ?, ?)",
                    arguments: [tagID, name, color]
                )
                if let actualID = try Int.fetchOne(
                    migDB,
                    sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE LIMIT 1",
                    arguments: [name]
                ) {
                    context.validTagIDs.insert(actualID)
                    context.tagIDsByLowercaseName[name.lowercased()] = actualID
                }
            }
            return .commit
        }
    }

    private func migrateLegacyClipBatches(
        from legacyDB: Database,
        into migratingQueue: DatabaseQueue,
        schemaFlags: LegacyClipSchemaFlags,
        context: LegacyMigrationContext,
        keys: ClipBookDerivedKeys
    ) throws {
        let cursor = try Row.fetchCursor(legacyDB, sql: "SELECT * FROM clips")
        var reachedEnd = false

        while !reachedEnd {
            try autoreleasepool {
                let decoder = Self.makeJSONDecoder()
                let encoder = Self.makeJSONEncoder()

                var batchRows: [Row] = []
                batchRows.reserveCapacity(Self.migrationBatchSize)
                while batchRows.count < Self.migrationBatchSize {
                    guard let row = try cursor.next() else {
                        reachedEnd = true
                        break
                    }
                    batchRows.append(row.copy())
                }

                guard !batchRows.isEmpty else {
                    return
                }

                try migratingQueue.inTransaction(.immediate) { migDB in
                    for row in batchRows {
                        try self.migrateLegacyClipRow(
                            row,
                            in: migDB,
                            schemaFlags: schemaFlags,
                            context: context,
                            keys: keys,
                            decoder: decoder,
                            encoder: encoder
                        )
                    }
                    return .commit
                }
            }
        }
    }

    private func migrateLegacyClipRow(
        _ row: Row,
        in migDB: Database,
        schemaFlags: LegacyClipSchemaFlags,
        context: LegacyMigrationContext,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) throws {
        guard let payloadData: Data = row["payload"],
              var item = try? decoder.decode(ClipboardItem.self, from: payloadData) else {
            return
        }

        try Self.migrateLegacyV1StringTagsIfNeeded(
            from: payloadData,
            for: &item,
            legacyVersion: schemaFlags.legacyVersion,
            in: migDB,
            context: context,
            decoder: decoder
        )
        applyLegacyClipColumnOverridesAndImageMetadata(
            from: row,
            schemaFlags: schemaFlags,
            to: &item,
            keys: keys
        )
        try stageOrRecordMigratedClipAssets(
            for: &item,
            context: context,
            keys: keys
        )

        // Deduplicate and filter tags against validTagIDs while preserving tagOrders.
        let savedTagOrders = item.tagOrders
        var seenTags: Set<Int> = []
        let validOrderedTags = item.tags.filter { context.validTagIDs.contains($0) && seenTags.insert($0).inserted }
        item.tags = validOrderedTags
        item.tagOrders = savedTagOrders.filter { seenTags.contains($0.key) }

        let finalEncrypted = SensitiveContent.shouldEncryptAtRest(item)
        let parts = item.contentKeyComponents
        let hmacKey = HistoryCrypto.contentKey(
            kind: item.kind,
            canonicalContent: parts.canonicalContent,
            htmlDigest: parts.htmlDigest,
            keys: keys
        )

        try Self.writeClipRow(
            in: migDB,
            item: item,
            isEncrypted: finalEncrypted,
            contentKeyBlob: hmacKey,
            keys: keys,
            encoder: encoder
        )

        try Self.writeClipContentsRow(
            in: migDB,
            item: item,
            isEncrypted: finalEncrypted,
            preserved: .freshInsert,
            keys: keys
        )

        if !validOrderedTags.isEmpty {
            let insertTagStmt = try migDB.cachedStatement(
                sql: "INSERT OR IGNORE INTO clip_tags (clipId, tagId, sortOrder) VALUES (?, ?, ?)"
            )
            let idString = item.id.uuidString
            for tagID in validOrderedTags {
                try insertTagStmt.execute(arguments: [idString, tagID, item.tagOrders[tagID]])
            }
        }
    }

    private static func migrateLegacyV1StringTagsIfNeeded(
        from payloadData: Data,
        for item: inout ClipboardItem,
        legacyVersion: Int,
        in migDB: Database,
        context: LegacyMigrationContext,
        decoder: JSONDecoder
    ) throws {
        guard legacyVersion < 2,
              let envelope = try? decoder.decode(LegacyStringTagsEnvelope.self, from: payloadData),
              let legacyTagNames = envelope.tags,
              !legacyTagNames.isEmpty else {
            return
        }

        var mappedTagIDs: [Int] = []
        for rawTagName in legacyTagNames {
            let lookupKey = rawTagName.lowercased()
            if let existingID = context.tagIDsByLowercaseName[lookupKey] {
                mappedTagIDs.append(existingID)
            } else {
                try migDB.execute(
                    sql: "INSERT INTO tags (name, color) VALUES (?, ?)",
                    arguments: [rawTagName, defaultMigratedTagColor]
                )
                let createdID = Int(migDB.lastInsertedRowID)
                context.validTagIDs.insert(createdID)
                context.tagIDsByLowercaseName[lookupKey] = createdID
                mappedTagIDs.append(createdID)
            }
        }
        item.tags = mappedTagIDs
    }

    private func applyLegacyClipColumnOverridesAndImageMetadata(
        from row: Row,
        schemaFlags: LegacyClipSchemaFlags,
        to item: inout ClipboardItem,
        keys: ClipBookDerivedKeys
    ) {
        if let sqlCopiedAt: Double = row["copiedAt"] {
            item.copiedAt = Date(timeIntervalSince1970: sqlCopiedAt)
        }
        if schemaFlags.hasDeletedAt {
            item.deletedAt = (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        }
        if schemaFlags.hasExpiresAt, let sqlExpiresAt: Double = row["expiresAt"] {
            item.expiresAt = Date(timeIntervalSince1970: sqlExpiresAt)
        }

        let columnHTML: String? = schemaFlags.hasHTML ? row["html"] : nil
        let columnRTF: Data? = schemaFlags.hasRTF ? row["rtf"] : nil
        let resolvedHTML = columnHTML ?? item.html
        let resolvedRTF = columnRTF ?? item.rtfData
        if resolvedHTML != nil || resolvedRTF != nil {
            item.setFormatting(html: resolvedHTML, rtfData: resolvedRTF)
        }

        guard item.kind == .image, let imagePath = item.assetPath else {
            return
        }
        let imageURL = URL(fileURLWithPath: imagePath, isDirectory: false)
        guard let imageBytes = try? assetStore.readPNGData(
            at: imageURL,
            role: .image,
            clipID: item.id,
            keys: keys,
            requiresEncryption: false
        ) else {
            return
        }
        item.imageDigest = HistoryCrypto.imageDigest(forPNGData: imageBytes, keys: keys)
        if let dims = ClipboardItem.pixelDimensions(of: imageBytes) {
            item.imageWidth = dims.width
            item.imageHeight = dims.height
        }
    }

    private func stageOrRecordMigratedClipAssets(
        for item: inout ClipboardItem,
        context: LegacyMigrationContext,
        keys: ClipBookDerivedKeys
    ) throws {
        if SensitiveContent.shouldEncryptAtRest(item) {
            item.assetPath = try stageMigratedEncryptedAsset(
                sourcePath: item.assetPath,
                role: .image,
                clipID: item.id,
                keys: keys,
                context: context
            )
            if var details = item.linkPreviewDetails {
                details.imagePath = try stageMigratedEncryptedAsset(
                    sourcePath: details.imagePath,
                    role: .linkPreview,
                    clipID: item.id,
                    keys: keys,
                    context: context
                )
                details.faviconPath = try stageMigratedEncryptedAsset(
                    sourcePath: details.faviconPath,
                    role: .linkFavicon,
                    clipID: item.id,
                    keys: keys,
                    context: context
                )
                item.linkPreviewDetails = details
            }
            return
        }

        if let assetPath = item.assetPath {
            context.nonSensitiveReferencedCanonicalURLs.insert(
                ImageAssetStore.canonicalFileURL(URL(fileURLWithPath: assetPath, isDirectory: false))
            )
        }
        if let details = item.linkPreviewDetails {
            if let imagePath = details.imagePath {
                context.nonSensitiveReferencedCanonicalURLs.insert(
                    ImageAssetStore.canonicalFileURL(URL(fileURLWithPath: imagePath, isDirectory: false))
                )
            }
            if let faviconPath = details.faviconPath {
                context.nonSensitiveReferencedCanonicalURLs.insert(
                    ImageAssetStore.canonicalFileURL(URL(fileURLWithPath: faviconPath, isDirectory: false))
                )
            }
        }
    }

    private func finalizeMigratingDatabaseMetadata(
        in migratingQueue: DatabaseQueue,
        keys: ClipBookDerivedKeys
    ) throws {
        try migratingQueue.inTransaction(.immediate) { migDB in
            let verifier = HistoryCrypto.makeKeyVerifier(keys: keys)
            try migDB.execute(
                sql: "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?, ?)",
                arguments: [Self.keyVerifierMetadataKey, verifier]
            )
            try migDB.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion)")
            return .commit
        }
    }

    private func cutOverAndScrubMigratedDatabase(unsharedSensitiveLegacyURLs: Set<URL>) throws {
        // Atomically cut over History.sqlite and scrub legacy plaintext files.
        if Self.fileOrSymlinkExists(at: scrubbingDBURL) {
            unlinkOrScrubSupportEntry(at: scrubbingDBURL)
        }

        if Darwin.link(databaseURL.path, scrubbingDBURL.path) != 0 {
            let linkErr = errno
            if linkErr == ENOTSUP || linkErr == EXDEV || linkErr == EPERM {
                try Self.copyRegularFile0600(
                    from: databaseURL,
                    to: scrubbingDBURL,
                    fullFsync: true,
                    failureError: HistoryStoreError.migrationFailed(
                        "Unable to copy legacy database for scrubbing (errno \(linkErr))"
                    )
                )
            } else if linkErr != ENOENT {
                throw HistoryStoreError.migrationFailed("Unable to stage History.sqlite.scrubbing (errno \(linkErr))")
            }
        }

        if Self.fileOrSymlinkExists(at: walURL) {
            _ = Darwin.rename(walURL.path, scrubbingWALURL.path)
        }
        if Self.fileOrSymlinkExists(at: shmURL) {
            _ = Darwin.rename(shmURL.path, scrubbingSHMURL.path)
        }
        if Self.fileOrSymlinkExists(at: journalURL) {
            _ = Darwin.rename(journalURL.path, scrubbingJournalURL.path)
        }

        guard Darwin.rename(migratingURL.path, databaseURL.path) == 0 else {
            throw HistoryStoreError.migrationFailed("Unable to rename History.v5.migrating.sqlite into place (errno \(errno))")
        }

        for scrubURL in [scrubbingDBURL, scrubbingWALURL, scrubbingSHMURL, scrubbingJournalURL]
        where Self.fileOrSymlinkExists(at: scrubURL) {
            unlinkOrScrubSupportEntry(at: scrubURL)
        }

        for legacyURL in unsharedSensitiveLegacyURLs {
            ImageAssetStore.secureUnlink(at: legacyURL)
            cacheHooks.removeThumbnailsForPath(legacyURL.path)
        }
    }

    private func stageMigratedEncryptedAsset(
        sourcePath: String?,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys,
        context: LegacyMigrationContext
    ) throws -> String? {
        guard let sourcePath, !sourcePath.isEmpty else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: false)
        var linkStat = stat()
        guard Darwin.lstat(sourceURL.path, &linkStat) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let plainBytes: Data
        do {
            plainBytes = try assetStore.readPNGData(
                at: sourceURL,
                role: role,
                clipID: clipID,
                keys: keys,
                requiresEncryption: false
            )
        } catch {
            return nil
        }

        let stagedURL = try assetStore.writeAsset(
            pngData: plainBytes,
            role: role,
            clipID: clipID,
            encrypted: true,
            keys: keys,
            sync: false
        )
        context.stagedEncURLs.append(stagedURL)

        let canonicalSource = ImageAssetStore.canonicalFileURL(sourceURL)
        let canonicalStaged = ImageAssetStore.canonicalFileURL(stagedURL)
        if canonicalSource != canonicalStaged && assetStore.isManagedAssetURL(sourceURL) {
            context.candidateLegacySensitiveSourceURLs.insert(canonicalSource)
        }

        return stagedURL.path
    }

    private func removeMigratingArtifacts() {
        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: migratingURL.path + suffix, isDirectory: false)
            if Self.fileOrSymlinkExists(at: url) && !Self.sameInode(url, databaseURL) {
                ImageAssetStore.secureUnlink(at: url)
            }
        }
    }
}
