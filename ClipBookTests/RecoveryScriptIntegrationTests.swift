@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import SQLite3
import Testing

@Suite
struct RecoveryScriptIntegrationTests {
    private nonisolated static let repoRootURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private nonisolated static let scriptURL: URL = repoRootURL
        .appendingPathComponent("scripts/recover-history.swift")

    private nonisolated struct ProcessResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private nonisolated struct ScriptCompilationError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private nonisolated static let compiledBinaryResult: Result<URL, Error> = Result {
        let binaryDir = repoRootURL.appendingPathComponent(".build/test-recovery-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)
        guard Darwin.chmod(binaryDir.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let stagedBinaryURL = binaryDir.appendingPathComponent(
            ".recover-history.tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let binaryURL = binaryDir.appendingPathComponent("recover-history", isDirectory: false)
        let compileResult = try executeProcessSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-O", scriptURL.path, "-o", stagedBinaryURL.path]
        )
        guard compileResult.exitCode == 0 else {
            _ = Darwin.unlink(stagedBinaryURL.path)
            throw ScriptCompilationError(
                message: "swiftc failed (\(compileResult.exitCode)):\n\(compileResult.stderr)\n\(compileResult.stdout)"
            )
        }
        guard Darwin.rename(stagedBinaryURL.path, binaryURL.path) == 0 else {
            let err = errno
            _ = Darwin.unlink(stagedBinaryURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return binaryURL
    }

    private nonisolated static func executeProcessSync(
        executableURL: URL,
        arguments: [String],
        stdinData: Data? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stdoutBox = OSAllocatedUnfairLock(initialState: Data())
        let stderrBox = OSAllocatedUnfairLock(initialState: Data())
        let ioGroup = DispatchGroup()

        try process.run()

        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if let stdinData, !stdinData.isEmpty {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            }
            try? stdinPipe.fileHandleForWriting.close()
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutBox.withLock { $0 = data }
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrBox.withLock { $0 = data }
            ioGroup.leave()
        }

        process.waitUntilExit()
        ioGroup.wait()

        let stdoutBytes = stdoutBox.withLock { $0 }
        let stderrBytes = stderrBox.withLock { $0 }
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutBytes, as: UTF8.self),
            stderr: String(decoding: stderrBytes, as: UTF8.self)
        )
    }

    private nonisolated static func runProcess(
        executableURL: URL,
        arguments: [String],
        stdinData: Data? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try executeProcessSync(
                executableURL: executableURL,
                arguments: arguments,
                stdinData: stdinData
            )
        }.value
    }

    private nonisolated static func runRecoveryCLI(
        arguments: [String],
        stdinData: Data? = nil
    ) async throws -> ProcessResult {
        let binaryURL = try await Task.detached(priority: .userInitiated) {
            try Self.compiledBinaryResult.get()
        }.value
        return try await runProcess(
            executableURL: binaryURL,
            arguments: arguments,
            stdinData: stdinData
        )
    }

    // MARK: - Forensic Directory Snapshot Helpers

    private nonisolated struct ForensicEntrySnapshot: Equatable, Sendable {
        let relativePath: String
        let mode: mode_t
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int
        let sha256Hex: String?
    }

    private nonisolated struct DirectoryForensicSnapshot: Equatable, Sendable {
        let rootMode: mode_t
        let rootMtimeSec: Int
        let rootMtimeNsec: Int
        let entries: [ForensicEntrySnapshot]
    }

    private nonisolated static func captureForensicSnapshot(of rootURL: URL) throws -> DirectoryForensicSnapshot {
        let rootNoSlash = URL(fileURLWithPath: rootURL.path, isDirectory: false)
        var rootStat = stat()
        guard Darwin.lstat(rootNoSlash.path, &rootStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        var entries: [ForensicEntrySnapshot] = []
        try collectForensicEntries(in: rootURL, relativePrefix: "", into: &entries)
        entries.sort { $0.relativePath < $1.relativePath }

        return DirectoryForensicSnapshot(
            rootMode: rootStat.st_mode,
            rootMtimeSec: rootStat.st_mtimespec.tv_sec,
            rootMtimeNsec: rootStat.st_mtimespec.tv_nsec,
            entries: entries
        )
    }

    private nonisolated static func collectForensicEntries(
        in directoryURL: URL,
        relativePrefix: String,
        into output: inout [ForensicEntrySnapshot]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for childURL in children {
            let name = childURL.lastPathComponent
            let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            let childNoSlash = URL(fileURLWithPath: childURL.path, isDirectory: false)

            var st = stat()
            guard Darwin.lstat(childNoSlash.path, &st) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
            }

            let fileType = st.st_mode & S_IFMT
            let digestHex: String?
            if fileType == S_IFREG {
                let data = try Data(contentsOf: childNoSlash)
                digestHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                digestHex = nil
            }

            output.append(
                ForensicEntrySnapshot(
                    relativePath: relPath,
                    mode: st.st_mode,
                    size: st.st_size,
                    mtimeSec: st.st_mtimespec.tv_sec,
                    mtimeNsec: st.st_mtimespec.tv_nsec,
                    sha256Hex: digestHex
                )
            )

            if fileType == S_IFDIR {
                try collectForensicEntries(
                    in: URL(fileURLWithPath: childURL.path, isDirectory: true),
                    relativePrefix: relPath,
                    into: &output
                )
            }
        }
    }

    private nonisolated static func makeArchiveJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func makeSampleICOData() -> Data {
        Data([
            0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10,
            0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x08, 0x00,
            0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0xDE, 0xAD,
            0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        ])
    }

    private nonisolated static func flipLastByteInEncryptedColumn(
        at databaseURL: URL,
        table: String,
        column: String,
        idColumn: String,
        clipID: UUID
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let sqliteDB = db else {
            if let db { sqlite3_close_v2(db) }
            throw HistoryStoreError.openFailed
        }
        defer {
            sqlite3_close_v2(sqliteDB)
        }

        let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let selectSQL = "SELECT \(column) FROM \(table) WHERE \(idColumn) = ?1 LIMIT 1;"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(sqliteDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK,
              let preparedSelect = selectStmt else {
            throw HistoryStoreError.prepareFailed(String(cString: sqlite3_errmsg(sqliteDB)))
        }
        defer {
            sqlite3_finalize(preparedSelect)
        }

        _ = clipID.uuidString.withCString {
            sqlite3_bind_text(preparedSelect, 1, $0, -1, sqlTransient)
        }
        guard sqlite3_step(preparedSelect) == SQLITE_ROW,
              sqlite3_column_type(preparedSelect, 0) == SQLITE_BLOB else {
            throw HistoryStoreError.stepFailed("Expected encrypted BLOB in \(table).\(column)")
        }

        let blobLength = Int(sqlite3_column_bytes(preparedSelect, 0))
        guard blobLength >= HistoryCrypto.minimumSealedColumnLength,
              let blobPtr = sqlite3_column_blob(preparedSelect, 0) else {
            throw HistoryStoreError.stepFailed("Encrypted BLOB shorter than minimum sealed length")
        }

        var tampered = Data(bytes: blobPtr, count: blobLength)
        tampered[tampered.count - 1] ^= 0x01

        let updateSQL = "UPDATE \(table) SET \(column) = ?1 WHERE \(idColumn) = ?2;"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(sqliteDB, updateSQL, -1, &updateStmt, nil) == SQLITE_OK,
              let preparedUpdate = updateStmt else {
            throw HistoryStoreError.prepareFailed(String(cString: sqlite3_errmsg(sqliteDB)))
        }
        defer {
            sqlite3_finalize(preparedUpdate)
        }

        tampered.withUnsafeBytes { rawBuffer in
            _ = sqlite3_bind_blob(preparedUpdate, 1, rawBuffer.baseAddress, Int32(rawBuffer.count), sqlTransient)
        }
        _ = clipID.uuidString.withCString {
            sqlite3_bind_text(preparedUpdate, 2, $0, -1, sqlTransient)
        }
        guard sqlite3_step(preparedUpdate) == SQLITE_DONE,
              sqlite3_changes(sqliteDB) == 1 else {
            throw HistoryStoreError.stepFailed("Failed updating \(table).\(column)")
        }
    }

    private nonisolated static func allFilesRecursively(in directoryURL: URL) throws -> [URL] {
        var result: [URL] = []
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            var st = stat()
            if Darwin.lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                result.append(contentsOf: try allFilesRecursively(in: child))
            } else {
                result.append(child)
            }
        }
        return result
    }

    private nonisolated static func assertCleanV1ArchiveStructure(at archiveURL: URL) throws {
        var archiveStat = stat()
        #expect(Darwin.lstat(archiveURL.path, &archiveStat) == 0)
        #expect((archiveStat.st_mode & 0o777) == 0o700)

        let decoder = makeArchiveJSONDecoder()
        let manifestURL = archiveURL.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(ClipBookArchiveManifest.self, from: manifestData)
        #expect(manifest.formatVersion == 1)
        #expect(manifest.encryption == nil)

        let allFiles = try allFilesRecursively(in: archiveURL)
        #expect(!allFiles.isEmpty)
        for fileURL in allFiles {
            #expect(fileURL.pathExtension.lowercased() != "enc", "Unexpected .enc file in recovered v1 archive: \(fileURL.path)")
            var fileStat = stat()
            #expect(Darwin.lstat(fileURL.path, &fileStat) == 0)
            #expect((fileStat.st_mode & 0o777) == 0o600)
        }

        let historyURL = archiveURL.appendingPathComponent("history.json", isDirectory: false)
        let rawHistoryJSON = try String(contentsOf: historyURL, encoding: .utf8)
        for forbiddenV2Key in ["\"assetExtension\"", "\"imageExtension\"", "\"faviconExtension\"", "\"expectedAssets\""] {
            #expect(!rawHistoryJSON.contains(forbiddenV2Key), "Found forbidden v2 key \(forbiddenV2Key) in v1 history.json")
        }
    }

    // MARK: - Tests

    @Test
    func shebangHelpAndCLIArgumentValidation() async throws {
        var scriptStat = stat()
        #expect(Darwin.lstat(Self.scriptURL.path, &scriptStat) == 0)
        #expect((scriptStat.st_mode & 0o111) != 0, "scripts/recover-history.swift must be executable")

        // 1. Direct shebang invocation via `/usr/bin/env swift <scriptPath> --help`.
        let shebangHelp = try await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", Self.scriptURL.path, "--help"]
        )
        #expect(shebangHelp.exitCode == 0, "Shebang --help stderr: \(shebangHelp.stderr)")
        #expect(shebangHelp.stdout.contains("--support-dir"))
        #expect(shebangHelp.stdout.contains("--archive"))
        #expect(shebangHelp.stdout.contains("--allow-test-iterations"))

        // 2. Compiled binary `--help` and invalid/ps-visible secret argument rejections.
        let compiledHelp = try await Self.runRecoveryCLI(arguments: ["--help"])
        #expect(compiledHelp.exitCode == 0)
        #expect(compiledHelp.stdout.contains("--key-hex-stdin"))
        #expect(compiledHelp.stdout.contains("--passphrase-stdin"))

        try await TestSupport.withTemporaryDirectory { workspace in
            let unusedOut = workspace.appendingPathComponent("RejectedOut.clipbookarchive", isDirectory: true)

            let emptyArgs = try await Self.runRecoveryCLI(arguments: [])
            #expect(emptyArgs.exitCode == 1)

            let rawKeyArg = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", workspace.path,
                    "--output-dir", unusedOut.path,
                    ["--key=", String(repeating: "01234567", count: 4), String(repeating: "89abcdef", count: 4)].joined(),
                ]
            )
            #expect(rawKeyArg.exitCode == 1)
            #expect(rawKeyArg.stderr.contains("Raw secrets are never accepted"))
            #expect(!FileManager.default.fileExists(atPath: unusedOut.path))

            let mixedModeArgs = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", workspace.path,
                    "--archive", workspace.path,
                    "--output-dir", unusedOut.path,
                ]
            )
            #expect(mixedModeArgs.exitCode == 1)
            #expect(!FileManager.default.fileExists(atPath: unusedOut.path))
        }
    }

    @Test
    func modeALiveUncheckpointedWALNonMutatingRecoveryAndImportParity() async throws {
        try await TestSupport.withTemporaryDirectory { workspace in
            let fileManager = FileManager.default
            let supportDir = workspace.appendingPathComponent("LiveSupport", isDirectory: true)
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)

            let keyProvider = FileDatabaseKeyProvider(supportDirectory: supportDir)
            let devKeyURL = keyProvider.keyFileURL
            let walURL = supportDir.appendingPathComponent("History.sqlite-wal", isDirectory: false)

            let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
            defer { store.close() }

            let alphaTag = try store.createTag(name: "AlphaVault", color: "#E53935")
            let betaTag = try store.createTag(name: "BetaDocs", color: "#1E88E5")
            #expect(fileManager.fileExists(atPath: devKeyURL.path))

            // 1. Plain .png inside <support-dir>/Images/
            let plainImageID = UUID()
            let plainPNG = try TestSupport.makePNGData(pixelWidth: 36, pixelHeight: 24, color: .systemTeal)
            let plainImageURL = try store.writeManagedAsset(
                pngData: plainPNG,
                role: .image,
                clipID: plainImageID,
                encrypted: false,
                preferredPlainExtension: "png"
            )
            #expect(plainImageURL.pathExtension == "png")

            var plainImageItem = ClipboardItem.fixture(
                id: plainImageID,
                kind: .image,
                title: "Plain Architecture Diagram",
                text: "Benign OCR Diagram Text",
                qrCodeText: "https://docs.example/diagram-qr",
                assetPath: plainImageURL.path,
                imageDigest: store.computeImageDigest(forPNGData: plainPNG),
                copiedAt: Date(timeIntervalSince1970: 1_715_000_100),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_050),
                byteSize: plainPNG.count,
                isFavorite: true,
                tags: [betaTag.id],
                favoriteOrder: 2
            )
            plainImageItem.tagOrders = [betaTag.id: 4]
            try store.saveAndReconcileItem(plainImageItem, convertingExternalAssets: true)

            // 2. Plain .ico favicon + plain .png preview inside <support-dir>/LinkPreviews/
            let linkID = UUID()
            let linkPreviewPNG = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 16, color: .systemGreen)
            let faviconICO = Self.makeSampleICOData()
            let linkPreviewImageURL = try store.writeManagedAsset(
                pngData: linkPreviewPNG,
                role: .linkPreview,
                clipID: linkID,
                encrypted: false,
                preferredPlainExtension: "png"
            )
            let linkFaviconURL = try store.writeManagedAsset(
                pngData: faviconICO,
                role: .linkFavicon,
                clipID: linkID,
                encrypted: false,
                preferredPlainExtension: "ico"
            )
            #expect(linkPreviewImageURL.pathExtension == "png")
            #expect(linkFaviconURL.pathExtension == "ico")

            let linkFetchedAt = Date(timeIntervalSince1970: 1_715_000_190)
            var linkItem = ClipboardItem.fixture(
                id: linkID,
                kind: .link,
                title: "Engineering Runbook Link",
                text: "https://runbook.example.org/persistence",
                copiedAt: Date(timeIntervalSince1970: 1_715_000_200),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_180),
                tags: [alphaTag.id, betaTag.id],
                linkPreviewDetails: LinkPreviewDetails(
                    url: "https://runbook.example.org/persistence",
                    title: "Persistence Runbook",
                    description: "Offline recovery and WAL replay guide",
                    imagePath: linkPreviewImageURL.path,
                    faviconPath: linkFaviconURL.path,
                    fetchedAt: linkFetchedAt
                )
            )
            linkItem.tagOrders = [alphaTag.id: 1, betaTag.id: 8]
            try store.saveAndReconcileItem(linkItem, convertingExternalAssets: true)

            // 3. Rich text item (html + rtfData)
            let richID = UUID()
            let richTextBody = "Formatted Recovery Heading and Body"
            let richRTFData = try TestSupport.makeRTFData(text: richTextBody)
            let richHTML = "<article><h1>Formatted Recovery Heading</h1><p>and Body</p></article>"
            var richItem = ClipboardItem.fixture(
                id: richID,
                kind: .richText,
                title: "Release Notes Draft",
                text: richTextBody,
                rtfData: richRTFData,
                html: richHTML,
                copiedAt: Date(timeIntervalSince1970: 1_715_000_300),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_250),
                isFavorite: true,
                tags: [betaTag.id],
                favoriteOrder: 5
            )
            richItem.tagOrders = [betaTag.id: 2]
            try store.upsert(richItem)

            // 4. Active sensitive text item
            let activeSecretID = UUID()
            let activeSecretToken = ["gh", "p_", "MODE_A_ACTIVE_SECRET_TOKEN_24681357902468"].joined()
            let copySeqDate = Date(timeIntervalSince1970: 1_715_000_395)
            var activeSecretItem = ClipboardItem.fixture(
                id: activeSecretID,
                kind: .text,
                title: "Production Deploy Credential",
                text: "export TOKEN=\(activeSecretToken)",
                copiedAt: Date(timeIntervalSince1970: 1_715_000_400),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_390),
                tags: [alphaTag.id],
                copyCount: 3,
                copySequenceID: copySeqDate,
                copySequenceOrder: 2
            )
            activeSecretItem.tagOrders = [alphaTag.id: 3]
            #expect(SensitiveContent.shouldEncryptAtRest(activeSecretItem))
            try store.upsert(activeSecretItem)

            // 5. Sensitive OCR .image (.enc)
            let encImageID = UUID()
            let encPNG = try TestSupport.makePNGData(pixelWidth: 40, pixelHeight: 28, color: .systemOrange)
            let stagedEncImageURL = try store.writeManagedAsset(
                pngData: encPNG,
                role: .image,
                clipID: encImageID,
                encrypted: true
            )
            #expect(stagedEncImageURL.pathExtension == "enc")

            let ocrSecretToken = ["Authorization", ": Bearer ", "MODE_A_OCR_IMAGE_SECRET_13579246801357"].joined()
            let otpQRSecret = ["otpauth", "://totp/ClipBook:ops?secret=", "JBSWY3DPEHPK3PXPJBSWY3DP"].joined()
            var encImageItem = ClipboardItem.fixture(
                id: encImageID,
                kind: .image,
                title: "Terminal Secret Screenshot",
                text: ocrSecretToken,
                qrCodeText: otpQRSecret,
                assetPath: stagedEncImageURL.path,
                imageDigest: store.computeImageDigest(forPNGData: encPNG),
                copiedAt: Date(timeIntervalSince1970: 1_715_000_500),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_480),
                byteSize: encPNG.count,
                tags: [alphaTag.id],
                sensitivity: .sensitive
            )
            encImageItem.tagOrders = [alphaTag.id: 7]
            let savedEncImage = try store.saveAndReconcileItem(encImageItem, convertingExternalAssets: true)
            #expect(savedEncImage.assetPath?.hasSuffix(".enc") == true)

            // 6. Trashed secret item
            let trashedSecretID = UUID()
            let trashedSecretToken = ["sk", "-ant-", "MODE_A_TRASHED_SECRET_975318642097531864"].joined()
            let trashedSecretItem = ClipboardItem.fixture(
                id: trashedSecretID,
                kind: .text,
                title: "Rotated Staging Key",
                text: trashedSecretToken,
                copiedAt: Date(timeIntervalSince1970: 1_715_000_550),
                tags: [alphaTag.id]
            )
            #expect(SensitiveContent.shouldEncryptAtRest(trashedSecretItem))
            try store.upsert(trashedSecretItem)
            try store.moveToTrash(ids: [trashedSecretID], at: Date(timeIntervalSince1970: 1_715_000_560))

            // Drain any pending free-page pass, then force a brand-new uncheckpointed WAL write
            // while keeping `store` open!
            store.flushPendingFreePageRelease()

            let walSecretID = UUID()
            let walSecretToken = ["glpat", "-", "UNCHECKPOINTED_WAL_SECRET_86420975318642"].joined()
            var walSecretItem = ClipboardItem.fixture(
                id: walSecretID,
                kind: .text,
                title: "Live Uncheckpointed WAL Secret",
                text: walSecretToken,
                copiedAt: Date(timeIntervalSince1970: 1_715_000_600),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_000_600),
                tags: [alphaTag.id, betaTag.id]
            )
            walSecretItem.tagOrders = [alphaTag.id: 9, betaTag.id: 6]
            #expect(SensitiveContent.shouldEncryptAtRest(walSecretItem))
            try store.upsert(walSecretItem)

            let walSizeBeforeRecovery = (try? fileManager.attributesOfItem(atPath: walURL.path)[.size] as? Int) ?? 0
            #expect(walSizeBeforeRecovery > 0, "Expected non-empty uncheckpointed History.sqlite-wal before recovery")

            // Record pre-run forensic snapshot (SHA-256 + exact st_mtimespec across <support-dir> and <support-dir>/**).
            let baselineSnapshot = try Self.captureForensicSnapshot(of: supportDir)

            // Run 1: Mode A with `--key-file <support-dir>/.devkey --include-trashed`.
            let recoveredKeyFileURL = workspace.appendingPathComponent("RecoveredKeyFile.clipbookarchive", isDirectory: true)
            let keyFileRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", supportDir.path,
                    "--key-file", devKeyURL.path,
                    "--include-trashed",
                    "--output-dir", recoveredKeyFileURL.path,
                ]
            )
            #expect(keyFileRun.exitCode == 0, "Mode A --key-file failed: \(keyFileRun.stderr)")

            let postKeyFileSnapshot = try Self.captureForensicSnapshot(of: supportDir)
            #expect(postKeyFileSnapshot == baselineSnapshot, "<support-dir> bytes or mtimes changed during --key-file recovery")

            // Run 2: Mode A piping `<devkey>\n` via `--key-hex-stdin`.
            var devKeyStdin = try Data(contentsOf: devKeyURL)
            devKeyStdin.append(0x0A)
            let recoveredStdinURL = workspace.appendingPathComponent("RecoveredStdin.clipbookarchive", isDirectory: true)
            let stdinRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", supportDir.path,
                    "--key-hex-stdin",
                    "--include-trashed",
                    "--output-dir", recoveredStdinURL.path,
                ],
                stdinData: devKeyStdin
            )
            #expect(stdinRun.exitCode == 0, "Mode A --key-hex-stdin failed: \(stdinRun.stderr)")

            let postStdinSnapshot = try Self.captureForensicSnapshot(of: supportDir)
            #expect(postStdinSnapshot == baselineSnapshot, "<support-dir> bytes or mtimes changed during --key-hex-stdin recovery")

            // Validate recovered v1 archive structure & sidecars on both outputs.
            let decoder = Self.makeArchiveJSONDecoder()
            for archiveURL in [recoveredKeyFileURL, recoveredStdinURL] {
                try Self.assertCleanV1ArchiveStructure(at: archiveURL)
                #expect(!fileManager.fileExists(atPath: archiveURL.appendingPathComponent("corrupted-items.json").path))

                let trashedURL = archiveURL.appendingPathComponent("trashed-history.json", isDirectory: false)
                let trashedItems = try decoder.decode([ClipBookArchiveItem].self, from: try Data(contentsOf: trashedURL))
                #expect(trashedItems.map(\.id) == [trashedSecretID])
                #expect(trashedItems.first?.text == trashedSecretToken)
                #expect(trashedItems.first?.title == "Rotated Staging Key")

                let activeArchiveItems = try decoder.decode(
                    [ClipBookArchiveItem].self,
                    from: try Data(contentsOf: archiveURL.appendingPathComponent("history.json", isDirectory: false))
                )
                #expect(activeArchiveItems.count == 6)
                let walRecovered = try #require(activeArchiveItems.first { $0.id == walSecretID })
                #expect(walRecovered.text == walSecretToken)
            }

            // Import <recovered.clipbookarchive> back into a brand-new GRDBHistoryStore with a distinct master key
            // and verify 100% item, tag, tagOrders, HTML/RTF, plain-PNG, encrypted-PNG, and .ico parity!
            let targetSupportDir = workspace.appendingPathComponent("TargetImportedSupport", isDirectory: true)
            let targetStore = GRDBHistoryStore(
                directory: targetSupportDir,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { targetStore.close() }

            let importService = ClipBookArchiveService(supportDirectory: targetSupportDir)
            let importResult = try importService.import(
                from: recoveredKeyFileURL,
                into: targetStore,
                passphrase: nil
            )
            #expect(importResult.itemCount == 6)
            #expect(importResult.tagCount == 2)

            let targetTags = try targetStore.fetchTags()
            let targetTagByName = Dictionary(uniqueKeysWithValues: targetTags.map { ($0.name, $0) })
            let importedAlphaTag = try #require(targetTagByName["AlphaVault"])
            let importedBetaTag = try #require(targetTagByName["BetaDocs"])
            #expect(importedAlphaTag.color == "#E53935")
            #expect(importedBetaTag.color == "#1E88E5")

            let importedHeadersByID = Dictionary(uniqueKeysWithValues: try targetStore.fetchAll().map { ($0.id, $0) })
            #expect(importedHeadersByID.count == 6)
            #expect(importedHeadersByID[trashedSecretID] == nil)

            // Verify plain PNG item
            let hydratedPlainImage = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[plainImageID]),
                scope: .full
            )
            #expect(hydratedPlainImage.title == "Plain Architecture Diagram")
            #expect(hydratedPlainImage.text == "Benign OCR Diagram Text")
            #expect(hydratedPlainImage.qrCodeText == "https://docs.example/diagram-qr")
            #expect(hydratedPlainImage.isFavorite)
            #expect(hydratedPlainImage.favoriteOrder == 2)
            #expect(hydratedPlainImage.tags == [importedBetaTag.id])
            #expect(hydratedPlainImage.tagOrders == [importedBetaTag.id: 4])
            #expect(hydratedPlainImage.imageDigest == targetStore.computeImageDigest(forPNGData: plainPNG))
            let importedPlainImageURL = URL(fileURLWithPath: try #require(hydratedPlainImage.assetPath))
            #expect(importedPlainImageURL.pathExtension == "png")
            #expect(try Data(contentsOf: importedPlainImageURL) == plainPNG)

            // Verify plain .ico + preview PNG link item
            let hydratedLink = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[linkID]),
                scope: .full
            )
            #expect(hydratedLink.title == "Engineering Runbook Link")
            #expect(hydratedLink.text == "https://runbook.example.org/persistence")
            #expect(Set(hydratedLink.tags) == [importedAlphaTag.id, importedBetaTag.id])
            #expect(hydratedLink.tagOrders == [importedAlphaTag.id: 1, importedBetaTag.id: 8])
            let importedPreviewDetails = try #require(hydratedLink.linkPreviewDetails)
            #expect(importedPreviewDetails.url == "https://runbook.example.org/persistence")
            #expect(importedPreviewDetails.title == "Persistence Runbook")
            #expect(importedPreviewDetails.description == "Offline recovery and WAL replay guide")
            #expect(importedPreviewDetails.fetchedAt == linkFetchedAt)
            let importedPreviewImgURL = URL(fileURLWithPath: try #require(importedPreviewDetails.imagePath))
            let importedFaviconURL = URL(fileURLWithPath: try #require(importedPreviewDetails.faviconPath))
            #expect(importedPreviewImgURL.pathExtension == "png")
            #expect(importedFaviconURL.pathExtension == "ico")
            #expect(try Data(contentsOf: importedPreviewImgURL) == linkPreviewPNG)
            #expect(try Data(contentsOf: importedFaviconURL) == faviconICO)

            // Verify rich text HTML + RTF item
            let hydratedRich = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[richID]),
                scope: .full
            )
            #expect(hydratedRich.text == richTextBody)
            #expect(hydratedRich.html == richHTML)
            #expect(hydratedRich.rtfData == richRTFData)
            #expect(hydratedRich.isFavorite)
            #expect(hydratedRich.favoriteOrder == 5)
            #expect(hydratedRich.tagOrders == [importedBetaTag.id: 2])

            // Verify active secret text item + uncheckpointed WAL secret text item
            let hydratedActiveSecret = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[activeSecretID]),
                scope: .full
            )
            #expect(hydratedActiveSecret.title == "Production Deploy Credential")
            #expect(hydratedActiveSecret.text == "export TOKEN=\(activeSecretToken)")
            #expect(hydratedActiveSecret.copyCount == 3)
            #expect(hydratedActiveSecret.copySequenceID == copySeqDate)
            #expect(hydratedActiveSecret.copySequenceOrder == 2)
            #expect(hydratedActiveSecret.tagOrders == [importedAlphaTag.id: 3])

            let hydratedWALSecret = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[walSecretID]),
                scope: .full
            )
            #expect(hydratedWALSecret.title == "Live Uncheckpointed WAL Secret")
            #expect(hydratedWALSecret.text == walSecretToken)
            #expect(hydratedWALSecret.tagOrders == [importedAlphaTag.id: 9, importedBetaTag.id: 6])

            // Verify sensitive OCR .image re-encrypted under targetStore's distinct key
            let hydratedEncImage = try targetStore.loadingContent(
                of: try #require(importedHeadersByID[encImageID]),
                scope: .full
            )
            #expect(hydratedEncImage.title == "Terminal Secret Screenshot")
            #expect(hydratedEncImage.text == ocrSecretToken)
            #expect(hydratedEncImage.qrCodeText == otpQRSecret)
            #expect(hydratedEncImage.sensitivity == .sensitive)
            #expect(hydratedEncImage.tagOrders == [importedAlphaTag.id: 7])
            #expect(hydratedEncImage.imageDigest == targetStore.computeImageDigest(forPNGData: encPNG))
            let importedEncImageURL = URL(fileURLWithPath: try #require(hydratedEncImage.assetPath))
            #expect(importedEncImageURL.pathExtension == "enc")
            #expect(
                try ImageAssetStore.readAssetData(
                    at: importedEncImageURL,
                    role: .image,
                    ownerClipID: encImageID,
                    requiresEncryption: true
                ) == encPNG
            )
        }
    }

    @Test
    func modeAColumnAndAssetTamperIsolationStrictModeAndWrongKey() async throws {
        try await TestSupport.withTemporaryDirectory { workspace in
            let fileManager = FileManager.default
            let decoder = Self.makeArchiveJSONDecoder()

            // --- Case 1: 1-byte flip in an `isEncrypted == 1` `clip_contents.text` cell + wrong `--key-file` ---
            let colSupportDir = workspace.appendingPathComponent("ColumnTamperSupport", isDirectory: true)
            try fileManager.createDirectory(at: colSupportDir, withIntermediateDirectories: true)
            let colKeyProvider = FileDatabaseKeyProvider(supportDirectory: colSupportDir)
            let colDBURL = colSupportDir.appendingPathComponent("History.sqlite", isDirectory: false)

            let healthyPlainID = UUID()
            let healthySecretID = UUID()
            let healthySecretText = ["gh", "p_", "HEALTHY_SURVIVING_SECRET_11223344556677"].joined()
            let corruptTextID = UUID()
            let corruptSecretText = ["sk", "-ant-", "CORRUPTED_CELL_SECRET_7788990011223344"].joined()

            do {
                let seedStore = GRDBHistoryStore(directory: colSupportDir, keyProvider: colKeyProvider)
                defer { seedStore.close() }

                try seedStore.upsert(
                    ClipboardItem.fixture(
                        id: healthyPlainID,
                        kind: .text,
                        text: "Healthy Plain Note",
                        copiedAt: Date(timeIntervalSince1970: 1_715_100_300)
                    )
                )
                try seedStore.upsert(
                    ClipboardItem.fixture(
                        id: healthySecretID,
                        kind: .text,
                        text: healthySecretText,
                        copiedAt: Date(timeIntervalSince1970: 1_715_100_200)
                    )
                )
                let corruptItem = ClipboardItem.fixture(
                    id: corruptTextID,
                    kind: .text,
                    title: "Corruptible Secret Row",
                    text: corruptSecretText,
                    copiedAt: Date(timeIntervalSince1970: 1_715_100_100)
                )
                #expect(SensitiveContent.shouldEncryptAtRest(corruptItem))
                try seedStore.upsert(corruptItem)
            }

            try Self.flipLastByteInEncryptedColumn(
                at: colDBURL,
                table: "clip_contents",
                column: "text",
                idColumn: "clipId",
                clipID: corruptTextID
            )

            // Default Mode A run isolates corruptTextID into corrupted-items.json and exits 2.
            let partialColOut = workspace.appendingPathComponent("PartialCol.clipbookarchive", isDirectory: true)
            let partialColRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", colSupportDir.path,
                    "--key-file", colKeyProvider.keyFileURL.path,
                    "--output-dir", partialColOut.path,
                ]
            )
            #expect(partialColRun.exitCode == 2, "Expected exit 2 on partial recovery, got \(partialColRun.exitCode): \(partialColRun.stderr)")

            let colCorruptedIDs = try decoder.decode(
                [String].self,
                from: try Data(contentsOf: partialColOut.appendingPathComponent("corrupted-items.json", isDirectory: false))
            )
            #expect(colCorruptedIDs == [corruptTextID.uuidString.lowercased()])

            let colRecoveredItems = try decoder.decode(
                [ClipBookArchiveItem].self,
                from: try Data(contentsOf: partialColOut.appendingPathComponent("history.json", isDirectory: false))
            )
            #expect(colRecoveredItems.map(\.id) == [healthyPlainID, healthySecretID])
            #expect(colRecoveredItems.first { $0.id == healthySecretID }?.text == healthySecretText)
            #expect(!colRecoveredItems.contains { $0.id == corruptTextID })

            // `--strict` exits 1 without writing <output-dir>.
            let strictColOut = workspace.appendingPathComponent("StrictCol.clipbookarchive", isDirectory: true)
            let strictColRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", colSupportDir.path,
                    "--key-file", colKeyProvider.keyFileURL.path,
                    "--strict",
                    "--output-dir", strictColOut.path,
                ]
            )
            #expect(strictColRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: strictColOut.path))

            // Wrong `--key-file` fails `key_verifier_v1` with exit 3 and leaves <output-dir> absent.
            let wrongKeyURL = workspace.appendingPathComponent("wrong.devkey", isDirectory: false)
            var wrongKeyData = MasterKeyHexCodec.encode(SymmetricKey(size: .bits256))
            wrongKeyData.append(0x0A)
            try wrongKeyData.write(to: wrongKeyURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wrongKeyURL.path)

            let wrongKeyOut = workspace.appendingPathComponent("WrongKeyOut.clipbookarchive", isDirectory: true)
            let wrongKeyRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", colSupportDir.path,
                    "--key-file", wrongKeyURL.path,
                    "--output-dir", wrongKeyOut.path,
                ]
            )
            #expect(wrongKeyRun.exitCode == 3)
            #expect(!fileManager.fileExists(atPath: wrongKeyOut.path))

            // --- Case 2: Corrupt 1 byte in `Images/<id>.enc` ---
            let assetSupportDir = workspace.appendingPathComponent("AssetTamperSupport", isDirectory: true)
            try fileManager.createDirectory(at: assetSupportDir, withIntermediateDirectories: true)
            let assetKeyProvider = FileDatabaseKeyProvider(supportDirectory: assetSupportDir)

            let survivingImageID = UUID()
            let survivingPNG = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20, color: .systemPurple)
            let corruptAssetID = UUID()
            let corruptPNG = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemBrown)
            var corruptEncAssetURL: URL!

            do {
                let seedStore = GRDBHistoryStore(directory: assetSupportDir, keyProvider: assetKeyProvider)
                defer { seedStore.close() }

                let survivingEncURL = try seedStore.writeManagedAsset(
                    pngData: survivingPNG,
                    role: .image,
                    clipID: survivingImageID,
                    encrypted: true
                )
                try seedStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: survivingImageID,
                        kind: .image,
                        title: "Healthy Encrypted Image",
                        text: ["Authorization", ": Bearer ", "SURVIVING_ASSET_SECRET_334455667788"].joined(),
                        assetPath: survivingEncURL.path,
                        copiedAt: Date(timeIntervalSince1970: 1_715_200_200),
                        sensitivity: .sensitive
                    ),
                    convertingExternalAssets: true
                )

                let stagedCorruptEncURL = try seedStore.writeManagedAsset(
                    pngData: corruptPNG,
                    role: .image,
                    clipID: corruptAssetID,
                    encrypted: true
                )
                let savedCorrupt = try seedStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: corruptAssetID,
                        kind: .image,
                        title: "Corrupted Encrypted Image",
                        text: ["Authorization", ": Bearer ", "CORRUPT_ASSET_SECRET_990011223344"].joined(),
                        assetPath: stagedCorruptEncURL.path,
                        copiedAt: Date(timeIntervalSince1970: 1_715_200_100),
                        sensitivity: .sensitive
                    ),
                    convertingExternalAssets: true
                )
                corruptEncAssetURL = URL(fileURLWithPath: try #require(savedCorrupt.assetPath))
            }

            var encAssetBytes = try Data(contentsOf: corruptEncAssetURL)
            #expect(encAssetBytes.starts(with: ImageAssetStore.encryptedMagic))
            encAssetBytes[encAssetBytes.count - 1] ^= 0x01
            try encAssetBytes.write(to: corruptEncAssetURL)

            let partialAssetOut = workspace.appendingPathComponent("PartialAsset.clipbookarchive", isDirectory: true)
            let partialAssetRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", assetSupportDir.path,
                    "--key-file", assetKeyProvider.keyFileURL.path,
                    "--output-dir", partialAssetOut.path,
                ]
            )
            #expect(partialAssetRun.exitCode == 2, "Expected exit 2 on corrupt .enc asset, got \(partialAssetRun.exitCode): \(partialAssetRun.stderr)")

            let assetCorruptedIDs = try decoder.decode(
                [String].self,
                from: try Data(contentsOf: partialAssetOut.appendingPathComponent("corrupted-items.json", isDirectory: false))
            )
            #expect(assetCorruptedIDs == [corruptAssetID.uuidString.lowercased()])

            let assetRecoveredItems = try decoder.decode(
                [ClipBookArchiveItem].self,
                from: try Data(contentsOf: partialAssetOut.appendingPathComponent("history.json", isDirectory: false))
            )
            #expect(assetRecoveredItems.map(\.id) == [survivingImageID])
            let survivingRelPath = try #require(assetRecoveredItems.first?.assetPath)
            #expect(try Data(contentsOf: partialAssetOut.appendingPathComponent(survivingRelPath)) == survivingPNG)

            let recoveredImageEntries = try fileManager.contentsOfDirectory(
                at: partialAssetOut.appendingPathComponent("assets/images", isDirectory: true),
                includingPropertiesForKeys: nil,
                options: []
            )
            #expect(!recoveredImageEntries.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(corruptAssetID.uuidString) })

            // `--strict` on corrupt .enc asset exits 1 without writing <output-dir>.
            let strictAssetOut = workspace.appendingPathComponent("StrictAsset.clipbookarchive", isDirectory: true)
            let strictAssetRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir", assetSupportDir.path,
                    "--key-file", assetKeyProvider.keyFileURL.path,
                    "--strict",
                    "--output-dir", strictAssetOut.path,
                ]
            )
            #expect(strictAssetRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: strictAssetOut.path))
        }
    }

    @Test
    func modeBEncryptedV2ArchiveRecoveryRoundTripAndUnicodeNormalization() async throws {
        try await TestSupport.withTemporaryDirectory { workspace in
            let fileManager = FileManager.default
            let sourceSupportDir = workspace.appendingPathComponent("ModeBSourceSupport", isDirectory: true)
            try fileManager.createDirectory(at: sourceSupportDir, withIntermediateDirectories: true)

            let sourceStore = GRDBHistoryStore(
                directory: sourceSupportDir,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { sourceStore.close() }

            let workTag = try sourceStore.createTag(name: "WorkVault", color: "#00897B")
            let designTag = try sourceStore.createTag(name: "DesignLinks", color: "#5E35B1")

            let secretTextID = UUID()
            let secretTextPayload = ["gh", "p_", "MODE_B_ARCHIVE_SECRET_6677889900112233"].joined()
            var secretTextItem = ClipboardItem.fixture(
                id: secretTextID,
                kind: .text,
                title: "Encrypted V2 Archive Token",
                text: secretTextPayload,
                copiedAt: Date(timeIntervalSince1970: 1_715_300_400),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_300_350),
                isFavorite: true,
                tags: [workTag.id],
                favoriteOrder: 1
            )
            secretTextItem.tagOrders = [workTag.id: 5]
            try sourceStore.upsert(secretTextItem)

            let richID = UUID()
            let richText = "Archive Mode B Rich Content"
            let richRTF = try TestSupport.makeRTFData(text: richText)
            let richHTML = "<section><h2>Archive Mode B</h2><p>Rich Content</p></section>"
            var richItem = ClipboardItem.fixture(
                id: richID,
                kind: .richText,
                title: "Rich Specification",
                text: richText,
                rtfData: richRTF,
                html: richHTML,
                copiedAt: Date(timeIntervalSince1970: 1_715_300_300),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_300_290),
                tags: [designTag.id]
            )
            richItem.tagOrders = [designTag.id: 2]
            try sourceStore.upsert(richItem)

            let encImageID = UUID()
            let encImagePNG = try TestSupport.makePNGData(pixelWidth: 34, pixelHeight: 22, color: .systemPink)
            let stagedEncImageURL = try sourceStore.writeManagedAsset(
                pngData: encImagePNG,
                role: .image,
                clipID: encImageID,
                encrypted: true
            )
            let ocrSecret = ["Authorization", ": Bearer ", "MODE_B_IMAGE_OCR_SECRET_445566778899"].joined()
            var encImageItem = ClipboardItem.fixture(
                id: encImageID,
                kind: .image,
                title: "Encrypted Diagram",
                text: ocrSecret,
                qrCodeText: "https://vault.example/mode-b-qr",
                assetPath: stagedEncImageURL.path,
                imageDigest: sourceStore.computeImageDigest(forPNGData: encImagePNG),
                copiedAt: Date(timeIntervalSince1970: 1_715_300_200),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_300_180),
                byteSize: encImagePNG.count,
                tags: [workTag.id, designTag.id],
                sensitivity: .sensitive
            )
            encImageItem.tagOrders = [workTag.id: 3, designTag.id: 6]
            try sourceStore.saveAndReconcileItem(encImageItem, convertingExternalAssets: true)

            let linkID = UUID()
            let previewPNG = try TestSupport.makePNGData(pixelWidth: 26, pixelHeight: 18, color: .systemCyan)
            let faviconICO = Self.makeSampleICOData()
            let previewURL = try sourceStore.writeManagedAsset(
                pngData: previewPNG,
                role: .linkPreview,
                clipID: linkID,
                encrypted: false,
                preferredPlainExtension: "png"
            )
            let faviconURL = try sourceStore.writeManagedAsset(
                pngData: faviconICO,
                role: .linkFavicon,
                clipID: linkID,
                encrypted: false,
                preferredPlainExtension: "ico"
            )
            let linkFetchedAt = Date(timeIntervalSince1970: 1_715_300_095)
            var linkItem = ClipboardItem.fixture(
                id: linkID,
                kind: .link,
                title: "Design System Portal",
                text: "https://design.example.com/tokens",
                copiedAt: Date(timeIntervalSince1970: 1_715_300_100),
                firstCopiedAt: Date(timeIntervalSince1970: 1_715_300_090),
                tags: [designTag.id],
                linkPreviewDetails: LinkPreviewDetails(
                    url: "https://design.example.com/tokens",
                    title: "Design Tokens",
                    description: "Cross-platform color and typography tokens",
                    imagePath: previewURL.path,
                    faviconPath: faviconURL.path,
                    fetchedAt: linkFetchedAt
                )
            )
            linkItem.tagOrders = [designTag.id: 1]
            try sourceStore.saveAndReconcileItem(linkItem, convertingExternalAssets: true)

            // Export production 600,000-iteration v2 archive using NFC passphrase ("caf\u{00E9}..."),
            // then recover using NFD ("caf\u{0065}\u{0301}...") + trailing "\n" via --passphrase-file!
            let nfcPassphrase = ["caf\u{00E9}-v2-recovery-", "passphrase-2026-prod"].joined()
            let nfdPassphraseBase = ["caf\u{0065}\u{0301}-v2-recovery-", "passphrase-2026-prod"].joined()
            #expect(nfcPassphrase.utf8.count != nfdPassphraseBase.utf8.count)
            #expect(nfdPassphraseBase.precomposedStringWithCanonicalMapping == nfcPassphrase)

            let prodV2ArchiveURL = workspace.appendingPathComponent("ProdBackupV2.clipbookarchive", isDirectory: true)
            let prodExportService = ClipBookArchiveService(supportDirectory: sourceSupportDir)
            try prodExportService.export(
                items: try sourceStore.fetchAll(),
                tags: try sourceStore.fetchTags(),
                to: prodV2ArchiveURL,
                passphrase: nfcPassphrase,
                loadItem: { try sourceStore.loadingContent(of: $0, scope: .full) }
            )
            #expect(try prodExportService.inspect(at: prodV2ArchiveURL) == ClipBookArchiveInspection(formatVersion: 2, isEncrypted: true))

            let nfdPassphraseFileURL = workspace.appendingPathComponent("archive-passphrase-nfd.txt", isDirectory: false)
            try Data((nfdPassphraseBase + "\n").utf8).write(to: nfdPassphraseFileURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nfdPassphraseFileURL.path)

            // Run Mode B WITHOUT `--allow-test-iterations` to verify production 600,000-round archive recovery!
            let recoveredV1URL = workspace.appendingPathComponent("RecoveredFromV2.clipbookarchive", isDirectory: true)
            let filePassRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", prodV2ArchiveURL.path,
                    "--passphrase-file", nfdPassphraseFileURL.path,
                    "--output-dir", recoveredV1URL.path,
                ]
            )
            #expect(filePassRun.exitCode == 0, "Mode B --passphrase-file failed: \(filePassRun.stderr)")
            try Self.assertCleanV1ArchiveStructure(at: recoveredV1URL)

            // Also verify `--passphrase-stdin` with NFD passphrase + "\r\n" against an NFC-exported v2 archive.
            let fastV2ArchiveURL = workspace.appendingPathComponent("FastStdinV2.clipbookarchive", isDirectory: true)
            let fastExportService = ClipBookArchiveService(
                supportDirectory: sourceSupportDir,
                kdfIterations: 1_000,
                allowTestIterations: true
            )
            try fastExportService.export(
                items: try sourceStore.fetchAll(),
                tags: try sourceStore.fetchTags(),
                to: fastV2ArchiveURL,
                passphrase: nfcPassphrase,
                loadItem: { try sourceStore.loadingContent(of: $0, scope: .full) }
            )

            let recoveredStdinV1URL = workspace.appendingPathComponent("RecoveredStdinV1.clipbookarchive", isDirectory: true)
            let stdinPassRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", fastV2ArchiveURL.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", recoveredStdinV1URL.path,
                ],
                stdinData: Data((nfdPassphraseBase + "\r\n").utf8)
            )
            #expect(stdinPassRun.exitCode == 0, "Mode B --passphrase-stdin failed: \(stdinPassRun.stderr)")
            try Self.assertCleanV1ArchiveStructure(at: recoveredStdinV1URL)

            // Verify decrypted asset extensions & raw bytes directly inside <recovered-v1.clipbookarchive>.
            let decoder = Self.makeArchiveJSONDecoder()
            let recoveredHistory = try decoder.decode(
                [ClipBookArchiveItem].self,
                from: try Data(contentsOf: recoveredV1URL.appendingPathComponent("history.json", isDirectory: false))
            )
            #expect(recoveredHistory.count == 4)

            let recoveredImageEntry = try #require(recoveredHistory.first { $0.id == encImageID })
            let recoveredImageRelPath = try #require(recoveredImageEntry.assetPath)
            #expect(URL(fileURLWithPath: recoveredImageRelPath).pathExtension == "png")
            #expect(try Data(contentsOf: recoveredV1URL.appendingPathComponent(recoveredImageRelPath)) == encImagePNG)

            let recoveredLinkEntry = try #require(recoveredHistory.first { $0.id == linkID })
            let recoveredPreviewRelPath = try #require(recoveredLinkEntry.linkPreviewDetails?.imagePath)
            let recoveredFaviconRelPath = try #require(recoveredLinkEntry.linkPreviewDetails?.faviconPath)
            #expect(URL(fileURLWithPath: recoveredPreviewRelPath).pathExtension == "png")
            #expect(URL(fileURLWithPath: recoveredFaviconRelPath).pathExtension == "ico")
            #expect(try Data(contentsOf: recoveredV1URL.appendingPathComponent(recoveredPreviewRelPath)) == previewPNG)
            #expect(try Data(contentsOf: recoveredV1URL.appendingPathComponent(recoveredFaviconRelPath)) == faviconICO)

            // Import <recovered-v1.clipbookarchive> via ClipBookArchiveService.import(..., passphrase: nil)
            // into a fresh GRDBHistoryStore and assert 100% fidelity!
            let targetSupportDir = workspace.appendingPathComponent("ModeBImportedSupport", isDirectory: true)
            let targetStore = GRDBHistoryStore(
                directory: targetSupportDir,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { targetStore.close() }

            let importService = ClipBookArchiveService(supportDirectory: targetSupportDir)
            let importResult = try importService.import(
                from: recoveredV1URL,
                into: targetStore,
                passphrase: nil
            )
            #expect(importResult.itemCount == 4)
            #expect(importResult.tagCount == 2)

            let targetTagByName = Dictionary(uniqueKeysWithValues: try targetStore.fetchTags().map { ($0.name, $0) })
            let targetWorkTag = try #require(targetTagByName["WorkVault"])
            let targetDesignTag = try #require(targetTagByName["DesignLinks"])

            let importedByID = Dictionary(uniqueKeysWithValues: try targetStore.fetchAll().map { ($0.id, $0) })

            let importedSecretText = try targetStore.loadingContent(
                of: try #require(importedByID[secretTextID]),
                scope: .full
            )
            #expect(importedSecretText.title == "Encrypted V2 Archive Token")
            #expect(importedSecretText.text == secretTextPayload)
            #expect(importedSecretText.isFavorite)
            #expect(importedSecretText.favoriteOrder == 1)
            #expect(importedSecretText.tagOrders == [targetWorkTag.id: 5])

            let importedRich = try targetStore.loadingContent(
                of: try #require(importedByID[richID]),
                scope: .full
            )
            #expect(importedRich.text == richText)
            #expect(importedRich.html == richHTML)
            #expect(importedRich.rtfData == richRTF)
            #expect(importedRich.tagOrders == [targetDesignTag.id: 2])

            let importedEncImage = try targetStore.loadingContent(
                of: try #require(importedByID[encImageID]),
                scope: .full
            )
            #expect(importedEncImage.text == ocrSecret)
            #expect(importedEncImage.qrCodeText == "https://vault.example/mode-b-qr")
            #expect(importedEncImage.sensitivity == .sensitive)
            #expect(importedEncImage.tagOrders == [targetWorkTag.id: 3, targetDesignTag.id: 6])
            #expect(importedEncImage.imageDigest == targetStore.computeImageDigest(forPNGData: encImagePNG))
            let importedEncImgURL = URL(fileURLWithPath: try #require(importedEncImage.assetPath))
            #expect(importedEncImgURL.pathExtension == "enc")
            #expect(
                try ImageAssetStore.readAssetData(
                    at: importedEncImgURL,
                    role: .image,
                    ownerClipID: encImageID,
                    requiresEncryption: true
                ) == encImagePNG
            )

            let importedLink = try targetStore.loadingContent(
                of: try #require(importedByID[linkID]),
                scope: .full
            )
            #expect(importedLink.tagOrders == [targetDesignTag.id: 1])
            let importedLinkDetails = try #require(importedLink.linkPreviewDetails)
            #expect(importedLinkDetails.url == "https://design.example.com/tokens")
            #expect(importedLinkDetails.title == "Design Tokens")
            #expect(importedLinkDetails.description == "Cross-platform color and typography tokens")
            #expect(importedLinkDetails.fetchedAt == linkFetchedAt)
            let importedLinkPrevURL = URL(fileURLWithPath: try #require(importedLinkDetails.imagePath))
            let importedLinkFavURL = URL(fileURLWithPath: try #require(importedLinkDetails.faviconPath))
            #expect(importedLinkPrevURL.pathExtension == "png")
            #expect(importedLinkFavURL.pathExtension == "ico")
            #expect(try Data(contentsOf: importedLinkPrevURL) == previewPNG)
            #expect(try Data(contentsOf: importedLinkFavURL) == faviconICO)
        }
    }

    @Test
    func modeBIterationBoundsWrongPassphraseTamperAndSymlinkRejections() async throws {
        try await TestSupport.withTemporaryDirectory { workspace in
            let fileManager = FileManager.default
            let sourceSupportDir = workspace.appendingPathComponent("ModeBNegativeSource", isDirectory: true)
            try fileManager.createDirectory(at: sourceSupportDir, withIntermediateDirectories: true)

            let sourceStore = GRDBHistoryStore(
                directory: sourceSupportDir,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { sourceStore.close() }

            let imageID = UUID()
            let pngBytes = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemRed)
            let stagedImgURL = try sourceStore.writeManagedAsset(
                pngData: pngBytes,
                role: .image,
                clipID: imageID,
                encrypted: true
            )
            try sourceStore.saveAndReconcileItem(
                ClipboardItem.fixture(
                    id: imageID,
                    kind: .image,
                    title: "Negative Check Image",
                    text: ["sk", "-ant-", "MODE_B_NEGATIVE_SECRET_5566778899001122"].joined(),
                    assetPath: stagedImgURL.path,
                    copiedAt: Date(timeIntervalSince1970: 1_715_400_100),
                    sensitivity: .sensitive
                ),
                convertingExternalAssets: true
            )

            let correctPassphrase = ["mode-b-negative-", "correct-passphrase-2026"].joined()
            let wrongPassphrase = ["mode-b-negative-", "wrong-passphrase-999999"].joined()

            let fastV2URL = workspace.appendingPathComponent("Fast1000.clipbookarchive", isDirectory: true)
            let fastService = ClipBookArchiveService(
                supportDirectory: sourceSupportDir,
                kdfIterations: 1_000,
                allowTestIterations: true
            )
            try fastService.export(
                items: try sourceStore.fetchAll(),
                tags: [],
                to: fastV2URL,
                passphrase: correctPassphrase,
                loadItem: { try sourceStore.loadingContent(of: $0, scope: .full) }
            )

            // 1. 1,000-iteration v2 archive fails WITHOUT `--allow-test-iterations` and succeeds WITH `--allow-test-iterations`.
            let rejectedIterOut = workspace.appendingPathComponent("RejectedIterOut.clipbookarchive", isDirectory: true)
            let rejectedIterRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", fastV2URL.path,
                    "--passphrase-stdin",
                    "--output-dir", rejectedIterOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(rejectedIterRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: rejectedIterOut.path))

            let allowedIterOut = workspace.appendingPathComponent("AllowedIterOut.clipbookarchive", isDirectory: true)
            let allowedIterRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", fastV2URL.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", allowedIterOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(allowedIterRun.exitCode == 0, "Expected 1,000-iter archive to succeed with --allow-test-iterations: \(allowedIterRun.stderr)")
            try Self.assertCleanV1ArchiveStructure(at: allowedIterOut)

            // 2. Wrong passphrase exits 3 (both --passphrase-file and --passphrase-stdin) and leaves <output-dir> absent.
            let wrongPassFileURL = workspace.appendingPathComponent("wrong-passphrase.txt", isDirectory: false)
            try Data((wrongPassphrase + "\n").utf8).write(to: wrongPassFileURL)

            let wrongPassFileOut = workspace.appendingPathComponent("WrongPassFileOut.clipbookarchive", isDirectory: true)
            let wrongPassFileRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", fastV2URL.path,
                    "--passphrase-file", wrongPassFileURL.path,
                    "--allow-test-iterations",
                    "--output-dir", wrongPassFileOut.path,
                ]
            )
            #expect(wrongPassFileRun.exitCode == 3)
            #expect(!fileManager.fileExists(atPath: wrongPassFileOut.path))

            let wrongPassStdinOut = workspace.appendingPathComponent("WrongPassStdinOut.clipbookarchive", isDirectory: true)
            let wrongPassStdinRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", fastV2URL.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", wrongPassStdinOut.path,
                ],
                stdinData: Data((wrongPassphrase + "\n").utf8)
            )
            #expect(wrongPassStdinRun.exitCode == 3)
            #expect(!fileManager.fileExists(atPath: wrongPassStdinOut.path))

            // 3. Tampered manifest.json (appVersion altered -> invalidates manifestDigest AAD) exits non-zero with <output-dir> clean.
            let tamperedManifestArchive = workspace.appendingPathComponent("TamperedManifest.clipbookarchive", isDirectory: true)
            try fileManager.copyItem(at: fastV2URL, to: tamperedManifestArchive)
            let manifestFileURL = tamperedManifestArchive.appendingPathComponent("manifest.json", isDirectory: false)
            let decoder = Self.makeArchiveJSONDecoder()
            var tamperedManifest = try decoder.decode(ClipBookArchiveManifest.self, from: try Data(contentsOf: manifestFileURL))
            tamperedManifest.appVersion = "99.99.99-tampered"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tamperedManifest).write(to: manifestFileURL)

            let tamperedManifestOut = workspace.appendingPathComponent("TamperedManifestOut.clipbookarchive", isDirectory: true)
            let tamperedManifestRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", tamperedManifestArchive.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", tamperedManifestOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(tamperedManifestRun.exitCode != 0)
            #expect(tamperedManifestRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: tamperedManifestOut.path))

            // 4. Tampered assets/images/*.enc (1-byte flip + missing .enc file) exits non-zero with <output-dir> clean.
            let tamperedAssetArchive = workspace.appendingPathComponent("TamperedAsset.clipbookarchive", isDirectory: true)
            try fileManager.copyItem(at: fastV2URL, to: tamperedAssetArchive)
            let assetEncURL = tamperedAssetArchive.appendingPathComponent("assets/images/\(imageID.uuidString).enc", isDirectory: false)
            var assetEncBytes = try Data(contentsOf: assetEncURL)
            assetEncBytes[assetEncBytes.count - 1] ^= 0xFF
            try assetEncBytes.write(to: assetEncURL)

            let tamperedAssetOut = workspace.appendingPathComponent("TamperedAssetOut.clipbookarchive", isDirectory: true)
            let tamperedAssetRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", tamperedAssetArchive.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", tamperedAssetOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(tamperedAssetRun.exitCode != 0)
            #expect(tamperedAssetRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: tamperedAssetOut.path))

            let deletedAssetArchive = workspace.appendingPathComponent("DeletedAsset.clipbookarchive", isDirectory: true)
            try fileManager.copyItem(at: fastV2URL, to: deletedAssetArchive)
            try fileManager.removeItem(
                at: deletedAssetArchive.appendingPathComponent("assets/images/\(imageID.uuidString).enc", isDirectory: false)
            )
            let deletedAssetOut = workspace.appendingPathComponent("DeletedAssetOut.clipbookarchive", isDirectory: true)
            let deletedAssetRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", deletedAssetArchive.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", deletedAssetOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(deletedAssetRun.exitCode != 0)
            #expect(deletedAssetRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: deletedAssetOut.path))

            // 5. Symlinked manifest.json exits non-zero with <output-dir> clean.
            let symlinkManifestArchive = workspace.appendingPathComponent("SymlinkManifest.clipbookarchive", isDirectory: true)
            try fileManager.copyItem(at: fastV2URL, to: symlinkManifestArchive)
            let archiveManifestURL = symlinkManifestArchive.appendingPathComponent("manifest.json", isDirectory: false)
            let externalManifestURL = workspace.appendingPathComponent("external-manifest.json", isDirectory: false)
            try fileManager.moveItem(at: archiveManifestURL, to: externalManifestURL)
            #expect(Darwin.symlink(externalManifestURL.path, archiveManifestURL.path) == 0)

            let symlinkManifestOut = workspace.appendingPathComponent("SymlinkManifestOut.clipbookarchive", isDirectory: true)
            let symlinkManifestRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive", symlinkManifestArchive.path,
                    "--passphrase-stdin",
                    "--allow-test-iterations",
                    "--output-dir", symlinkManifestOut.path,
                ],
                stdinData: Data((correctPassphrase + "\n").utf8)
            )
            #expect(symlinkManifestRun.exitCode != 0)
            #expect(symlinkManifestRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: symlinkManifestOut.path))
        }
    }

    @Test
    func modeAUnencryptedMissingPlainAssetRecoversNilPathAndInlineEqualsFlagParsing() async throws {
        try await TestSupport.withTemporaryDirectory { workspace in
            let fileManager = FileManager.default
            let supportDir = workspace.appendingPathComponent("ModeAPlainMissingAsset", isDirectory: true)
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)

            let keyProvider = FileDatabaseKeyProvider(supportDirectory: supportDir)
            let linkID = UUID()
            let survivingPlainImgID = UUID()
            let plainImgID = UUID()
            let missingEncID = UUID()
            let unencryptedMissingEncID = UUID()
            let survivingPlainPNG = try TestSupport.makePNGData(pixelWidth: 18, pixelHeight: 18, color: .systemGreen)
            let missingEncURL: URL

            do {
                let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                defer { store.close() }

                // 1. Plain unencrypted .link row whose LinkPreviews/ directory & .ico/.png files are absent on disk.
                let linkItem = ClipboardItem.fixture(
                    id: linkID,
                    kind: .link,
                    title: "Healthy Link With Cleaned Preview",
                    text: "https://example.org/docs",
                    copiedAt: Date(timeIntervalSince1970: 1_715_500_300),
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://example.org/docs",
                        title: "Example Docs",
                        description: "Documentation home",
                        imagePath: supportDir.appendingPathComponent("LinkPreviews/\(linkID.uuidString)-preview.png").path,
                        faviconPath: supportDir.appendingPathComponent("LinkPreviews/\(linkID.uuidString)-favicon.ico").path,
                        fetchedAt: Date(timeIntervalSince1970: 1_715_500_305)
                    )
                )
                #expect(!SensitiveContent.shouldEncryptAtRest(linkItem))
                try store.upsert(linkItem)

                // 2. Seed an existing Images/ directory with one valid plain PNG alongside a plain .image row whose .png file is missing on disk.
                let survivingPlainURL = try store.writeManagedAsset(
                    pngData: survivingPlainPNG,
                    role: .image,
                    clipID: survivingPlainImgID,
                    encrypted: false
                )
                try store.upsert(
                    ClipboardItem.fixture(
                        id: survivingPlainImgID,
                        kind: .image,
                        title: "Surviving Plain PNG",
                        assetPath: survivingPlainURL.path,
                        copiedAt: Date(timeIntervalSince1970: 1_715_500_250)
                    )
                )

                let plainImgItem = ClipboardItem.fixture(
                    id: plainImgID,
                    kind: .image,
                    title: "Plain Missing PNG",
                    text: "harmless caption",
                    assetPath: supportDir.appendingPathComponent("Images/\(plainImgID.uuidString).png").path,
                    copiedAt: Date(timeIntervalSince1970: 1_715_500_200)
                )
                #expect(!SensitiveContent.shouldEncryptAtRest(plainImgItem))
                try store.upsert(plainImgItem)

                // Verify clean Mode A recovery (including `--flag=value` syntax and `--strict`!) exits 0 with nil asset paths!
            }

            let cleanOut = workspace.appendingPathComponent("CleanPlainMissing.clipbookarchive", isDirectory: true)
            let cleanRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir=\(supportDir.path)",
                    "--key-file=\(keyProvider.keyFileURL.path)",
                    "--strict",
                    "--output-dir=\(cleanOut.path)",
                ]
            )
            #expect(cleanRun.exitCode == 0, "Expected exit 0 on plain missing assets, got \(cleanRun.exitCode): \(cleanRun.stderr)")
            #expect(!fileManager.fileExists(atPath: cleanOut.appendingPathComponent("corrupted-items.json").path))

            let decoder = Self.makeArchiveJSONDecoder()
            let recoveredPlainItems = try decoder.decode(
                [ClipBookArchiveItem].self,
                from: try Data(contentsOf: cleanOut.appendingPathComponent("history.json"))
            )
            #expect(recoveredPlainItems.count == 3)
            let recoveredLink = try #require(recoveredPlainItems.first { $0.id == linkID })
            #expect(recoveredLink.text == "https://example.org/docs")
            #expect(recoveredLink.linkPreviewDetails?.title == "Example Docs")
            #expect(recoveredLink.linkPreviewDetails?.imagePath == nil)
            #expect(recoveredLink.linkPreviewDetails?.faviconPath == nil)

            let recoveredSurvivingPlainImg = try #require(recoveredPlainItems.first { $0.id == survivingPlainImgID })
            let survivingRelAssetPath = try #require(recoveredSurvivingPlainImg.assetPath)
            #expect(try Data(contentsOf: cleanOut.appendingPathComponent(survivingRelAssetPath)) == survivingPlainPNG)

            let recoveredPlainImg = try #require(recoveredPlainItems.first { $0.id == plainImgID })
            #expect(recoveredPlainImg.assetPath == nil)

            // 3. Missing .enc asset paths (both isEncrypted == 1 and isEncrypted == 0 with .enc extension) isolate to corrupted-items.json with exit 2 and fail --strict with exit 1!
            do {
                let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                defer { store.close() }
                let pngBytes = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20)
                let encURL = try store.writeManagedAsset(pngData: pngBytes, role: .image, clipID: missingEncID, encrypted: true)
                let savedEnc = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: missingEncID,
                        kind: .image,
                        title: "Missing Encrypted Asset",
                        text: ["gh", "p_", "MISSING_ENC_ASSET_SECRET_778899001122"].joined(),
                        assetPath: encURL.path,
                        copiedAt: Date(timeIntervalSince1970: 1_715_500_100),
                        sensitivity: .sensitive
                    ),
                    convertingExternalAssets: true
                )
                missingEncURL = URL(fileURLWithPath: try #require(savedEnc.assetPath))

                // Pending-OCR style unencrypted header row (`isEncrypted == 0`) referencing a missing `.enc` asset path.
                let pendingOCRMissingEncItem = ClipboardItem.fixture(
                    id: unencryptedMissingEncID,
                    kind: .image,
                    title: "Pending OCR Missing Enc",
                    text: nil,
                    assetPath: supportDir.appendingPathComponent("Images/\(unencryptedMissingEncID.uuidString).enc").path,
                    copiedAt: Date(timeIntervalSince1970: 1_715_500_050),
                    sensitivity: nil
                )
                #expect(!SensitiveContent.shouldEncryptAtRest(pendingOCRMissingEncItem))
                try store.upsert(pendingOCRMissingEncItem)
            }
            try fileManager.removeItem(at: missingEncURL)

            let partialOut = workspace.appendingPathComponent("PartialMissingEnc.clipbookarchive", isDirectory: true)
            let partialRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir=\(supportDir.path)",
                    "--key-file=\(keyProvider.keyFileURL.path)",
                    "--output-dir=\(partialOut.path)",
                ]
            )
            #expect(partialRun.exitCode == 2)
            let corruptedIDs = try decoder.decode(
                [String].self,
                from: try Data(contentsOf: partialOut.appendingPathComponent("corrupted-items.json"))
            )
            #expect(
                Set(corruptedIDs) == [
                    missingEncID.uuidString.lowercased(),
                    unencryptedMissingEncID.uuidString.lowercased(),
                ]
            )

            let strictMissingEncOut = workspace.appendingPathComponent("StrictMissingEnc.clipbookarchive", isDirectory: true)
            let strictMissingEncRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--support-dir=\(supportDir.path)",
                    "--key-file=\(keyProvider.keyFileURL.path)",
                    "--strict",
                    "--output-dir=\(strictMissingEncOut.path)",
                ]
            )
            #expect(strictMissingEncRun.exitCode == 1)
            #expect(!fileManager.fileExists(atPath: strictMissingEncOut.path))

            // Mode B inline `--archive=<path>` and `--passphrase-file=<path>` syntax also succeeds cleanly.
            let v2EncArchiveURL = workspace.appendingPathComponent("InlineFlagsV2.clipbookarchive", isDirectory: true)
            let inlinePassphrase = "inline-equals-passphrase-2026"
            let inlinePassFileURL = workspace.appendingPathComponent("inline.pass", isDirectory: false)
            try Data((inlinePassphrase + "\n").utf8).write(to: inlinePassFileURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inlinePassFileURL.path)
            do {
                let archiveSourceDir = workspace.appendingPathComponent("InlineArchiveSource", isDirectory: true)
                let archiveStore = GRDBHistoryStore(directory: archiveSourceDir, keyProvider: InMemoryDatabaseKeyProvider())
                defer { archiveStore.close() }
                try archiveStore.upsert(ClipboardItem.fixture(kind: .text, text: "Mode B inline flag clip"))
                let service = ClipBookArchiveService(
                    supportDirectory: archiveSourceDir,
                    kdfIterations: 1_000,
                    allowTestIterations: true
                )
                try service.export(
                    items: try archiveStore.fetchAll(),
                    tags: try archiveStore.fetchTags(),
                    to: v2EncArchiveURL,
                    passphrase: inlinePassphrase,
                    loadItem: { try archiveStore.loadingContent(of: $0, scope: .full) }
                )
            }
            let modeBInlineOut = workspace.appendingPathComponent("ModeBInlineOut.clipbookarchive", isDirectory: true)
            let modeBInlineRun = try await Self.runRecoveryCLI(
                arguments: [
                    "--archive=\(v2EncArchiveURL.path)",
                    "--passphrase-file=\(inlinePassFileURL.path)",
                    "--allow-test-iterations",
                    "--output-dir=\(modeBInlineOut.path)",
                ]
            )
            #expect(modeBInlineRun.exitCode == 0, "Expected Mode B inline flags to exit 0, got \(modeBInlineRun.exitCode): \(modeBInlineRun.stderr)")

            // 4. Reject raw `--key=...`, `--passphrase=...`, empty `--key-file=`, and boolean `--strict=true` with exit 1.
            let rawKeyRun = try await Self.runRecoveryCLI(
                arguments: ["--support-dir=\(supportDir.path)", "--key=deadbeef", "--output-dir=\(workspace.path)/x"]
            )
            #expect(rawKeyRun.exitCode == 1)
            #expect(rawKeyRun.stderr.contains("Raw secrets are never accepted"))

            let rawPassRun = try await Self.runRecoveryCLI(
                arguments: ["--archive=\(cleanOut.path)", "--passphrase=hunter2", "--output-dir=\(workspace.path)/y"]
            )
            #expect(rawPassRun.exitCode == 1)
            #expect(rawPassRun.stderr.contains("Raw secrets are never accepted"))

            let emptyInlineRun = try await Self.runRecoveryCLI(
                arguments: ["--support-dir=\(supportDir.path)", "--key-file=", "--output-dir=\(workspace.path)/z"]
            )
            #expect(emptyInlineRun.exitCode == 1)

            let boolInlineRun = try await Self.runRecoveryCLI(
                arguments: ["--support-dir=\(supportDir.path)", "--key-file=\(keyProvider.keyFileURL.path)", "--strict=true", "--output-dir=\(workspace.path)/w"]
            )
            #expect(boolInlineRun.exitCode == 1)
        }
    }
}
