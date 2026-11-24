import CryptoKit
import Darwin
import Foundation
import GRDB
import GRDBSQLite
import os

nonisolated extension GRDBHistoryStore {
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
            cacheHooks.removeSVGRendering(clipID)
        }
        cacheHooks.removeAllSensitiveContentCaches()
        cacheHooks.unregisterSVGTextLoader(instanceID)
        ImageAssetStore.unregisterKeys(forSupportDirectory: directory, ownerID: instanceID)
        cacheHooks.removeThumbnailsInDirectory(directory)
        cacheHooks.removeDragCopiesInDirectory(directory)

        if let writer = transition.writer {
            writer.interrupt()
            activeAccessGroup.wait()
            if let svgIDStrings = try? writer.unsafeReentrantRead({ db in
                try String.fetchAll(db, sql: "SELECT id FROM clips WHERE isSVGText != 0")
            }) {
                for idString in svgIDStrings {
                    if let clipID = UUID(uuidString: idString) {
                        cacheHooks.removeSVGRendering(clipID)
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

    func closeWriterCleanly(_ writer: any DatabaseWriter) {
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

    // MARK: - Connection Lifecycle, Startup Probe & Barrier Free-Page Scrubbing

    func acquireAccess() throws -> (writer: any DatabaseWriter, keys: ClipBookDerivedKeys) {
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

    func withRead<T>(_ value: (Database, ClipBookDerivedKeys) throws -> T) throws -> T {
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

    func withWrite<T>(_ updates: (Database, ClipBookDerivedKeys) throws -> T) throws -> T {
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
                    ImageAssetStore.secureUnlinkBatch(rolledBackAssets.newlyWrittenURLs)
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
            ImageAssetStore.secureUnlinkBatch(committedAssets.supersededManagedURLs)
            for evictedPath in committedAssets.evictedThumbnailPaths {
                cacheHooks.removeThumbnailsForPath(evictedPath)
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
                cacheHooks.removeSVGRendering(clipID)
            }
            if committedAssets.purgeOwnerSVGRenderingsOnCommit {
                cacheHooks.removeOwnerSVGRenderings(self.instanceID)
            }
            if committedAssets.purgeSensitiveCachesOnCommit {
                cacheHooks.removeAllSensitiveContentCaches()
            }
            scheduleAsyncFreePageReleaseIfNeeded(on: writer)
        }
        activeAccessGroup.leave()
        return output
    }

    func takeWriteAssetContext() -> TransactionAssetContext {
        writeAssetContext.withLock { ctx in
            let snapshot = ctx
            ctx = TransactionAssetContext()
            return snapshot
        }
    }

    func recordSVGMembershipInsert(_ id: UUID) {
        writeAssetContext.withLock { ctx in
            ctx.insertedSVGClipIDs.insert(id)
            ctx.removedSVGClipIDs.remove(id)
        }
    }

    func recordSVGMembershipRemoval(_ id: UUID) {
        writeAssetContext.withLock { ctx in
            ctx.removedSVGClipIDs.insert(id)
            ctx.insertedSVGClipIDs.remove(id)
            ctx.evictedSVGClipIDs.append(id)
        }
    }

    func recordSVGMembershipRemovals(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            return
        }
        writeAssetContext.withLock { ctx in
            ctx.removedSVGClipIDs.formUnion(ids)
            ctx.insertedSVGClipIDs.subtract(ids)
            ctx.evictedSVGClipIDs.append(contentsOf: ids)
        }
    }

    func recordAssetOutcome(_ outcome: ImageAssetStore.AssetConversionOutcome, evictedPath: String?) {
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

    func recordSupersededAsset(supersededURL: URL?, evictedPath: String?) {
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

    func markNeedsFreePageRelease() {
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

    func openIfNeeded(allowRetryFromFailure: Bool) throws {
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
        switch probeState {
        case .fresh:
            do {
                try bootstrapFreshV5Schema(in: writer, keys: keys)
            } catch {
                closeWriterCleanly(writer)
                throw error
            }
        case .existingV5:
            let hasSVGIndex = (try? writer.unsafeReentrantRead { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_clips_svg' LIMIT 1"
                )
            }) != nil
            if !hasSVGIndex {
                try? writer.unsafeReentrantWrite { db in
                    try db.execute(sql: """
                        CREATE INDEX IF NOT EXISTS idx_clips_svg
                            ON clips(id) WHERE isSVGText != 0;
                        """)
                }
            }
        case .legacy:
            break
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
        cacheHooks.registerSVGTextLoader(
            { [weak self] clipID in
                self?.loadDecryptedSVGText(for: clipID)
            },
            { [weak self] clipID in
                self?.ownsKnownSVGClip(id: clipID) ?? false
            },
            instanceID
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
            cacheHooks.unregisterSVGTextLoader(instanceID)
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

    static func regularSidecarSizeIfPresent(at url: URL) throws -> Int64? {
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
    static func copyRegularFile0600(
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

    static func makeConnectionConfiguration() -> Configuration {
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
            unlinkUnreferencedCollidingAssets(in: directoryScan, referenced: referenced)
        }
    }

    func unlinkOrScrubSupportEntry(at url: URL) {
        unlinkOrScrubSupportEntries([url])
    }

    func unlinkOrScrubSupportEntries<S: Sequence>(_ urls: S) where S.Element == URL {
        var urlsToScrub: [URL] = []
        for url in urls {
            if Self.sameInode(url, databaseURL) {
                _ = Darwin.unlink(url.path)
            } else {
                urlsToScrub.append(url)
            }
        }
        ImageAssetStore.secureUnlinkBatch(urlsToScrub)
    }

    private func sweepScrubbingDatabaseSidecars() {
        var entriesToProcess: [URL] = [
            scrubbingDBURL,
            scrubbingWALURL,
            scrubbingSHMURL,
            scrubbingJournalURL,
        ].filter { Self.fileOrSymlinkExists(at: $0) }

        if let dirContents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in dirContents where entry.lastPathComponent.hasSuffix(".scrubbing") {
                entriesToProcess.append(entry)
            }
        }

        unlinkOrScrubSupportEntries(entriesToProcess)
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
        var scrubbingEntries: [URL] = []
        var encStems: Set<String> = []
        var plainStems: Set<String> = []

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".scrubbing") {
                scrubbingEntries.append(entry)
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

        if !scrubbingEntries.isEmpty {
            ImageAssetStore.secureUnlinkBatch(scrubbingEntries)
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

    private func unlinkUnreferencedCollidingAssets(
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

        var filesToUnlink: [URL] = []
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
                filesToUnlink.append(file)
            }
        }
        if !filesToUnlink.isEmpty {
            ImageAssetStore.secureUnlinkBatch(filesToUnlink)
            for file in filesToUnlink {
                cacheHooks.removeThumbnailsForPath(file.path)
            }
        }
    }

    // MARK: - JSON & Low-Level POSIX Utilities

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func fileOrSymlinkExists(at url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    static func sameInode(_ lhs: URL, _ rhs: URL) -> Bool {
        var leftStat = stat()
        var rightStat = stat()
        guard Darwin.lstat(lhs.path, &leftStat) == 0,
              Darwin.lstat(rhs.path, &rightStat) == 0 else {
            return false
        }
        return leftStat.st_dev == rightStat.st_dev && leftStat.st_ino == rightStat.st_ino
    }

    static func fullFsyncFile(at url: URL) throws {
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
