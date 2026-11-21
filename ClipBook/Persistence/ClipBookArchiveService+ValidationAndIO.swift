import CryptoKit
import Darwin
import Foundation

nonisolated extension ClipBookArchiveService {
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
