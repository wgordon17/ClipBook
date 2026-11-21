import CryptoKit
import Darwin
import Foundation
import GRDB
import GRDBSQLite
import os

nonisolated final class GRDBHistoryStore: HistoryStore, Sendable {
    static let currentSchemaVersion = 5
    static let keyVerifierMetadataKey = "key_verifier_v1"
    static let cursorBatchSize = 512
    static let databaseBusyTimeoutSeconds: TimeInterval = 5.0
    static let defaultMigratedTagColor = "#3B85ED"
    private static let walJournalSizeLimit = 4_194_304
    private static let searchInClauseBatchLimit = 500
    private static let migrationBatchSize = 500
    private static let dontSaveContentLifetime = 0

    nonisolated enum AEADTable {
        static let clips = "clips"
        static let clipContents = "clip_contents"
    }

    nonisolated enum ClipAEADColumn: String, Sendable {
        case title
        case textPreview
        case htmlDigest
        case imageDigest
        case assetPath
        case filePathsData
        case linkPreviewData
    }

    nonisolated enum ClipContentAEADColumn: String, Sendable {
        case text
        case qrCodeText
        case rtf
        case html
    }

    nonisolated enum SealedColumn: Sendable {
        case clip(ClipAEADColumn)
        case clipContent(ClipContentAEADColumn)

        var aadTable: String {
            switch self {
            case .clip:
                return AEADTable.clips
            case .clipContent:
                return AEADTable.clipContents
            }
        }

        var aadColumn: String {
            switch self {
            case .clip(let column):
                return column.rawValue
            case .clipContent(let column):
                return column.rawValue
            }
        }
    }

    private enum LifecycleState: Equatable, Sendable {
        case open
        case closing
        case closed
    }

    private struct StoreState: Sendable {
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

    private struct TransactionAssetContext: Sendable {
        var newlyWrittenURLs: [URL] = []
        var supersededManagedURLs: [URL] = []
        var evictedThumbnailPaths: [String] = []
        var evictedSVGClipIDs: [UUID] = []
        var insertedSVGClipIDs: Set<UUID> = []
        var removedSVGClipIDs: Set<UUID> = []
        var purgeOwnerSVGRenderingsOnCommit: Bool = false
        var purgeSensitiveCachesOnCommit: Bool = false
    }

    private enum DatabaseProbeState {
        case fresh
        case legacy(version: Int)
        case existingV5(verifier: Data)
    }

    nonisolated struct TagAttachment {
        var tagIDs: [Int] = []
        var tagNames: [String] = []
        var tagOrders: [Int: Int] = [:]

        mutating func append(row: Row) {
            let tagID: Int = row["tagId"]
            let tagName: String = row["name"]
            let sortOrder: Int? = row["sortOrder"]
            tagIDs.append(tagID)
            tagNames.append(tagName)
            if let sortOrder {
                tagOrders[tagID] = sortOrder
            }
        }
    }

    let directory: URL

    private let instanceID = UUID()
    private let keyProvider: any DatabaseKeyProvider
    private let assetStore: ImageAssetStore
    private let openLock = NSLock()
    private let state = OSAllocatedUnfairLock<StoreState>(initialState: StoreState())
    private let writeAssetContext = OSAllocatedUnfairLock<TransactionAssetContext>(initialState: TransactionAssetContext())
    private let knownSVGClipIDs = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    private let activeAccessGroup = DispatchGroup()

    private var databaseURL: URL {
        directory.appendingPathComponent("History.sqlite", isDirectory: false)
    }

    private var walURL: URL {
        directory.appendingPathComponent("History.sqlite-wal", isDirectory: false)
    }

    private var shmURL: URL {
        directory.appendingPathComponent("History.sqlite-shm", isDirectory: false)
    }

    private var journalURL: URL {
        directory.appendingPathComponent("History.sqlite-journal", isDirectory: false)
    }

    private var migratingURL: URL {
        directory.appendingPathComponent("History.v5.migrating.sqlite", isDirectory: false)
    }

    private var scrubbingDBURL: URL {
        directory.appendingPathComponent("History.sqlite.scrubbing", isDirectory: false)
    }

    private var scrubbingWALURL: URL {
        directory.appendingPathComponent("History.sqlite-wal.scrubbing", isDirectory: false)
    }

    private var scrubbingSHMURL: URL {
        directory.appendingPathComponent("History.sqlite-shm.scrubbing", isDirectory: false)
    }

    private var scrubbingJournalURL: URL {
        directory.appendingPathComponent("History.sqlite-journal.scrubbing", isDirectory: false)
    }

    init(
        directory: URL,
        keyProvider: (any DatabaseKeyProvider)? = nil
    ) {
        self.directory = directory
        self.assetStore = ImageAssetStore(supportDirectory: directory)

        if let keyProvider {
            self.keyProvider = keyProvider
        } else if AppDelegate.isRunningTests {
            self.keyProvider = InMemoryDatabaseKeyProvider()
        } else if AppDirectories.usesIsolatedDebugStorage {
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

    func retryUnlock() throws {
        try openIfNeeded(allowRetryFromFailure: true)
    }

    func close() {
        let transition: (didBeginClose: Bool, writer: (any DatabaseWriter)?, hadPendingRelease: Bool) = state.withLock { s in
            guard s.lifecycle == .open else {
                return (false, nil, false)
            }
            s.lifecycle = .closing
            let writer = s.dbWriter
            let pending = s.needsFreePageRelease || s.isFreePageReleaseScheduled
            s.dbWriter = nil
            s.keys = nil
            return (true, writer, pending)
        }

        guard transition.didBeginClose else {
            return
        }

        let trackedSVGIDs = knownSVGClipIDs.withLock { ids -> Set<UUID> in
            let snapshot = ids
            ids.removeAll()
            return snapshot
        }
        for clipID in trackedSVGIDs {
            SVGImageRenderer.shared.removeRendering(for: clipID)
        }
        SensitiveContent.removeAll()
        SVGImageRenderer.unregisterTextLoader(ownerID: instanceID)
        ImageAssetStore.unregisterKeys(forSupportDirectory: directory, ownerID: instanceID)
        ImageAssetThumbnailLoader.shared.removeThumbnails(inDirectory: directory)
        ImageDragFiles.removeCopies(forSupportDirectory: directory)

        if let writer = transition.writer {
            writer.interrupt()
            activeAccessGroup.wait()
            if let svgIDStrings = try? writer.unsafeReentrantRead({ db in
                try String.fetchAll(db, sql: "SELECT id FROM clips WHERE isSVGText != 0")
            }) {
                for idString in svgIDStrings {
                    if let clipID = UUID(uuidString: idString) {
                        SVGImageRenderer.shared.removeRendering(for: clipID)
                    }
                }
            }
            let hadPendingRelease = transition.hadPendingRelease || state.withLock {
                $0.needsFreePageRelease || $0.isFreePageReleaseScheduled
            }
            if hadPendingRelease {
                try? writer.barrierWriteWithoutTransaction { db in
                    self.performFreePageReleasePass(on: db, forceIfAlreadyCleared: true)
                }
            }
            closeWriterCleanly(writer)
        } else {
            activeAccessGroup.wait()
        }

        state.withLock { $0.lifecycle = .closed }
    }

    private func closeWriterCleanly(_ writer: any DatabaseWriter) {
        try? writer.close()
        guard (try? Self.regularSidecarSizeIfPresent(at: databaseURL)) != nil,
              Self.fileOrSymlinkExists(at: walURL) || Self.fileOrSymlinkExists(at: shmURL) else {
            return
        }
        if let cleanupQueue = try? DatabaseQueue(
            path: databaseURL.path,
            configuration: Self.makeConnectionConfiguration()
        ) {
            try? cleanupQueue.writeWithoutTransaction { db in
                if let conn = db.sqliteConnection {
                    var persistWAL: CInt = 0
                    _ = sqlite3_file_control(conn, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
                }
                _ = try db.checkpoint(.truncate)
            }
            try? cleanupQueue.close()
        }
    }

    func flushPendingFreePageRelease() {
        let writer: (any DatabaseWriter)? = state.withLock { s in
            guard s.lifecycle == .open,
                  s.needsFreePageRelease || s.isFreePageReleaseScheduled,
                  let w = s.dbWriter else {
                return nil
            }
            activeAccessGroup.enter()
            return w
        }

        guard let writer else {
            return
        }
        defer {
            activeAccessGroup.leave()
        }

        try? writer.barrierWriteWithoutTransaction { db in
            self.performFreePageReleasePass(on: db, forceIfAlreadyCleared: false)
        }
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
        preferredPlainExtension: String? = nil
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
            preferredPlainExtension: preferredPlainExtension
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
                existingItem.assetPath = item.assetPath ?? existingItem.assetPath
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
                tagNames: tagNames
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

    private nonisolated struct SearchTextQueryPlan {
        let tagIDsByClipID: [String: [Int]]
        let clipWhereClause: String
        let clipArguments: StatementArguments
    }

    private static func prepareSearchTextQueryPlan(
        in db: Database,
        idCount: Int,
        indicesByIDString: [String: [Int]],
        trashed: Bool,
        isCancelled: () -> Bool
    ) throws -> SearchTextQueryPlan? {
        let deletedFilter = trashed ? "IS NOT NULL" : "IS NULL"
        let tagSQL: String
        let tagArguments: StatementArguments
        let clipWhereClause: String
        let clipArguments: StatementArguments

        if idCount <= searchInClauseBatchLimit {
            let idStrings = Array(indicesByIDString.keys)
            let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
            let arguments = StatementArguments(idStrings)
            tagSQL = """
                SELECT ct.clipId, ct.tagId
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                WHERE ct.clipId IN (\(placeholders))
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """
            tagArguments = arguments
            clipWhereClause = "c.id IN (\(placeholders)) AND c.deletedAt \(deletedFilter)"
            clipArguments = arguments
        } else {
            tagSQL = """
                SELECT ct.clipId, ct.tagId
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """
            tagArguments = StatementArguments()
            clipWhereClause = "c.deletedAt \(deletedFilter)"
            clipArguments = StatementArguments()
        }

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
            return nil
        }

        return SearchTextQueryPlan(
            tagIDsByClipID: tagIDsByClipID,
            clipWhereClause: clipWhereClause,
            clipArguments: clipArguments
        )
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

        return try withRead { db, keys in
            guard !isCancelled(),
                  let plan = try Self.prepareSearchTextQueryPlan(
                      in: db,
                      idCount: ids.count,
                      indicesByIDString: indicesByIDString,
                      trashed: trashed,
                      isCancelled: isCancelled
                  ) else {
                return nil
            }

            var results = [String?](repeating: nil, count: ids.count)
            let decoder = Self.makeJSONDecoder()
            let clipSQL = """
                SELECT c.id, c.kind, c.isEncrypted, c.sourceAppName, c.title, c.filePathsData, c.linkPreviewData,
                       cc.text, cc.qrCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE \(plan.clipWhereClause)
                """
            let cursor = try Row.fetchCursor(db, sql: clipSQL, arguments: plan.clipArguments)
            let completed = try Self.drainCursorInBatches(cursor, isCancelled: isCancelled) { row in
                guard let idString: String = row["id"],
                      let targetIndices = indicesByIDString[idString] else {
                    return
                }
                let searchText = Self.decodeSearchTextForRow(
                    row,
                    idString: idString,
                    tagIDs: plan.tagIDsByClipID[idString] ?? [],
                    tagNamesByID: tagNamesByID,
                    keys: keys,
                    decoder: decoder
                )
                for index in targetIndices {
                    results[index] = searchText
                }
            }
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
            let sql = """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.deletedAt IS NULL
                ORDER BY c.copiedAt DESC
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql)
            while let row = try cursor.next() {
                guard let idString: String = row["id"] else {
                    continue
                }
                let attachment = try self.fetchTagAttachment(in: db, clipIDString: idString)
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                ), isIncluded(item) {
                    return item
                }
            }
            return nil
        }
    }

    func performInTransaction(_ body: () throws -> Void) throws {
        try withWrite { _, _ in
            try body()
        }
    }

    // MARK: - Connection Lifecycle, Startup Probe & Barrier Free-Page Scrubbing

    private func acquireAccess() throws -> (writer: any DatabaseWriter, keys: ClipBookDerivedKeys) {
        if let existing = try tryAcquireExistingAccess() {
            return existing
        }

        try openIfNeeded(allowRetryFromFailure: false)

        if let opened = try tryAcquireExistingAccess() {
            return opened
        }

        throw HistoryStoreError.openFailed
    }

    private func tryAcquireExistingAccess() throws -> (writer: any DatabaseWriter, keys: ClipBookDerivedKeys)? {
        try state.withLock { s in
            guard s.lifecycle == .open else {
                throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
            }
            switch s.lockState {
            case .locked(let reason):
                throw HistoryStoreError.encryptionKeyUnavailable(reason)
            case .keyMismatch:
                throw HistoryStoreError.encryptionKeyMismatch
            case .unlocked:
                if let openFailure = s.openFailure {
                    throw openFailure
                }
                guard let writer = s.dbWriter, let keys = s.keys else {
                    return nil
                }
                activeAccessGroup.enter()
                return (writer, keys)
            }
        }
    }

    private func withRead<T>(_ value: (Database, ClipBookDerivedKeys) throws -> T) throws -> T {
        let (writer, keys) = try acquireAccess()
        defer {
            activeAccessGroup.leave()
        }

        return try writer.unsafeReentrantRead { db in
            if db.isInsideTransaction {
                return try value(db, keys)
            }
            var result: T!
            try db.inTransaction(.deferred) {
                result = try value(db, keys)
                return .commit
            }
            return result
        }
    }

    private func withWrite<T>(_ updates: (Database, ClipBookDerivedKeys) throws -> T) throws -> T {
        let (writer, keys) = try acquireAccess()
        var isOutermostCommit = false
        var committedAssets = TransactionAssetContext()
        let output: T
        do {
            output = try writer.unsafeReentrantWrite { db in
                if db.isInsideTransaction {
                    return try updates(db, keys)
                }
                self.writeAssetContext.withLock { $0 = TransactionAssetContext() }
                var result: T!
                do {
                    try db.inTransaction(.immediate) {
                        result = try updates(db, keys)
                        return .commit
                    }
                } catch {
                    let rolledBackAssets = self.takeWriteAssetContext()
                    for writtenURL in rolledBackAssets.newlyWrittenURLs {
                        ImageAssetStore.secureUnlink(at: writtenURL)
                    }
                    throw error
                }
                committedAssets = self.takeWriteAssetContext()
                isOutermostCommit = true
                return result
            }
        } catch {
            activeAccessGroup.leave()
            throw error
        }

        if isOutermostCommit {
            for supersededURL in committedAssets.supersededManagedURLs {
                ImageAssetStore.secureUnlink(at: supersededURL)
            }
            for evictedPath in committedAssets.evictedThumbnailPaths {
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: evictedPath)
            }
            if !committedAssets.removedSVGClipIDs.isEmpty || !committedAssets.insertedSVGClipIDs.isEmpty {
                let removedSVGClipIDs = committedAssets.removedSVGClipIDs
                let insertedSVGClipIDs = committedAssets.insertedSVGClipIDs
                knownSVGClipIDs.withLock { set in
                    set.subtract(removedSVGClipIDs)
                    set.formUnion(insertedSVGClipIDs)
                }
            }
            for clipID in Set(committedAssets.evictedSVGClipIDs) {
                SVGImageRenderer.shared.removeRendering(for: clipID)
            }
            if committedAssets.purgeOwnerSVGRenderingsOnCommit {
                SVGImageRenderer.shared.removeRenderings(forOwner: self.instanceID)
            }
            if committedAssets.purgeSensitiveCachesOnCommit {
                SensitiveContent.removeAll()
            }
            scheduleAsyncFreePageReleaseIfNeeded(on: writer)
        }
        activeAccessGroup.leave()
        return output
    }

    private func takeWriteAssetContext() -> TransactionAssetContext {
        writeAssetContext.withLock { ctx in
            let snapshot = ctx
            ctx = TransactionAssetContext()
            return snapshot
        }
    }

    private func recordSVGMembershipInsert(_ id: UUID) {
        writeAssetContext.withLock { ctx in
            ctx.insertedSVGClipIDs.insert(id)
            ctx.removedSVGClipIDs.remove(id)
        }
    }

    private func recordSVGMembershipRemoval(_ id: UUID) {
        writeAssetContext.withLock { ctx in
            ctx.removedSVGClipIDs.insert(id)
            ctx.insertedSVGClipIDs.remove(id)
            ctx.evictedSVGClipIDs.append(id)
        }
    }

    private func recordSVGMembershipRemovals(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            return
        }
        writeAssetContext.withLock { ctx in
            ctx.removedSVGClipIDs.formUnion(ids)
            ctx.insertedSVGClipIDs.subtract(ids)
            ctx.evictedSVGClipIDs.append(contentsOf: ids)
        }
    }

    private func recordAssetOutcome(_ outcome: ImageAssetStore.AssetConversionOutcome, evictedPath: String?) {
        let canonicalWritten = ImageAssetStore.canonicalFileURL(outcome.writtenURL)
        let canonicalSuperseded = outcome.supersededManagedURL.map(ImageAssetStore.canonicalFileURL)
        writeAssetContext.withLock { ctx in
            ctx.supersededManagedURLs.removeAll { ImageAssetStore.canonicalFileURL($0) == canonicalWritten }
            if outcome.createdNewFile,
               !ctx.newlyWrittenURLs.contains(where: { ImageAssetStore.canonicalFileURL($0) == canonicalWritten }) {
                ctx.newlyWrittenURLs.append(outcome.writtenURL)
            }
            if let superseded = outcome.supersededManagedURL,
               let canonicalSuperseded,
               canonicalSuperseded != canonicalWritten,
               !ctx.supersededManagedURLs.contains(where: { ImageAssetStore.canonicalFileURL($0) == canonicalSuperseded }) {
                ctx.supersededManagedURLs.append(superseded)
            }
            if let evictedPath, !evictedPath.isEmpty, !ctx.evictedThumbnailPaths.contains(evictedPath) {
                ctx.evictedThumbnailPaths.append(evictedPath)
            }
        }
    }

    private func recordSupersededAsset(supersededURL: URL?, evictedPath: String?) {
        let canonicalSuperseded = supersededURL.map(ImageAssetStore.canonicalFileURL)
        writeAssetContext.withLock { ctx in
            if let supersededURL,
               let canonicalSuperseded,
               !ctx.supersededManagedURLs.contains(where: { ImageAssetStore.canonicalFileURL($0) == canonicalSuperseded }) {
                ctx.supersededManagedURLs.append(supersededURL)
            }
            if let evictedPath, !evictedPath.isEmpty, !ctx.evictedThumbnailPaths.contains(evictedPath) {
                ctx.evictedThumbnailPaths.append(evictedPath)
            }
        }
    }

    private func markNeedsFreePageRelease() {
        state.withLock { s in
            if s.lifecycle != .closed {
                s.needsFreePageRelease = true
            }
        }
    }

    private func scheduleAsyncFreePageReleaseIfNeeded(on writer: any DatabaseWriter) {
        let shouldSchedule: Bool = state.withLock { s in
            guard s.lifecycle == .open,
                  s.needsFreePageRelease,
                  !s.isFreePageReleaseScheduled else {
                return false
            }
            s.isFreePageReleaseScheduled = true
            activeAccessGroup.enter()
            return true
        }

        guard shouldSchedule else {
            return
        }

        writer.asyncBarrierWriteWithoutTransaction { result in
            defer {
                self.activeAccessGroup.leave()
            }

            guard case .success(let db) = result else {
                self.state.withLock { $0.isFreePageReleaseScheduled = false }
                return
            }

            let isStillOpen = self.state.withLock { s -> Bool in
                guard s.lifecycle == .open else {
                    s.isFreePageReleaseScheduled = false
                    return false
                }
                return true
            }
            guard isStillOpen else {
                return
            }

            self.performFreePageReleasePass(on: db, forceIfAlreadyCleared: false)
            self.state.withLock { $0.isFreePageReleaseScheduled = false }
        }
    }

    private func performFreePageReleasePass(on db: Database, forceIfAlreadyCleared: Bool) {
        let shouldRun = state.withLock { s -> Bool in
            let pending = s.needsFreePageRelease || forceIfAlreadyCleared
            s.needsFreePageRelease = false
            return pending
        }
        guard shouldRun else {
            return
        }

        try? db.execute(sql: "PRAGMA incremental_vacuum;")
        do {
            let ckpt = try db.checkpoint(.truncate)
            if ckpt.walFrameCount > 0 {
                state.withLock { s in
                    if s.lifecycle == .open {
                        s.needsFreePageRelease = true
                    }
                }
            }
        } catch {
            state.withLock { s in
                if s.lifecycle == .open {
                    s.needsFreePageRelease = true
                }
            }
        }
    }

    private func openIfNeeded(allowRetryFromFailure: Bool) throws {
        openLock.lock()
        defer { openLock.unlock() }

        guard try beginOpenAttemptIfNeeded(allowRetryFromFailure: allowRetryFromFailure) else {
            return
        }
        defer {
            activeAccessGroup.leave()
        }

        do {
            // Recover interrupted migration cutover before touching DatabaseKeyProvider.
            recoverInterruptedMigrationCutoverIfNeeded()

            // Probe History.sqlite without mutating bytes or mtime.
            let probeState = try probeExistingDatabaseReadOnly()
            let keys = try resolveAndVerifyStoreKeys(for: probeState)
            let writer = try openPreparedDatabaseWriter(for: probeState, keys: keys)
            sweepLeftoverScrubbingAndSupersededPlaintextAssets(in: writer, keys: keys)
            try activateOpenedStore(writer: writer, keys: keys)
        } catch {
            recordOpenFailure(error)
            throw error
        }
    }

    private func beginOpenAttemptIfNeeded(allowRetryFromFailure: Bool) throws -> Bool {
        try state.withLock { s in
            guard s.lifecycle == .open else {
                throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
            }
            if allowRetryFromFailure {
                s.openFailure = nil
            } else {
                switch s.lockState {
                case .locked(let reason):
                    throw HistoryStoreError.encryptionKeyUnavailable(reason)
                case .keyMismatch:
                    throw HistoryStoreError.encryptionKeyMismatch
                case .unlocked:
                    if let openFailure = s.openFailure {
                        throw openFailure
                    }
                }
            }
            if s.isReady {
                return false
            }
            activeAccessGroup.enter()
            return true
        }
    }

    private func resolveAndVerifyStoreKeys(for probeState: DatabaseProbeState) throws -> ClipBookDerivedKeys {
        let keys: ClipBookDerivedKeys
        switch probeState {
        case .fresh, .legacy:
            let masterKey = try keyProvider.loadOrCreateMasterKey(canCreateNewKey: true)
            keys = ClipBookDerivedKeys(masterKey: masterKey)
        case .existingV5(let verifier):
            let masterKey = try keyProvider.loadOrCreateMasterKey(canCreateNewKey: false)
            let candidateKeys = ClipBookDerivedKeys(masterKey: masterKey)
            guard HistoryCrypto.verifyKeyVerifier(verifier, keys: candidateKeys) else {
                state.withLock {
                    $0.lockState = .keyMismatch
                    $0.openFailure = nil
                }
                throw HistoryStoreError.encryptionKeyMismatch
            }
            keys = candidateKeys
        }
        state.withLock {
            $0.lockState = .unlocked
            $0.openFailure = nil
        }
        return keys
    }

    private func openPreparedDatabaseWriter(
        for probeState: DatabaseProbeState,
        keys: ClipBookDerivedKeys
    ) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch probeState {
        case .legacy:
            try migrateLegacyDatabaseToV5(keys: keys)
        case .fresh:
            try precreateFreshDatabaseFile()
        case .existingV5:
            break
        }

        let writer = try Self.makeDatabaseWriter(at: databaseURL.path)
        if case .fresh = probeState {
            do {
                try bootstrapFreshV5Schema(in: writer, keys: keys)
            } catch {
                closeWriterCleanly(writer)
                throw error
            }
        }
        return writer
    }

    private func bootstrapFreshV5Schema(in writer: any DatabaseWriter, keys: ClipBookDerivedKeys) throws {
        try writer.unsafeReentrantWrite { db in
            try db.inTransaction(.immediate) {
                try Self.createV5Schema(in: db)
                let verifier = HistoryCrypto.makeKeyVerifier(keys: keys)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?, ?)",
                    arguments: [Self.keyVerifierMetadataKey, verifier]
                )
                try db.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion)")
                return .commit
            }
        }
        try? writer.barrierWriteWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    private func activateOpenedStore(writer: any DatabaseWriter, keys: ClipBookDerivedKeys) throws {
        let initialSVGIDs: Set<UUID> = (try? writer.unsafeReentrantRead { db in
            Set(
                try String.fetchAll(db, sql: "SELECT id FROM clips WHERE isSVGText != 0")
                    .compactMap(UUID.init(uuidString:))
            )
        }) ?? []
        knownSVGClipIDs.withLock { $0 = initialSVGIDs }

        ImageAssetStore.registerKeys(keys, forSupportDirectory: directory, ownerID: instanceID)
        SVGImageRenderer.registerTextLoader(
            { [weak self] clipID in
                self?.loadDecryptedSVGText(for: clipID)
            },
            ownsClip: { [weak self] clipID in
                self?.ownsKnownSVGClip(id: clipID) ?? false
            },
            ownerID: instanceID
        )

        let installed = state.withLock { s -> Bool in
            guard s.lifecycle == .open else {
                return false
            }
            s.dbWriter = writer
            s.keys = keys
            s.lockState = .unlocked
            s.openFailure = nil
            return true
        }

        if !installed {
            SVGImageRenderer.unregisterTextLoader(ownerID: instanceID)
            ImageAssetStore.unregisterKeys(forSupportDirectory: directory, ownerID: instanceID)
            closeWriterCleanly(writer)
            throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
        }
    }

    private func recordOpenFailure(_ error: any Error) {
        state.withLock { s in
            guard s.lifecycle == .open else {
                return
            }
            if let storeError = error as? HistoryStoreError {
                switch storeError {
                case .encryptionKeyUnavailable(let reason):
                    s.lockState = .locked(reason)
                    s.openFailure = nil
                case .encryptionKeyMismatch:
                    s.lockState = .keyMismatch
                    s.openFailure = nil
                default:
                    s.openFailure = storeError
                }
            } else {
                s.openFailure = error
            }
        }
    }

    private func ownsKnownSVGClip(id: UUID) -> Bool {
        guard isOpen else {
            return false
        }
        return knownSVGClipIDs.withLock { $0.contains(id) }
    }

    private func loadDecryptedSVGText(for clipID: UUID) -> String? {
        guard isOpen, knownSVGClipIDs.withLock({ $0.contains(clipID) }) else {
            return nil
        }
        return try? withRead { db, keys in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT c.isEncrypted, cc.text
                    FROM clips c
                    LEFT JOIN clip_contents cc ON cc.clipId = c.id
                    WHERE c.id = ?
                    LIMIT 1
                    """,
                arguments: [clipID.uuidString]
            ) else {
                return nil
            }
            let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
            return try Self.decodeStringColumn(
                from: row,
                column: .clipContent(.text),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
        }
    }

    private func recoverInterruptedMigrationCutoverIfNeeded() {
        let dbExists = Self.fileOrSymlinkExists(at: databaseURL)
        let scrubbingExists = Self.fileOrSymlinkExists(at: scrubbingDBURL)
        let migratingExists = Self.fileOrSymlinkExists(at: migratingURL)

        guard scrubbingExists || (!dbExists && migratingExists) else {
            return
        }

        if migratingExists && isCompletedV5MigratingDatabase(at: migratingURL) {
            _ = Darwin.rename(migratingURL.path, databaseURL.path)
            return
        }

        if !dbExists && scrubbingExists {
            _ = Darwin.rename(scrubbingDBURL.path, databaseURL.path)
            if Self.fileOrSymlinkExists(at: scrubbingWALURL) && !Self.fileOrSymlinkExists(at: walURL) {
                _ = Darwin.rename(scrubbingWALURL.path, walURL.path)
            }
            if Self.fileOrSymlinkExists(at: scrubbingSHMURL) && !Self.fileOrSymlinkExists(at: shmURL) {
                _ = Darwin.rename(scrubbingSHMURL.path, shmURL.path)
            }
            if Self.fileOrSymlinkExists(at: scrubbingJournalURL) && !Self.fileOrSymlinkExists(at: journalURL) {
                _ = Darwin.rename(scrubbingJournalURL.path, journalURL.path)
            }
            return
        }

        if dbExists && scrubbingExists && Self.sameInode(databaseURL, scrubbingDBURL) {
            _ = Darwin.unlink(scrubbingDBURL.path)
            if Self.fileOrSymlinkExists(at: scrubbingWALURL) && !Self.fileOrSymlinkExists(at: walURL) {
                _ = Darwin.rename(scrubbingWALURL.path, walURL.path)
            }
            if Self.fileOrSymlinkExists(at: scrubbingSHMURL) && !Self.fileOrSymlinkExists(at: shmURL) {
                _ = Darwin.rename(scrubbingSHMURL.path, shmURL.path)
            }
            if Self.fileOrSymlinkExists(at: scrubbingJournalURL) && !Self.fileOrSymlinkExists(at: journalURL) {
                _ = Darwin.rename(scrubbingJournalURL.path, journalURL.path)
            }
        }
    }

    private func isCompletedV5MigratingDatabase(at url: URL) -> Bool {
        (try? Self.withNonMutatingProbeDatabase(
            at: url,
            shmURL: URL(fileURLWithPath: url.path + "-shm", isDirectory: false),
            walURL: URL(fileURLWithPath: url.path + "-wal", isDirectory: false),
            journalURL: URL(fileURLWithPath: url.path + "-journal", isDirectory: false)
        ) { db in
            let version = (try Int.fetchOne(db, sql: "PRAGMA user_version")) ?? 0
            guard version == Self.currentSchemaVersion,
                  try db.tableExists("store_metadata"),
                  let verifier = try Data.fetchOne(
                      db,
                      sql: "SELECT value FROM store_metadata WHERE key = ?",
                      arguments: [Self.keyVerifierMetadataKey]
                  ) else {
                return false
            }
            return verifier.count == SHA256.byteCount
        }) ?? false
    }

    private func probeExistingDatabaseReadOnly() throws -> DatabaseProbeState {
        var st = stat()
        guard Darwin.lstat(databaseURL.path, &st) == 0 else {
            if errno == ENOENT {
                return .fresh
            }
            throw HistoryStoreError.openFailed
        }

        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.openFailed
        }

        if st.st_size == 0 {
            return .fresh
        }

        return try Self.withNonMutatingProbeDatabase(
            at: databaseURL,
            shmURL: shmURL,
            walURL: walURL,
            journalURL: journalURL
        ) { db in
            let userVersion = (try Int.fetchOne(db, sql: "PRAGMA user_version")) ?? 0
            let hasStoreMetadata = try db.tableExists("store_metadata")

            if hasStoreMetadata {
                guard let verifier = try Data.fetchOne(
                    db,
                    sql: "SELECT value FROM store_metadata WHERE key = ?",
                    arguments: [Self.keyVerifierMetadataKey]
                ), verifier.count == SHA256.byteCount else {
                    state.withLock { $0.lockState = .keyMismatch }
                    throw HistoryStoreError.encryptionKeyMismatch
                }
                return .existingV5(verifier: verifier)
            }

            if userVersion < Self.currentSchemaVersion {
                let hasClips = try db.tableExists(AEADTable.clips)
                if !hasClips && userVersion == 0 {
                    return .fresh
                }
                return .legacy(version: userVersion)
            }

            throw HistoryStoreError.migrationFailed("Missing store_metadata on schema version \(userVersion)")
        }
    }

    private static func withNonMutatingProbeDatabase<T>(
        at dbURL: URL,
        shmURL: URL,
        walURL: URL,
        journalURL: URL,
        _ body: (Database) throws -> T
    ) throws -> T {
        var dbStat = stat()
        guard Darwin.lstat(dbURL.path, &dbStat) == 0,
              (dbStat.st_mode & S_IFMT) == S_IFREG,
              dbStat.st_size > 0 else {
            throw HistoryStoreError.openFailed
        }

        let shmSize = try regularSidecarSizeIfPresent(at: shmURL)
        let walSize = try regularSidecarSizeIfPresent(at: walURL) ?? 0
        let journalSize = try regularSidecarSizeIfPresent(at: journalURL) ?? 0
        let shmExists = (shmSize != nil)

        // Case 1: No -shm and no unrecovered -wal/-journal -> pure pread via ?immutable=1
        // (zero lock files, zero -wal/-shm creation or unlinking, zero mtime changes).
        if !shmExists && walSize == 0 && journalSize == 0 {
            let checkFD = Darwin.open(dbURL.path, O_RDONLY | O_NOFOLLOW)
            guard checkFD >= 0 else {
                throw HistoryStoreError.openFailed
            }
            var fdStat = stat()
            let isReg = Darwin.fstat(checkFD, &fdStat) == 0 && (fdStat.st_mode & S_IFMT) == S_IFREG
            _ = Darwin.close(checkFD)
            guard isReg else {
                throw HistoryStoreError.openFailed
            }

            var readonlyConfig = Configuration()
            readonlyConfig.readonly = true
            readonlyConfig.foreignKeysEnabled = true
            readonlyConfig.busyMode = .timeout(databaseBusyTimeoutSeconds)
            readonlyConfig.prepareDatabase { db in
                try db.execute(sql: """
                    PRAGMA trusted_schema = OFF;
                    PRAGMA cell_size_check = ON;
                    PRAGMA temp_store = MEMORY;
                    """)
            }

            let immutableURI = URL(fileURLWithPath: dbURL.path, isDirectory: false).absoluteString + "?immutable=1"
            let probeQueue = try DatabaseQueue(path: immutableURI, configuration: readonlyConfig)
            defer {
                try? probeQueue.close()
            }
            return try probeQueue.read { db in
                try body(db)
            }
        }

        // Case 2: Uncheckpointed -wal, existing -shm, or hot -journal -> copy into an isolated
        // 0o700 ephemeral directory, replay WAL/journal on the temp copy, and secure-unlink all temp files.
        let baseTempDir = FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: baseTempDir, withIntermediateDirectories: true)

        let probeDir = baseTempDir.appendingPathComponent("clipbook-probe-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(probeDir.path, mode_t(0o700)) == 0 else {
            throw HistoryStoreError.openFailed
        }
        _ = Darwin.chmod(probeDir.path, mode_t(0o700))

        var tempQueue: DatabaseQueue?
        defer {
            try? tempQueue?.close()
            tempQueue = nil
            scrubAndRemoveProbeDirectory(at: probeDir)
        }

        let tempDBURL = probeDir.appendingPathComponent(dbURL.lastPathComponent, isDirectory: false)
        try copyRegularFile0600(from: dbURL, to: tempDBURL)

        let tempWALURL = URL(fileURLWithPath: tempDBURL.path + "-wal", isDirectory: false)
        let tempJournalURL = URL(fileURLWithPath: tempDBURL.path + "-journal", isDirectory: false)

        if walSize > 0 {
            let copiedWAL = try copyRegularFile0600(from: walURL, to: tempWALURL, allowMissingSource: true)
            if copiedWAL {
                _ = Darwin.link(tempWALURL.path, tempWALURL.path + ".pin")
            } else {
                try copyRegularFile0600(from: dbURL, to: tempDBURL)
            }
        }

        if journalSize > 0 {
            let copiedJournal = try copyRegularFile0600(
                from: journalURL,
                to: tempJournalURL,
                allowMissingSource: true
            )
            if copiedJournal {
                _ = Darwin.link(tempJournalURL.path, tempJournalURL.path + ".pin")
            } else {
                try copyRegularFile0600(from: dbURL, to: tempDBURL)
            }
        }

        var tempConfig = Configuration()
        tempConfig.foreignKeysEnabled = true
        tempConfig.busyMode = .timeout(databaseBusyTimeoutSeconds)
        tempConfig.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                PRAGMA secure_delete = ON;
                """)
        }

        let openedQueue = try DatabaseQueue(path: tempDBURL.path, configuration: tempConfig)
        tempQueue = openedQueue

        let result = try openedQueue.read { db in
            try body(db)
        }

        try? openedQueue.close()
        tempQueue = nil
        return result
    }

    private static func regularSidecarSizeIfPresent(at url: URL) throws -> Int64? {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw HistoryStoreError.openFailed
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.openFailed
        }
        return Int64(st.st_size)
    }

    @discardableResult
    private static func copyRegularFile0600(
        from sourceURL: URL,
        to destinationURL: URL,
        allowMissingSource: Bool = false,
        fullFsync: Bool = false,
        failureError: @autoclosure () -> any Error = HistoryStoreError.openFailed
    ) throws -> Bool {
        let inFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard inFD >= 0 else {
            if allowMissingSource && errno == ENOENT {
                return false
            }
            throw failureError()
        }
        defer {
            _ = Darwin.close(inFD)
        }

        var inStat = stat()
        guard Darwin.fstat(inFD, &inStat) == 0,
              (inStat.st_mode & S_IFMT) == S_IFREG else {
            throw failureError()
        }

        let outFD = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        guard outFD >= 0 else {
            throw failureError()
        }

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        defer {
            buffer.withUnsafeMutableBytes { rawBuffer in
                if let base = rawBuffer.baseAddress, rawBuffer.count > 0 {
                    _ = memset_s(base, rawBuffer.count, 0, rawBuffer.count)
                }
            }
        }

        var outFDOpen = true
        do {
            _ = Darwin.fchmod(outFD, mode_t(0o600))
            try buffer.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while true {
                    let bytesRead = Darwin.read(inFD, base, chunkSize)
                    if bytesRead > 0 {
                        var writtenTotal = 0
                        while writtenTotal < bytesRead {
                            let written = Darwin.write(outFD, base.advanced(by: writtenTotal), bytesRead - writtenTotal)
                            if written > 0 {
                                writtenTotal += written
                            } else if written < 0 && errno == EINTR {
                                continue
                            } else {
                                throw failureError()
                            }
                        }
                    } else if bytesRead == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        throw failureError()
                    }
                }
            }
            if fullFsync {
                if Darwin.fcntl(outFD, F_FULLFSYNC) != 0 {
                    _ = Darwin.fsync(outFD)
                }
            }
            outFDOpen = false
            guard Darwin.close(outFD) == 0 else {
                throw failureError()
            }
            return true
        } catch {
            if outFDOpen {
                _ = Darwin.close(outFD)
            }
            ImageAssetStore.secureUnlink(at: destinationURL)
            throw error
        }
    }

    private static func scrubAndRemoveProbeDirectory(at probeDir: URL) {
        ImageAssetStore.secureRemoveItem(at: probeDir)
    }

    private func precreateFreshDatabaseFile() throws {
        let fd = Darwin.open(databaseURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw HistoryStoreError.openFailed
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        _ = Darwin.close(fd)

        var bootstrapConfig = Configuration()
        bootstrapConfig.foreignKeysEnabled = true
        bootstrapConfig.busyMode = .timeout(Self.databaseBusyTimeoutSeconds)
        bootstrapConfig.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                PRAGMA secure_delete = ON;
                """)
        }

        let bootstrapQueue = try DatabaseQueue(path: databaseURL.path, configuration: bootstrapConfig)
        do {
            try bootstrapQueue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL;")
            }
            try bootstrapQueue.close()
        } catch {
            try? bootstrapQueue.close()
            throw error
        }
    }

    private static func makeConnectionConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(databaseBusyTimeoutSeconds)
        config.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                """)
            if !db.configuration.readonly {
                if let conn = db.sqliteConnection {
                    var persistWAL: CInt = 0
                    _ = sqlite3_file_control(conn, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
                }
                try db.execute(sql: """
                    PRAGMA secure_delete = ON;
                    PRAGMA journal_size_limit = \(Self.walJournalSizeLimit);
                    """)
            }
        }
        return config
    }

    private static func makeDatabaseWriter(at path: String) throws -> any DatabaseWriter {
        let config = makeConnectionConfiguration()
        do {
            return try DatabasePool(path: path, configuration: config)
        } catch {
            return try DatabaseQueue(path: path, configuration: config)
        }
    }

    private nonisolated struct OverlappingAssetDirectory {
        let files: [URL]
        let encryptedStems: Set<String>
    }

    private nonisolated struct ReferencedAssetFileNames {
        var unencrypted: Set<String> = []
        var encrypted: Set<String> = []
    }

    private func sweepLeftoverScrubbingAndSupersededPlaintextAssets(
        in writer: any DatabaseWriter,
        keys: ClipBookDerivedKeys
    ) {
        sweepScrubbingDatabaseSidecars()

        // Inspect managed asset directories on disk first, scrubbing any leftover .scrubbing files
        // immediately and checking whether any stem has both .enc and plain files present before
        // querying SQLite or decrypting rows.
        let overlappingDirectories = scanOverlappingManagedAssetDirectories()
        guard !overlappingDirectories.isEmpty else {
            return
        }

        // Resolve referenced plaintext and encrypted filenames from SQLite only when a stem has
        // both .enc and plain files on disk after an interrupted post-commit cleanup.
        let referenced = Self.fetchReferencedManagedAssetFileNames(in: writer, keys: keys)
        for directoryScan in overlappingDirectories {
            Self.unlinkUnreferencedCollidingAssets(in: directoryScan, referenced: referenced)
        }
    }

    func unlinkOrScrubSupportEntry(at url: URL) {
        if Self.sameInode(url, databaseURL) {
            _ = Darwin.unlink(url.path)
        } else {
            ImageAssetStore.secureUnlink(at: url)
        }
    }

    private func sweepScrubbingDatabaseSidecars() {
        let scrubbingCandidates: [URL] = [
            scrubbingDBURL,
            scrubbingWALURL,
            scrubbingSHMURL,
            scrubbingJournalURL,
        ]
        for candidate in scrubbingCandidates where Self.fileOrSymlinkExists(at: candidate) {
            unlinkOrScrubSupportEntry(at: candidate)
        }

        guard let dirContents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for entry in dirContents where entry.lastPathComponent.hasSuffix(".scrubbing") {
            unlinkOrScrubSupportEntry(at: entry)
        }
    }

    private func scanOverlappingManagedAssetDirectories() -> [OverlappingAssetDirectory] {
        [assetStore.imagesDirectory, assetStore.linkPreviewsDirectory]
            .compactMap(Self.scanManagedAssetDirectoryForOverlaps)
    }

    private static func scanManagedAssetDirectoryForOverlaps(_ assetDir: URL) -> OverlappingAssetDirectory? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: assetDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return nil
        }

        var visibleFiles: [URL] = []
        visibleFiles.reserveCapacity(entries.count)
        var encStems: Set<String> = []
        var plainStems: Set<String> = []

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".scrubbing") {
                ImageAssetStore.secureUnlink(at: entry)
                continue
            }
            if name.hasPrefix(".") {
                continue
            }
            visibleFiles.append(entry)
            let ext = entry.pathExtension.lowercased()
            let stem = entry.deletingPathExtension().lastPathComponent
            if ext == "enc" {
                encStems.insert(stem)
            } else {
                plainStems.insert(stem)
            }
        }

        guard !encStems.isDisjoint(with: plainStems) else {
            return nil
        }
        return OverlappingAssetDirectory(files: visibleFiles, encryptedStems: encStems)
    }

    private static func fetchReferencedManagedAssetFileNames(
        in writer: any DatabaseWriter,
        keys: ClipBookDerivedKeys
    ) -> ReferencedAssetFileNames {
        (try? writer.unsafeReentrantRead { db -> ReferencedAssetFileNames in
            let decoder = makeJSONDecoder()
            var referenced = ReferencedAssetFileNames()
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, isEncrypted, assetPath, linkPreviewData
                    FROM clips
                    WHERE assetPath IS NOT NULL OR linkPreviewData IS NOT NULL
                    """
            )
            while let row = try cursor.next() {
                collectReferencedAssetFileNames(
                    from: row,
                    keys: keys,
                    decoder: decoder,
                    into: &referenced
                )
            }
            return referenced
        }) ?? ReferencedAssetFileNames()
    }

    private static func collectReferencedAssetFileNames(
        from row: Row,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder,
        into referenced: inout ReferencedAssetFileNames
    ) {
        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        if !isEncrypted {
            if let assetData: Data = row[ClipAEADColumn.assetPath.rawValue],
               let path = String(data: assetData, encoding: .utf8) {
                referenced.unencrypted.insert(URL(fileURLWithPath: path).lastPathComponent)
            }
            if let lpData: Data = row[ClipAEADColumn.linkPreviewData.rawValue],
               let details = try? decoder.decode(LinkPreviewDetails.self, from: lpData) {
                if let imgPath = details.imagePath {
                    referenced.unencrypted.insert(URL(fileURLWithPath: imgPath).lastPathComponent)
                }
                if let favPath = details.faviconPath {
                    referenced.unencrypted.insert(URL(fileURLWithPath: favPath).lastPathComponent)
                }
            }
            return
        }

        guard let idString: String = row["id"],
              let clipID = UUID(uuidString: idString) else {
            return
        }
        if let path = try? decodeProtectedAssetPath(
            from: row,
            clipID: clipID,
            isEncrypted: true,
            keys: keys
        ) {
            referenced.encrypted.insert(URL(fileURLWithPath: path).lastPathComponent)
        }
        if let details = try? decodeProtectedLinkPreview(
            from: row,
            clipID: clipID,
            isEncrypted: true,
            keys: keys,
            decoder: decoder
        ) {
            if let imgPath = details.imagePath {
                referenced.encrypted.insert(URL(fileURLWithPath: imgPath).lastPathComponent)
            }
            if let favPath = details.faviconPath {
                referenced.encrypted.insert(URL(fileURLWithPath: favPath).lastPathComponent)
            }
        }
    }

    private static func unlinkUnreferencedCollidingAssets(
        in directoryScan: OverlappingAssetDirectory,
        referenced: ReferencedAssetFileNames
    ) {
        var existingPlainStemsReferencedByUnencryptedRows: Set<String> = []
        for file in directoryScan.files where file.pathExtension.lowercased() != "enc" {
            if referenced.unencrypted.contains(file.lastPathComponent) {
                existingPlainStemsReferencedByUnencryptedRows.insert(
                    file.deletingPathExtension().lastPathComponent
                )
            }
        }

        for file in directoryScan.files {
            let ext = file.pathExtension.lowercased()
            let stem = file.deletingPathExtension().lastPathComponent
            let shouldUnlink: Bool
            if ext != "enc" {
                shouldUnlink = directoryScan.encryptedStems.contains(stem)
                    && !referenced.unencrypted.contains(file.lastPathComponent)
            } else {
                shouldUnlink = existingPlainStemsReferencedByUnencryptedRows.contains(stem)
                    && !referenced.unencrypted.contains(file.lastPathComponent)
                    && !referenced.encrypted.contains(file.lastPathComponent)
            }
            if shouldUnlink {
                ImageAssetStore.secureUnlink(at: file)
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: file.path)
            }
        }
    }

    // MARK: - Normalized v5 DDL

    private static func createV5Schema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                color TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                copiedAt REAL NOT NULL,
                firstCopiedAt REAL NOT NULL,
                deletedAt REAL,
                expiresAt REAL,
                copySequenceID REAL,
                copySequenceOrder INTEGER,
                byteSize INTEGER NOT NULL,
                copyCount INTEGER NOT NULL,
                isFavorite INTEGER NOT NULL,
                favoriteOrder INTEGER,
                sourceAppName TEXT,
                sourceBundleIdentifier TEXT,
                sensitivity TEXT,
                isEncrypted INTEGER NOT NULL DEFAULT 0,
                title BLOB,
                textPreview BLOB,
                characterCount INTEGER NOT NULL DEFAULT 0,
                containsPreviewSecret INTEGER NOT NULL DEFAULT 0,
                containsRestSecret INTEGER NOT NULL DEFAULT 0,
                hasRecognizedText INTEGER NOT NULL DEFAULT 0,
                hasQRCodeText INTEGER NOT NULL DEFAULT 0,
                isSVGText INTEGER NOT NULL DEFAULT 0,
                hasFormatting INTEGER NOT NULL DEFAULT 0,
                htmlDigest BLOB,
                imageDigest BLOB,
                imageWidth INTEGER,
                imageHeight INTEGER,
                assetPath BLOB,
                filePathsData BLOB NOT NULL,
                linkPreviewData BLOB,
                contentKey BLOB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_clips_active_copiedAt
                ON clips(copiedAt DESC) WHERE deletedAt IS NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_trashed_deletedAt
                ON clips(deletedAt DESC) WHERE deletedAt IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_active_kind_copiedAt
                ON clips(kind, copiedAt DESC) WHERE deletedAt IS NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_kind_contentKey
                ON clips(kind, contentKey);
            CREATE INDEX IF NOT EXISTS idx_clips_expiresAt
                ON clips(expiresAt) WHERE expiresAt IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_stored_files
                ON clips(id) WHERE assetPath IS NOT NULL OR linkPreviewData IS NOT NULL;

            CREATE TABLE IF NOT EXISTS clip_contents (
                clipId TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                text BLOB,
                qrCodeText BLOB,
                rtf BLOB,
                html BLOB
            );

            CREATE TABLE IF NOT EXISTS clip_tags (
                clipId TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                tagId INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                sortOrder INTEGER,
                PRIMARY KEY (clipId, tagId)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS idx_clip_tags_tagId ON clip_tags(tagId);

            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
            """)
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

    private func reconcileManagedAssetsForPersistence(
        _ workingItem: inout ClipboardItem,
        shouldEncrypt: Bool,
        keys: ClipBookDerivedKeys
    ) throws {
        if let oldAssetPath = workingItem.assetPath {
            workingItem.assetPath = try stageReconciledAssetPath(
                oldAssetPath,
                role: .image,
                clipID: workingItem.id,
                shouldEncrypt: shouldEncrypt,
                keys: keys
            )
        }

        if var details = workingItem.linkPreviewDetails {
            if let oldImagePath = details.imagePath {
                details.imagePath = try stageReconciledAssetPath(
                    oldImagePath,
                    role: .linkPreview,
                    clipID: workingItem.id,
                    shouldEncrypt: shouldEncrypt,
                    keys: keys
                )
            }
            if let oldFaviconPath = details.faviconPath {
                details.faviconPath = try stageReconciledAssetPath(
                    oldFaviconPath,
                    role: .linkFavicon,
                    clipID: workingItem.id,
                    shouldEncrypt: shouldEncrypt,
                    keys: keys
                )
            }
            workingItem.linkPreviewDetails = details
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
        if let currentAssetPath = workingItem.assetPath {
            let stagedAssetPath = try stageNonDestructiveEncryptedAssetIfNeeded(
                path: currentAssetPath,
                role: .image,
                clipID: workingItem.id,
                keys: keys
            )
            if stagedAssetPath != currentAssetPath {
                workingItem.assetPath = stagedAssetPath
            }
        }

        guard var details = workingItem.linkPreviewDetails else {
            return
        }
        var detailsChanged = false
        if let currentImagePath = details.imagePath {
            let stagedImagePath = try stageNonDestructiveEncryptedAssetIfNeeded(
                path: currentImagePath,
                role: .linkPreview,
                clipID: workingItem.id,
                keys: keys
            )
            if stagedImagePath != currentImagePath {
                details.imagePath = stagedImagePath
                detailsChanged = true
            }
        }
        if let currentFaviconPath = details.faviconPath {
            let stagedFaviconPath = try stageNonDestructiveEncryptedAssetIfNeeded(
                path: currentFaviconPath,
                role: .linkFavicon,
                clipID: workingItem.id,
                keys: keys
            )
            if stagedFaviconPath != currentFaviconPath {
                details.faviconPath = stagedFaviconPath
                detailsChanged = true
            }
        }
        if detailsChanged {
            workingItem.linkPreviewDetails = details
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
            tagNames: nil
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

    // MARK: - Column AEAD & Row Decoding Helpers

    static func encodeStringColumn(
        _ value: String?,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        let utf8 = Data(value.utf8)
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                utf8,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return utf8
    }

    static func encodeOptionalDataColumn(
        _ value: Data?,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                value,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return value
    }

    static func encodeRequiredDataColumn(
        _ value: Data,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                value,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return value
    }

    static func decodeDataColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        let dbValue: DatabaseValue = row[rowColumn ?? column.aadColumn]
        switch dbValue.storage {
        case .null:
            return nil
        case .blob(let data):
            if isEncrypted {
                return try HistoryCrypto.openColumn(
                    data,
                    table: column.aadTable,
                    column: column.aadColumn,
                    clipID: clipID,
                    keys: keys
                )
            }
            return data
        case .string(let string):
            if isEncrypted {
                throw HistoryStoreError.authenticationFailed
            }
            return Data(string.utf8)
        case .int64, .double:
            throw HistoryStoreError.authenticationFailed
        }
    }

    static func decodeRequiredDataColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        guard let data = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            throw HistoryStoreError.authenticationFailed
        }
        return data
    }

    static func decodeStringColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let data = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw HistoryStoreError.authenticationFailed
        }
        return string
    }

    private static func hasEncryptedAssetExtension(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "enc"
    }

    static func decodeProtectedAssetPath(
        from row: Row,
        rowColumn: String = ClipAEADColumn.assetPath.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let path = try decodeStringColumn(
            from: row,
            rowColumn: rowColumn,
            column: .clip(.assetPath),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        if isEncrypted && !hasEncryptedAssetExtension(path) {
            throw HistoryStoreError.authenticationFailed
        }
        return path
    }

    static func decodeProtectedLinkPreview(
        from row: Row,
        rowColumn: String = ClipAEADColumn.linkPreviewData.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> LinkPreviewDetails? {
        guard let jsonData = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            column: .clip(.linkPreviewData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        let details: LinkPreviewDetails
        do {
            details = try decoder.decode(LinkPreviewDetails.self, from: jsonData)
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
        if isEncrypted {
            if let imagePath = details.imagePath, !hasEncryptedAssetExtension(imagePath) {
                throw HistoryStoreError.authenticationFailed
            }
            if let faviconPath = details.faviconPath, !hasEncryptedAssetExtension(faviconPath) {
                throw HistoryStoreError.authenticationFailed
            }
        }
        return details
    }

    static func decodeProtectedFilePaths(
        from row: Row,
        rowColumn: String = ClipAEADColumn.filePathsData.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> [String] {
        let jsonData = try decodeRequiredDataColumn(
            from: row,
            rowColumn: rowColumn,
            column: .clip(.filePathsData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        if jsonData.count == 2,
           jsonData[jsonData.startIndex] == 0x5B,
           jsonData[jsonData.index(after: jsonData.startIndex)] == 0x5D {
            return []
        }
        do {
            return try decoder.decode([String].self, from: jsonData)
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
    }

    nonisolated struct UnsealedClipHeaderMetadata {
        let id: UUID
        let kind: ClipboardKind
        let copiedAt: Date
        let firstCopiedAt: Date
        let deletedAt: Date?
        let expiresAt: Date?
        let copySequenceID: Date?
        let copySequenceOrder: Int?
        let byteSize: Int
        let copyCount: Int
        let isFavorite: Bool
        let favoriteOrder: Int?
        let sourceAppName: String?
        let sourceBundleIdentifier: String?
        let sensitivity: ItemSensitivity?
        let isEncrypted: Bool
        let storedContentKey: Data?
        let characterCount: Int
        let containsPreviewSecret: Bool
        let containsRestSecret: Bool
        let hasRecognizedText: Bool
        let hasQRCodeText: Bool
        let isSVGText: Bool
        let hasFormatting: Bool
        let imageWidth: Int?
        let imageHeight: Int?

        init?(row: Row) {
            guard let idString: String = row["id"],
                  let clipID = UUID(uuidString: idString) else {
                return nil
            }
            let kindRaw: String = row["kind"] ?? ClipboardKind.text.rawValue
            let copiedAtTimestamp = (row["copiedAt"] as Double?) ?? 0

            self.id = clipID
            self.kind = ClipboardKind(rawValue: kindRaw) ?? .text
            self.copiedAt = Date(timeIntervalSince1970: copiedAtTimestamp)
            self.firstCopiedAt = Date(timeIntervalSince1970: (row["firstCopiedAt"] as Double?) ?? copiedAtTimestamp)
            self.deletedAt = (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.expiresAt = (row["expiresAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.copySequenceID = (row["copySequenceID"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.copySequenceOrder = row["copySequenceOrder"]
            self.byteSize = row["byteSize"] ?? 0
            self.copyCount = row["copyCount"] ?? 0
            self.isFavorite = ((row["isFavorite"] as Int?) ?? 0) != 0
            self.favoriteOrder = row["favoriteOrder"]
            self.sourceAppName = row["sourceAppName"]
            self.sourceBundleIdentifier = row["sourceBundleIdentifier"]
            self.sensitivity = (row["sensitivity"] as String?).flatMap(ItemSensitivity.init(rawValue:))
            self.isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
            self.storedContentKey = row["contentKey"]
            self.characterCount = (row["characterCount"] as Int?) ?? 0
            self.containsPreviewSecret = ((row["containsPreviewSecret"] as Int?) ?? 0) != 0
            self.containsRestSecret = ((row["containsRestSecret"] as Int?) ?? 0) != 0
            self.hasRecognizedText = ((row["hasRecognizedText"] as Int?) ?? 0) != 0
            self.hasQRCodeText = ((row["hasQRCodeText"] as Int?) ?? 0) != 0
            self.isSVGText = ((row["isSVGText"] as Int?) ?? 0) != 0
            self.hasFormatting = ((row["hasFormatting"] as Int?) ?? 0) != 0
            self.imageWidth = row["imageWidth"]
            self.imageHeight = row["imageHeight"]
        }
    }

    private nonisolated struct SealedClipHeaderFields {
        let title: String?
        let textPreview: String?
        let htmlDigest: String?
        let imageDigest: String?
        let assetPath: String?
        let filePaths: [String]
        let linkPreviewDetails: LinkPreviewDetails?
    }

    private static func decodeSealedClipHeaderFields(
        from row: Row,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> SealedClipHeaderFields {
        SealedClipHeaderFields(
            title: try decodeStringColumn(
                from: row,
                column: .clip(.title),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            textPreview: try decodeStringColumn(
                from: row,
                column: .clip(.textPreview),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            htmlDigest: try decodeStringColumn(
                from: row,
                column: .clip(.htmlDigest),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            imageDigest: try decodeStringColumn(
                from: row,
                column: .clip(.imageDigest),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            assetPath: try decodeProtectedAssetPath(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            filePaths: try decodeProtectedFilePaths(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            ),
            linkPreviewDetails: try decodeProtectedLinkPreview(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
        )
    }

    static func authenticateEncryptedClipHeaderColumns(
        in row: Row,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws {
        _ = try decodeSealedClipHeaderFields(
            from: row,
            clipID: clipID,
            isEncrypted: true,
            keys: keys,
            decoder: makeJSONDecoder()
        )
    }

    private static func makeStoredHeaderItem(
        metadata: UnsealedClipHeaderMetadata,
        sealed: SealedClipHeaderFields,
        attachment: TagAttachment
    ) -> ClipboardItem {
        ClipboardItem.fromStoredHeader(
            id: metadata.id,
            kind: metadata.kind,
            title: sealed.title,
            textPreview: sealed.textPreview,
            characterCount: metadata.characterCount,
            containsPreviewSecret: metadata.containsPreviewSecret,
            containsRestSecret: metadata.containsRestSecret,
            hasRecognizedText: metadata.hasRecognizedText,
            hasQRCodeText: metadata.hasQRCodeText,
            isSVGText: metadata.isSVGText,
            hasFormatting: metadata.hasFormatting,
            htmlDigest: sealed.htmlDigest,
            imageDigest: sealed.imageDigest,
            imageWidth: metadata.imageWidth,
            imageHeight: metadata.imageHeight,
            assetPath: sealed.assetPath,
            filePaths: sealed.filePaths,
            sourceAppName: metadata.sourceAppName,
            sourceBundleIdentifier: metadata.sourceBundleIdentifier,
            copiedAt: metadata.copiedAt,
            firstCopiedAt: metadata.firstCopiedAt,
            byteSize: metadata.byteSize,
            isFavorite: metadata.isFavorite,
            tags: attachment.tagIDs,
            tagOrders: attachment.tagOrders,
            copyCount: metadata.copyCount,
            linkPreviewDetails: sealed.linkPreviewDetails,
            copySequenceID: metadata.copySequenceID,
            copySequenceOrder: metadata.copySequenceOrder,
            favoriteOrder: metadata.favoriteOrder,
            sensitivity: metadata.sensitivity,
            expiresAt: metadata.expiresAt,
            deletedAt: metadata.deletedAt,
            storedContentKey: metadata.storedContentKey
        )
    }

    private static func hydrateBatchRowBody(
        from row: Row,
        header: ClipboardItem,
        metadata: UnsealedClipHeaderMetadata,
        attachment: TagAttachment,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem {
        let bodyText = try decodeStringColumn(
            from: row,
            rowColumn: "bodyText",
            column: .clipContent(.text),
            clipID: metadata.id,
            isEncrypted: metadata.isEncrypted,
            keys: keys
        )
        let bodyQRCodeText = try decodeStringColumn(
            from: row,
            rowColumn: "bodyQRCodeText",
            column: .clipContent(.qrCodeText),
            clipID: metadata.id,
            isEncrypted: metadata.isEncrypted,
            keys: keys
        )
        return header.withLoadedContent(
            text: bodyText,
            qrCodeText: bodyQRCodeText,
            scope: .body,
            tagNames: attachment.tagNames
        )
    }

    func decodeBatchRow(
        _ row: Row,
        attachment: TagAttachment,
        hydratesBody: Bool,
        isolatesCorruptEncryptedRows: Bool = true,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> ClipboardItem? {
        guard let metadata = UnsealedClipHeaderMetadata(row: row) else {
            return nil
        }

        do {
            let sealed = try Self.decodeSealedClipHeaderFields(
                from: row,
                clipID: metadata.id,
                isEncrypted: metadata.isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let header = Self.makeStoredHeaderItem(
                metadata: metadata,
                sealed: sealed,
                attachment: attachment
            )
            guard hydratesBody else {
                return header
            }
            return try Self.hydrateBatchRowBody(
                from: row,
                header: header,
                metadata: metadata,
                attachment: attachment,
                keys: keys
            )
        } catch {
            guard metadata.isEncrypted else {
                return nil
            }
            guard isolatesCorruptEncryptedRows else {
                throw error
            }
            return Self.makeCorruptEncryptedPlaceholder(metadata: metadata, attachment: attachment)
        }
    }

    private static func makeCorruptEncryptedPlaceholder(
        metadata: UnsealedClipHeaderMetadata,
        attachment: TagAttachment
    ) -> ClipboardItem {
        ClipboardItem.fromStoredHeader(
            id: metadata.id,
            kind: metadata.kind,
            title: nil,
            textPreview: nil,
            characterCount: 0,
            containsPreviewSecret: true,
            containsRestSecret: true,
            hasRecognizedText: false,
            hasQRCodeText: false,
            isSVGText: false,
            hasFormatting: false,
            htmlDigest: nil,
            imageDigest: nil,
            imageWidth: nil,
            imageHeight: nil,
            assetPath: nil,
            filePaths: [],
            sourceAppName: metadata.sourceAppName,
            sourceBundleIdentifier: metadata.sourceBundleIdentifier,
            copiedAt: metadata.copiedAt,
            firstCopiedAt: metadata.firstCopiedAt,
            byteSize: metadata.byteSize,
            isFavorite: metadata.isFavorite,
            tags: attachment.tagIDs,
            tagOrders: attachment.tagOrders,
            copyCount: metadata.copyCount,
            linkPreviewDetails: nil,
            copySequenceID: metadata.copySequenceID,
            copySequenceOrder: metadata.copySequenceOrder,
            favoriteOrder: metadata.favoriteOrder,
            sensitivity: .sensitive,
            expiresAt: metadata.expiresAt,
            deletedAt: metadata.deletedAt,
            storedContentKey: metadata.storedContentKey,
            isCorruptPlaceholder: true
        )
    }

    static func decodeSearchTextForRow(
        _ row: Row,
        idString: String,
        tagIDs: [Int],
        tagNamesByID: [Tag.ID: String],
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) -> String {
        guard let clipID = UUID(uuidString: idString) else {
            return ""
        }
        let kindRaw: String = row["kind"] ?? ClipboardKind.text.rawValue
        let kind = ClipboardKind(rawValue: kindRaw) ?? .text
        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        let sourceAppName: String? = row["sourceAppName"]

        do {
            let title = try decodeStringColumn(
                from: row,
                column: .clip(.title),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let filePaths = try decodeProtectedFilePaths(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let linkPreviewDetails = try decodeProtectedLinkPreview(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let text = try decodeStringColumn(
                from: row,
                column: .clipContent(.text),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let qrCodeText = try decodeStringColumn(
                from: row,
                column: .clipContent(.qrCodeText),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let tagNames = tagIDs.compactMap { tagNamesByID[$0] }
            return ClipboardItem.makeSearchText(
                title: title,
                text: text,
                filePaths: kind == .image ? [] : filePaths,
                tagNames: tagNames,
                sourceAppName: sourceAppName,
                linkPreviewDetails: linkPreviewDetails,
                qrCodeText: qrCodeText
            )
        } catch {
            return ""
        }
    }

    private func fetchMatchingItem(
        in db: Database,
        kind: ClipboardKind,
        contentKeyBlob: Data,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem? {
        let sql = """
            SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE c.kind = ? AND c.contentKey = ?
            ORDER BY c.deletedAt IS NOT NULL, c.copiedAt DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [kind.rawValue, contentKeyBlob]),
              let idString: String = row["id"] else {
            return nil
        }
        let attachment = try fetchTagAttachment(in: db, clipIDString: idString)
        return try decodeBatchRow(
            row,
            attachment: attachment,
            hydratesBody: true,
            keys: keys,
            decoder: Self.makeJSONDecoder()
        )
    }

    private func fetchFullItemByID(
        in db: Database,
        id: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem? {
        let idString = id.uuidString
        let sql = """
            SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText,
                   cc.rtf AS bodyRTF, cc.html AS bodyHTML
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE c.id = ?
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [idString]) else {
            return nil
        }

        let attachment = try fetchTagAttachment(in: db, clipIDString: idString)
        let decoder = Self.makeJSONDecoder()
        guard let header = try decodeBatchRow(
            row,
            attachment: attachment,
            hydratesBody: false,
            isolatesCorruptEncryptedRows: false,
            keys: keys,
            decoder: decoder
        ) else {
            return nil
        }

        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        let text = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyText",
            column: .clipContent(.text),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let qrCodeText = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyQRCodeText",
            column: .clipContent(.qrCodeText),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let rtfData = try Self.decodeDataColumn(
            from: row,
            rowColumn: "bodyRTF",
            column: .clipContent(.rtf),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let html = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyHTML",
            column: .clipContent(.html),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )

        return header.withLoadedContent(
            text: text,
            qrCodeText: qrCodeText,
            html: html,
            rtfData: rtfData,
            scope: .full,
            tagNames: attachment.tagNames
        )
    }

    // MARK: - Tag Query Helpers

    private static func fetchAllTags(in db: Database) throws -> [Tag] {
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE ASC, id ASC"
        )
        var tags: [Tag] = []
        while let row = try cursor.next() {
            tags.append(Tag(
                id: row["id"],
                name: row["name"],
                color: row["color"]
            ))
        }
        return tags
    }

    private func fetchTagAttachments(in db: Database, trashedFilter: Bool) throws -> [String: TagAttachment] {
        let whereClause = trashedFilter ? "WHERE c.deletedAt IS NOT NULL" : "WHERE c.deletedAt IS NULL"

        let sql = """
            SELECT ct.clipId, ct.tagId, ct.sortOrder, t.name
            FROM clip_tags ct
            JOIN tags t ON t.id = ct.tagId
            JOIN clips c ON c.id = ct.clipId
            \(whereClause)
            ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
            """
        let cursor = try Row.fetchCursor(db, sql: sql)
        var map: [String: TagAttachment] = [:]
        while let row = try cursor.next() {
            let clipID: String = row["clipId"]
            map[clipID, default: TagAttachment()].append(row: row)
        }
        return map
    }

    private func fetchTagAttachments(
        in db: Database,
        forClipIDStrings clipIDStrings: [String]
    ) throws -> [String: TagAttachment] {
        guard !clipIDStrings.isEmpty else {
            return [:]
        }
        var map: [String: TagAttachment] = [:]
        var offset = 0
        while offset < clipIDStrings.count {
            let end = min(offset + Self.searchInClauseBatchLimit, clipIDStrings.count)
            let batch = Array(clipIDStrings[offset..<end])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let sql = """
                SELECT ct.clipId, ct.tagId, ct.sortOrder, t.name
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                WHERE ct.clipId IN (\(placeholders))
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(batch))
            while let row = try cursor.next() {
                let clipID: String = row["clipId"]
                map[clipID, default: TagAttachment()].append(row: row)
            }
            offset = end
        }
        return map
    }

    private func fetchTagAttachment(in db: Database, clipIDString: String) throws -> TagAttachment {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT ct.tagId, ct.sortOrder, t.name
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                WHERE ct.clipId = ?
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """,
            arguments: [clipIDString]
        )
        var attachment = TagAttachment()
        while let row = try cursor.next() {
            attachment.append(row: row)
        }
        return attachment
    }

    private func fetchOrderedTagNames(in db: Database, clipIDString: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT t.name
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                WHERE ct.clipId = ?
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """,
            arguments: [clipIDString]
        )
    }

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
            ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: legacyURL.path)
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
            keys: keys
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

    // MARK: - JSON & Low-Level POSIX Utilities

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func fileOrSymlinkExists(at url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    private static func sameInode(_ lhs: URL, _ rhs: URL) -> Bool {
        var leftStat = stat()
        var rightStat = stat()
        guard Darwin.lstat(lhs.path, &leftStat) == 0,
              Darwin.lstat(rhs.path, &rightStat) == 0 else {
            return false
        }
        return leftStat.st_dev == rightStat.st_dev && leftStat.st_ino == rightStat.st_ino
    }

    private static func fullFsyncFile(at url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else {
            throw HistoryStoreError.migrationFailed("Unable to fsync migrated database (errno \(errno))")
        }
        defer {
            _ = Darwin.close(fd)
        }
        if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
            _ = Darwin.fsync(fd)
        }
    }
}
