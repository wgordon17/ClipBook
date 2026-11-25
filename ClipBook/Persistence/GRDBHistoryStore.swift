import Darwin
import Foundation
import GRDB
import os

nonisolated final class GRDBHistoryStore: HistoryStore, Sendable {
    static let currentSchemaVersion = 5
    static let keyVerifierMetadataKey = "key_verifier_v1"
    static let cursorBatchSize = 512
    static let databaseBusyTimeoutSeconds: TimeInterval = 5.0
    static let defaultMigratedTagColor = "#3B85ED"
    static let walJournalSizeLimit = 4_194_304
    static let searchInClauseBatchLimit = 500
    static let searchInClauseChunkedMaxIDs = 25_000
    static let migrationBatchSize = 500
    static let dontSaveContentLifetime = 0

    enum LifecycleState: Equatable, Sendable {
        case open
        case closing
        case closed
    }

    struct StoreState: Sendable {
        var lifecycle: LifecycleState = .open
        var lockState: StoreLockState = .unlocked
        var openFailure: (any Error)? = nil
        var dbWriter: (any DatabaseWriter)? = nil
        var keys: ClipBookDerivedKeys? = nil
        var needsFreePageRelease: Bool = false
        var isFreePageReleaseScheduled: Bool = false

        var isReady: Bool {
            lifecycle == .open && lockState == .unlocked && dbWriter != nil && keys != nil
        }
    }

    struct TransactionAssetContext: Sendable {
        var newlyWrittenURLs: [URL] = []
        var supersededManagedURLs: [URL] = []
        var evictedThumbnailPaths: [String] = []
        var evictedSVGClipIDs: [UUID] = []
        var insertedSVGClipIDs: Set<UUID> = []
        var removedSVGClipIDs: Set<UUID> = []
        var purgeOwnerSVGRenderingsOnCommit: Bool = false
        var purgeSensitiveCachesOnCommit: Bool = false
    }

    enum DatabaseProbeState {
        case fresh
        case legacy(version: Int)
        case existingV5(verifier: Data)
    }

    let directory: URL
    let cacheHooks: HistoryStoreCacheHooks

    let instanceID = UUID()
    let keyProvider: any DatabaseKeyProvider
    let assetStore: ImageAssetStore
    let openLock = NSLock()
    let state = OSAllocatedUnfairLock<StoreState>(initialState: StoreState())
    let writeAssetContext = OSAllocatedUnfairLock<TransactionAssetContext>(initialState: TransactionAssetContext())
    let knownSVGClipIDs = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    let activeAccessGroup = DispatchGroup()

    var databaseURL: URL {
        directory.appendingPathComponent("History.sqlite", isDirectory: false)
    }

    var walURL: URL {
        directory.appendingPathComponent("History.sqlite-wal", isDirectory: false)
    }

    var shmURL: URL {
        directory.appendingPathComponent("History.sqlite-shm", isDirectory: false)
    }

    var journalURL: URL {
        directory.appendingPathComponent("History.sqlite-journal", isDirectory: false)
    }

    var migratingURL: URL {
        directory.appendingPathComponent("History.v5.migrating.sqlite", isDirectory: false)
    }

    var scrubbingDBURL: URL {
        directory.appendingPathComponent("History.sqlite.scrubbing", isDirectory: false)
    }

    var scrubbingWALURL: URL {
        directory.appendingPathComponent("History.sqlite-wal.scrubbing", isDirectory: false)
    }

    var scrubbingSHMURL: URL {
        directory.appendingPathComponent("History.sqlite-shm.scrubbing", isDirectory: false)
    }

    var scrubbingJournalURL: URL {
        directory.appendingPathComponent("History.sqlite-journal.scrubbing", isDirectory: false)
    }

    init(
        directory: URL,
        keyProvider: (any DatabaseKeyProvider)? = nil,
        cacheHooks: HistoryStoreCacheHooks = .live
    ) {
        self.directory = directory
        self.cacheHooks = cacheHooks
        self.assetStore = ImageAssetStore(supportDirectory: directory)

        if let keyProvider {
            self.keyProvider = keyProvider
        } else if RuntimeSigningEnvironment.isRunningTests {
            self.keyProvider = InMemoryDatabaseKeyProvider()
        } else if RuntimeSigningEnvironment.usesIsolatedDebugStorage {
            self.keyProvider = FileDatabaseKeyProvider(supportDirectory: directory)
        } else {
            self.keyProvider = SystemKeychainKeyProvider()
        }

        try? openIfNeeded(allowRetryFromFailure: false)
    }

    deinit {
        close()
    }

    var lockState: StoreLockState {
        state.withLock { $0.lockState }
    }

    var isOpen: Bool {
        state.withLock { $0.isReady }
    }

    func computeImageDigest(forPNGData pngData: Data) -> String {
        if let keys = state.withLock({ $0.lifecycle == .open && $0.lockState == .unlocked ? $0.keys : nil }) {
            return HistoryCrypto.imageDigest(forPNGData: pngData, keys: keys)
        }
        if (try? openIfNeeded(allowRetryFromFailure: false)) != nil,
           let keys = state.withLock({ $0.lifecycle == .open && $0.lockState == .unlocked ? $0.keys : nil }) {
            return HistoryCrypto.imageDigest(forPNGData: pngData, keys: keys)
        }
        return ContentDigest.sha256(pngData)
    }

    func writeManagedAsset(
        pngData: Data,
        role: AssetRole,
        clipID: UUID,
        encrypted: Bool,
        preferredPlainExtension: String? = nil,
        sync: Bool = true
    ) throws -> URL {
        let (_, keys) = try acquireAccess()
        defer {
            activeAccessGroup.leave()
        }
        return try assetStore.writeAsset(
            pngData: pngData,
            role: role,
            clipID: clipID,
            encrypted: encrypted,
            keys: keys,
            preferredPlainExtension: preferredPlainExtension,
            sync: sync
        )
    }

    func finalizeRecognizedImage(
        id: UUID,
        content: RecognizedImageContent,
        sensitiveContentLifetime: Int
    ) throws -> (updated: ClipboardItem?, previous: ClipboardItem?, isTrashed: Bool, purged: Bool) {
        try withWrite { db, keys in
            guard let existing = try self.fetchFullItemByID(
                in: db,
                id: id,
                keys: keys
            ) else {
                return (nil, nil, false, false)
            }

            let isTrashed = existing.deletedAt != nil
            var candidate = existing
            candidate.text = content.text
            candidate.qrCodeText = content.qrCodeText
            let tagNamesByID = Dictionary(
                uniqueKeysWithValues: try Self.fetchAllTags(in: db).map { ($0.id, $0.name) }
            )
            candidate = candidate.rebuildingSearchText(
                tagNames: candidate.tags.compactMap { tagNamesByID[$0] }
            )

            let shouldEncrypt = SensitiveContent.shouldEncryptAtRest(candidate)
            let hasDetectedOCRSecret = existing.sensitivity != .notSensitive
                && SensitiveContent.detectsBodySecretAtRest(
                    kind: candidate.kind,
                    text: content.text,
                    qrCodeText: content.qrCodeText,
                    html: nil
                )

            if (isTrashed && shouldEncrypt)
                || (hasDetectedOCRSecret && !existing.isKeptByUser && sensitiveContentLifetime == Self.dontSaveContentLifetime) {
                let deleteStmt = try db.cachedStatement(sql: "DELETE FROM clips WHERE id = ?")
                try deleteStmt.execute(arguments: [id.uuidString])
                self.markNeedsFreePageRelease()
                if let assetPath = existing.assetPath {
                    let assetURL = URL(fileURLWithPath: assetPath, isDirectory: false)
                    let superseded = self.assetStore.isManagedAssetURL(assetURL) ? assetURL : nil
                    self.recordSupersededAsset(supersededURL: superseded, evictedPath: assetPath)
                }
                self.recordSVGMembershipRemoval(id)
                self.writeAssetContext.withLock {
                    $0.purgeSensitiveCachesOnCommit = true
                }
                return (nil, existing.unloadingContent(), isTrashed, true)
            }

            if hasDetectedOCRSecret && !candidate.isKeptByUser && sensitiveContentLifetime > 0 {
                let ocrExpiry = existing.copiedAt.addingTimeInterval(TimeInterval(sensitiveContentLifetime))
                if let currentExpiry = candidate.expiresAt {
                    candidate.expiresAt = min(currentExpiry, ocrExpiry)
                } else {
                    candidate.expiresAt = ocrExpiry
                }
            }

            let saved = try self.persistUpsert(
                in: db,
                item: candidate,
                keys: keys,
                assetMode: .reconcileManagedAssets
            )

            return (saved.unloadingContent(), existing.unloadingContent(), isTrashed, false)
        }
    }

    // MARK: - HistoryStore Queries & Mutations

    private static let clipBatchSelectClause = "SELECT c.* FROM clips c"
    private static let clipBatchWithBodySelectClause =
        "SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText FROM clips c LEFT JOIN clip_contents cc ON cc.clipId = c.id"

    @discardableResult
    static func drainCursorInBatches(
        _ cursor: RowCursor,
        batchSize: Int = cursorBatchSize,
        isCancelled: () -> Bool = { false },
        _ body: (Row) throws -> Void
    ) throws -> Bool {
        var cancelled = false
        var reachedEnd = false
        while !reachedEnd && !cancelled {
            try autoreleasepool {
                var batchCount = 0
                while batchCount < batchSize {
                    guard let row = try cursor.next() else {
                        reachedEnd = true
                        break
                    }
                    batchCount += 1
                    try body(row)
                }
                if !reachedEnd && isCancelled() {
                    cancelled = true
                }
            }
        }
        return !cancelled
    }

    private func fetchBatchedCursorItems(
        in db: Database,
        whereAndOrderSQL: String,
        tagAttachments: [String: TagAttachment],
        hydratesBody: Bool = false,
        keys: ClipBookDerivedKeys,
        where isIncluded: (ClipboardItem) -> Bool = { _ in true }
    ) throws -> [ClipboardItem] {
        let selectClause = hydratesBody ? Self.clipBatchWithBodySelectClause : Self.clipBatchSelectClause
        let sql = "\(selectClause) \(whereAndOrderSQL)"
        let decoder = Self.makeJSONDecoder()
        let cursor = try Row.fetchCursor(db, sql: sql)
        var items: [ClipboardItem] = []
        try Self.drainCursorInBatches(cursor) { row in
            let idString: String? = row["id"]
            let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
            if let item = try self.decodeBatchRow(
                row,
                attachment: attachment,
                hydratesBody: hydratesBody,
                keys: keys,
                decoder: decoder
            ), isIncluded(item) {
                items.append(item)
            }
        }
        return items
    }

    private func decodeFetchedBatchRows(
        _ rows: [Row],
        tagAttachments: [String: TagAttachment],
        hydratesBody: Bool = false,
        keys: ClipBookDerivedKeys,
        where isIncluded: ((ClipboardItem) -> Bool)? = nil
    ) throws -> [ClipboardItem] {
        let decoder = Self.makeJSONDecoder()
        var items: [ClipboardItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            let idString: String? = row["id"]
            let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
            if let item = try decodeBatchRow(
                row,
                attachment: attachment,
                hydratesBody: hydratesBody,
                keys: keys,
                decoder: decoder
            ), isIncluded?(item) ?? true {
                items.append(item)
            }
        }
        return items
    }

    func fetchAll() throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: false)
            return try self.fetchBatchedCursorItems(
                in: db,
                whereAndOrderSQL: "WHERE c.deletedAt IS NULL ORDER BY c.copiedAt DESC",
                tagAttachments: tagAttachments,
                keys: keys
            )
        }
    }

    func fetchTrashedItems() throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: true)
            return try self.fetchBatchedCursorItems(
                in: db,
                whereAndOrderSQL: "WHERE c.deletedAt IS NOT NULL ORDER BY c.deletedAt DESC",
                tagAttachments: tagAttachments,
                keys: keys
            )
        }
    }

    func fetchItems(trashedBefore date: Date) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let sql = "\(Self.clipBatchSelectClause) WHERE c.deletedAt < ? ORDER BY c.deletedAt DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [date.timeIntervalSince1970])
            guard !rows.isEmpty else {
                return []
            }
            let matchedIDs = rows.compactMap { $0["id"] as String? }
            let tagAttachments = try self.fetchTagAttachments(in: db, forClipIDStrings: matchedIDs)
            return try self.decodeFetchedBatchRows(rows, tagAttachments: tagAttachments, keys: keys)
        }
    }

    func moveToTrash(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            let timestamp = date.timeIntervalSince1970
            let stmt = try db.cachedStatement(sql: "UPDATE clips SET deletedAt = ? WHERE id = ?")
            for id in ids {
                try stmt.execute(arguments: [timestamp, id.uuidString])
            }
        }
    }

    func restoreFromTrash(ids: [UUID]) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            let stmt = try db.cachedStatement(
                sql: "UPDATE clips SET deletedAt = NULL WHERE id = ? AND deletedAt IS NOT NULL"
            )
            for id in ids {
                try stmt.execute(arguments: [id.uuidString])
            }
        }
    }

    func fetchTags() throws -> [Tag] {
        try withRead { db, _ in
            try Self.fetchAllTags(in: db)
        }
    }

    func createTag(name: String, color: String) throws -> Tag {
        try withWrite { db, _ in
            if let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT id, name, color FROM tags WHERE name = ? COLLATE NOCASE LIMIT 1",
                arguments: [name]
            ) {
                return Tag(
                    id: existingRow["id"],
                    name: existingRow["name"],
                    color: existingRow["color"]
                )
            }

            try db.execute(
                sql: "INSERT INTO tags (name, color) VALUES (?, ?)",
                arguments: [name, color]
            )
            return Tag(id: Int(db.lastInsertedRowID), name: name, color: color)
        }
    }

    func updateTag(id: Tag.ID, name: String, color: String) throws -> Tag {
        try withWrite { db, _ in
            try db.execute(
                sql: "UPDATE tags SET name = ?, color = ? WHERE id = ?",
                arguments: [name, color, id]
            )
            return Tag(id: id, name: name, color: color)
        }
    }

    func deleteTag(id: Tag.ID) throws {
        try withWrite { db, _ in
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
        }
    }

    func capture(_ item: ClipboardItem, updatesCopySequence: Bool) throws -> ClipboardItem {
        try withWrite { db, keys in
            let parts = item.contentKeyComponents
            let lookupKey = HistoryCrypto.contentKey(
                kind: item.kind,
                canonicalContent: parts.canonicalContent,
                htmlDigest: parts.htmlDigest,
                keys: keys
            )

            if var existingItem = try self.fetchMatchingItem(
                in: db,
                kind: item.kind,
                contentKeyBlob: lookupKey,
                keys: keys
            ) {
                let wasTrashed = existingItem.deletedAt != nil
                let previousAssetPath = existingItem.assetPath
                let previousLinkPreview = existingItem.linkPreviewDetails
                existingItem.title = item.title ?? existingItem.title
                existingItem.text = item.text ?? existingItem.text
                existingItem.qrCodeText = item.qrCodeText ?? existingItem.qrCodeText
                existingItem.setFormatting(html: item.html, rtfData: item.rtfData)
                existingItem.imageDigest = item.imageDigest ?? existingItem.imageDigest
                existingItem.imageWidth = item.imageWidth ?? existingItem.imageWidth
                existingItem.imageHeight = item.imageHeight ?? existingItem.imageHeight
                if let incomingAssetPath = item.assetPath {
                    let hasLiveExistingAsset = existingItem.assetPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                    if !hasLiveExistingAsset || FileManager.default.fileExists(atPath: incomingAssetPath) {
                        existingItem.assetPath = incomingAssetPath
                    }
                }
                existingItem.filePaths = item.filePaths
                existingItem.sourceAppName = item.sourceAppName
                existingItem.sourceBundleIdentifier = item.sourceBundleIdentifier
                existingItem.copiedAt = item.copiedAt
                existingItem.byteSize = item.byteSize
                existingItem.linkPreviewDetails = item.linkPreviewDetails ?? existingItem.linkPreviewDetails
                if updatesCopySequence {
                    existingItem.copySequenceID = item.copySequenceID
                    existingItem.copySequenceOrder = item.copySequenceOrder
                }
                if existingItem.sensitivity == nil && item.sensitivity == .sensitive {
                    existingItem.sensitivity = .sensitive
                }
                existingItem.copyCount += 1
                existingItem.expiresAt = existingItem.isKeptByUser ? nil : item.expiresAt

                if SensitiveContent.shouldEncryptAtRest(existingItem) {
                    try self.reconcileManagedAssetsForPersistence(
                        &existingItem,
                        shouldEncrypt: true,
                        keys: keys
                    )
                    self.scrubSupersededManagedAssetIfNeeded(
                        previousPath: previousAssetPath,
                        currentPath: existingItem.assetPath
                    )
                    self.scrubSupersededManagedAssetIfNeeded(
                        previousPath: previousLinkPreview?.imagePath,
                        currentPath: existingItem.linkPreviewDetails?.imagePath
                    )
                    self.scrubSupersededManagedAssetIfNeeded(
                        previousPath: previousLinkPreview?.faviconPath,
                        currentPath: existingItem.linkPreviewDetails?.faviconPath
                    )
                }

                let tagNamesByID = Dictionary(
                    uniqueKeysWithValues: try Self.fetchAllTags(in: db).map { ($0.id, $0.name) }
                )
                existingItem.searchText = ClipboardItem.makeSearchText(
                    title: existingItem.title,
                    text: existingItem.text,
                    filePaths: existingItem.filePaths,
                    tagNames: existingItem.tags.compactMap { tagNamesByID[$0] },
                    sourceAppName: existingItem.sourceAppName,
                    linkPreviewDetails: existingItem.linkPreviewDetails,
                    qrCodeText: existingItem.qrCodeText
                )

                let saved = try self.persistUpsert(
                    in: db,
                    item: existingItem,
                    keys: keys,
                    assetMode: .nonDestructiveEncryptedStaging
                )
                var result = saved
                if wasTrashed {
                    try db.execute(
                        sql: "UPDATE clips SET deletedAt = NULL WHERE id = ?",
                        arguments: [result.id.uuidString]
                    )
                    result.deletedAt = nil
                }
                return result
            }

            let saved = try self.persistUpsert(
                in: db,
                item: item,
                keys: keys,
                assetMode: .nonDestructiveEncryptedStaging
            )
            return saved
        }
    }

    func upsert(_ item: ClipboardItem) throws {
        try withWrite { db, keys in
            _ = try self.persistUpsert(
                in: db,
                item: item,
                keys: keys,
                assetMode: .nonDestructiveEncryptedStaging
            )
        }
    }

    @discardableResult
    func saveAndReconcileItem(_ item: ClipboardItem, convertingExternalAssets: Bool = true) throws -> ClipboardItem {
        try withWrite { db, keys in
            try self.persistUpsert(
                in: db,
                item: item,
                keys: keys,
                assetMode: convertingExternalAssets ? .reconcileManagedAssets : .nonDestructiveEncryptedStaging
            )
        }
    }

    func setSensitivity(_ sensitivity: ItemSensitivity?, for id: UUID) throws -> ClipboardItem? {
        try withWrite { db, keys in
            guard var existing = try self.fetchFullItemByID(
                in: db,
                id: id,
                keys: keys
            ) else {
                return nil
            }

            if sensitivity == .notSensitive && existing.sensitivity == nil {
                existing.expiresAt = nil
            }
            existing.sensitivity = sensitivity

            return try self.persistUpsert(
                in: db,
                item: existing,
                keys: keys,
                assetMode: .reconcileManagedAssets
            )
        }
    }

    func loadingContent(of item: ClipboardItem, scope: ClipboardContentScope = .full) throws -> ClipboardItem {
        if item.isCorruptPlaceholder {
            throw HistoryStoreError.authenticationFailed
        }
        if scope == .body || !item.hasFormatting {
            if item.isContentLoaded {
                return item
            }
        } else if scope == .preview {
            if item.isContentLoaded && item.isPreviewFormattingLoaded {
                return item
            }
        } else {
            if item.isContentLoaded && item.isFormattingLoaded {
                return item
            }
        }

        return try withRead { db, keys in
            let idString = item.id.uuidString
            let needsBodyColumns = !item.isContentLoaded

            let clipHeaderColumns = "c.isEncrypted, c.title, c.textPreview, c.htmlDigest, c.imageDigest, c.assetPath, c.filePathsData, c.linkPreviewData"
            let selectedColumns: String
            if scope == .body || !item.hasFormatting {
                selectedColumns = "\(clipHeaderColumns), cc.text, cc.qrCodeText"
            } else if scope == .preview {
                if needsBodyColumns {
                    selectedColumns = "\(clipHeaderColumns), cc.text, cc.qrCodeText, cc.rtf"
                } else {
                    selectedColumns = "\(clipHeaderColumns), cc.rtf"
                }
            } else {
                if needsBodyColumns {
                    selectedColumns = "\(clipHeaderColumns), cc.text, cc.qrCodeText, cc.rtf, cc.html"
                } else {
                    selectedColumns = "\(clipHeaderColumns), cc.rtf, cc.html"
                }
            }

            let sql = """
                SELECT \(selectedColumns)
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.id = ?
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [idString]) else {
                return item
            }

            let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
            if isEncrypted {
                try Self.authenticateEncryptedClipHeaderColumns(
                    in: row,
                    clipID: item.id,
                    keys: keys
                )
            }

            let resolvedText: String?
            let resolvedQRCodeText: String?
            if needsBodyColumns {
                resolvedText = try Self.decodeStringColumn(
                    from: row,
                    column: .clipContent(.text),
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                resolvedQRCodeText = try Self.decodeStringColumn(
                    from: row,
                    column: .clipContent(.qrCodeText),
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
            } else {
                resolvedText = item.text
                resolvedQRCodeText = item.qrCodeText
            }

            var resolvedRTF: Data? = nil
            var resolvedHTML: String? = nil
            let effectiveScope: ClipboardContentScope

            if scope == .body || !item.hasFormatting {
                effectiveScope = !item.hasFormatting ? .full : .body
            } else if scope == .preview {
                resolvedRTF = try Self.decodeDataColumn(
                    from: row,
                    column: .clipContent(.rtf),
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                if resolvedRTF == nil && (resolvedText?.isEmpty ?? true) {
                    if let htmlRow = try Row.fetchOne(
                        db,
                        sql: "SELECT html FROM clip_contents WHERE clipId = ? LIMIT 1",
                        arguments: [idString]
                    ) {
                        resolvedHTML = try Self.decodeStringColumn(
                            from: htmlRow,
                            column: .clipContent(.html),
                            clipID: item.id,
                            isEncrypted: isEncrypted,
                            keys: keys
                        )
                    }
                    effectiveScope = .full
                } else {
                    effectiveScope = .preview
                }
            } else {
                resolvedRTF = try Self.decodeDataColumn(
                    from: row,
                    column: .clipContent(.rtf),
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                resolvedHTML = try Self.decodeStringColumn(
                    from: row,
                    column: .clipContent(.html),
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                effectiveScope = .full
            }

            let tagNames: [String]
            if item.tags.isEmpty {
                tagNames = []
            } else {
                tagNames = try self.fetchOrderedTagNames(in: db, clipIDString: idString)
            }

            return item.withLoadedContent(
                text: resolvedText,
                qrCodeText: resolvedQRCodeText,
                html: resolvedHTML,
                rtfData: resolvedRTF,
                scope: effectiveScope,
                tagNames: tagNames,
                recomputesDerivedMetadata: item.storedContentKey == nil
            )
        }
    }

    func delete(_ id: UUID) throws {
        try withWrite { db, _ in
            let stmt = try db.cachedStatement(sql: "DELETE FROM clips WHERE id = ?")
            try stmt.execute(arguments: [id.uuidString])
            self.recordSVGMembershipRemoval(id)
            self.markNeedsFreePageRelease()
        }
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            let stmt = try db.cachedStatement(sql: "DELETE FROM clips WHERE id = ?")
            for id in ids {
                try stmt.execute(arguments: [id.uuidString])
            }
            self.recordSVGMembershipRemovals(ids)
            self.markNeedsFreePageRelease()
        }
    }

    func clear() throws {
        try withWrite { db, _ in
            let svgIDs = try String.fetchAll(db, sql: "SELECT id FROM clips WHERE isSVGText != 0")
                .compactMap(UUID.init(uuidString:))
            let allRemovedSVGIDs = Array(Set(svgIDs).union(self.knownSVGClipIDs.withLock { $0 }))
            try db.execute(sql: "DELETE FROM clips")
            self.recordSVGMembershipRemovals(allRemovedSVGIDs)
            self.writeAssetContext.withLock {
                $0.purgeOwnerSVGRenderingsOnCommit = true
            }
            self.markNeedsFreePageRelease()
        }
    }

    func clear(keepingFavoritesAndTaggedItems: Bool) throws {
        guard keepingFavoritesAndTaggedItems else {
            try clear()
            return
        }

        try withWrite { db, _ in
            let svgIDs = try String.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isSVGText != 0
                  AND (deletedAt IS NOT NULL
                       OR (isFavorite = 0 AND NOT EXISTS (
                           SELECT 1 FROM clip_tags WHERE clip_tags.clipId = clips.id
                       )))
                """).compactMap(UUID.init(uuidString:))
            try db.execute(sql: """
                DELETE FROM clips
                WHERE deletedAt IS NOT NULL
                   OR (isFavorite = 0 AND NOT EXISTS (
                       SELECT 1 FROM clip_tags WHERE clip_tags.clipId = clips.id
                   ))
                """)
            if db.changesCount > 0 {
                self.recordSVGMembershipRemovals(svgIDs)
                self.markNeedsFreePageRelease()
            }
        }
    }

    func recordAction(_ id: UUID, copiedAt: Date?, incrementsCopyCount: Bool) throws -> ClipboardItem? {
        try withWrite { db, keys in
            let idString = id.uuidString
            let selectCountsStmt = try db.cachedStatement(
                sql: "SELECT copiedAt, copyCount FROM clips WHERE id = ? AND deletedAt IS NULL LIMIT 1"
            )
            guard let existingCounts = try Row.fetchOne(selectCountsStmt, arguments: [idString]) else {
                return nil
            }

            let newCopiedAt = copiedAt?.timeIntervalSince1970 ?? (existingCounts["copiedAt"] as Double)
            let currentCopyCount: Int = existingCounts["copyCount"]
            let newCopyCount = incrementsCopyCount ? (currentCopyCount + 1) : currentCopyCount

            let updateStmt = try db.cachedStatement(
                sql: "UPDATE clips SET copiedAt = ?, copyCount = ? WHERE id = ? AND deletedAt IS NULL"
            )
            try updateStmt.execute(arguments: [newCopiedAt, newCopyCount, idString])

            let attachment = try self.fetchTagAttachment(in: db, clipIDString: idString)
            let decoder = Self.makeJSONDecoder()
            let selectClipStmt = try db.cachedStatement(
                sql: "\(Self.clipBatchSelectClause) WHERE c.id = ? AND c.deletedAt IS NULL LIMIT 1"
            )
            guard let row = try Row.fetchOne(selectClipStmt, arguments: [idString]) else {
                return nil
            }
            return try self.decodeBatchRow(
                row,
                attachment: attachment,
                hydratesBody: false,
                keys: keys,
                decoder: decoder
            )
        }
    }

    func fetchItems(expiredBy policy: HistoryRetentionPolicy) throws -> [ClipboardItem] {
        let cutoffs = policy.cutoffsByKind.sorted { $0.key.rawValue < $1.key.rawValue }
        guard !cutoffs.isEmpty else {
            return []
        }

        return try withRead { db, keys in
            let conditions = cutoffs.map { _ in "(c.kind = ? AND c.copiedAt < ?)" }.joined(separator: " OR ")
            var arguments: [any DatabaseValueConvertible] = []
            arguments.reserveCapacity(cutoffs.count * 2)
            for (kind, cutoff) in cutoffs {
                arguments.append(kind.rawValue)
                arguments.append(cutoff.timeIntervalSince1970)
            }

            let protectedClause = policy.keepsFavoritesAndTaggedItems
                ? " AND c.isFavorite = 0 AND NOT EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clipId = c.id)"
                : ""
            let sql = """
                \(Self.clipBatchSelectClause)
                WHERE c.deletedAt IS NULL AND (\(conditions))\(protectedClause)
                ORDER BY c.copiedAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            guard !rows.isEmpty else {
                return []
            }

            let tagAttachments: [String: TagAttachment]
            if policy.keepsFavoritesAndTaggedItems {
                tagAttachments = [:]
            } else {
                let matchedIDs = rows.compactMap { $0["id"] as String? }
                tagAttachments = try self.fetchTagAttachments(in: db, forClipIDStrings: matchedIDs)
            }

            return try self.decodeFetchedBatchRows(
                rows,
                tagAttachments: tagAttachments,
                keys: keys,
                where: policy.isExpired
            )
        }
    }

    func fetchItems(expiringBy date: Date) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let sql = """
                \(Self.clipBatchSelectClause)
                WHERE c.expiresAt IS NOT NULL AND c.expiresAt <= ?
                ORDER BY c.copiedAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [date.timeIntervalSince1970])
            guard !rows.isEmpty else {
                return []
            }
            let matchedIDs = rows.compactMap { $0["id"] as String? }
            let tagAttachments = try self.fetchTagAttachments(in: db, forClipIDStrings: matchedIDs)
            return try self.decodeFetchedBatchRows(rows, tagAttachments: tagAttachments, keys: keys)
        }
    }

    func nextExpiryDate() throws -> Date? {
        try withRead { db, _ in
            guard let minTimestamp = try Double.fetchOne(
                db,
                sql: "SELECT MIN(expiresAt) FROM clips WHERE expiresAt IS NOT NULL"
            ) else {
                return nil
            }
            return Date(timeIntervalSince1970: minTimestamp)
        }
    }

    func fetchItem(kind: ClipboardKind, contentKey: String, htmlDigest: String? = nil) throws -> ClipboardItem? {
        try withRead { db, keys in
            let lookupKey = HistoryCrypto.contentKey(
                kind: kind,
                canonicalContent: contentKey,
                htmlDigest: htmlDigest,
                keys: keys
            )
            return try self.fetchMatchingItem(
                in: db,
                kind: kind,
                contentKeyBlob: lookupKey,
                keys: keys
            )
        }
    }

    func fetchStoredFilePaths() throws -> Set<String> {
        try withRead { db, keys in
            let sql = """
                SELECT id, isEncrypted, assetPath, linkPreviewData
                FROM clips
                WHERE assetPath IS NOT NULL OR linkPreviewData IS NOT NULL
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql)
            var paths: Set<String> = []
            try Self.drainCursorInBatches(cursor) { row in
                guard let idString: String = row["id"],
                      let clipID = UUID(uuidString: idString) else {
                    throw HistoryStoreError.authenticationFailed
                }
                let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0

                if let assetPath = try Self.decodeProtectedAssetPath(
                    from: row,
                    clipID: clipID,
                    isEncrypted: isEncrypted,
                    keys: keys
                ) {
                    paths.insert(assetPath)
                }

                if let details = try Self.decodeProtectedLinkPreview(
                    from: row,
                    clipID: clipID,
                    isEncrypted: isEncrypted,
                    keys: keys,
                    decoder: decoder
                ) {
                    if let imagePath = details.imagePath {
                        paths.insert(imagePath)
                    }
                    if let faviconPath = details.faviconPath {
                        paths.insert(faviconPath)
                    }
                }
            }
            return paths
        }
    }

    func fetchTrashedAssetPaths() throws -> Set<String> {
        try withRead { db, keys in
            let sql = """
                SELECT id, isEncrypted, assetPath
                FROM clips
                WHERE deletedAt IS NOT NULL AND assetPath IS NOT NULL
                """
            let cursor = try Row.fetchCursor(db, sql: sql)
            var paths: Set<String> = []
            try Self.drainCursorInBatches(cursor) { row in
                guard let idString: String = row["id"],
                      let clipID = UUID(uuidString: idString) else {
                    return
                }
                let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
                if let assetPath = try? Self.decodeProtectedAssetPath(
                    from: row,
                    clipID: clipID,
                    isEncrypted: isEncrypted,
                    keys: keys
                ) {
                    paths.insert(assetPath)
                }
            }
            return paths
        }
    }

    private static func fetchSearchTextBatch(
        in db: Database,
        clipWhereClause: String,
        clipArguments: StatementArguments,
        tagSQL: String,
        tagArguments: StatementArguments,
        indicesByIDString: [String: [Int]],
        tagNamesByID: [Tag.ID: String],
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder,
        results: inout [String?],
        isCancelled: () -> Bool
    ) throws -> Bool {
        let tagCursor = try Row.fetchCursor(db, sql: tagSQL, arguments: tagArguments)
        var tagIDsByClipID: [String: [Int]] = [:]
        let completedTags = try drainCursorInBatches(tagCursor, isCancelled: isCancelled) { tagRow in
            let clipIDString: String = tagRow["clipId"]
            guard indicesByIDString[clipIDString] != nil else {
                return
            }
            let tagID: Int = tagRow["tagId"]
            tagIDsByClipID[clipIDString, default: []].append(tagID)
        }
        guard completedTags, !isCancelled() else {
            return false
        }

        let clipSQL = """
            SELECT c.id, c.kind, c.isEncrypted, c.sourceAppName, c.title, c.filePathsData, c.linkPreviewData,
                   cc.text, cc.qrCodeText
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE \(clipWhereClause)
            """
        let cursor = try Row.fetchCursor(db, sql: clipSQL, arguments: clipArguments)
        return try drainCursorInBatches(cursor, isCancelled: isCancelled) { row in
            guard let idString: String = row["id"],
                  let targetIndices = indicesByIDString[idString] else {
                return
            }
            let searchText = decodeSearchTextForRow(
                row,
                idString: idString,
                tagIDs: tagIDsByClipID[idString] ?? [],
                tagNamesByID: tagNamesByID,
                keys: keys,
                decoder: decoder
            )
            for index in targetIndices {
                results[index] = searchText
            }
        }
    }

    func fetchSearchTexts(
        for ids: [UUID],
        trashed: Bool,
        tagNamesByID: [Tag.ID: String],
        isCancelled: () -> Bool
    ) throws -> [String?]? {
        guard !isCancelled() else {
            return nil
        }
        guard !ids.isEmpty else {
            return []
        }

        var indicesByIDString: [String: [Int]] = [:]
        indicesByIDString.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            indicesByIDString[id.uuidString, default: []].append(index)
        }

        let deletedFilter = trashed ? "IS NOT NULL" : "IS NULL"
        return try withRead { db, keys in
            guard !isCancelled() else {
                return nil
            }
            var results = [String?](repeating: nil, count: ids.count)
            let decoder = Self.makeJSONDecoder()
            let uniqueIDStrings = Array(indicesByIDString.keys)

            if uniqueIDStrings.count <= Self.searchInClauseChunkedMaxIDs {
                var offset = 0
                while offset < uniqueIDStrings.count {
                    guard !isCancelled() else {
                        return nil
                    }
                    let end = min(offset + Self.searchInClauseBatchLimit, uniqueIDStrings.count)
                    let chunk = Array(uniqueIDStrings[offset..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    let arguments = StatementArguments(chunk)
                    let tagSQL = """
                        SELECT ct.clipId, ct.tagId
                        FROM clip_tags ct
                        JOIN tags t ON t.id = ct.tagId
                        WHERE ct.clipId IN (\(placeholders))
                        ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                        """
                    let completed = try Self.fetchSearchTextBatch(
                        in: db,
                        clipWhereClause: "c.id IN (\(placeholders)) AND c.deletedAt \(deletedFilter)",
                        clipArguments: arguments,
                        tagSQL: tagSQL,
                        tagArguments: arguments,
                        indicesByIDString: indicesByIDString,
                        tagNamesByID: tagNamesByID,
                        keys: keys,
                        decoder: decoder,
                        results: &results,
                        isCancelled: isCancelled
                    )
                    guard completed else {
                        return nil
                    }
                    offset = end
                }
                return results
            }

            let tagSQL = """
                SELECT ct.clipId, ct.tagId
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """
            let completed = try Self.fetchSearchTextBatch(
                in: db,
                clipWhereClause: "c.deletedAt \(deletedFilter)",
                clipArguments: StatementArguments(),
                tagSQL: tagSQL,
                tagArguments: StatementArguments(),
                indicesByIDString: indicesByIDString,
                tagNamesByID: tagNamesByID,
                keys: keys,
                decoder: decoder,
                results: &results,
                isCancelled: isCancelled
            )
            return completed ? results : nil
        }
    }

    func fetchItems(where isIncluded: (ClipboardItem) -> Bool) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: false)
            return try self.fetchBatchedCursorItems(
                in: db,
                whereAndOrderSQL: "WHERE c.deletedAt IS NULL ORDER BY c.copiedAt DESC",
                tagAttachments: tagAttachments,
                hydratesBody: true,
                keys: keys,
                where: isIncluded
            )
        }
    }

    func fetchMostRecentItem(where isIncluded: (ClipboardItem) -> Bool) throws -> ClipboardItem? {
        try withRead { db, keys in
            let stmt = try db.cachedStatement(sql: """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.deletedAt IS NULL
                ORDER BY c.copiedAt DESC
                """)
            let cursor = try Row.fetchCursor(stmt)
            return try self.fetchFirstMatchingItem(in: db, cursor: cursor, keys: keys, where: isIncluded)
        }
    }

    func performInTransaction(_ body: () throws -> Void) throws {
        try withWrite { _, _ in
            try body()
        }
    }

    // MARK: - Write & Reconcile Helpers

    private enum AssetPersistenceMode {
        case nonDestructiveEncryptedStaging
        case reconcileManagedAssets
    }

    private func scrubSupersededManagedAssetIfNeeded(
        previousPath: String?,
        currentPath: String?
    ) {
        guard let previousPath, !previousPath.isEmpty else {
            return
        }
        let previousURL = URL(fileURLWithPath: previousPath, isDirectory: false)
        if let currentPath, !currentPath.isEmpty {
            let currentURL = URL(fileURLWithPath: currentPath, isDirectory: false)
            if ImageAssetStore.canonicalFileURL(previousURL) == ImageAssetStore.canonicalFileURL(currentURL) {
                return
            }
        }
        guard assetStore.isManagedAssetURL(previousURL) else {
            return
        }
        var linkStat = stat()
        let superseded = Darwin.lstat(previousURL.path, &linkStat) == 0 ? previousURL : nil
        recordSupersededAsset(supersededURL: superseded, evictedPath: previousPath)
    }

    private func stageReconciledAssetPath(
        _ oldPath: String,
        role: AssetRole,
        clipID: UUID,
        shouldEncrypt: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        let outcome = shouldEncrypt
            ? try assetStore.stageEncryptedAssetIfNeeded(at: oldPath, role: role, clipID: clipID, keys: keys)
            : try assetStore.stageDecryptedAssetIfNeeded(at: oldPath, role: role, clipID: clipID, keys: keys)
        let reconciledPath = outcome?.writtenURL.path
        if let outcome {
            recordAssetOutcome(outcome, evictedPath: reconciledPath != oldPath ? oldPath : nil)
        } else if reconciledPath != oldPath {
            recordSupersededAsset(supersededURL: nil, evictedPath: oldPath)
        }
        return reconciledPath
    }

    static func mapManagedAssetPaths(
        on workingItem: inout ClipboardItem,
        _ transform: (String, AssetRole) throws -> String?
    ) rethrows {
        if let currentAssetPath = workingItem.assetPath {
            let updatedAssetPath = try transform(currentAssetPath, .image)
            if updatedAssetPath != currentAssetPath {
                workingItem.assetPath = updatedAssetPath
            }
        }

        guard var details = workingItem.linkPreviewDetails else {
            return
        }
        var detailsChanged = false
        if let currentImagePath = details.imagePath {
            let updatedImagePath = try transform(currentImagePath, .linkPreview)
            if updatedImagePath != currentImagePath {
                details.imagePath = updatedImagePath
                detailsChanged = true
            }
        }
        if let currentFaviconPath = details.faviconPath {
            let updatedFaviconPath = try transform(currentFaviconPath, .linkFavicon)
            if updatedFaviconPath != currentFaviconPath {
                details.faviconPath = updatedFaviconPath
                detailsChanged = true
            }
        }
        if detailsChanged {
            workingItem.linkPreviewDetails = details
        }
    }

    private func reconcileManagedAssetsForPersistence(
        _ workingItem: inout ClipboardItem,
        shouldEncrypt: Bool,
        keys: ClipBookDerivedKeys
    ) throws {
        let clipID = workingItem.id
        try Self.mapManagedAssetPaths(on: &workingItem) { oldPath, role in
            try stageReconciledAssetPath(
                oldPath,
                role: role,
                clipID: clipID,
                shouldEncrypt: shouldEncrypt,
                keys: keys
            )
        }
    }

    private func stageNonDestructiveEncryptedAssetIfNeeded(
        path: String?,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: path, isDirectory: false)
        if sourceURL.pathExtension.lowercased() == "enc" && assetStore.isManagedAssetURL(sourceURL) {
            if (try? assetStore.readPNGData(
                at: sourceURL,
                role: role,
                clipID: clipID,
                keys: keys,
                requiresEncryption: true
            )) != nil {
                return path
            }
        }

        var linkStat = stat()
        if Darwin.lstat(sourceURL.path, &linkStat) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.authenticationFailed
        }

        let plainData = try assetStore.readPNGData(
            at: sourceURL,
            role: role,
            clipID: clipID,
            keys: keys,
            requiresEncryption: false
        )
        let expectedTargetURL = assetStore.targetURL(for: role, clipID: clipID, fileExtension: "enc")
        let targetPreexisted = Self.fileOrSymlinkExists(at: expectedTargetURL)
        let stagedURL = try assetStore.writeAsset(
            pngData: plainData,
            role: role,
            clipID: clipID,
            encrypted: true,
            keys: keys
        )
        let createdNew = !targetPreexisted && ImageAssetStore.canonicalFileURL(sourceURL) != ImageAssetStore.canonicalFileURL(stagedURL)
        recordAssetOutcome(
            ImageAssetStore.AssetConversionOutcome(
                writtenURL: stagedURL,
                createdNewFile: createdNew,
                supersededManagedURL: nil
            ),
            evictedPath: nil
        )
        return stagedURL.path
    }

    private static let selectExistingClipSQL = """
        SELECT isEncrypted, sourceAppName, sourceBundleIdentifier, contentKey,
               title, textPreview, htmlDigest, imageDigest, assetPath, filePathsData, linkPreviewData
        FROM clips
        WHERE id = ?
        LIMIT 1
        """

    private static let selectExistingBodySQL =
        "SELECT text, qrCodeText FROM clip_contents WHERE clipId = ? LIMIT 1"

    private static let selectExistingFormattingSQL =
        "SELECT rtf, html FROM clip_contents WHERE clipId = ? LIMIT 1"

    private static let selectExistingBodyAndFormattingSQL =
        "SELECT text, qrCodeText, rtf, html FROM clip_contents WHERE clipId = ? LIMIT 1"

    private static let upsertClipSQL = """
        INSERT INTO clips (
            id, kind, copiedAt, firstCopiedAt, deletedAt, expiresAt,
            copySequenceID, copySequenceOrder, byteSize, copyCount,
            isFavorite, favoriteOrder, sourceAppName, sourceBundleIdentifier,
            sensitivity, isEncrypted, title, textPreview, characterCount,
            containsPreviewSecret, containsRestSecret, hasRecognizedText,
            hasQRCodeText, isSVGText, hasFormatting, htmlDigest, imageDigest,
            imageWidth, imageHeight, assetPath, filePathsData, linkPreviewData,
            contentKey
        ) VALUES (
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?
        )
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            copiedAt = excluded.copiedAt,
            firstCopiedAt = excluded.firstCopiedAt,
            expiresAt = excluded.expiresAt,
            copySequenceID = excluded.copySequenceID,
            copySequenceOrder = excluded.copySequenceOrder,
            byteSize = excluded.byteSize,
            copyCount = excluded.copyCount,
            isFavorite = excluded.isFavorite,
            favoriteOrder = excluded.favoriteOrder,
            sourceAppName = excluded.sourceAppName,
            sourceBundleIdentifier = excluded.sourceBundleIdentifier,
            sensitivity = excluded.sensitivity,
            isEncrypted = excluded.isEncrypted,
            title = excluded.title,
            textPreview = excluded.textPreview,
            characterCount = excluded.characterCount,
            containsPreviewSecret = excluded.containsPreviewSecret,
            containsRestSecret = excluded.containsRestSecret,
            hasRecognizedText = excluded.hasRecognizedText,
            hasQRCodeText = excluded.hasQRCodeText,
            isSVGText = excluded.isSVGText,
            hasFormatting = excluded.hasFormatting,
            htmlDigest = excluded.htmlDigest,
            imageDigest = excluded.imageDigest,
            imageWidth = excluded.imageWidth,
            imageHeight = excluded.imageHeight,
            assetPath = excluded.assetPath,
            filePathsData = excluded.filePathsData,
            linkPreviewData = excluded.linkPreviewData,
            contentKey = excluded.contentKey
        """

    private static let upsertClipContentsBodyAndFormattingSQL = """
        INSERT INTO clip_contents (clipId, text, qrCodeText, rtf, html)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(clipId) DO UPDATE SET text = excluded.text, qrCodeText = excluded.qrCodeText, rtf = excluded.rtf, html = excluded.html
        """

    private static let upsertClipContentsBodyOnlySQL = """
        INSERT INTO clip_contents (clipId, text, qrCodeText, rtf, html)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(clipId) DO UPDATE SET text = excluded.text, qrCodeText = excluded.qrCodeText
        """

    private static let upsertClipContentsFormattingOnlySQL = """
        INSERT INTO clip_contents (clipId, text, qrCodeText, rtf, html)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(clipId) DO UPDATE SET rtf = excluded.rtf, html = excluded.html
        """

    nonisolated struct PreservedClipContents: Sendable {
        var existingIsEncrypted: Bool? = nil
        var writesBody: Bool = true
        var writesFormatting: Bool = true
        var plainText: String? = nil
        var plainQR: String? = nil
        var plainRTF: Data? = nil
        var plainHTML: String? = nil
        var loadedBody: Bool = false
        var loadedFormatting: Bool = false

        static let freshInsert = PreservedClipContents()
    }

    private nonisolated struct ExistingClipUpsertSnapshot {
        var isEncrypted: Bool? = nil
        var sourceAppName: String? = nil
        var sourceBundleIdentifier: String? = nil
        var assetPath: String? = nil
        var linkPreview: LinkPreviewDetails? = nil
    }

    private func persistUpsert(
        in db: Database,
        item: ClipboardItem,
        keys: ClipBookDerivedKeys,
        assetMode: AssetPersistenceMode
    ) throws -> ClipboardItem {
        if item.isCorruptPlaceholder {
            throw HistoryStoreError.authenticationFailed
        }

        var workingItem = item
        let priorStoredContentKey = item.storedContentKey
        let idString = workingItem.id.uuidString

        let existingSnapshot = try Self.loadExistingClipUpsertSnapshot(
            in: db,
            clipID: workingItem.id,
            idString: idString,
            keys: keys
        )

        let shouldEncrypt = try prepareManagedAssetsForUpsert(
            &workingItem,
            existing: existingSnapshot,
            assetMode: assetMode,
            keys: keys
        )

        let reusableStoredKey = workingItem.storedContentKey ?? (
            workingItem.kind == .image && workingItem.imageDigest != nil ? priorStoredContentKey : nil
        )
        let canReuseContentKey = workingItem.isContentLoaded || reusableStoredKey != nil

        let preservedContents = try Self.loadPreservedClipContentsIfNeeded(
            in: db,
            item: workingItem,
            existingIsEncrypted: existingSnapshot.isEncrypted,
            shouldEncrypt: shouldEncrypt,
            canReuseContentKey: canReuseContentKey,
            keys: keys
        )

        let hmacKey = Self.resolveUpsertContentKey(
            for: workingItem,
            reusableStoredKey: reusableStoredKey,
            preserved: preservedContents,
            keys: keys
        )

        let encoder = Self.makeJSONEncoder()
        try Self.writeClipRow(
            in: db,
            item: workingItem,
            isEncrypted: shouldEncrypt,
            contentKeyBlob: hmacKey,
            keys: keys,
            encoder: encoder
        )
        if workingItem.isSVGText {
            recordSVGMembershipInsert(workingItem.id)
        } else {
            recordSVGMembershipRemoval(workingItem.id)
        }

        try Self.writeClipContentsRow(
            in: db,
            item: workingItem,
            isEncrypted: shouldEncrypt,
            preserved: preservedContents,
            keys: keys
        )

        try Self.replaceClipTagAssociations(in: db, clipIDString: idString, item: workingItem)
        recordUpsertPostWriteSideEffects(
            for: workingItem,
            existing: existingSnapshot,
            shouldEncrypt: shouldEncrypt
        )

        workingItem.storedContentKey = hmacKey
        return workingItem
    }

    private static func loadExistingClipUpsertSnapshot(
        in db: Database,
        clipID: UUID,
        idString: String,
        keys: ClipBookDerivedKeys
    ) throws -> ExistingClipUpsertSnapshot {
        let existingClipStmt = try db.cachedStatement(sql: selectExistingClipSQL)
        guard let existingClipRow = try Row.fetchOne(existingClipStmt, arguments: [idString]) else {
            return ExistingClipUpsertSnapshot()
        }

        let wasEncrypted = ((existingClipRow["isEncrypted"] as Int?) ?? 0) != 0
        var snapshot = ExistingClipUpsertSnapshot(
            isEncrypted: wasEncrypted,
            sourceAppName: existingClipRow["sourceAppName"],
            sourceBundleIdentifier: existingClipRow["sourceBundleIdentifier"]
        )

        let decoder = makeJSONDecoder()
        if wasEncrypted {
            try authenticateEncryptedClipHeaderColumns(
                in: existingClipRow,
                clipID: clipID,
                keys: keys
            )
            snapshot.assetPath = try decodeProtectedAssetPath(
                from: existingClipRow,
                clipID: clipID,
                isEncrypted: true,
                keys: keys
            )
            snapshot.linkPreview = try decodeProtectedLinkPreview(
                from: existingClipRow,
                clipID: clipID,
                isEncrypted: true,
                keys: keys,
                decoder: decoder
            )
        } else {
            snapshot.assetPath = try? decodeProtectedAssetPath(
                from: existingClipRow,
                clipID: clipID,
                isEncrypted: false,
                keys: keys
            )
            snapshot.linkPreview = try? decodeProtectedLinkPreview(
                from: existingClipRow,
                clipID: clipID,
                isEncrypted: false,
                keys: keys,
                decoder: decoder
            )
        }
        return snapshot
    }

    private func prepareManagedAssetsForUpsert(
        _ workingItem: inout ClipboardItem,
        existing: ExistingClipUpsertSnapshot,
        assetMode: AssetPersistenceMode,
        keys: ClipBookDerivedKeys
    ) throws -> Bool {
        var shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)

        switch assetMode {
        case .reconcileManagedAssets:
            try reconcileManagedAssetsForPersistence(
                &workingItem,
                shouldEncrypt: shouldEncrypt,
                keys: keys
            )
            scrubSupersededManagedAssetIfNeeded(
                previousPath: existing.assetPath,
                currentPath: workingItem.assetPath
            )
            scrubSupersededManagedAssetIfNeeded(
                previousPath: existing.linkPreview?.imagePath,
                currentPath: workingItem.linkPreviewDetails?.imagePath
            )
            scrubSupersededManagedAssetIfNeeded(
                previousPath: existing.linkPreview?.faviconPath,
                currentPath: workingItem.linkPreviewDetails?.faviconPath
            )
            shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)
        case .nonDestructiveEncryptedStaging:
            guard shouldEncrypt else {
                break
            }
            try stageNonDestructiveEncryptedAssetsOnItem(&workingItem, keys: keys)
            shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)
        }

        return shouldEncrypt
    }

    private func stageNonDestructiveEncryptedAssetsOnItem(
        _ workingItem: inout ClipboardItem,
        keys: ClipBookDerivedKeys
    ) throws {
        let clipID = workingItem.id
        try Self.mapManagedAssetPaths(on: &workingItem) { currentPath, role in
            try stageNonDestructiveEncryptedAssetIfNeeded(
                path: currentPath,
                role: role,
                clipID: clipID,
                keys: keys
            )
        }
    }

    private static func loadPreservedClipContentsIfNeeded(
        in db: Database,
        item: ClipboardItem,
        existingIsEncrypted: Bool?,
        shouldEncrypt: Bool,
        canReuseContentKey: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> PreservedClipContents {
        var preserved = PreservedClipContents(
            existingIsEncrypted: existingIsEncrypted,
            writesBody: item.isContentLoaded,
            writesFormatting: item.isFormattingLoaded || !item.hasFormatting
        )

        guard let wasEncrypted = existingIsEncrypted else {
            return preserved
        }

        let needsExistingBody = !preserved.writesBody && (wasEncrypted != shouldEncrypt || !canReuseContentKey)
        let needsExistingFormatting = !preserved.writesFormatting && (wasEncrypted != shouldEncrypt)
        guard needsExistingBody || needsExistingFormatting else {
            return preserved
        }

        let existingContentsSQL: String
        switch (needsExistingBody, needsExistingFormatting) {
        case (true, false):
            existingContentsSQL = selectExistingBodySQL
        case (false, true):
            existingContentsSQL = selectExistingFormattingSQL
        default:
            existingContentsSQL = selectExistingBodyAndFormattingSQL
        }

        let existingContentsStmt = try db.cachedStatement(sql: existingContentsSQL)
        guard let existingContentsRow = try Row.fetchOne(existingContentsStmt, arguments: [item.id.uuidString]) else {
            return preserved
        }

        if needsExistingBody {
            preserved.plainText = try decodeStringColumn(
                from: existingContentsRow,
                column: .clipContent(.text),
                clipID: item.id,
                isEncrypted: wasEncrypted,
                keys: keys
            )
            preserved.plainQR = try decodeStringColumn(
                from: existingContentsRow,
                column: .clipContent(.qrCodeText),
                clipID: item.id,
                isEncrypted: wasEncrypted,
                keys: keys
            )
            preserved.loadedBody = true
        }

        if needsExistingFormatting {
            preserved.plainRTF = try decodeDataColumn(
                from: existingContentsRow,
                column: .clipContent(.rtf),
                clipID: item.id,
                isEncrypted: wasEncrypted,
                keys: keys
            )
            preserved.plainHTML = try decodeStringColumn(
                from: existingContentsRow,
                column: .clipContent(.html),
                clipID: item.id,
                isEncrypted: wasEncrypted,
                keys: keys
            )
            preserved.loadedFormatting = true
        }

        return preserved
    }

    private static func resolveUpsertContentKey(
        for item: ClipboardItem,
        reusableStoredKey: Data?,
        preserved: PreservedClipContents,
        keys: ClipBookDerivedKeys
    ) -> Data {
        if item.isContentLoaded {
            let parts = item.contentKeyComponents
            return HistoryCrypto.contentKey(
                kind: item.kind,
                canonicalContent: parts.canonicalContent,
                htmlDigest: parts.htmlDigest,
                keys: keys
            )
        }
        if let reusableStoredKey {
            return reusableStoredKey
        }
        let hydrated = item.withLoadedContent(
            text: preserved.plainText,
            qrCodeText: preserved.plainQR,
            scope: .body,
            tagNames: nil,
            recomputesDerivedMetadata: false
        )
        let parts = hydrated.contentKeyComponents
        return HistoryCrypto.contentKey(
            kind: hydrated.kind,
            canonicalContent: parts.canonicalContent,
            htmlDigest: parts.htmlDigest,
            keys: keys
        )
    }

    private static func replaceClipTagAssociations(
        in db: Database,
        clipIDString: String,
        item: ClipboardItem
    ) throws {
        let deleteTagsStmt = try db.cachedStatement(sql: "DELETE FROM clip_tags WHERE clipId = ?")
        try deleteTagsStmt.execute(arguments: [clipIDString])
        guard !item.tags.isEmpty else {
            return
        }
        let insertTagStmt = try db.cachedStatement(
            sql: "INSERT OR IGNORE INTO clip_tags (clipId, tagId, sortOrder) SELECT ?, id, ? FROM tags WHERE id = ?"
        )
        for tagID in item.tags {
            try insertTagStmt.execute(arguments: [clipIDString, item.tagOrders[tagID], tagID])
        }
    }

    private func recordUpsertPostWriteSideEffects(
        for item: ClipboardItem,
        existing: ExistingClipUpsertSnapshot,
        shouldEncrypt: Bool
    ) {
        let overwroteEncryptedUnsealedMetadata = existing.isEncrypted == true && shouldEncrypt && (
            (existing.sourceAppName != nil && existing.sourceAppName != item.sourceAppName)
            || (existing.sourceBundleIdentifier != nil && existing.sourceBundleIdentifier != item.sourceBundleIdentifier)
        )
        if existing.isEncrypted == false && shouldEncrypt {
            let evictedClipID = item.id
            writeAssetContext.withLock { $0.evictedSVGClipIDs.append(evictedClipID) }
        }
        if (existing.isEncrypted == false && shouldEncrypt) || overwroteEncryptedUnsealedMetadata {
            markNeedsFreePageRelease()
        }
    }

    static func writeClipRow(
        in db: Database,
        item: ClipboardItem,
        isEncrypted: Bool,
        contentKeyBlob: Data,
        keys: ClipBookDerivedKeys,
        encoder: JSONEncoder
    ) throws {
        let clipID = item.id
        let idString = clipID.uuidString

        let titleBlob = try encodeStringColumn(
            item.title,
            column: .clip(.title),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let textPreviewBlob = try encodeStringColumn(
            item.textPreview,
            column: .clip(.textPreview),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let htmlDigestBlob = try encodeStringColumn(
            item.htmlDigest,
            column: .clip(.htmlDigest),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let imageDigestBlob = try encodeStringColumn(
            item.imageDigest,
            column: .clip(.imageDigest),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let assetPathBlob = try encodeStringColumn(
            item.assetPath,
            column: .clip(.assetPath),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let rawFilePathsJSON = try encoder.encode(item.filePaths)
        let filePathsBlob = try encodeRequiredDataColumn(
            rawFilePathsJSON,
            column: .clip(.filePathsData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let rawLinkPreviewJSON = try item.linkPreviewDetails.map { try encoder.encode($0) }
        let linkPreviewBlob = try encodeOptionalDataColumn(
            rawLinkPreviewJSON,
            column: .clip(.linkPreviewData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let arguments: StatementArguments = [
            idString,
            item.kind.rawValue,
            item.copiedAt.timeIntervalSince1970,
            item.firstCopiedAt.timeIntervalSince1970,
            item.deletedAt?.timeIntervalSince1970,
            item.expiresAt?.timeIntervalSince1970,
            item.copySequenceID?.timeIntervalSince1970,
            item.copySequenceOrder,
            item.byteSize,
            item.copyCount,
            item.isFavorite ? 1 : 0,
            item.favoriteOrder,
            item.sourceAppName,
            item.sourceBundleIdentifier,
            item.sensitivity?.rawValue,
            isEncrypted ? 1 : 0,
            titleBlob,
            textPreviewBlob,
            item.characterCount,
            item.containsPreviewSecret ? 1 : 0,
            item.containsRestSecret ? 1 : 0,
            item.hasRecognizedText ? 1 : 0,
            item.hasQRCodeText ? 1 : 0,
            item.isSVGText ? 1 : 0,
            item.hasFormatting ? 1 : 0,
            htmlDigestBlob,
            imageDigestBlob,
            item.imageWidth,
            item.imageHeight,
            assetPathBlob,
            filePathsBlob,
            linkPreviewBlob,
            contentKeyBlob,
        ]

        let stmt = try db.cachedStatement(sql: upsertClipSQL)
        try stmt.execute(arguments: arguments)
    }

    static func writeClipContentsRow(
        in db: Database,
        item: ClipboardItem,
        isEncrypted: Bool,
        preserved: PreservedClipContents,
        keys: ClipBookDerivedKeys
    ) throws {
        let clipID = item.id
        let idString = clipID.uuidString
        let encryptionChanged = preserved.existingIsEncrypted != nil && preserved.existingIsEncrypted != isEncrypted

        let effectiveWritesBody = preserved.writesBody
            || (encryptionChanged && preserved.loadedBody)
            || preserved.existingIsEncrypted == nil
        let effectiveWritesFormatting = preserved.writesFormatting
            || (encryptionChanged && preserved.loadedFormatting)
            || preserved.existingIsEncrypted == nil

        guard effectiveWritesBody || effectiveWritesFormatting else {
            return
        }

        let sourceText = preserved.writesBody ? item.text : (preserved.loadedBody ? preserved.plainText : nil)
        let sourceQR = preserved.writesBody ? item.qrCodeText : (preserved.loadedBody ? preserved.plainQR : nil)
        let sourceRTF = preserved.writesFormatting ? item.rtfData : (preserved.loadedFormatting ? preserved.plainRTF : nil)
        let sourceHTML = preserved.writesFormatting ? item.html : (preserved.loadedFormatting ? preserved.plainHTML : nil)

        let textBlob = effectiveWritesBody ? try encodeStringColumn(
            sourceText,
            column: .clipContent(.text),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let qrBlob = effectiveWritesBody ? try encodeStringColumn(
            sourceQR,
            column: .clipContent(.qrCodeText),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let rtfBlob = effectiveWritesFormatting ? try encodeOptionalDataColumn(
            sourceRTF,
            column: .clipContent(.rtf),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let htmlBlob = effectiveWritesFormatting ? try encodeStringColumn(
            sourceHTML,
            column: .clipContent(.html),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let sql: String
        switch (effectiveWritesBody, effectiveWritesFormatting) {
        case (true, true):
            sql = upsertClipContentsBodyAndFormattingSQL
        case (true, false):
            sql = upsertClipContentsBodyOnlySQL
        default:
            sql = upsertClipContentsFormattingOnlySQL
        }
        let stmt = try db.cachedStatement(sql: sql)
        try stmt.execute(arguments: [idString, textBlob, qrBlob, rtfBlob, htmlBlob])
    }
}
