import CryptoKit
import Darwin
import Foundation
import GRDB
import GRDBSQLite
import ImageIO
import os

nonisolated enum GRDBRuntimeInfo {
    static func makeInMemoryQueue() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    static func sqliteVersion() throws -> String {
        try makeInMemoryQueue().read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? ""
        }
    }
}

nonisolated final class GRDBHistoryStore: HistoryStore, Sendable {
    static let currentSchemaVersion = 5
    static let keyVerifierMetadataKey = "key_verifier_v1"
    private static let walJournalSizeLimit = 4_194_304
    private static let searchInClauseBatchLimit = 500
    private static let migrationBatchSize = 500
    private static let dontSaveContentLifetime = 0

    private enum LifecycleState: Equatable, Sendable {
        case open
        case closing
        case closed
    }

    private struct StoreState: Sendable {
        var lifecycle: LifecycleState = .open
        var lockState: StoreLockState = .unlocked
        var dbWriter: (any DatabaseWriter)? = nil
        var keys: ClipBookDerivedKeys? = nil
        var needsFreePageRelease: Bool = false
        var isFreePageReleaseScheduled: Bool = false
    }

    private enum DatabaseProbeState {
        case fresh
        case legacy(version: Int)
        case existingV5(verifier: Data)
    }

    private struct TagAttachment {
        var tagIDs: [Int] = []
        var tagNames: [String] = []
        var tagOrders: [Int: Int] = [:]
    }

    let directory: URL
    let loadsBodiesOnFetchAll: Bool

    private let instanceID = UUID()
    private let keyProvider: any DatabaseKeyProvider
    private let assetStore: ImageAssetStore
    private let openLock = NSLock()
    private let state = OSAllocatedUnfairLock<StoreState>(initialState: StoreState())
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
        keyProvider: (any DatabaseKeyProvider)? = nil,
        loadsBodiesOnFetchAll: Bool = true
    ) {
        self.directory = directory
        self.loadsBodiesOnFetchAll = loadsBodiesOnFetchAll
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

        ImageAssetStore.unregisterKeys(forSupportDirectory: directory, ownerID: instanceID)
        ImageAssetThumbnailLoader.shared.removeThumbnails(inDirectory: directory)
        ImageDragFiles.removeAll()

        if let writer = transition.writer {
            writer.interrupt()
            activeAccessGroup.wait()
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
            guard let priorRow = try Row.fetchOne(
                db,
                sql: "SELECT isEncrypted FROM clips WHERE id = ? LIMIT 1",
                arguments: [id.uuidString]
            ) else {
                return (nil, nil, false, false)
            }
            let existingIsEncrypted = ((priorRow["isEncrypted"] as Int?) ?? 0) != 0

            guard let existing = try self.fetchFullItemByID(
                in: db,
                id: id,
                includeTrashed: true,
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
                try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id.uuidString])
                self.markNeedsFreePageRelease()
                if let assetPath = existing.assetPath {
                    let assetURL = URL(fileURLWithPath: assetPath, isDirectory: false)
                    if self.assetStore.isManagedAssetURL(assetURL) {
                        ImageAssetStore.secureUnlink(at: assetURL)
                    }
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: assetPath)
                }
                let formattedPrevious = self.loadsBodiesOnFetchAll ? existing : existing.unloadingContent()
                return (nil, formattedPrevious, isTrashed, true)
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
            if !existingIsEncrypted && shouldEncrypt {
                self.markNeedsFreePageRelease()
            }

            let formattedUpdated = self.loadsBodiesOnFetchAll ? saved : saved.unloadingContent()
            let formattedPrevious = self.loadsBodiesOnFetchAll ? existing : existing.unloadingContent()
            return (formattedUpdated, formattedPrevious, isTrashed, false)
        }
    }

    // MARK: - HistoryStore Queries & Mutations

    func fetchAll() throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: false)
            let sql: String
            if self.loadsBodiesOnFetchAll {
                sql = """
                    SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                    FROM clips c
                    LEFT JOIN clip_contents cc ON cc.clipId = c.id
                    WHERE c.deletedAt IS NULL
                    ORDER BY c.copiedAt DESC
                    """
            } else {
                sql = """
                    SELECT c.*
                    FROM clips c
                    WHERE c.deletedAt IS NULL
                    ORDER BY c.copiedAt DESC
                    """
            }

            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql)
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: self.loadsBodiesOnFetchAll,
                    keys: keys,
                    decoder: decoder
                ) {
                    items.append(item)
                }
            }
            return items
        }
    }

    func fetchTrashedItems() throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: true)
            let sql: String
            if self.loadsBodiesOnFetchAll {
                sql = """
                    SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                    FROM clips c
                    LEFT JOIN clip_contents cc ON cc.clipId = c.id
                    WHERE c.deletedAt IS NOT NULL
                    ORDER BY c.deletedAt DESC
                    """
            } else {
                sql = """
                    SELECT c.*
                    FROM clips c
                    WHERE c.deletedAt IS NOT NULL
                    ORDER BY c.deletedAt DESC
                    """
            }

            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql)
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: self.loadsBodiesOnFetchAll,
                    keys: keys,
                    decoder: decoder
                ) {
                    items.append(item)
                }
            }
            return items
        }
    }

    func fetchItems(trashedBefore date: Date) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: true)
            let sql = """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.deletedAt < ?
                ORDER BY c.deletedAt DESC
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: [date.timeIntervalSince1970])
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                ) {
                    items.append(item)
                }
            }
            return items
        }
    }

    func moveToTrash(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            let timestamp = date.timeIntervalSince1970
            for id in ids {
                try db.execute(
                    sql: "UPDATE clips SET deletedAt = ? WHERE id = ?",
                    arguments: [timestamp, id.uuidString]
                )
            }
        }
    }

    func restoreFromTrash(ids: [UUID]) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            for id in ids {
                try db.execute(
                    sql: "UPDATE clips SET deletedAt = NULL WHERE id = ?",
                    arguments: [id.uuidString]
                )
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
                    try self.encryptManagedOrExternalAssetsOnCapture(&existingItem, keys: keys)
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
            try self.reconcileAndPersistItem(
                in: db,
                item: item,
                convertingExternalAssets: convertingExternalAssets,
                keys: keys
            )
        }
    }

    func setSensitivity(_ sensitivity: ItemSensitivity?, for id: UUID) throws -> ClipboardItem? {
        try withWrite { db, keys in
            guard var existing = try self.fetchFullItemByID(
                in: db,
                id: id,
                includeTrashed: true,
                keys: keys
            ) else {
                return nil
            }

            if sensitivity == .notSensitive && existing.sensitivity == nil {
                existing.expiresAt = nil
            }
            existing.sensitivity = sensitivity

            return try self.reconcileAndPersistItem(
                in: db,
                item: existing,
                convertingExternalAssets: true,
                keys: keys
            )
        }
    }

    func loadingContent(of item: ClipboardItem, scope: ClipboardContentScope = .full) throws -> ClipboardItem {
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
                let decoder = Self.makeJSONDecoder()
                _ = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "title",
                    aadTable: "clips",
                    aadColumn: "title",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys
                )
                _ = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "textPreview",
                    aadTable: "clips",
                    aadColumn: "textPreview",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys
                )
                _ = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "htmlDigest",
                    aadTable: "clips",
                    aadColumn: "htmlDigest",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys
                )
                _ = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "imageDigest",
                    aadTable: "clips",
                    aadColumn: "imageDigest",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys
                )
                _ = try Self.decodeProtectedAssetPath(
                    from: row,
                    column: "assetPath",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys
                )
                _ = try Self.decodeProtectedFilePaths(
                    from: row,
                    column: "filePathsData",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys,
                    decoder: decoder
                )
                _ = try Self.decodeProtectedLinkPreview(
                    from: row,
                    column: "linkPreviewData",
                    clipID: item.id,
                    isEncrypted: true,
                    keys: keys,
                    decoder: decoder
                )
            }

            let resolvedText: String?
            let resolvedQRCodeText: String?
            if needsBodyColumns {
                resolvedText = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "text",
                    aadTable: "clip_contents",
                    aadColumn: "text",
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                resolvedQRCodeText = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "qrCodeText",
                    aadTable: "clip_contents",
                    aadColumn: "qrCodeText",
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
                    rowColumn: "rtf",
                    aadTable: "clip_contents",
                    aadColumn: "rtf",
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
                            rowColumn: "html",
                            aadTable: "clip_contents",
                            aadColumn: "html",
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
                    rowColumn: "rtf",
                    aadTable: "clip_contents",
                    aadColumn: "rtf",
                    clipID: item.id,
                    isEncrypted: isEncrypted,
                    keys: keys
                )
                resolvedHTML = try Self.decodeStringColumn(
                    from: row,
                    rowColumn: "html",
                    aadTable: "clip_contents",
                    aadColumn: "html",
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
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id.uuidString])
            self.markNeedsFreePageRelease()
        }
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else {
            return
        }
        try withWrite { db, _ in
            for id in ids {
                try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id.uuidString])
            }
            self.markNeedsFreePageRelease()
        }
    }

    func clear() throws {
        try withWrite { db, _ in
            try db.execute(sql: "DELETE FROM clips")
            self.markNeedsFreePageRelease()
        }
    }

    func clear(keepingFavoritesAndTaggedItems: Bool) throws {
        guard keepingFavoritesAndTaggedItems else {
            try clear()
            return
        }

        try withWrite { db, _ in
            try db.execute(sql: """
                DELETE FROM clips
                WHERE deletedAt IS NOT NULL
                   OR (isFavorite = 0 AND NOT EXISTS (
                       SELECT 1 FROM clip_tags WHERE clip_tags.clipId = clips.id
                   ))
                """)
            if db.changesCount > 0 {
                self.markNeedsFreePageRelease()
            }
        }
    }

    func incrementCopyCount(_ id: UUID) throws {
        try withWrite { db, _ in
            try db.execute(
                sql: "UPDATE clips SET copyCount = copyCount + 1 WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]
            )
        }
    }

    func recordAction(_ id: UUID, copiedAt: Date?, incrementsCopyCount: Bool) throws -> ClipboardItem? {
        try withWrite { db, keys in
            let idString = id.uuidString
            guard let existingCounts = try Row.fetchOne(
                db,
                sql: "SELECT copiedAt, copyCount FROM clips WHERE id = ? AND deletedAt IS NULL LIMIT 1",
                arguments: [idString]
            ) else {
                return nil
            }

            let newCopiedAt = copiedAt?.timeIntervalSince1970 ?? (existingCounts["copiedAt"] as Double)
            let currentCopyCount: Int = existingCounts["copyCount"]
            let newCopyCount = incrementsCopyCount ? (currentCopyCount + 1) : currentCopyCount

            try db.execute(
                sql: "UPDATE clips SET copiedAt = ?, copyCount = ? WHERE id = ? AND deletedAt IS NULL",
                arguments: [newCopiedAt, newCopyCount, idString]
            )

            let attachment = try self.fetchTagAttachment(in: db, clipIDString: idString)
            let decoder = Self.makeJSONDecoder()
            if self.loadsBodiesOnFetchAll {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                        FROM clips c
                        LEFT JOIN clip_contents cc ON cc.clipId = c.id
                        WHERE c.id = ? AND c.deletedAt IS NULL
                        LIMIT 1
                        """,
                    arguments: [idString]
                ) else {
                    return nil
                }
                return try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                )
            } else {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT c.* FROM clips c WHERE c.id = ? AND c.deletedAt IS NULL LIMIT 1",
                    arguments: [idString]
                ) else {
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
    }

    func fetchItems(expiredBy policy: HistoryRetentionPolicy) throws -> [ClipboardItem] {
        let cutoffs = policy.cutoffsByKind.sorted { $0.key.rawValue < $1.key.rawValue }
        guard !cutoffs.isEmpty else {
            return []
        }

        return try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: false)
            let conditions = cutoffs.map { _ in "(c.kind = ? AND c.copiedAt < ?)" }.joined(separator: " OR ")
            var arguments: [any DatabaseValueConvertible] = []
            arguments.reserveCapacity(cutoffs.count * 2)
            for (kind, cutoff) in cutoffs {
                arguments.append(kind.rawValue)
                arguments.append(cutoff.timeIntervalSince1970)
            }

            let sql = """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.deletedAt IS NULL AND (\(conditions))
                ORDER BY c.copiedAt DESC
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments))
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                ), policy.isExpired(item) {
                    items.append(item)
                }
            }
            return items
        }
    }

    func fetchItems(expiringBy date: Date) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: nil)
            let sql = """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.expiresAt IS NOT NULL AND c.expiresAt <= ?
                ORDER BY c.copiedAt DESC
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: [date.timeIntervalSince1970])
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                ) {
                    items.append(item)
                }
            }
            return items
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
            while let row = try cursor.next() {
                guard let idString: String = row["id"],
                      let clipID = UUID(uuidString: idString) else {
                    throw HistoryStoreError.authenticationFailed
                }
                let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0

                if let assetPath = try Self.decodeProtectedAssetPath(
                    from: row,
                    column: "assetPath",
                    clipID: clipID,
                    isEncrypted: isEncrypted,
                    keys: keys
                ) {
                    paths.insert(assetPath)
                }

                if let details = try Self.decodeProtectedLinkPreview(
                    from: row,
                    column: "linkPreviewData",
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

    func fetchSearchTexts(
        for ids: [UUID],
        trashed: Bool,
        tagNamesByID: [Tag.ID: String],
        isCancelled: () -> Bool
    ) throws -> [String?]? {
        if isCancelled() {
            return nil
        }
        if ids.isEmpty {
            return []
        }

        var indicesByIDString: [String: [Int]] = [:]
        indicesByIDString.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            indicesByIDString[id.uuidString, default: []].append(index)
        }

        return try withRead { db, keys in
            if isCancelled() {
                return nil
            }

            var results = [String?](repeating: nil, count: ids.count)
            let deletedFilter = trashed ? "IS NOT NULL" : "IS NULL"
            let decoder = Self.makeJSONDecoder()

            if ids.count <= Self.searchInClauseBatchLimit {
                let idStrings = Array(indicesByIDString.keys)
                let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
                let arguments = StatementArguments(idStrings)

                var tagIDsByClipID: [String: [Int]] = [:]
                let tagCursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT ct.clipId, ct.tagId
                        FROM clip_tags ct
                        JOIN tags t ON t.id = ct.tagId
                        WHERE ct.clipId IN (\(placeholders))
                        ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                        """,
                    arguments: arguments
                )
                while let tagRow = try tagCursor.next() {
                    let clipIDString: String = tagRow["clipId"]
                    let tagID: Int = tagRow["tagId"]
                    tagIDsByClipID[clipIDString, default: []].append(tagID)
                }

                if isCancelled() {
                    return nil
                }

                let clipSQL = """
                    SELECT c.id, c.isEncrypted, c.sourceAppName, c.title, c.filePathsData, c.linkPreviewData,
                           cc.text, cc.qrCodeText
                    FROM clips c
                    LEFT JOIN clip_contents cc ON cc.clipId = c.id
                    WHERE c.id IN (\(placeholders)) AND c.deletedAt \(deletedFilter)
                    """
                let cursor = try Row.fetchCursor(db, sql: clipSQL, arguments: arguments)
                var rowCounter = 0
                while let row = try cursor.next() {
                    rowCounter += 1
                    if (rowCounter & 511) == 0 && isCancelled() {
                        return nil
                    }
                    guard let idString: String = row["id"],
                          let targetIndices = indicesByIDString[idString] else {
                        continue
                    }
                    let searchText = Self.decodeSearchTextForRow(
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
            } else {
                var tagIDsByClipID: [String: [Int]] = [:]
                let tagCursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT ct.clipId, ct.tagId
                        FROM clip_tags ct
                        JOIN tags t ON t.id = ct.tagId
                        ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                        """
                )
                var tagRowCounter = 0
                while let tagRow = try tagCursor.next() {
                    tagRowCounter += 1
                    if (tagRowCounter & 511) == 0 && isCancelled() {
                        return nil
                    }
                    let clipIDString: String = tagRow["clipId"]
                    guard indicesByIDString[clipIDString] != nil else {
                        continue
                    }
                    let tagID: Int = tagRow["tagId"]
                    tagIDsByClipID[clipIDString, default: []].append(tagID)
                }

                if isCancelled() {
                    return nil
                }

                let clipSQL = """
                    SELECT c.id, c.isEncrypted, c.sourceAppName, c.title, c.filePathsData, c.linkPreviewData,
                           cc.text, cc.qrCodeText
                    FROM clips c
                    LEFT JOIN clip_contents cc ON cc.clipId = c.id
                    WHERE c.deletedAt \(deletedFilter)
                    """
                let cursor = try Row.fetchCursor(db, sql: clipSQL)
                var rowCounter = 0
                while let row = try cursor.next() {
                    rowCounter += 1
                    if (rowCounter & 511) == 0 && isCancelled() {
                        return nil
                    }
                    guard let idString: String = row["id"],
                          let targetIndices = indicesByIDString[idString] else {
                        continue
                    }
                    let searchText = Self.decodeSearchTextForRow(
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

            return results
        }
    }

    func fetchItems(where isIncluded: (ClipboardItem) -> Bool) throws -> [ClipboardItem] {
        try withRead { db, keys in
            let tagAttachments = try self.fetchTagAttachments(in: db, trashedFilter: false)
            let sql = """
                SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
                FROM clips c
                LEFT JOIN clip_contents cc ON cc.clipId = c.id
                WHERE c.deletedAt IS NULL
                ORDER BY c.copiedAt DESC
                """
            let decoder = Self.makeJSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: sql)
            var items: [ClipboardItem] = []
            while let row = try cursor.next() {
                let idString: String? = row["id"]
                let attachment = idString.flatMap { tagAttachments[$0] } ?? TagAttachment()
                if let item = try self.decodeBatchRow(
                    row,
                    attachment: attachment,
                    hydratesBody: true,
                    keys: keys,
                    decoder: decoder
                ), isIncluded(item) {
                    items.append(item)
                }
            }
            return items
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
        let output: T
        do {
            output = try writer.unsafeReentrantWrite { db in
                if db.isInsideTransaction {
                    return try updates(db, keys)
                }
                var result: T!
                try db.inTransaction(.immediate) {
                    result = try updates(db, keys)
                    return .commit
                }
                isOutermostCommit = true
                return result
            }
        } catch {
            activeAccessGroup.leave()
            throw error
        }

        if isOutermostCommit {
            scheduleAsyncFreePageReleaseIfNeeded(on: writer)
        }
        activeAccessGroup.leave()
        return output
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

        let enteredOpen: Bool = try state.withLock { s in
            guard s.lifecycle == .open else {
                throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
            }
            if !allowRetryFromFailure {
                switch s.lockState {
                case .locked(let reason):
                    throw HistoryStoreError.encryptionKeyUnavailable(reason)
                case .keyMismatch:
                    throw HistoryStoreError.encryptionKeyMismatch
                case .unlocked:
                    break
                }
            }
            if s.lockState == .unlocked, s.dbWriter != nil, s.keys != nil {
                return false
            }
            activeAccessGroup.enter()
            return true
        }

        guard enteredOpen else {
            return
        }
        defer {
            activeAccessGroup.leave()
        }

        // Phase 1: Purely structural read-only crash recovery BEFORE touching DatabaseKeyProvider.
        recoverInterruptedPhaseBCutoverIfNeeded()

        // Phase 2: Read-only probe of History.sqlite (mutates zero bytes / mtime).
        let probeState = try probeExistingDatabaseReadOnly()

        // Phase 3: Master key load/create + verifier check -> StoreLockState transitions.
        let keys: ClipBookDerivedKeys
        switch probeState {
        case .fresh, .legacy:
            do {
                let masterKey = try keyProvider.loadOrCreateMasterKey(canCreateNewKey: true)
                keys = ClipBookDerivedKeys(masterKey: masterKey)
            } catch let error as HistoryStoreError {
                if case .encryptionKeyUnavailable(let reason) = error {
                    state.withLock { $0.lockState = .locked(reason) }
                }
                throw error
            }
        case .existingV5(let verifier):
            let masterKey: SymmetricKey
            do {
                masterKey = try keyProvider.loadOrCreateMasterKey(canCreateNewKey: false)
            } catch let error as HistoryStoreError {
                if case .encryptionKeyUnavailable(let reason) = error {
                    state.withLock { $0.lockState = .locked(reason) }
                }
                throw error
            }
            let candidateKeys = ClipBookDerivedKeys(masterKey: masterKey)
            guard HistoryCrypto.verifyKeyVerifier(verifier, keys: candidateKeys) else {
                state.withLock { $0.lockState = .keyMismatch }
                throw HistoryStoreError.encryptionKeyMismatch
            }
            keys = candidateKeys
        }

        // Phase 4: Initialize fresh DB or run clean-room v0-v4 -> v5 migration, then open DatabasePool.
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
            } catch {
                closeWriterCleanly(writer)
                throw error
            }
        }

        sweepLeftoverScrubbingAndSupersededPlaintextAssets(in: writer)

        let installed = state.withLock { s -> Bool in
            guard s.lifecycle == .open else {
                return false
            }
            s.dbWriter = writer
            s.keys = keys
            s.lockState = .unlocked
            ImageAssetStore.registerKeys(keys, forSupportDirectory: directory, ownerID: instanceID)
            return true
        }

        if !installed {
            closeWriterCleanly(writer)
            throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
        }
    }

    private func recoverInterruptedPhaseBCutoverIfNeeded() {
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
                let hasClips = try db.tableExists("clips")
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
            readonlyConfig.busyMode = .timeout(5.0)
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
        try copyProbeRegularFile0600(from: dbURL, to: tempDBURL)

        let tempWALURL = URL(fileURLWithPath: tempDBURL.path + "-wal", isDirectory: false)
        let tempJournalURL = URL(fileURLWithPath: tempDBURL.path + "-journal", isDirectory: false)

        if walSize > 0 {
            let copiedWAL = try copyProbeRegularFile0600(from: walURL, to: tempWALURL, allowMissingSource: true)
            if copiedWAL {
                _ = Darwin.link(tempWALURL.path, tempWALURL.path + ".pin")
            } else {
                try copyProbeRegularFile0600(from: dbURL, to: tempDBURL)
            }
        }

        if journalSize > 0 {
            let copiedJournal = try copyProbeRegularFile0600(
                from: journalURL,
                to: tempJournalURL,
                allowMissingSource: true
            )
            if copiedJournal {
                _ = Darwin.link(tempJournalURL.path, tempJournalURL.path + ".pin")
            } else {
                try copyProbeRegularFile0600(from: dbURL, to: tempDBURL)
            }
        }

        var tempConfig = Configuration()
        tempConfig.foreignKeysEnabled = true
        tempConfig.busyMode = .timeout(5.0)
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
    private static func copyProbeRegularFile0600(
        from sourceURL: URL,
        to destinationURL: URL,
        allowMissingSource: Bool = false
    ) throws -> Bool {
        let inFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard inFD >= 0 else {
            if allowMissingSource && errno == ENOENT {
                return false
            }
            throw HistoryStoreError.openFailed
        }
        defer {
            _ = Darwin.close(inFD)
        }

        var inStat = stat()
        guard Darwin.fstat(inFD, &inStat) == 0,
              (inStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.openFailed
        }

        let outFD = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        guard outFD >= 0 else {
            throw HistoryStoreError.openFailed
        }
        _ = Darwin.fchmod(outFD, mode_t(0o600))

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        defer {
            buffer.resetBytes(in: 0..<buffer.count)
        }
        do {
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
                                throw HistoryStoreError.openFailed
                            }
                        }
                    } else if bytesRead == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        throw HistoryStoreError.openFailed
                    }
                }
            }
            _ = Darwin.close(outFD)
            return true
        } catch {
            _ = Darwin.close(outFD)
            ImageAssetStore.secureUnlink(at: destinationURL)
            throw error
        }
    }

    private static func scrubAndRemoveProbeDirectory(at probeDir: URL) {
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: probeDir,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries {
                var st = stat()
                if Darwin.lstat(entry.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    scrubAndRemoveProbeDirectory(at: entry)
                } else {
                    ImageAssetStore.secureUnlink(at: entry)
                }
            }
        }
        _ = Darwin.rmdir(probeDir.path)
        if fileOrSymlinkExists(at: probeDir) {
            try? FileManager.default.removeItem(at: probeDir)
        }
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
        bootstrapConfig.busyMode = .timeout(5.0)
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
        config.busyMode = .timeout(5.0)
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

    private func sweepLeftoverScrubbingAndSupersededPlaintextAssets(in writer: any DatabaseWriter) {
        let scrubbingCandidates: [URL] = [
            scrubbingDBURL,
            scrubbingWALURL,
            scrubbingSHMURL,
            scrubbingJournalURL,
        ]
        for candidate in scrubbingCandidates where Self.fileOrSymlinkExists(at: candidate) {
            if Self.sameInode(candidate, databaseURL) {
                _ = Darwin.unlink(candidate.path)
            } else {
                ImageAssetStore.secureUnlink(at: candidate)
            }
        }

        if let dirContents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in dirContents where entry.lastPathComponent.hasSuffix(".scrubbing") {
                if Self.sameInode(entry, databaseURL) {
                    _ = Darwin.unlink(entry.path)
                } else {
                    ImageAssetStore.secureUnlink(at: entry)
                }
            }
        }

        // Remove any leftover <stem>.png/.jpg/.ico/.gif/.webp in Images/ or LinkPreviews/
        // whose <stem>.enc counterpart already exists and is not referenced by an unencrypted row.
        let unencryptedAssetFileNames: Set<String> = (try? writer.unsafeReentrantRead { db -> Set<String> in
            let decoder = Self.makeJSONDecoder()
            var names: Set<String> = []
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT assetPath, linkPreviewData
                    FROM clips
                    WHERE isEncrypted = 0 AND (assetPath IS NOT NULL OR linkPreviewData IS NOT NULL)
                    """
            )
            while let row = try cursor.next() {
                if let assetData: Data = row["assetPath"],
                   let path = String(data: assetData, encoding: .utf8) {
                    names.insert(URL(fileURLWithPath: path).lastPathComponent)
                }
                if let lpData: Data = row["linkPreviewData"],
                   let details = try? decoder.decode(LinkPreviewDetails.self, from: lpData) {
                    if let imgPath = details.imagePath {
                        names.insert(URL(fileURLWithPath: imgPath).lastPathComponent)
                    }
                    if let favPath = details.faviconPath {
                        names.insert(URL(fileURLWithPath: favPath).lastPathComponent)
                    }
                }
            }
            return names
        }) ?? []

        for assetDir in [assetStore.imagesDirectory, assetStore.linkPreviewsDirectory] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: assetDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var encStems: Set<String> = []
            for file in files where file.pathExtension.lowercased() == "enc" {
                encStems.insert(file.deletingPathExtension().lastPathComponent)
            }
            guard !encStems.isEmpty else {
                continue
            }

            for file in files where file.pathExtension.lowercased() != "enc" {
                let stem = file.deletingPathExtension().lastPathComponent
                if encStems.contains(stem) && !unencryptedAssetFileNames.contains(file.lastPathComponent) {
                    ImageAssetStore.secureUnlink(at: file)
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: file.path)
                }
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

    private func encryptManagedOrExternalAssetsOnCapture(
        _ item: inout ClipboardItem,
        keys: ClipBookDerivedKeys
    ) throws {
        if let oldAssetPath = item.assetPath {
            let encryptedPath = try assetStore.encryptAssetIfNeeded(
                at: oldAssetPath,
                role: .image,
                clipID: item.id,
                keys: keys
            )
            item.assetPath = encryptedPath
            if encryptedPath != oldAssetPath {
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldAssetPath)
            }
        }

        if var details = item.linkPreviewDetails {
            if let oldImagePath = details.imagePath {
                let encryptedImagePath = try assetStore.encryptAssetIfNeeded(
                    at: oldImagePath,
                    role: .linkPreview,
                    clipID: item.id,
                    keys: keys
                )
                details.imagePath = encryptedImagePath
                if encryptedImagePath != oldImagePath {
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldImagePath)
                }
            }
            if let oldFaviconPath = details.faviconPath {
                let encryptedFaviconPath = try assetStore.encryptAssetIfNeeded(
                    at: oldFaviconPath,
                    role: .linkFavicon,
                    clipID: item.id,
                    keys: keys
                )
                details.faviconPath = encryptedFaviconPath
                if encryptedFaviconPath != oldFaviconPath {
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldFaviconPath)
                }
            }
            item.linkPreviewDetails = details
        }
    }

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
            if Self.canonicalFileURL(previousURL) == Self.canonicalFileURL(currentURL) {
                return
            }
        }
        guard assetStore.isManagedAssetURL(previousURL) else {
            return
        }
        var linkStat = stat()
        if Darwin.lstat(previousURL.path, &linkStat) == 0 {
            ImageAssetStore.secureUnlink(at: previousURL)
        }
        ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: previousPath)
    }

    private func reconcileManagedAssetsForPersistence(
        _ workingItem: inout ClipboardItem,
        shouldEncrypt: Bool,
        keys: ClipBookDerivedKeys
    ) throws {
        if let oldAssetPath = workingItem.assetPath {
            let reconciledPath: String?
            if shouldEncrypt {
                reconciledPath = try assetStore.encryptAssetIfNeeded(
                    at: oldAssetPath,
                    role: .image,
                    clipID: workingItem.id,
                    keys: keys
                )
            } else {
                reconciledPath = try assetStore.decryptAssetIfNeeded(
                    at: oldAssetPath,
                    role: .image,
                    clipID: workingItem.id,
                    keys: keys
                )
            }
            workingItem.assetPath = reconciledPath
            if reconciledPath != oldAssetPath {
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldAssetPath)
            }
        }

        if var details = workingItem.linkPreviewDetails {
            if let oldImagePath = details.imagePath {
                let reconciledPreview: String?
                if shouldEncrypt {
                    reconciledPreview = try assetStore.encryptAssetIfNeeded(
                        at: oldImagePath,
                        role: .linkPreview,
                        clipID: workingItem.id,
                        keys: keys
                    )
                } else {
                    reconciledPreview = try assetStore.decryptAssetIfNeeded(
                        at: oldImagePath,
                        role: .linkPreview,
                        clipID: workingItem.id,
                        keys: keys
                    )
                }
                details.imagePath = reconciledPreview
                if reconciledPreview != oldImagePath {
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldImagePath)
                }
            }
            if let oldFaviconPath = details.faviconPath {
                let reconciledFavicon: String?
                if shouldEncrypt {
                    reconciledFavicon = try assetStore.encryptAssetIfNeeded(
                        at: oldFaviconPath,
                        role: .linkFavicon,
                        clipID: workingItem.id,
                        keys: keys
                    )
                } else {
                    reconciledFavicon = try assetStore.decryptAssetIfNeeded(
                        at: oldFaviconPath,
                        role: .linkFavicon,
                        clipID: workingItem.id,
                        keys: keys
                    )
                }
                details.faviconPath = reconciledFavicon
                if reconciledFavicon != oldFaviconPath {
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldFaviconPath)
                }
            }
            workingItem.linkPreviewDetails = details
        }
    }

    private func reconcileAndPersistItem(
        in db: Database,
        item: ClipboardItem,
        convertingExternalAssets: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem {
        try persistUpsert(
            in: db,
            item: item,
            keys: keys,
            assetMode: convertingExternalAssets ? .reconcileManagedAssets : .nonDestructiveEncryptedStaging
        )
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
        let stagedURL = try assetStore.writeAsset(
            pngData: plainData,
            role: role,
            clipID: clipID,
            encrypted: true,
            keys: keys
        )
        return stagedURL.path
    }

    private func persistUpsert(
        in db: Database,
        item: ClipboardItem,
        keys: ClipBookDerivedKeys,
        assetMode: AssetPersistenceMode
    ) throws -> ClipboardItem {
        var workingItem = item
        let priorStoredContentKey = item.storedContentKey
        let idString = workingItem.id.uuidString

        let existingClipRow = try Row.fetchOne(
            db,
            sql: "SELECT isEncrypted, sourceAppName, sourceBundleIdentifier, contentKey FROM clips WHERE id = ? LIMIT 1",
            arguments: [idString]
        )
        let existingIsEncrypted: Bool? = existingClipRow.map { (($0["isEncrypted"] as Int?) ?? 0) != 0 }
        let existingSourceAppName: String? = existingClipRow?["sourceAppName"]
        let existingSourceBundleID: String? = existingClipRow?["sourceBundleIdentifier"]

        var shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)

        // Preserve unloaded body/formatting columns and re-seal/unseal if encryption state changed.
        let writesBody = workingItem.isContentLoaded
        let writesFormatting = workingItem.isFormattingLoaded || !workingItem.hasFormatting

        var existingPlainText: String? = nil
        var existingPlainQR: String? = nil
        var existingPlainRTF: Data? = nil
        var existingPlainHTML: String? = nil
        var loadedExistingBody = false
        var loadedExistingFormatting = false

        if let wasEncrypted = existingIsEncrypted, (!writesBody || !writesFormatting) {
            if let existingContentsRow = try Row.fetchOne(
                db,
                sql: "SELECT text, qrCodeText, rtf, html FROM clip_contents WHERE clipId = ? LIMIT 1",
                arguments: [idString]
            ) {
                if !writesBody && (wasEncrypted != shouldEncrypt || (!workingItem.isContentLoaded && priorStoredContentKey == nil)) {
                    existingPlainText = try Self.decodeStringColumn(
                        from: existingContentsRow,
                        rowColumn: "text",
                        aadTable: "clip_contents",
                        aadColumn: "text",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    existingPlainQR = try Self.decodeStringColumn(
                        from: existingContentsRow,
                        rowColumn: "qrCodeText",
                        aadTable: "clip_contents",
                        aadColumn: "qrCodeText",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    loadedExistingBody = true
                }
                if !writesFormatting && wasEncrypted != shouldEncrypt {
                    existingPlainRTF = try Self.decodeDataColumn(
                        from: existingContentsRow,
                        rowColumn: "rtf",
                        aadTable: "clip_contents",
                        aadColumn: "rtf",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    existingPlainHTML = try Self.decodeStringColumn(
                        from: existingContentsRow,
                        rowColumn: "html",
                        aadTable: "clip_contents",
                        aadColumn: "html",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    loadedExistingFormatting = true
                }
            }
        }

        switch assetMode {
        case .reconcileManagedAssets:
            try reconcileManagedAssetsForPersistence(
                &workingItem,
                shouldEncrypt: shouldEncrypt,
                keys: keys
            )
            shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)
        case .nonDestructiveEncryptedStaging:
            if shouldEncrypt {
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
                if var details = workingItem.linkPreviewDetails {
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
                shouldEncrypt = SensitiveContent.shouldEncryptAtRest(workingItem)
            }
        }

        // Compute contentKey (32-byte HMAC-SHA256 BLOB).
        let hmacKey: Data
        if workingItem.isContentLoaded {
            let parts = workingItem.contentKeyComponents
            hmacKey = HistoryCrypto.contentKey(
                kind: workingItem.kind,
                canonicalContent: parts.canonicalContent,
                htmlDigest: parts.htmlDigest,
                keys: keys
            )
        } else if let reusableKey = workingItem.storedContentKey ?? (
            workingItem.kind == .image && workingItem.imageDigest != nil ? priorStoredContentKey : nil
        ) {
            hmacKey = reusableKey
        } else {
            if !loadedExistingBody, let wasEncrypted = existingIsEncrypted {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT text, qrCodeText FROM clip_contents WHERE clipId = ? LIMIT 1",
                    arguments: [idString]
                ) {
                    existingPlainText = try Self.decodeStringColumn(
                        from: row,
                        rowColumn: "text",
                        aadTable: "clip_contents",
                        aadColumn: "text",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    existingPlainQR = try Self.decodeStringColumn(
                        from: row,
                        rowColumn: "qrCodeText",
                        aadTable: "clip_contents",
                        aadColumn: "qrCodeText",
                        clipID: workingItem.id,
                        isEncrypted: wasEncrypted,
                        keys: keys
                    )
                    loadedExistingBody = true
                }
            }
            let hydrated = workingItem.withLoadedContent(
                text: existingPlainText,
                qrCodeText: existingPlainQR,
                scope: .body,
                tagNames: nil
            )
            let parts = hydrated.contentKeyComponents
            hmacKey = HistoryCrypto.contentKey(
                kind: hydrated.kind,
                canonicalContent: parts.canonicalContent,
                htmlDigest: parts.htmlDigest,
                keys: keys
            )
        }

        let encoder = Self.makeJSONEncoder()
        try Self.writeClipRow(
            in: db,
            item: workingItem,
            isEncrypted: shouldEncrypt,
            contentKeyBlob: hmacKey,
            keys: keys,
            encoder: encoder
        )

        // Write or update clip_contents according to independent writesBody / writesFormatting flags.
        try Self.writeClipContentsRow(
            in: db,
            item: workingItem,
            isEncrypted: shouldEncrypt,
            existingIsEncrypted: existingIsEncrypted,
            writesBody: writesBody,
            writesFormatting: writesFormatting,
            preservedPlainText: existingPlainText,
            preservedPlainQR: existingPlainQR,
            preservedPlainRTF: existingPlainRTF,
            preservedPlainHTML: existingPlainHTML,
            loadedExistingBody: loadedExistingBody,
            loadedExistingFormatting: loadedExistingFormatting,
            keys: keys
        )

        // Sync clip_tags (detaching removed tags and preserving sortOrder).
        try db.execute(sql: "DELETE FROM clip_tags WHERE clipId = ?", arguments: [idString])
        if !workingItem.tags.isEmpty {
            let validTagIDs = try Set(Int.fetchAll(db, sql: "SELECT id FROM tags"))
            for tagID in workingItem.tags where validTagIDs.contains(tagID) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_tags (clipId, tagId, sortOrder) VALUES (?, ?, ?)",
                    arguments: [idString, tagID, workingItem.tagOrders[tagID]]
                )
            }
        }

        let overwroteEncryptedUnsealedMetadata = existingIsEncrypted == true && shouldEncrypt && (
            (existingSourceAppName != nil && existingSourceAppName != workingItem.sourceAppName)
            || (existingSourceBundleID != nil && existingSourceBundleID != workingItem.sourceBundleIdentifier)
        )
        if (existingIsEncrypted == false && shouldEncrypt) || overwroteEncryptedUnsealedMetadata {
            markNeedsFreePageRelease()
        }

        workingItem.storedContentKey = hmacKey
        return workingItem
    }

    private static func writeClipRow(
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
            table: "clips",
            column: "title",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let textPreviewBlob = try encodeStringColumn(
            item.textPreview,
            table: "clips",
            column: "textPreview",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let htmlDigestBlob = try encodeStringColumn(
            item.htmlDigest,
            table: "clips",
            column: "htmlDigest",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let imageDigestBlob = try encodeStringColumn(
            item.imageDigest,
            table: "clips",
            column: "imageDigest",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let assetPathBlob = try encodeStringColumn(
            item.assetPath,
            table: "clips",
            column: "assetPath",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let rawFilePathsJSON = try encoder.encode(item.filePaths)
        let filePathsBlob = try encodeRequiredDataColumn(
            rawFilePathsJSON,
            table: "clips",
            column: "filePathsData",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let rawLinkPreviewJSON = try item.linkPreviewDetails.map { try encoder.encode($0) }
        let linkPreviewBlob = try encodeOptionalDataColumn(
            rawLinkPreviewJSON,
            table: "clips",
            column: "linkPreviewData",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )

        let sql = """
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

        try db.execute(sql: sql, arguments: arguments)
    }

    private static func writeClipContentsRow(
        in db: Database,
        item: ClipboardItem,
        isEncrypted: Bool,
        existingIsEncrypted: Bool?,
        writesBody: Bool,
        writesFormatting: Bool,
        preservedPlainText: String?,
        preservedPlainQR: String?,
        preservedPlainRTF: Data?,
        preservedPlainHTML: String?,
        loadedExistingBody: Bool,
        loadedExistingFormatting: Bool,
        keys: ClipBookDerivedKeys
    ) throws {
        let clipID = item.id
        let idString = clipID.uuidString
        let encryptionChanged = existingIsEncrypted != nil && existingIsEncrypted != isEncrypted

        let effectiveWritesBody = writesBody || (encryptionChanged && loadedExistingBody) || existingIsEncrypted == nil
        let effectiveWritesFormatting = writesFormatting || (encryptionChanged && loadedExistingFormatting) || existingIsEncrypted == nil

        guard effectiveWritesBody || effectiveWritesFormatting else {
            return
        }

        let sourceText = writesBody ? item.text : (loadedExistingBody ? preservedPlainText : nil)
        let sourceQR = writesBody ? item.qrCodeText : (loadedExistingBody ? preservedPlainQR : nil)
        let sourceRTF = writesFormatting ? item.rtfData : (loadedExistingFormatting ? preservedPlainRTF : nil)
        let sourceHTML = writesFormatting ? item.html : (loadedExistingFormatting ? preservedPlainHTML : nil)

        let textBlob = effectiveWritesBody ? try encodeStringColumn(
            sourceText,
            table: "clip_contents",
            column: "text",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let qrBlob = effectiveWritesBody ? try encodeStringColumn(
            sourceQR,
            table: "clip_contents",
            column: "qrCodeText",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let rtfBlob = effectiveWritesFormatting ? try encodeOptionalDataColumn(
            sourceRTF,
            table: "clip_contents",
            column: "rtf",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        let htmlBlob = effectiveWritesFormatting ? try encodeStringColumn(
            sourceHTML,
            table: "clip_contents",
            column: "html",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) : nil

        var updateClauses: [String] = []
        if effectiveWritesBody {
            updateClauses.append("text = excluded.text")
            updateClauses.append("qrCodeText = excluded.qrCodeText")
        }
        if effectiveWritesFormatting {
            updateClauses.append("rtf = excluded.rtf")
            updateClauses.append("html = excluded.html")
        }

        let sql = """
            INSERT INTO clip_contents (clipId, text, qrCodeText, rtf, html)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(clipId) DO UPDATE SET \(updateClauses.joined(separator: ", "))
            """
        try db.execute(sql: sql, arguments: [idString, textBlob, qrBlob, rtfBlob, htmlBlob])
    }

    // MARK: - Column AEAD & Row Decoding Helpers

    private static func encodeStringColumn(
        _ value: String?,
        table: String,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        let utf8 = Data(value.utf8)
        if isEncrypted {
            return try HistoryCrypto.sealColumn(utf8, table: table, column: column, clipID: clipID, keys: keys)
        }
        return utf8
    }

    private static func encodeOptionalDataColumn(
        _ value: Data?,
        table: String,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        if isEncrypted {
            return try HistoryCrypto.sealColumn(value, table: table, column: column, clipID: clipID, keys: keys)
        }
        return value
    }

    private static func encodeRequiredDataColumn(
        _ value: Data,
        table: String,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        if isEncrypted {
            return try HistoryCrypto.sealColumn(value, table: table, column: column, clipID: clipID, keys: keys)
        }
        return value
    }

    private static func decodeDataColumn(
        from row: Row,
        rowColumn: String,
        aadTable: String,
        aadColumn: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        let dbValue: DatabaseValue = row[rowColumn]
        switch dbValue.storage {
        case .null:
            return nil
        case .blob(let data):
            if isEncrypted {
                return try HistoryCrypto.openColumn(
                    data,
                    table: aadTable,
                    column: aadColumn,
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

    private static func decodeRequiredDataColumn(
        from row: Row,
        rowColumn: String,
        aadTable: String,
        aadColumn: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        guard let data = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            aadTable: aadTable,
            aadColumn: aadColumn,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            throw HistoryStoreError.authenticationFailed
        }
        return data
    }

    private static func decodeStringColumn(
        from row: Row,
        rowColumn: String,
        aadTable: String,
        aadColumn: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let data = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            aadTable: aadTable,
            aadColumn: aadColumn,
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

    private static func decodeProtectedAssetPath(
        from row: Row,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let path = try decodeStringColumn(
            from: row,
            rowColumn: column,
            aadTable: "clips",
            aadColumn: "assetPath",
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

    private static func decodeProtectedLinkPreview(
        from row: Row,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> LinkPreviewDetails? {
        guard let jsonData = try decodeDataColumn(
            from: row,
            rowColumn: column,
            aadTable: "clips",
            aadColumn: "linkPreviewData",
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

    private static func decodeProtectedFilePaths(
        from row: Row,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> [String] {
        let jsonData = try decodeRequiredDataColumn(
            from: row,
            rowColumn: column,
            aadTable: "clips",
            aadColumn: "filePathsData",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        do {
            return try decoder.decode([String].self, from: jsonData)
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
    }

    private func decodeBatchRow(
        _ row: Row,
        attachment: TagAttachment,
        hydratesBody: Bool,
        isolatesCorruptEncryptedRows: Bool = true,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> ClipboardItem? {
        guard let idString: String = row["id"],
              let clipID = UUID(uuidString: idString) else {
            return nil
        }
        let kindRaw: String = row["kind"] ?? ClipboardKind.text.rawValue
        let kind = ClipboardKind(rawValue: kindRaw) ?? .text
        let copiedAt = Date(timeIntervalSince1970: (row["copiedAt"] as Double?) ?? 0)
        let firstCopiedAt = Date(timeIntervalSince1970: (row["firstCopiedAt"] as Double?) ?? copiedAt.timeIntervalSince1970)
        let deletedAt = (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        let expiresAt = (row["expiresAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        let copySequenceID = (row["copySequenceID"] as Double?).map(Date.init(timeIntervalSince1970:))
        let copySequenceOrder: Int? = row["copySequenceOrder"]
        let byteSize: Int = row["byteSize"] ?? 0
        let copyCount: Int = row["copyCount"] ?? 0
        let isFavorite = ((row["isFavorite"] as Int?) ?? 0) != 0
        let favoriteOrder: Int? = row["favoriteOrder"]
        let sourceAppName: String? = row["sourceAppName"]
        let sourceBundleIdentifier: String? = row["sourceBundleIdentifier"]
        let sensitivity = (row["sensitivity"] as String?).flatMap(ItemSensitivity.init(rawValue:))
        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        let storedContentKey: Data? = row["contentKey"]

        do {
            let title = try Self.decodeStringColumn(
                from: row,
                rowColumn: "title",
                aadTable: "clips",
                aadColumn: "title",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let textPreview = try Self.decodeStringColumn(
                from: row,
                rowColumn: "textPreview",
                aadTable: "clips",
                aadColumn: "textPreview",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let htmlDigest = try Self.decodeStringColumn(
                from: row,
                rowColumn: "htmlDigest",
                aadTable: "clips",
                aadColumn: "htmlDigest",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let imageDigest = try Self.decodeStringColumn(
                from: row,
                rowColumn: "imageDigest",
                aadTable: "clips",
                aadColumn: "imageDigest",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let assetPath = try Self.decodeProtectedAssetPath(
                from: row,
                column: "assetPath",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let filePaths = try Self.decodeProtectedFilePaths(
                from: row,
                column: "filePathsData",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let linkPreviewDetails = try Self.decodeProtectedLinkPreview(
                from: row,
                column: "linkPreviewData",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )

            let header = ClipboardItem.fromStoredHeader(
                id: clipID,
                kind: kind,
                title: title,
                textPreview: textPreview,
                characterCount: (row["characterCount"] as Int?) ?? 0,
                containsPreviewSecret: ((row["containsPreviewSecret"] as Int?) ?? 0) != 0,
                containsRestSecret: ((row["containsRestSecret"] as Int?) ?? 0) != 0,
                hasRecognizedText: ((row["hasRecognizedText"] as Int?) ?? 0) != 0,
                hasQRCodeText: ((row["hasQRCodeText"] as Int?) ?? 0) != 0,
                isSVGText: ((row["isSVGText"] as Int?) ?? 0) != 0,
                hasFormatting: ((row["hasFormatting"] as Int?) ?? 0) != 0,
                htmlDigest: htmlDigest,
                imageDigest: imageDigest,
                imageWidth: row["imageWidth"],
                imageHeight: row["imageHeight"],
                assetPath: assetPath,
                filePaths: filePaths,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                copiedAt: copiedAt,
                firstCopiedAt: firstCopiedAt,
                byteSize: byteSize,
                isFavorite: isFavorite,
                tags: attachment.tagIDs,
                tagOrders: attachment.tagOrders,
                copyCount: copyCount,
                linkPreviewDetails: linkPreviewDetails,
                copySequenceID: copySequenceID,
                copySequenceOrder: copySequenceOrder,
                favoriteOrder: favoriteOrder,
                sensitivity: sensitivity,
                expiresAt: expiresAt,
                deletedAt: deletedAt,
                storedContentKey: storedContentKey
            )

            guard hydratesBody else {
                return header
            }

            let bodyText = try Self.decodeStringColumn(
                from: row,
                rowColumn: "bodyText",
                aadTable: "clip_contents",
                aadColumn: "text",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let bodyQRCodeText = try Self.decodeStringColumn(
                from: row,
                rowColumn: "bodyQRCodeText",
                aadTable: "clip_contents",
                aadColumn: "qrCodeText",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )

            return header.withLoadedContent(
                text: bodyText,
                qrCodeText: bodyQRCodeText,
                scope: .body,
                tagNames: attachment.tagNames
            )
        } catch {
            if isEncrypted {
                if !isolatesCorruptEncryptedRows {
                    throw error
                }
                return Self.makeCorruptEncryptedPlaceholder(
                    id: clipID,
                    kind: kind,
                    copiedAt: copiedAt,
                    firstCopiedAt: firstCopiedAt,
                    deletedAt: deletedAt,
                    expiresAt: expiresAt,
                    copySequenceID: copySequenceID,
                    copySequenceOrder: copySequenceOrder,
                    byteSize: byteSize,
                    copyCount: copyCount,
                    isFavorite: isFavorite,
                    favoriteOrder: favoriteOrder,
                    sourceAppName: sourceAppName,
                    sourceBundleIdentifier: sourceBundleIdentifier,
                    attachment: attachment,
                    storedContentKey: storedContentKey
                )
            }
            return nil
        }
    }

    private static func makeCorruptEncryptedPlaceholder(
        id: UUID,
        kind: ClipboardKind,
        copiedAt: Date,
        firstCopiedAt: Date,
        deletedAt: Date?,
        expiresAt: Date?,
        copySequenceID: Date?,
        copySequenceOrder: Int?,
        byteSize: Int,
        copyCount: Int,
        isFavorite: Bool,
        favoriteOrder: Int?,
        sourceAppName: String?,
        sourceBundleIdentifier: String?,
        attachment: TagAttachment,
        storedContentKey: Data?
    ) -> ClipboardItem {
        ClipboardItem.fromStoredHeader(
            id: id,
            kind: kind,
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
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: byteSize,
            isFavorite: isFavorite,
            tags: attachment.tagIDs,
            tagOrders: attachment.tagOrders,
            copyCount: copyCount,
            linkPreviewDetails: nil,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            sensitivity: .sensitive,
            expiresAt: expiresAt,
            deletedAt: deletedAt,
            storedContentKey: storedContentKey
        )
    }

    private static func decodeSearchTextForRow(
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
        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        let sourceAppName: String? = row["sourceAppName"]

        do {
            let title = try decodeStringColumn(
                from: row,
                rowColumn: "title",
                aadTable: "clips",
                aadColumn: "title",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let filePaths = try decodeProtectedFilePaths(
                from: row,
                column: "filePathsData",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let linkPreviewDetails = try decodeProtectedLinkPreview(
                from: row,
                column: "linkPreviewData",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let text = try decodeStringColumn(
                from: row,
                rowColumn: "text",
                aadTable: "clip_contents",
                aadColumn: "text",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let qrCodeText = try decodeStringColumn(
                from: row,
                rowColumn: "qrCodeText",
                aadTable: "clip_contents",
                aadColumn: "qrCodeText",
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
            let tagNames = tagIDs.compactMap { tagNamesByID[$0] }
            return ClipboardItem.makeSearchText(
                title: title,
                text: text,
                filePaths: filePaths,
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
        includeTrashed: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem? {
        let idString = id.uuidString
        let deletedClause = includeTrashed ? "" : " AND c.deletedAt IS NULL"
        let sql = """
            SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText,
                   cc.rtf AS bodyRTF, cc.html AS bodyHTML
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE c.id = ?\(deletedClause)
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
            aadTable: "clip_contents",
            aadColumn: "text",
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let qrCodeText = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyQRCodeText",
            aadTable: "clip_contents",
            aadColumn: "qrCodeText",
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let rtfData = try Self.decodeDataColumn(
            from: row,
            rowColumn: "bodyRTF",
            aadTable: "clip_contents",
            aadColumn: "rtf",
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let html = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyHTML",
            aadTable: "clip_contents",
            aadColumn: "html",
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

    private func fetchTagAttachments(in db: Database, trashedFilter: Bool?) throws -> [String: TagAttachment] {
        let whereClause: String
        if let trashedFilter {
            whereClause = trashedFilter ? "WHERE c.deletedAt IS NOT NULL" : "WHERE c.deletedAt IS NULL"
        } else {
            whereClause = ""
        }

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
            let tagID: Int = row["tagId"]
            let tagName: String = row["name"]
            let sortOrder: Int? = row["sortOrder"]
            var entry = map[clipID] ?? TagAttachment()
            entry.tagIDs.append(tagID)
            entry.tagNames.append(tagName)
            if let sortOrder {
                entry.tagOrders[tagID] = sortOrder
            }
            map[clipID] = entry
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
            let tagID: Int = row["tagId"]
            let tagName: String = row["name"]
            let sortOrder: Int? = row["sortOrder"]
            attachment.tagIDs.append(tagID)
            attachment.tagNames.append(tagName)
            if let sortOrder {
                attachment.tagOrders[tagID] = sortOrder
            }
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

    private struct LegacyStringTagsEnvelope: Decodable {
        var tags: [String]?
    }

    private func migrateLegacyDatabaseToV5(keys: ClipBookDerivedKeys) throws {
        // Clean up any stale partial migration artifacts first.
        removeMigratingArtifacts()

        var legacyConfig = Configuration()
        legacyConfig.foreignKeysEnabled = false
        legacyConfig.busyMode = .timeout(5.0)
        legacyConfig.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                """)
        }

        var stagedEncURLs: [URL] = []
        var candidateLegacySensitiveSourceURLs: Set<URL> = []
        var nonSensitiveReferencedCanonicalURLs: Set<URL> = []

        var legacyQueue: DatabaseQueue?
        var migratingQueue: DatabaseQueue?

        do {
            let openedLegacy = try DatabaseQueue(path: databaseURL.path, configuration: legacyConfig)
            legacyQueue = openedLegacy

            openedLegacy.writeWithoutTransaction { db in
                try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
            }

            // Create 0o600 History.v5.migrating.sqlite with journal_mode = DELETE & auto_vacuum = INCREMENTAL.
            let fd = Darwin.open(migratingURL.path, O_CREAT | O_RDWR | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else {
                throw HistoryStoreError.migrationFailed("Unable to create History.v5.migrating.sqlite (errno \(errno))")
            }
            _ = Darwin.fchmod(fd, mode_t(0o600))
            _ = Darwin.close(fd)

            var migratingConfig = Configuration()
            migratingConfig.foreignKeysEnabled = true
            migratingConfig.busyMode = .timeout(5.0)
            migratingConfig.prepareDatabase { db in
                try db.execute(sql: """
                    PRAGMA trusted_schema = OFF;
                    PRAGMA cell_size_check = ON;
                    PRAGMA temp_store = MEMORY;
                    PRAGMA secure_delete = ON;
                    """)
            }

            let openedMigrating = try DatabaseQueue(path: migratingURL.path, configuration: migratingConfig)
            migratingQueue = openedMigrating

            try openedMigrating.writeWithoutTransaction { migDB in
                try migDB.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL;")
                _ = try String.fetchOne(migDB, sql: "PRAGMA journal_mode = DELETE;")
                try migDB.inTransaction(.immediate) {
                    try Self.createV5Schema(in: migDB)
                    return .commit
                }
            }

            try openedLegacy.read { legacyDB in
                let legacyVersion = (try Int.fetchOne(legacyDB, sql: "PRAGMA user_version")) ?? 0
                let hasTagsTable = try legacyDB.tableExists("tags")
                let hasClipsTable = try legacyDB.tableExists("clips")

                var validTagIDs: Set<Int> = []
                var tagIDsByLowercaseName: [String: Int] = [:]

                if hasTagsTable {
                    let legacyTags = try Row.fetchAll(legacyDB, sql: "SELECT id, name, color FROM tags ORDER BY id ASC")
                    try openedMigrating.inTransaction(.immediate) { migDB in
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
                                validTagIDs.insert(actualID)
                                tagIDsByLowercaseName[name.lowercased()] = actualID
                            }
                        }
                        return .commit
                    }
                }

                guard hasClipsTable else {
                    return
                }

                let clipColumns = Set(try legacyDB.columns(in: "clips").map(\.name))
                let hasDeletedAtCol = clipColumns.contains("deletedAt")
                let hasExpiresAtCol = clipColumns.contains("expiresAt")
                let hasHTMLCol = clipColumns.contains("html")
                let hasRTFCol = clipColumns.contains("rtf")

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

                        try openedMigrating.inTransaction(.immediate) { migDB in
                            for row in batchRows {
                                guard let payloadData: Data = row["payload"],
                                      var item = try? decoder.decode(ClipboardItem.self, from: payloadData) else {
                                    continue
                                }

                                if legacyVersion < 2,
                                   let envelope = try? decoder.decode(LegacyStringTagsEnvelope.self, from: payloadData),
                                   let legacyTagNames = envelope.tags,
                                   !legacyTagNames.isEmpty {
                                    var mappedTagIDs: [Int] = []
                                    for rawTagName in legacyTagNames {
                                        let lookupKey = rawTagName.lowercased()
                                        if let existingID = tagIDsByLowercaseName[lookupKey] {
                                            mappedTagIDs.append(existingID)
                                        } else {
                                            try migDB.execute(
                                                sql: "INSERT INTO tags (name, color) VALUES (?, ?)",
                                                arguments: [rawTagName, "#3B85ED"]
                                            )
                                            let createdID = Int(migDB.lastInsertedRowID)
                                            validTagIDs.insert(createdID)
                                            tagIDsByLowercaseName[lookupKey] = createdID
                                            mappedTagIDs.append(createdID)
                                        }
                                    }
                                    item.tags = mappedTagIDs
                                }

                                if let sqlCopiedAt: Double = row["copiedAt"] {
                                    item.copiedAt = Date(timeIntervalSince1970: sqlCopiedAt)
                                }
                                if hasDeletedAtCol {
                                    item.deletedAt = (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
                                }
                                if hasExpiresAtCol, let sqlExpiresAt: Double = row["expiresAt"] {
                                    item.expiresAt = Date(timeIntervalSince1970: sqlExpiresAt)
                                }

                                let columnHTML: String? = hasHTMLCol ? row["html"] : nil
                                let columnRTF: Data? = hasRTFCol ? row["rtf"] : nil
                                let resolvedHTML = columnHTML ?? item.html
                                let resolvedRTF = columnRTF ?? item.rtfData
                                if resolvedHTML != nil || resolvedRTF != nil {
                                    item.setFormatting(html: resolvedHTML, rtfData: resolvedRTF)
                                }

                                if item.kind == .image, let imagePath = item.assetPath {
                                    let imageURL = URL(fileURLWithPath: imagePath, isDirectory: false)
                                    if let imageBytes = try? self.assetStore.readPNGData(
                                        at: imageURL,
                                        role: .image,
                                        clipID: item.id,
                                        keys: keys,
                                        requiresEncryption: false
                                    ) {
                                        item.imageDigest = HistoryCrypto.imageDigest(forPNGData: imageBytes, keys: keys)
                                        if let dims = Self.pixelDimensions(ofImageData: imageBytes) {
                                            item.imageWidth = dims.width
                                            item.imageHeight = dims.height
                                        }
                                    }
                                }

                                let shouldEncrypt = SensitiveContent.shouldEncryptAtRest(item)
                                if shouldEncrypt {
                                    item.assetPath = try self.stageMigratedEncryptedAsset(
                                        sourcePath: item.assetPath,
                                        role: .image,
                                        clipID: item.id,
                                        keys: keys,
                                        stagedEncURLs: &stagedEncURLs,
                                        candidateLegacySensitiveSourceURLs: &candidateLegacySensitiveSourceURLs
                                    )
                                    if var details = item.linkPreviewDetails {
                                        details.imagePath = try self.stageMigratedEncryptedAsset(
                                            sourcePath: details.imagePath,
                                            role: .linkPreview,
                                            clipID: item.id,
                                            keys: keys,
                                            stagedEncURLs: &stagedEncURLs,
                                            candidateLegacySensitiveSourceURLs: &candidateLegacySensitiveSourceURLs
                                        )
                                        details.faviconPath = try self.stageMigratedEncryptedAsset(
                                            sourcePath: details.faviconPath,
                                            role: .linkFavicon,
                                            clipID: item.id,
                                            keys: keys,
                                            stagedEncURLs: &stagedEncURLs,
                                            candidateLegacySensitiveSourceURLs: &candidateLegacySensitiveSourceURLs
                                        )
                                        item.linkPreviewDetails = details
                                    }
                                } else {
                                    if let assetPath = item.assetPath {
                                        nonSensitiveReferencedCanonicalURLs.insert(
                                            Self.canonicalFileURL(URL(fileURLWithPath: assetPath, isDirectory: false))
                                        )
                                    }
                                    if let details = item.linkPreviewDetails {
                                        if let imagePath = details.imagePath {
                                            nonSensitiveReferencedCanonicalURLs.insert(
                                                Self.canonicalFileURL(URL(fileURLWithPath: imagePath, isDirectory: false))
                                            )
                                        }
                                        if let faviconPath = details.faviconPath {
                                            nonSensitiveReferencedCanonicalURLs.insert(
                                                Self.canonicalFileURL(URL(fileURLWithPath: faviconPath, isDirectory: false))
                                            )
                                        }
                                    }
                                }

                                // Deduplicate and filter tags against validTagIDs while preserving tagOrders.
                                let savedTagOrders = item.tagOrders
                                var seenTags: Set<Int> = []
                                let validOrderedTags = item.tags.filter { validTagIDs.contains($0) && seenTags.insert($0).inserted }
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
                                    existingIsEncrypted: nil,
                                    writesBody: true,
                                    writesFormatting: true,
                                    preservedPlainText: nil,
                                    preservedPlainQR: nil,
                                    preservedPlainRTF: nil,
                                    preservedPlainHTML: nil,
                                    loadedExistingBody: false,
                                    loadedExistingFormatting: false,
                                    keys: keys
                                )

                                let idString = item.id.uuidString
                                for tagID in validOrderedTags {
                                    try migDB.execute(
                                        sql: "INSERT OR IGNORE INTO clip_tags (clipId, tagId, sortOrder) VALUES (?, ?, ?)",
                                        arguments: [idString, tagID, item.tagOrders[tagID]]
                                    )
                                }
                            }
                            return .commit
                        }
                    }
                }
            }

            // Final Phase A commit: write key_verifier_v1 + PRAGMA user_version = 5 ONLY after all rows succeed.
            try openedMigrating.inTransaction(.immediate) { migDB in
                let verifier = HistoryCrypto.makeKeyVerifier(keys: keys)
                try migDB.execute(
                    sql: "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?, ?)",
                    arguments: [Self.keyVerifierMetadataKey, verifier]
                )
                try migDB.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion)")
                return .commit
            }

            try openedMigrating.close()
            migratingQueue = nil
            try openedLegacy.close()
            legacyQueue = nil

            try Self.fullFsyncFile(at: migratingURL)
        } catch {
            try? migratingQueue?.close()
            try? legacyQueue?.close()
            removeMigratingArtifacts()
            for stagedURL in stagedEncURLs {
                ImageAssetStore.secureUnlink(at: stagedURL)
            }
            throw error
        }

        // Phase B: Zero-Gap Atomic Cutover & Zero-Fill Scrub.
        let unsharedSensitiveLegacyURLs = candidateLegacySensitiveSourceURLs.subtracting(nonSensitiveReferencedCanonicalURLs)

        if Self.fileOrSymlinkExists(at: scrubbingDBURL) {
            if Self.sameInode(scrubbingDBURL, databaseURL) {
                _ = Darwin.unlink(scrubbingDBURL.path)
            } else {
                ImageAssetStore.secureUnlink(at: scrubbingDBURL)
            }
        }

        if Darwin.link(databaseURL.path, scrubbingDBURL.path) != 0 {
            let linkErr = errno
            if linkErr == ENOTSUP || linkErr == EXDEV || linkErr == EPERM {
                try Self.copyRegularFile0600(from: databaseURL, to: scrubbingDBURL)
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
            if Self.sameInode(scrubURL, databaseURL) {
                _ = Darwin.unlink(scrubURL.path)
            } else {
                ImageAssetStore.secureUnlink(at: scrubURL)
            }
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
        stagedEncURLs: inout [URL],
        candidateLegacySensitiveSourceURLs: inout Set<URL>
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
        stagedEncURLs.append(stagedURL)

        let canonicalSource = Self.canonicalFileURL(sourceURL)
        let canonicalStaged = Self.canonicalFileURL(stagedURL)
        if canonicalSource != canonicalStaged && assetStore.isManagedAssetURL(sourceURL) {
            candidateLegacySensitiveSourceURLs.insert(canonicalSource)
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

    // MARK: - Low-Level POSIX & Image Dimension Utilities

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

    private static func pixelDimensions(ofImageData data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    private static func fileOrSymlinkExists(at url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    private static func fileSize(at url: URL) -> Int64? {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            return nil
        }
        return Int64(st.st_size)
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

    private static func canonicalFileURL(_ fileURL: URL) -> URL {
        canonicalDirectoryURL(fileURL.deletingLastPathComponent())
            .appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
            .standardizedFileURL
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

    private static func copyRegularFile0600(from sourceURL: URL, to destinationURL: URL) throws {
        let inFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard inFD >= 0 else {
            throw HistoryStoreError.migrationFailed("Unable to open legacy database for scrubbing copy (errno \(errno))")
        }
        defer {
            _ = Darwin.close(inFD)
        }

        let outFD = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        guard outFD >= 0 else {
            throw HistoryStoreError.migrationFailed("Unable to create scrubbing copy (errno \(errno))")
        }
        _ = Darwin.fchmod(outFD, mode_t(0o600))

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        do {
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
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                        }
                    } else if bytesRead == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            if Darwin.fcntl(outFD, F_FULLFSYNC) != 0 {
                _ = Darwin.fsync(outFD)
            }
            _ = Darwin.close(outFD)
        } catch {
            _ = Darwin.close(outFD)
            ImageAssetStore.secureUnlink(at: destinationURL)
            throw error
        }
    }
}
