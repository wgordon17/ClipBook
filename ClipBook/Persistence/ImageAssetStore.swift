import CryptoKit
import Darwin
import Foundation
import os

nonisolated final class ImageAssetStore: Sendable {
    static let encryptedMagic = Data("CBENC01\0".utf8)
    static let minimumEncryptedFileLength = 36

    nonisolated struct AssetConversionOutcome: Sendable {
        let writtenURL: URL
        let createdNewFile: Bool
        let supersededManagedURL: URL?
    }

    private struct RegisteredKeysEntry: Sendable {
        let ownerID: UUID
        let keys: ClipBookDerivedKeys
    }

    private static let keyRegistry = OSAllocatedUnfairLock<[String: [RegisteredKeysEntry]]>(initialState: [:])

    static func registerKeys(_ keys: ClipBookDerivedKeys, forSupportDirectory url: URL, ownerID: UUID) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let canonicalPath = canonicalDirectoryURL(url).path
        keyRegistry.withLock { registry in
            var entries = registry[canonicalPath] ?? []
            entries.removeAll { $0.ownerID == ownerID }
            entries.append(RegisteredKeysEntry(ownerID: ownerID, keys: keys))
            registry[canonicalPath] = entries
        }
    }

    static func unregisterKeys(forSupportDirectory url: URL, ownerID: UUID) {
        let canonicalPath = canonicalDirectoryURL(url).path
        keyRegistry.withLock { registry in
            removeOwner(ownerID, forPath: canonicalPath, in: &registry)
        }
    }

    private static func removeOwner(
        _ ownerID: UUID,
        forPath path: String,
        in registry: inout [String: [RegisteredKeysEntry]]
    ) {
        guard var entries = registry[path] else {
            return
        }
        entries.removeAll { $0.ownerID == ownerID }
        if entries.isEmpty {
            registry.removeValue(forKey: path)
        } else {
            registry[path] = entries
        }
    }

    static func isEncryptedAssetFile(at url: URL) -> Bool {
        url.pathExtension.lowercased() == "enc" || hasMagic(encryptedMagic, at: url)
    }

    static func readAssetData(
        at url: URL,
        role: AssetRole,
        ownerClipID: UUID,
        requiresEncryption: Bool = false
    ) throws -> Data {
        var leafStat = stat()
        if Darwin.lstat(url.path, &leafStat) == 0, (leafStat.st_mode & S_IFMT) != S_IFREG {
            throw HistoryStoreError.authenticationFailed
        }

        let isEncryptedFile = isEncryptedAssetFile(at: url)
        if requiresEncryption && !isEncryptedFile {
            throw HistoryStoreError.authenticationFailed
        }
        if !isEncryptedFile {
            return try readNonSymlinkRegularFileData(at: url)
        }

        let parentURL = url.deletingLastPathComponent()
        var parentStat = stat()
        guard Darwin.lstat(parentURL.path, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR else {
            throw HistoryStoreError.authenticationFailed
        }

        let expectedSubdir = (role == .image) ? "Images" : "LinkPreviews"
        guard parentURL.lastPathComponent == expectedSubdir else {
            throw HistoryStoreError.authenticationFailed
        }

        let supportDirURL = parentURL.deletingLastPathComponent()
        let supportDirPath = canonicalDirectoryURL(supportDirURL).path
        let expectedParentPath = URL(fileURLWithPath: supportDirPath, isDirectory: true)
            .appendingPathComponent(expectedSubdir, isDirectory: true)
            .standardizedFileURL
            .path
        guard canonicalDirectoryURL(parentURL).path == expectedParentPath else {
            throw HistoryStoreError.authenticationFailed
        }

        guard let entry = keyRegistry.withLock({ $0[supportDirPath]?.last }) else {
            throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
        }

        let store = ImageAssetStore(supportDirectory: URL(fileURLWithPath: supportDirPath, isDirectory: true))
        return try store.readPNGData(
            at: url,
            role: role,
            clipID: ownerClipID,
            keys: entry.keys,
            requiresEncryption: true
        )
    }

    let supportDirectory: URL

    var imagesDirectory: URL {
        supportDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    var linkPreviewsDirectory: URL {
        supportDirectory.appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    static func plainAssetExtension(preferred: String? = nil, magicBytes data: Data) -> String {
        if let preferred {
            let normalized = preferred.lowercased()
            if normalized != "enc",
               (1...8).contains(normalized.utf8.count),
               normalized.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }) {
                return normalized
            }
        }

        return data.withUnsafeBytes { rawBuffer -> String in
            let count = rawBuffer.count
            if count >= 8,
               rawBuffer[0] == 0x89, rawBuffer[1] == 0x50, rawBuffer[2] == 0x4E, rawBuffer[3] == 0x47,
               rawBuffer[4] == 0x0D, rawBuffer[5] == 0x0A, rawBuffer[6] == 0x1A, rawBuffer[7] == 0x0A {
                return "png"
            }
            if count >= 4,
               rawBuffer[0] == 0x00, rawBuffer[1] == 0x00, rawBuffer[2] == 0x01, rawBuffer[3] == 0x00 {
                return "ico"
            }
            if count >= 3,
               rawBuffer[0] == 0xFF, rawBuffer[1] == 0xD8, rawBuffer[2] == 0xFF {
                return "jpg"
            }
            if count >= 6,
               rawBuffer[0] == 0x47, rawBuffer[1] == 0x49, rawBuffer[2] == 0x46, rawBuffer[3] == 0x38,
               (rawBuffer[4] == 0x37 || rawBuffer[4] == 0x39), rawBuffer[5] == 0x61 {
                return "gif"
            }
            if count >= 12,
               rawBuffer[0] == 0x52, rawBuffer[1] == 0x49, rawBuffer[2] == 0x46, rawBuffer[3] == 0x46,
               rawBuffer[8] == 0x57, rawBuffer[9] == 0x45, rawBuffer[10] == 0x42, rawBuffer[11] == 0x50 {
                return "webp"
            }
            return "png"
        }
    }

    func isManagedAssetURL(_ url: URL) -> Bool {
        let parentURL = url.deletingLastPathComponent()
        var parentStat = stat()
        guard Darwin.lstat(parentURL.path, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }

        let resolvedParent = Self.canonicalDirectoryURL(parentURL)
        return resolvedParent == Self.canonicalDirectoryURL(imagesDirectory)
            || resolvedParent == Self.canonicalDirectoryURL(linkPreviewsDirectory)
    }

    func writeAsset(
        pngData: Data,
        role: AssetRole,
        clipID: UUID,
        encrypted: Bool,
        keys: ClipBookDerivedKeys?,
        preferredPlainExtension: String? = nil,
        sync: Bool = true
    ) throws -> URL {
        let ext = encrypted ? "enc" : Self.plainAssetExtension(preferred: preferredPlainExtension, magicBytes: pngData)
        let destinationDirectory = directory(for: role)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var dirStat = stat()
        guard Darwin.lstat(destinationDirectory.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            throw HistoryStoreError.authenticationFailed
        }

        let destinationURL = targetURL(for: role, clipID: clipID, fileExtension: ext)
        let payload: Data
        if encrypted {
            guard let keys else {
                throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
            }
            let aad = HistoryCrypto.assetAAD(role: role, clipID: clipID)
            let nonce = AES.GCM.Nonce()
            let sealedBox: AES.GCM.SealedBox
            do {
                sealedBox = try AES.GCM.seal(
                    pngData,
                    using: keys.assetFileAEADKey,
                    nonce: nonce,
                    authenticating: aad
                )
            } catch {
                throw HistoryStoreError.authenticationFailed
            }
            guard let combined = sealedBox.combined else {
                throw HistoryStoreError.authenticationFailed
            }
            var encoded = Data(capacity: Self.encryptedMagic.count + combined.count)
            encoded.append(Self.encryptedMagic)
            encoded.append(combined)
            payload = encoded
        } else {
            payload = pngData
        }

        try Self.writeAtomically(payload, to: destinationURL, in: destinationDirectory, sync: sync)
        return destinationURL
    }

    func readPNGData(
        at url: URL,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys?,
        requiresEncryption: Bool = false
    ) throws -> Data {
        let rawData = try Self.readNonSymlinkRegularFileData(at: url)
        return try Self.decodePNGData(
            fromRawData: rawData,
            hasEncExtension: url.pathExtension.lowercased() == "enc",
            role: role,
            clipID: clipID,
            keys: keys,
            requiresEncryption: requiresEncryption
        )
    }

    private static func decodePNGData(
        fromRawData rawData: Data,
        hasEncExtension: Bool,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys?,
        requiresEncryption: Bool
    ) throws -> Data {
        let hasMagic = hasEncryptedMagic(rawData)

        if hasMagic || hasEncExtension {
            guard let keys else {
                throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
            }
            guard hasMagic, rawData.count >= minimumEncryptedFileLength else {
                throw HistoryStoreError.authenticationFailed
            }
            let aad = HistoryCrypto.assetAAD(role: role, clipID: clipID)
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: rawData.dropFirst(encryptedMagic.count))
                return try AES.GCM.open(
                    sealedBox,
                    using: keys.assetFileAEADKey,
                    authenticating: aad
                )
            } catch {
                throw HistoryStoreError.authenticationFailed
            }
        }

        if requiresEncryption {
            throw HistoryStoreError.authenticationFailed
        }

        return rawData
    }

    func stageEncryptedAssetIfNeeded(
        at path: String,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> AssetConversionOutcome? {
        guard !path.isEmpty else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: path, isDirectory: false)
        guard try Self.regularFileExistsRejectingSymlinks(at: sourceURL) else {
            return nil
        }

        let targetURL = self.targetURL(for: role, clipID: clipID, fileExtension: "enc")
        if Self.sameFileLocation(sourceURL, targetURL) {
            let rawData = try Self.readNonSymlinkRegularFileData(at: sourceURL)
            if Self.hasEncryptedMagic(rawData) {
                _ = try Self.decodePNGData(
                    fromRawData: rawData,
                    hasEncExtension: true,
                    role: role,
                    clipID: clipID,
                    keys: keys,
                    requiresEncryption: true
                )
                return AssetConversionOutcome(
                    writtenURL: targetURL,
                    createdNewFile: false,
                    supersededManagedURL: nil
                )
            }
            // Same path with .enc extension but lacking valid CBENC01\0 magic fails closed.
            throw HistoryStoreError.authenticationFailed
        }

        let targetPreexisted = Self.pathExistsNoFollow(targetURL)
        let plainData = try readPNGData(
            at: sourceURL,
            role: role,
            clipID: clipID,
            keys: keys,
            requiresEncryption: false
        )
        let writtenURL = try writeAsset(
            pngData: plainData,
            role: role,
            clipID: clipID,
            encrypted: true,
            keys: keys
        )

        return makeStagedWriteOutcome(
            writtenURL: writtenURL,
            sourceURL: sourceURL,
            targetPreexisted: targetPreexisted
        )
    }

    func stageDecryptedAssetIfNeeded(
        at path: String,
        role: AssetRole,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> AssetConversionOutcome? {
        guard !path.isEmpty else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: path, isDirectory: false)
        guard try Self.regularFileExistsRejectingSymlinks(at: sourceURL) else {
            return nil
        }

        let rawSourceData = try Self.readNonSymlinkRegularFileData(at: sourceURL)
        let hasEncExt = sourceURL.pathExtension.lowercased() == "enc"
        let isEncryptedSource = Self.hasEncryptedMagic(rawSourceData) || hasEncExt

        let plainData: Data
        if isEncryptedSource {
            plainData = try Self.decodePNGData(
                fromRawData: rawSourceData,
                hasEncExtension: hasEncExt,
                role: role,
                clipID: clipID,
                keys: keys,
                requiresEncryption: true
            )
        } else {
            plainData = rawSourceData
        }

        let ext = Self.plainAssetExtension(preferred: sourceURL.pathExtension, magicBytes: plainData)
        let targetURL = self.targetURL(for: role, clipID: clipID, fileExtension: ext)
        if !isEncryptedSource && Self.sameFileLocation(sourceURL, targetURL) {
            return AssetConversionOutcome(
                writtenURL: targetURL,
                createdNewFile: false,
                supersededManagedURL: nil
            )
        }

        let targetPreexisted = Self.pathExistsNoFollow(targetURL)
        let writtenURL = try writeAsset(
            pngData: plainData,
            role: role,
            clipID: clipID,
            encrypted: false,
            keys: nil,
            preferredPlainExtension: ext
        )

        return makeStagedWriteOutcome(
            writtenURL: writtenURL,
            sourceURL: sourceURL,
            targetPreexisted: targetPreexisted
        )
    }

    private func makeStagedWriteOutcome(
        writtenURL: URL,
        sourceURL: URL,
        targetPreexisted: Bool
    ) -> AssetConversionOutcome {
        let sameLocation = Self.sameFileLocation(sourceURL, writtenURL)
        return AssetConversionOutcome(
            writtenURL: writtenURL,
            createdNewFile: !targetPreexisted && !sameLocation,
            supersededManagedURL: (!sameLocation && isManagedAssetURL(sourceURL)) ? sourceURL : nil
        )
    }

    private static func pathExistsNoFollow(_ url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    static func secureUnlink(at url: URL, sync: Bool = true) {
        let path = url.path
        guard !path.isEmpty else {
            return
        }

        var linkStat = stat()
        guard Darwin.lstat(path, &linkStat) == 0 else {
            return
        }

        let mode = linkStat.st_mode & S_IFMT
        if mode == S_IFLNK {
            _ = Darwin.unlink(path)
            return
        }
        guard mode == S_IFREG else {
            return
        }

        let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
        if fd < 0 {
            if errno == ELOOP || errno == EACCES || errno == EPERM {
                _ = Darwin.unlink(path)
            }
            return
        }

        var fileStat = stat()
        if Darwin.fstat(fd, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG {
            let fileSize = Int64(fileStat.st_size)
            if fileSize > 0, Darwin.lseek(fd, 0, SEEK_SET) == 0 {
                let chunkSize = 64 * 1024
                let zeroChunk = [UInt8](repeating: 0, count: chunkSize)
                var remaining = fileSize
                zeroChunk.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    while remaining > 0 {
                        let toWrite = Int(min(Int64(chunkSize), remaining))
                        let written = Darwin.write(fd, baseAddress, toWrite)
                        if written > 0 {
                            remaining -= Int64(written)
                        } else if written < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                }
            }
            if sync {
                if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
                    _ = Darwin.fsync(fd)
                }
            }
        }

        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
    }

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    static func secureUnlinkBatch<S: Sequence>(_ urls: S) where S.Element == URL {
        var zeroFilledRegularURLs: [URL] = []
        var barrierURLByDevice: [dev_t: URL] = [:]
        var zeroFilledInodes: Set<InodeKey> = []
        let chunkSize = 64 * 1024
        var zeroChunk: [UInt8]?

        for url in urls {
            let path = url.path
            guard !path.isEmpty else {
                continue
            }
            var linkStat = stat()
            guard Darwin.lstat(path, &linkStat) == 0 else {
                continue
            }
            let mode = linkStat.st_mode & S_IFMT
            if mode == S_IFLNK {
                _ = Darwin.unlink(path)
                continue
            }
            guard mode == S_IFREG else {
                continue
            }
            let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
            if fd < 0 {
                if errno == ELOOP || errno == EACCES || errno == EPERM {
                    _ = Darwin.unlink(path)
                }
                continue
            }
            var fileStat = stat()
            if Darwin.fstat(fd, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG {
                let inodeKey = InodeKey(dev: fileStat.st_dev, ino: fileStat.st_ino)
                if zeroFilledInodes.insert(inodeKey).inserted {
                    let fileSize = Int64(fileStat.st_size)
                    if fileSize > 0, Darwin.lseek(fd, 0, SEEK_SET) == 0 {
                        if zeroChunk == nil {
                            zeroChunk = [UInt8](repeating: 0, count: chunkSize)
                        }
                        var remaining = fileSize
                        zeroChunk?.withUnsafeBytes { rawBuffer in
                            guard let baseAddress = rawBuffer.baseAddress else { return }
                            while remaining > 0 {
                                let toWrite = Int(min(Int64(chunkSize), remaining))
                                let written = Darwin.write(fd, baseAddress, toWrite)
                                if written > 0 {
                                    remaining -= Int64(written)
                                } else if written < 0 && errno == EINTR {
                                    continue
                                } else {
                                    break
                                }
                            }
                        }
                    }
                    // Flush this vnode's dirty zero-fill pages from UBC to the block device before unlinking.
                    _ = Darwin.fsync(fd)
                    if barrierURLByDevice[fileStat.st_dev] == nil {
                        barrierURLByDevice[fileStat.st_dev] = url
                    }
                }
            }
            _ = Darwin.close(fd)
            zeroFilledRegularURLs.append(url)
        }

        if !zeroFilledRegularURLs.isEmpty {
            issueFullFsyncDeviceBarriers(barrierURLByDevice.values)
            for url in zeroFilledRegularURLs {
                _ = Darwin.unlink(url.path)
            }
        }
    }

    private static func collectEntriesForSecureRemoval(
        at url: URL,
        files: inout [URL],
        directoriesPostOrder: inout [URL]
    ) {
        let path = url.path
        guard !path.isEmpty else {
            return
        }

        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else {
            return
        }

        if (st.st_mode & S_IFMT) == S_IFDIR {
            if let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                for child in children {
                    collectEntriesForSecureRemoval(
                        at: child,
                        files: &files,
                        directoriesPostOrder: &directoriesPostOrder
                    )
                }
            }
            directoriesPostOrder.append(url)
        } else {
            files.append(url)
        }
    }

    static func secureRemoveItem(at url: URL) {
        var files: [URL] = []
        var directoriesPostOrder: [URL] = []
        collectEntriesForSecureRemoval(
            at: url,
            files: &files,
            directoriesPostOrder: &directoriesPostOrder
        )

        if !files.isEmpty {
            secureUnlinkBatch(files)
            var st = stat()
            for fileURL in files where Darwin.lstat(fileURL.path, &st) == 0 {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        var st = stat()
        for dirURL in directoriesPostOrder {
            _ = Darwin.rmdir(dirURL.path)
            if Darwin.lstat(dirURL.path, &st) == 0 {
                try? FileManager.default.removeItem(at: dirURL)
            }
        }
    }

    static func writeExclusivePrivateFile(
        _ data: Data,
        to destinationURL: URL,
        sync: Bool = false,
        mapELOOPToAuthFailed: Bool = false
    ) throws {
        let fd = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            let err = errno
            if mapELOOPToAuthFailed && err == ELOOP {
                throw HistoryStoreError.authenticationFailed
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        var fdOpen = true
        do {
            _ = Darwin.fchmod(fd, mode_t(0o600))
            try data.withUnsafeBytes { rawBuffer in
                guard rawBuffer.count > 0, let baseAddress = rawBuffer.baseAddress else { return }
                var writtenTotal = 0
                while writtenTotal < rawBuffer.count {
                    let result = Darwin.write(fd, baseAddress.advanced(by: writtenTotal), rawBuffer.count - writtenTotal)
                    if result > 0 {
                        writtenTotal += result
                    } else if result < 0 && errno == EINTR {
                        continue
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }

            if sync {
                if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
                    _ = Darwin.fsync(fd)
                }
            }

            fdOpen = false
            guard Darwin.close(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if fdOpen {
                _ = Darwin.close(fd)
            }
            secureUnlink(at: destinationURL)
            throw error
        }
    }

    // MARK: - Private Helpers

    private func directory(for role: AssetRole) -> URL {
        switch role {
        case .image:
            return imagesDirectory
        case .linkPreview, .linkFavicon:
            return linkPreviewsDirectory
        }
    }

    func targetURL(for role: AssetRole, clipID: UUID, fileExtension ext: String) -> URL {
        let dir = directory(for: role)
        switch role {
        case .image:
            return dir.appendingPathComponent("\(clipID.uuidString).\(ext)", isDirectory: false)
        case .linkPreview:
            return dir.appendingPathComponent("\(clipID.uuidString)-preview.\(ext)", isDirectory: false)
        case .linkFavicon:
            return dir.appendingPathComponent("\(clipID.uuidString)-favicon.\(ext)", isDirectory: false)
        }
    }

    private static func hasEncryptedMagic(_ data: Data) -> Bool {
        data.count >= encryptedMagic.count && data.prefix(encryptedMagic.count) == encryptedMagic
    }

    private static func hasMagic(_ magic: Data, at url: URL) -> Bool {
        guard !magic.isEmpty else {
            return false
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return false
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              Int(clamping: fileStat.st_size) >= magic.count else {
            return false
        }

        var header = [UInt8](repeating: 0, count: magic.count)
        let bytesRead: Int = header.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            var total = 0
            while total < magic.count {
                let result = Darwin.read(fd, baseAddress.advanced(by: total), magic.count - total)
                if result > 0 {
                    total += result
                } else if result == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return total
        }

        return bytesRead == magic.count && Data(header) == magic
    }

    private static func sameFileLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL == rhs.standardizedFileURL {
            return true
        }
        return canonicalFileURL(lhs) == canonicalFileURL(rhs)
    }

    static func canonicalFileURL(_ fileURL: URL) -> URL {
        var st = stat()
        if Darwin.lstat(fileURL.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK {
            return fileURL.resolvingSymlinksInPath().standardizedFileURL
        }
        return canonicalDirectoryURL(fileURL.deletingLastPathComponent())
            .appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
            .standardizedFileURL
    }

    static func resolvedFilePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        var st = stat()
        if stat(url.path, &st) == 0 {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonicalDirectoryURL(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
            .standardizedFileURL
            .path
    }

    static func canonicalDirectoryURL(_ directoryURL: URL) -> URL {
        let standardized = directoryURL.standardizedFileURL
        if standardized.path == "/" || standardized.path.isEmpty {
            return standardized
        }
        var st = stat()
        if stat(standardized.path, &st) == 0 {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = canonicalDirectoryURL(standardized.deletingLastPathComponent())
        return parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true).standardizedFileURL
    }

    private static func regularFileExistsRejectingSymlinks(at url: URL) throws -> Bool {
        var linkStat = stat()
        if Darwin.lstat(url.path, &linkStat) != 0 {
            let err = errno
            if err == ENOENT {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.authenticationFailed
        }
        return true
    }

    private static func readNonSymlinkRegularFileData(at url: URL) throws -> Data {
        var linkStat = stat()
        if Darwin.lstat(url.path, &linkStat) != 0 {
            let err = errno
            if err == ENOENT {
                throw CocoaError(
                    .fileReadNoSuchFile,
                    userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url]
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.authenticationFailed
        }

        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            let err = errno
            if err == ELOOP {
                throw HistoryStoreError.authenticationFailed
            }
            if err == ENOENT {
                throw CocoaError(
                    .fileReadNoSuchFile,
                    userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url]
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.authenticationFailed
        }

        let expectedSize = max(0, Int(clamping: fileStat.st_size))
        var data = Data()
        data.reserveCapacity(expectedSize)

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

    static func fullFsyncBatch<S: Sequence>(_ urls: S) where S.Element == URL {
        var barrierURLByDevice: [dev_t: URL] = [:]
        for url in urls {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                continue
            }
            var fileStat = stat()
            if Darwin.fstat(fd, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG {
                // Push each file's dirty UBC pages to the device before issuing per-device hardware cache barriers.
                _ = Darwin.fsync(fd)
                if barrierURLByDevice[fileStat.st_dev] == nil {
                    barrierURLByDevice[fileStat.st_dev] = url
                }
            }
            _ = Darwin.close(fd)
        }
        issueFullFsyncDeviceBarriers(barrierURLByDevice.values)
    }

    private static func issueFullFsyncDeviceBarriers<S: Sequence>(_ barrierURLs: S) where S.Element == URL {
        for url in barrierURLs {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                continue
            }
            if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
                _ = Darwin.fsync(fd)
            }
            _ = Darwin.close(fd)
        }
    }

    private static func writeAtomically(
        _ data: Data,
        to destinationURL: URL,
        in directoryURL: URL,
        sync: Bool
    ) throws {
        let tempFileName = ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)"
        let tempURL = directoryURL.appendingPathComponent(tempFileName, isDirectory: false)
        try writeExclusivePrivateFile(data, to: tempURL, sync: sync, mapELOOPToAuthFailed: true)
        guard Darwin.rename(tempURL.path, destinationURL.path) == 0 else {
            let err = errno
            secureUnlink(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
