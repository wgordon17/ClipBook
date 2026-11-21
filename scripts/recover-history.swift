#!/usr/bin/env swift

import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

private enum ExitStatus {
    static let success: Int32 = 0
    static let fatalError: Int32 = 1
    static let partialRecovery: Int32 = 2
    static let keyOrPassphraseMismatch: Int32 = 3
}

private enum RecoveryFailure: Error {
    case usage(String)
    case fatal(String)
    case keyOrPassphraseMismatch(String)
}

private enum RowCorruptionError: Error {
    case columnAuthenticationFailed(String)
    case columnMalformed(String)
    case assetInvalidOrMissing(String)
}

private enum AssetRole: String {
    case image = "image"
    case linkPreview = "link-preview"
    case linkFavicon = "link-favicon"

    var managedSubdirectory: String {
        switch self {
        case .image:
            return "Images"
        case .linkPreview, .linkFavicon:
            return "LinkPreviews"
        }
    }

    var archiveSubdirectory: String {
        switch self {
        case .image:
            return "images"
        case .linkPreview, .linkFavicon:
            return "link-previews"
        }
    }
}

private struct DerivedStoreKeys {
    static let hkdfSalt = Data("com.ikryanov.clipbook.v2.hkdf.v1".utf8)

    let dbColumnAEADKey: SymmetricKey
    let assetFileAEADKey: SymmetricKey
    let keyVerifierHMACKey: SymmetricKey

    init(masterKey: SymmetricKey) {
        self.dbColumnAEADKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Self.hkdfSalt,
            info: Data("clipbook.db.column.aes256gcm.v1".utf8),
            outputByteCount: 32
        )
        self.assetFileAEADKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Self.hkdfSalt,
            info: Data("clipbook.fs.asset.aes256gcm.v1".utf8),
            outputByteCount: 32
        )
        self.keyVerifierHMACKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Self.hkdfSalt,
            info: Data("clipbook.db.keyverifier.hmacsha256.v1".utf8),
            outputByteCount: 32
        )
    }
}

private struct DerivedArchiveKeys {
    let aeadKey: SymmetricKey
    let verifierHMACKey: SymmetricKey
}

// MARK: - Wire Codable Types (matching ClipBookArchiveService.swift)

private struct ClipBookArchiveEncryptionMetadata: Codable {
    var archiveID: UUID
    var kdf: String = "PBKDF2-HMAC-SHA256"
    var algorithm: String = "AES-256-GCM"
    var iterations: Int
    var saltBase64: String
    var keyVerifierBase64: String
}

private struct ClipBookArchiveManifest: Codable {
    var formatVersion: Int
    var appName: String
    var appVersion: String?
    var exportedAt: Date
    var encryption: ClipBookArchiveEncryptionMetadata? = nil
}

private struct ClipBookArchiveTag: Codable {
    var id: String
    var name: String
    var color: String
}

private struct ClipBookArchiveLinkPreviewDetails: Codable {
    var url: String
    var title: String?
    var description: String?
    var imagePath: String?
    var faviconPath: String?
    var fetchedAt: Date
    var imageExtension: String? = nil
    var faviconExtension: String? = nil
}

private struct ClipBookArchiveItem: Codable {
    var id: UUID
    var kind: String
    var title: String?
    var text: String?
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
    var favoriteOrder: Int?
    var tagOrders: [String: Int]?
    var sensitivity: String?
}

private struct ClipBookEncryptedHistoryPayload: Codable {
    var items: [ClipBookArchiveItem]
    var expectedAssets: [String: String]
}

private struct StoredLinkPreviewDetails: Decodable {
    var url: String
    var title: String?
    var description: String?
    var imagePath: String?
    var faviconPath: String?
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case url
        case title
        case description
        case imagePath
        case faviconPath
        case fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        self.faviconPath = try container.decodeIfPresent(String.self, forKey: .faviconPath)

        if let dateString = try? container.decode(String.self, forKey: .fetchedAt) {
            if let parsed = RecoveryCryptoAndIO.parseISO8601Date(dateString) {
                self.fetchedAt = parsed
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fetchedAt,
                    in: container,
                    debugDescription: "Invalid ISO-8601 date string in LinkPreviewDetails"
                )
            }
        } else {
            self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        }
    }
}

// MARK: - Signal-Safe TTY Echo Restoration State

private var activeTTYFD: Int32 = -1
private var savedTTYTermios = termios()
private var hasSavedTTYTermios: sig_atomic_t = 0

private let ttySignalRestoreHandler: @convention(c) (Int32) -> Void = { sig in
    if hasSavedTTYTermios != 0, activeTTYFD >= 0 {
        var restored = savedTTYTermios
        _ = tcsetattr(activeTTYFD, TCSANOW, &restored)
        var newline: UInt8 = 0x0A
        _ = Darwin.write(activeTTYFD, &newline, 1)
    }
    _exit(128 + sig)
}

// MARK: - Cryptographic & Filesystem Primitives

private enum RecoveryCryptoAndIO {
    static let keychainService = "com.ikryanov.clipbook.v2.encryption"
    static let keychainAccount = "master-key-v1"

    static let columnFormatVersion: UInt8 = 0x01
    static let aadFormatVersion: UInt8 = 0x01
    static let archiveFormatVersion: UInt8 = 0x02
    static let minimumSealedColumnLength = 29

    static let assetEncryptedMagic = Data("CBENC01\0".utf8)
    static let minimumEncryptedAssetLength = 36

    static let archiveEntryMagic = Data("CBARC02\0".utf8)
    static let minimumSealedArchiveEntryLength = 36

    static let storeKeyVerifierContext = Data("clipbook-key-verifier-v1".utf8)
    static let archiveKeyVerifierPrefix = "clipbook-archive-v2-verifier\0"

    static let minimumProductionKDFIterations = 100_000
    static let minimumTestKDFIterations = 1_000
    static let maximumKDFIterations = 10_000_000
    static let archiveSaltByteCount = 32
    static let archiveDerivedKeyByteCount = 32
    static let archiveAEADHKDFInfo = Data("clipbook.archive.aes256gcm.v2".utf8)
    static let archiveKeyVerifierHKDFInfo = Data("clipbook.archive.keyverifier.hmacsha256.v2".utf8)

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

    static func parseISO8601Date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    static func zeroBytes(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { rawBuffer in
            if let base = rawBuffer.baseAddress, rawBuffer.count > 0 {
                _ = memset_s(base, rawBuffer.count, 0, rawBuffer.count)
            }
        }
    }

    static func zeroData(_ data: inout Data) {
        let count = data.count
        guard count > 0 else { return }
        data.withUnsafeMutableBytes { rawBuffer in
            if let base = rawBuffer.baseAddress {
                _ = memset_s(base, count, 0, count)
            }
        }
    }

    static func decodeMasterKeyFromRawInput(_ rawBytes: inout [UInt8], sourceLabel: String) throws -> SymmetricKey {
        defer {
            zeroBytes(&rawBytes)
        }

        // Trim leading/trailing ASCII whitespace and newlines without leaving unzeroed String copies if invalid.
        var start = 0
        var end = rawBytes.count
        while start < end, isASCIIWhitespace(rawBytes[start]) {
            start += 1
        }
        while end > start, isASCIIWhitespace(rawBytes[end - 1]) {
            end -= 1
        }

        guard (end - start) == 64 else {
            throw RecoveryFailure.fatal(
                "Invalid master key in \(sourceLabel): expected 64 lowercase hexadecimal characters."
            )
        }

        var decoded = [UInt8](repeating: 0, count: 32)
        defer {
            zeroBytes(&decoded)
        }

        for i in 0..<32 {
            guard let high = lowercaseHexNibble(rawBytes[start + (i * 2)]),
                  let low = lowercaseHexNibble(rawBytes[start + (i * 2) + 1]) else {
                throw RecoveryFailure.fatal(
                    "Invalid master key in \(sourceLabel): expected strict lowercase hexadecimal (^[0-9a-f]{64}$)."
                )
            }
            decoded[i] = (high << 4) | low
        }

        return decoded.withUnsafeBytes { SymmetricKey(data: $0) }
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    private static func lowercaseHexNibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39:
            return ascii - 0x30
        case 0x61...0x66:
            return ascii - 0x61 + 10
        default:
            return nil
        }
    }

    static func columnAAD(table: String, column: String, clipID: UUID) -> Data {
        let tableUTF8 = Data(table.utf8)
        let columnUTF8 = Data(column.utf8)
        var aad = Data(capacity: 1 + 1 + tableUTF8.count + 1 + columnUTF8.count + 16)
        aad.append(aadFormatVersion)
        aad.append(UInt8(tableUTF8.count))
        aad.append(tableUTF8)
        aad.append(UInt8(columnUTF8.count))
        aad.append(columnUTF8)
        let uuidTuple = clipID.uuid
        withUnsafeBytes(of: uuidTuple) { uuidBytes in
            aad.append(contentsOf: uuidBytes)
        }
        return aad
    }

    static func assetAAD(role: AssetRole, clipID: UUID) -> Data {
        let roleUTF8 = Data(role.rawValue.utf8)
        var aad = Data(capacity: 1 + 1 + roleUTF8.count + 16)
        aad.append(aadFormatVersion)
        aad.append(UInt8(roleUTF8.count))
        aad.append(roleUTF8)
        let uuidTuple = clipID.uuid
        withUnsafeBytes(of: uuidTuple) { uuidBytes in
            aad.append(contentsOf: uuidBytes)
        }
        return aad
    }

    static func openColumn(
        _ blob: Data,
        table: String,
        column: String,
        clipID: UUID,
        keys: DerivedStoreKeys
    ) throws -> Data {
        guard blob.count >= minimumSealedColumnLength,
              blob.first == columnFormatVersion else {
            throw RowCorruptionError.columnAuthenticationFailed("\(table).\(column)")
        }
        let aad = columnAAD(table: table, column: column, clipID: clipID)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(blob.dropFirst()))
            return try AES.GCM.open(sealedBox, using: keys.dbColumnAEADKey, authenticating: aad)
        } catch {
            throw RowCorruptionError.columnAuthenticationFailed("\(table).\(column)")
        }
    }

    static func openEncryptedAsset(
        _ rawData: Data,
        role: AssetRole,
        clipID: UUID,
        keys: DerivedStoreKeys
    ) throws -> Data {
        guard rawData.count >= minimumEncryptedAssetLength,
              rawData.prefix(assetEncryptedMagic.count) == assetEncryptedMagic else {
            throw RowCorruptionError.assetInvalidOrMissing(role.rawValue)
        }
        let aad = assetAAD(role: role, clipID: clipID)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(rawData.dropFirst(assetEncryptedMagic.count)))
            return try AES.GCM.open(sealedBox, using: keys.assetFileAEADKey, authenticating: aad)
        } catch {
            throw RowCorruptionError.assetInvalidOrMissing(role.rawValue)
        }
    }

    static func verifyStoreKeyVerifier(_ verifier: Data, keys: DerivedStoreKeys) -> Bool {
        guard verifier.count == SHA256.byteCount else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            verifier,
            authenticating: storeKeyVerifierContext,
            using: keys.keyVerifierHMACKey
        )
    }

    static func deriveArchiveKeys(
        nfcPassphrase: String,
        salt: Data,
        iterations: Int,
        archiveID: UUID,
        allowTestIterations: Bool
    ) throws -> DerivedArchiveKeys {
        let minIterations = allowTestIterations ? minimumTestKDFIterations : minimumProductionKDFIterations
        guard !nfcPassphrase.isEmpty,
              salt.count == archiveSaltByteCount,
              (minIterations...maximumKDFIterations).contains(iterations) else {
            throw RecoveryFailure.fatal("Invalid or unsupported archive encryption parameters.")
        }

        var nfcCString = nfcPassphrase.utf8CString
        defer {
            nfcCString.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress, buffer.count > 0 {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
        }

        var derivedBytes = [UInt8](repeating: 0, count: archiveDerivedKeyByteCount)
        defer {
            zeroBytes(&derivedBytes)
        }

        let kdfStatus: Int32 = nfcCString.withUnsafeBufferPointer { passwordBuffer in
            let passwordLength = max(0, passwordBuffer.count - 1)
            return salt.withUnsafeBytes { saltRawBuffer in
                let saltPtr = saltRawBuffer.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress,
                    passwordLength,
                    saltPtr,
                    saltRawBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedBytes,
                    archiveDerivedKeyByteCount
                )
            }
        }

        guard kdfStatus == kCCSuccess else {
            throw RecoveryFailure.fatal("PBKDF2 key derivation failed (status \(kdfStatus)).")
        }

        let archiveMasterKey = derivedBytes.withUnsafeBytes { SymmetricKey(data: $0) }
        let hkdfSalt = Data(archiveID.uuidString.lowercased().utf8)
        let aeadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: archiveMasterKey,
            salt: hkdfSalt,
            info: archiveAEADHKDFInfo,
            outputByteCount: 32
        )
        let verifierHMACKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: archiveMasterKey,
            salt: hkdfSalt,
            info: archiveKeyVerifierHKDFInfo,
            outputByteCount: 32
        )
        return DerivedArchiveKeys(aeadKey: aeadKey, verifierHMACKey: verifierHMACKey)
    }

    static func verifyArchiveKeyVerifier(
        _ verifier: Data,
        verifierKey: SymmetricKey,
        archiveID: UUID
    ) -> Bool {
        guard verifier.count == SHA256.byteCount else {
            return false
        }
        let context = Data((archiveKeyVerifierPrefix + archiveID.uuidString.lowercased()).utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            verifier,
            authenticating: context,
            using: verifierKey
        )
    }

    static func archiveEntryAAD(
        archiveID: UUID,
        manifestDigest: Data,
        relativePath: String
    ) throws -> Data {
        let pathUTF8 = Data(relativePath.utf8)
        guard manifestDigest.count == SHA256.byteCount,
              pathUTF8.count <= Int(UInt16.max) else {
            throw RecoveryFailure.fatal("Invalid archive entry AAD parameters for \(relativePath).")
        }

        var aad = Data(capacity: 1 + 16 + SHA256.byteCount + 2 + pathUTF8.count)
        aad.append(archiveFormatVersion)
        let uuidTuple = archiveID.uuid
        withUnsafeBytes(of: uuidTuple) { uuidBytes in
            aad.append(contentsOf: uuidBytes)
        }
        aad.append(manifestDigest)
        var pathLengthBE = UInt16(pathUTF8.count).bigEndian
        withUnsafeBytes(of: &pathLengthBE) { lengthBytes in
            aad.append(contentsOf: lengthBytes)
        }
        aad.append(pathUTF8)
        return aad
    }

    static func openArchiveEntry(
        _ blob: Data,
        key: SymmetricKey,
        archiveID: UUID,
        manifestDigest: Data,
        relativePath: String
    ) throws -> Data {
        let aad = try archiveEntryAAD(
            archiveID: archiveID,
            manifestDigest: manifestDigest,
            relativePath: relativePath
        )
        guard blob.count >= minimumSealedArchiveEntryLength,
              blob.prefix(archiveEntryMagic.count) == archiveEntryMagic else {
            throw RecoveryFailure.fatal("Encrypted archive entry is malformed or missing CBARC02 header: \(relativePath)")
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(archiveEntryMagic.count)))
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw RecoveryFailure.fatal("Encrypted archive entry failed authentication: \(relativePath)")
        }
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

    static func secureUnlink(at url: URL) {
        let path = url.path
        guard !path.isEmpty else { return }

        var linkStat = stat()
        guard Darwin.lstat(path, &linkStat) == 0 else { return }

        let mode = linkStat.st_mode & S_IFMT
        if mode == S_IFLNK {
            _ = Darwin.unlink(path)
            return
        }
        guard mode == S_IFREG else { return }

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
            if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
                _ = Darwin.fsync(fd)
            }
        }

        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
    }

    static func scrubAndRemoveDirectory(at directoryURL: URL) {
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries {
                var st = stat()
                if Darwin.lstat(entry.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    scrubAndRemoveDirectory(at: entry)
                } else {
                    secureUnlink(at: entry)
                }
            }
        }
        _ = Darwin.rmdir(directoryURL.path)
        var checkStat = stat()
        if Darwin.lstat(directoryURL.path, &checkStat) == 0 {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    static func readRegularFileBytesNoFollow(
        at url: URL,
        maxBytes: Int? = nil,
        label: String
    ) throws -> [UInt8] {
        let noSlashURL = URL(fileURLWithPath: url.path, isDirectory: false)
        if (try? noSlashURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecoveryFailure.fatal("Refusing to read symbolic link for \(label): \(url.path)")
        }

        var linkStat = stat()
        guard Darwin.lstat(noSlashURL.path, &linkStat) == 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to access \(label) (\(url.path)): \(String(cString: strerror(err)))")
        }
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryFailure.fatal("Expected regular file for \(label): \(url.path)")
        }

        let fd = Darwin.open(noSlashURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to open \(label) (\(url.path)): \(String(cString: strerror(err)))")
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryFailure.fatal("Expected regular file descriptor for \(label): \(url.path)")
        }

        if let maxBytes, fileStat.st_size > off_t(maxBytes) {
            throw RecoveryFailure.fatal("\(label) exceeds maximum expected size (\(maxBytes) bytes).")
        }

        return try readFDBytes(
            fd: fd,
            maxBytes: maxBytes,
            initialCapacity: max(0, Int(clamping: fileStat.st_size)),
            chunkSize: 64 * 1024,
            label: label
        )
    }

    static func readRegularFileDataNoFollow(at url: URL, label: String) throws -> Data {
        var bytes = try readRegularFileBytesNoFollow(at: url, label: label)
        defer {
            zeroBytes(&bytes)
        }
        return Data(bytes)
    }

    static func readFDBytes(
        fd: Int32,
        maxBytes: Int? = nil,
        initialCapacity: Int = 0,
        chunkSize: Int = 4096,
        label: String
    ) throws -> [UInt8] {
        var output: [UInt8] = []
        if initialCapacity > 0 {
            output.reserveCapacity(initialCapacity)
        }
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        defer {
            zeroBytes(&chunk)
        }

        do {
            try chunk.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while true {
                    let bytesRead = Darwin.read(fd, base, chunkSize)
                    if bytesRead > 0 {
                        if let maxBytes, output.count + bytesRead > maxBytes {
                            throw RecoveryFailure.fatal("\(label) exceeds maximum expected size (\(maxBytes) bytes).")
                        }
                        let ptr = base.assumingMemoryBound(to: UInt8.self)
                        output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: bytesRead))
                    } else if bytesRead == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        let err = errno
                        throw RecoveryFailure.fatal("Failed reading \(label): \(String(cString: strerror(err)))")
                    }
                }
            }
            return output
        } catch {
            zeroBytes(&output)
            throw error
        }
    }

    static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard Darwin.chmod(url.path, mode_t(0o700)) == 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Failed setting 0700 permissions on \(url.path): \(String(cString: strerror(err)))")
        }
    }

    static func writePrivateFile(_ data: Data, to destinationURL: URL, sync: Bool = false) throws {
        let fd = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to create file \(destinationURL.path): \(String(cString: strerror(err)))")
        }

        var fdOpen = true
        do {
            _ = Darwin.fchmod(fd, mode_t(0o600))
            try data.withUnsafeBytes { rawBuffer in
                guard rawBuffer.count > 0, let baseAddress = rawBuffer.baseAddress else { return }
                var writtenTotal = 0
                while writtenTotal < rawBuffer.count {
                    let result = Darwin.write(
                        fd,
                        baseAddress.advanced(by: writtenTotal),
                        rawBuffer.count - writtenTotal
                    )
                    if result > 0 {
                        writtenTotal += result
                    } else if result < 0 && errno == EINTR {
                        continue
                    } else {
                        let err = errno
                        throw RecoveryFailure.fatal("Failed writing \(destinationURL.path): \(String(cString: strerror(err)))")
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
                let err = errno
                throw RecoveryFailure.fatal("Failed closing \(destinationURL.path): \(String(cString: strerror(err)))")
            }
        } catch {
            if fdOpen {
                _ = Darwin.close(fd)
            }
            secureUnlink(at: destinationURL)
            throw error
        }
    }

    static func makeStagingRoot(appropriateFor destinationParent: URL, outputName: String) throws -> URL {
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
            ".\(outputName).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        try createPrivateDirectory(at: fallbackURL)
        return fallbackURL
    }

    struct StagedV1ArchiveLayout {
        let stagingRoot: URL
        let stagedArchiveURL: URL
        let stagedImagesDir: URL
        let stagedPreviewsDir: URL
    }

    static func prepareStagedV1ArchiveLayout(for outputDir: URL) throws -> StagedV1ArchiveLayout {
        let destinationParent = outputDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let stagingRoot = try makeStagingRoot(
            appropriateFor: destinationParent,
            outputName: outputDir.lastPathComponent
        )
        do {
            let stagedArchiveURL = stagingRoot.appendingPathComponent(outputDir.lastPathComponent, isDirectory: true)
            let assetsDirectory = stagedArchiveURL.appendingPathComponent("assets", isDirectory: true)
            let stagedImagesDir = assetsDirectory.appendingPathComponent("images", isDirectory: true)
            let stagedPreviewsDir = assetsDirectory.appendingPathComponent("link-previews", isDirectory: true)
            try createPrivateDirectory(at: stagedArchiveURL)
            try createPrivateDirectory(at: assetsDirectory)
            try createPrivateDirectory(at: stagedImagesDir)
            try createPrivateDirectory(at: stagedPreviewsDir)
            return StagedV1ArchiveLayout(
                stagingRoot: stagingRoot,
                stagedArchiveURL: stagedArchiveURL,
                stagedImagesDir: stagedImagesDir,
                stagedPreviewsDir: stagedPreviewsDir
            )
        } catch {
            scrubAndRemoveDirectory(at: stagingRoot)
            throw error
        }
    }

    struct DisambiguatedPlainAsset {
        let relativeArchivePath: String
        let writtenURL: URL
        let usedNameKey: String
    }

    static func writeDisambiguatedPlainAsset(
        _ plainData: Data,
        archiveSubdirectory: String,
        rawStem: String,
        defaultStem: String,
        fileExtension: String,
        destinationDir: URL,
        usedPlainFileNames: inout Set<String>
    ) throws -> DisambiguatedPlainAsset {
        let baseStem = rawStem.isEmpty ? defaultStem : rawStem
        var outputFileName = "\(baseStem).\(fileExtension)"
        var disambiguator = 1
        while usedPlainFileNames.contains("\(archiveSubdirectory)/\(outputFileName)".lowercased()) {
            outputFileName = "\(baseStem)-\(disambiguator).\(fileExtension)"
            disambiguator += 1
        }
        let destinationURL = destinationDir.appendingPathComponent(outputFileName, isDirectory: false)
        try writePrivateFile(plainData, to: destinationURL)
        let usedKey = "\(archiveSubdirectory)/\(outputFileName)".lowercased()
        usedPlainFileNames.insert(usedKey)
        return DisambiguatedPlainAsset(
            relativeArchivePath: "assets/\(archiveSubdirectory)/\(outputFileName)",
            writtenURL: destinationURL,
            usedNameKey: usedKey
        )
    }

    static func swapStagedOutput(at stagedOutputURL: URL, into outputDirURL: URL) throws {
        let outputNoSlash = URL(fileURLWithPath: outputDirURL.path, isDirectory: false)
        if (try? outputNoSlash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecoveryFailure.fatal("Refusing to overwrite symbolic link at output path: \(outputDirURL.path)")
        }
        var existingStat = stat()
        if Darwin.lstat(outputNoSlash.path, &existingStat) == 0 {
            if (existingStat.st_mode & S_IFMT) == S_IFLNK {
                throw RecoveryFailure.fatal("Refusing to overwrite symbolic link at output path: \(outputDirURL.path)")
            }
            _ = try FileManager.default.replaceItemAt(outputDirURL, withItemAt: stagedOutputURL)
        } else {
            try FileManager.default.moveItem(at: stagedOutputURL, to: outputDirURL)
        }
        _ = Darwin.chmod(outputDirURL.path, mode_t(0o700))
    }

    static func isValidLowercaseSHA256Hex(_ hex: String) -> Bool {
        guard hex.utf8.count == 64 else { return false }
        return hex.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func sha256LowercaseHexNoFollow(at url: URL, label: String) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to open \(label) for SHA-256 verification: \(String(cString: strerror(err)))")
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryFailure.fatal("Expected regular file for SHA-256 verification: \(label)")
        }

        var hasher = SHA256()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        defer {
            zeroBytes(&buffer)
        }

        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while true {
                let bytesRead = Darwin.read(fd, base, chunkSize)
                if bytesRead > 0 {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: bytesRead))
                } else if bytesRead == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    let err = errno
                    throw RecoveryFailure.fatal("Error reading \(label) for SHA-256: \(String(cString: strerror(err)))")
                }
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CLI Options Parser

private enum KeyInputSource {
    case auto
    case file(String)
    case stdinHex
}

private enum PassphraseInputSource {
    case interactiveTTY
    case file(String)
    case stdin
}

private enum RecoveryCommand {
    case help
    case supportDirectory(
        supportDir: URL,
        outputDir: URL,
        keySource: KeyInputSource,
        includeTrashed: Bool,
        strict: Bool
    )
    case archive(
        archiveURL: URL,
        outputDir: URL,
        passphraseSource: PassphraseInputSource,
        allowTestIterations: Bool
    )
}

private enum CLIParser {
    static let usageText = """
        Usage:
          recover-history.swift --support-dir <path> --output-dir <path> [options]
          recover-history.swift --archive <path.clipbookarchive> --output-dir <path> [options]

        Decrypts a local ClipBook v5 Application Support directory (Mode A) or a
        passphrase-encrypted v2 .clipbookarchive (Mode B) into a standard,
        Upstream-compatible formatVersion = 1 .clipbookarchive directory.

        Mode A Options (--support-dir):
          --support-dir <path>       ClipBook support directory containing History.sqlite
          --output-dir <path>        Destination directory for the recovered v1 archive
          --key-file <path>          Read 64-char lowercase hex master key from <path>
          --key-hex-stdin            Read 64-char lowercase hex master key from stdin
          --include-trashed          Also recover trashed items into trashed-history.json
          --strict                   Abort with exit 1 on any corrupt row or missing asset

          (When neither --key-file nor --key-hex-stdin is provided, Mode A checks
          <support-dir>/.devkey first and falls back to macOS login.keychain-db.)

        Mode B Options (--archive):
          --archive <path>           Path to a formatVersion = 2 .clipbookarchive
          --output-dir <path>        Destination directory for the decrypted v1 archive
          --passphrase-file <path>   Read archive passphrase from <path>
          --passphrase-stdin         Read archive passphrase from stdin
          --allow-test-iterations    Allow PBKDF2 iteration counts down to 1,000 (tests only)

          (When neither --passphrase-file nor --passphrase-stdin is provided, Mode B
          prompts interactively on /dev/tty with terminal echo disabled.)

        General Options:
          -h, --help                 Show this help message and exit 0

        Exit Codes:
          0  Clean recovery completed
          1  Invalid arguments, fatal I/O/schema/archive error, or --strict failure
          2  Mode A partial recovery completed (corrupted UUIDs written to corrupted-items.json)
          3  Master key or archive passphrase mismatch
        """

    static func parse(arguments: [String]) throws -> RecoveryCommand {
        if arguments.isEmpty {
            throw RecoveryFailure.usage("Missing required arguments.")
        }

        var supportDirPath: String?
        var archivePath: String?
        var outputDirPath: String?
        var keyFilePath: String?
        var keyHexStdin = false
        var includeTrashed = false
        var strict = false
        var passphraseFilePath: String?
        var passphraseStdin = false
        var allowTestIterations = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            let flagName: String
            let inlineValue: String?
            if arg.hasPrefix("--"), let eqIndex = arg.firstIndex(of: "=") {
                flagName = String(arg[..<eqIndex])
                inlineValue = String(arg[arg.index(after: eqIndex)...])
            } else {
                flagName = arg
                inlineValue = nil
            }

            switch flagName {
            case "-h", "--help":
                try rejectInlineValue(inlineValue, for: flagName)
                return .help
            case "--support-dir":
                supportDirPath = try resolveOptionValue(for: flagName, inlineValue: inlineValue, arguments: arguments, index: &index)
            case "--archive":
                archivePath = try resolveOptionValue(for: flagName, inlineValue: inlineValue, arguments: arguments, index: &index)
            case "--output-dir":
                outputDirPath = try resolveOptionValue(for: flagName, inlineValue: inlineValue, arguments: arguments, index: &index)
            case "--key-file":
                keyFilePath = try resolveOptionValue(for: flagName, inlineValue: inlineValue, arguments: arguments, index: &index)
            case "--key-hex-stdin":
                try rejectInlineValue(inlineValue, for: flagName)
                keyHexStdin = true
            case "--include-trashed":
                try rejectInlineValue(inlineValue, for: flagName)
                includeTrashed = true
            case "--strict":
                try rejectInlineValue(inlineValue, for: flagName)
                strict = true
            case "--passphrase-file":
                passphraseFilePath = try resolveOptionValue(for: flagName, inlineValue: inlineValue, arguments: arguments, index: &index)
            case "--passphrase-stdin":
                try rejectInlineValue(inlineValue, for: flagName)
                passphraseStdin = true
            case "--allow-test-iterations":
                try rejectInlineValue(inlineValue, for: flagName)
                allowTestIterations = true
            default:
                if flagName.hasPrefix("--key") || flagName.hasPrefix("--pass") {
                    throw RecoveryFailure.usage(
                        "Raw secrets are never accepted as CLI arguments (\(flagName)); use file or stdin flags."
                    )
                }
                if arg.hasPrefix("-") {
                    throw RecoveryFailure.usage("Unknown option: \(flagName)")
                } else {
                    throw RecoveryFailure.usage("Unexpected positional argument.")
                }
            }
            index += 1
        }

        if supportDirPath != nil && archivePath != nil {
            throw RecoveryFailure.usage("Specify either --support-dir or --archive, not both.")
        }
        guard supportDirPath != nil || archivePath != nil else {
            throw RecoveryFailure.usage("Either --support-dir or --archive is required.")
        }
        guard let outputDirPath, !outputDirPath.isEmpty else {
            throw RecoveryFailure.usage("--output-dir <path> is required.")
        }

        let outputURL = URL(fileURLWithPath: outputDirPath, isDirectory: true)

        if let supportDirPath {
            guard !supportDirPath.isEmpty else {
                throw RecoveryFailure.usage("--support-dir requires a non-empty path.")
            }
            if passphraseFilePath != nil || passphraseStdin || allowTestIterations {
                throw RecoveryFailure.usage("Archive passphrase flags cannot be combined with --support-dir.")
            }
            if keyFilePath != nil && keyHexStdin {
                throw RecoveryFailure.usage("Specify at most one of --key-file and --key-hex-stdin.")
            }

            let keySource: KeyInputSource
            if let keyFilePath {
                keySource = .file(keyFilePath)
            } else if keyHexStdin {
                keySource = .stdinHex
            } else {
                keySource = .auto
            }

            return .supportDirectory(
                supportDir: URL(fileURLWithPath: supportDirPath, isDirectory: true),
                outputDir: outputURL,
                keySource: keySource,
                includeTrashed: includeTrashed,
                strict: strict
            )
        }

        guard let archivePath, !archivePath.isEmpty else {
            throw RecoveryFailure.usage("--archive requires a non-empty path.")
        }
        if keyFilePath != nil || keyHexStdin || includeTrashed || strict {
            throw RecoveryFailure.usage("Mode A --support-dir flags cannot be combined with --archive.")
        }
        if passphraseFilePath != nil && passphraseStdin {
            throw RecoveryFailure.usage("Specify at most one of --passphrase-file and --passphrase-stdin.")
        }

        let passphraseSource: PassphraseInputSource
        if let passphraseFilePath {
            passphraseSource = .file(passphraseFilePath)
        } else if passphraseStdin {
            passphraseSource = .stdin
        } else {
            passphraseSource = .interactiveTTY
        }

        return .archive(
            archiveURL: URL(fileURLWithPath: archivePath, isDirectory: true),
            outputDir: outputURL,
            passphraseSource: passphraseSource,
            allowTestIterations: allowTestIterations
        )
    }

    private static func rejectInlineValue(_ inlineValue: String?, for flag: String) throws {
        if inlineValue != nil {
            throw RecoveryFailure.usage("Option \(flag) does not take a value.")
        }
    }

    private static func resolveOptionValue(
        for flag: String,
        inlineValue: String?,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        if let inlineValue {
            guard !inlineValue.isEmpty else {
                throw RecoveryFailure.usage("Option \(flag) requires a non-empty value.")
            }
            return inlineValue
        }
        return try requireValue(for: flag, arguments: arguments, index: &index)
    }

    private static func requireValue(for flag: String, arguments: [String], index: inout Int) throws -> String {
        let nextIndex = index + 1
        guard nextIndex < arguments.count else {
            throw RecoveryFailure.usage("Option \(flag) requires a value.")
        }
        let value = arguments[nextIndex]
        guard !value.isEmpty else {
            throw RecoveryFailure.usage("Option \(flag) requires a non-empty value.")
        }
        index = nextIndex
        return value
    }
}

// MARK: - Mode A: Local History.sqlite + Assets Recovery

private enum LocalStoreRecovery {
    private struct TagAttachment {
        var tagIDs: [Int64] = []
        var tagNames: [String] = []
        var tagOrders: [Int64: Int] = [:]
    }

    private typealias ResolvedRowAsset = RecoveryCryptoAndIO.DisambiguatedPlainAsset

    static func run(
        supportDir: URL,
        outputDir: URL,
        keySource: KeyInputSource,
        includeTrashed: Bool,
        strict: Bool
    ) throws -> Int32 {
        let supportNoSlash = URL(fileURLWithPath: supportDir.path, isDirectory: false)
        if (try? supportNoSlash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecoveryFailure.fatal("Refusing symbolic link for --support-dir: \(supportDir.path)")
        }
        var supportStat = stat()
        guard Darwin.lstat(supportNoSlash.path, &supportStat) == 0,
              (supportStat.st_mode & S_IFMT) == S_IFDIR else {
            throw RecoveryFailure.fatal("Support directory does not exist or is not a directory: \(supportDir.path)")
        }

        let sourceDBURL = supportDir.appendingPathComponent("History.sqlite", isDirectory: false)
        let sourceWALURL = supportDir.appendingPathComponent("History.sqlite-wal", isDirectory: false)
        let sourceJournalURL = supportDir.appendingPathComponent("History.sqlite-journal", isDirectory: false)

        let dbSize = try validateRegularSidecarOrDatabase(at: sourceDBURL, required: true, label: "History.sqlite") ?? 0
        guard dbSize > 0 else {
            throw RecoveryFailure.fatal("History.sqlite is empty: \(sourceDBURL.path)")
        }
        let walSize = try validateRegularSidecarOrDatabase(at: sourceWALURL, required: false, label: "History.sqlite-wal") ?? 0
        let journalSize = try validateRegularSidecarOrDatabase(at: sourceJournalURL, required: false, label: "History.sqlite-journal") ?? 0

        let masterKey = try resolveMasterKey(supportDir: supportDir, keySource: keySource)
        let keys = DerivedStoreKeys(masterKey: masterKey)

        // Copy History.sqlite (+ any non-empty -wal / -journal) into an ephemeral 0o700 directory
        // under FileManager.default.temporaryDirectory so <support-dir> files and mtime stay 100% untouched.
        let baseTempDir = FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: baseTempDir, withIntermediateDirectories: true)
        let probeDir = baseTempDir.appendingPathComponent("clipbook-recover-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(probeDir.path, mode_t(0o700)) == 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to create ephemeral WAL replay directory: \(String(cString: strerror(err)))")
        }
        _ = Darwin.chmod(probeDir.path, mode_t(0o700))

        var db: OpaquePointer?
        defer {
            if let openDB = db {
                _ = sqlite3_close_v2(openDB)
                db = nil
            }
            RecoveryCryptoAndIO.scrubAndRemoveDirectory(at: probeDir)
        }

        let copiedDBURL = probeDir.appendingPathComponent("History.sqlite", isDirectory: false)
        try copyRegularFile0600(from: sourceDBURL, to: copiedDBURL, allowMissingSource: false)

        if walSize > 0 {
            let copiedWALURL = probeDir.appendingPathComponent("History.sqlite-wal", isDirectory: false)
            let didCopyWAL = try copyRegularFile0600(from: sourceWALURL, to: copiedWALURL, allowMissingSource: true)
            if didCopyWAL {
                // Pre-pin BEFORE sqlite3_open_v2 so SQLite closing/checkpointing cannot drop the inode prior to zero-fill scrub.
                _ = Darwin.link(copiedWALURL.path, copiedWALURL.path + ".pin")
            } else {
                try copyRegularFile0600(from: sourceDBURL, to: copiedDBURL, allowMissingSource: false)
            }
        }

        if journalSize > 0 {
            let copiedJournalURL = probeDir.appendingPathComponent("History.sqlite-journal", isDirectory: false)
            let didCopyJournal = try copyRegularFile0600(from: sourceJournalURL, to: copiedJournalURL, allowMissingSource: true)
            if didCopyJournal {
                _ = Darwin.link(copiedJournalURL.path, copiedJournalURL.path + ".pin")
            } else {
                try copyRegularFile0600(from: sourceDBURL, to: copiedDBURL, allowMissingSource: false)
            }
        }

        let openRC = sqlite3_open_v2(copiedDBURL.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openRC == SQLITE_OK, let sqliteDB = db else {
            let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "code \(openRC)"
            throw RecoveryFailure.fatal("Failed opening copied History.sqlite: \(msg)")
        }

        try execSQL(
            sqliteDB,
            sql: """
                PRAGMA foreign_keys = ON;
                PRAGMA busy_timeout = 5000;
                PRAGMA trusted_schema = OFF;
                PRAGMA cell_size_check = ON;
                PRAGMA temp_store = MEMORY;
                PRAGMA secure_delete = ON;
                """
        )

        let userVersion = try querySingleInt(sqliteDB, sql: "PRAGMA user_version;")
        guard userVersion == 5 else {
            throw RecoveryFailure.fatal(
                "Unsupported History.sqlite schema version \(userVersion) (expected PRAGMA user_version = 5)."
            )
        }

        guard try tableExists(sqliteDB, name: "store_metadata") else {
            throw RecoveryFailure.fatal("History.sqlite is missing required v5 store_metadata table.")
        }

        guard let verifier = try queryKeyVerifier(sqliteDB),
              RecoveryCryptoAndIO.verifyStoreKeyVerifier(verifier, keys: keys) else {
            throw RecoveryFailure.keyOrPassphraseMismatch(
                "Encryption key mismatch: master key does not match store_metadata 'key_verifier_v1'."
            )
        }

        let archiveTags = try loadTags(sqliteDB)
        let tagAttachmentsByClipID = try loadTagAttachments(sqliteDB)

        let layout = try RecoveryCryptoAndIO.prepareStagedV1ArchiveLayout(for: outputDir)
        let stagingRoot = layout.stagingRoot
        let stagedArchiveURL = layout.stagedArchiveURL
        let stagedImagesDir = layout.stagedImagesDir
        let stagedPreviewsDir = layout.stagedPreviewsDir
        defer {
            RecoveryCryptoAndIO.scrubAndRemoveDirectory(at: stagingRoot)
        }

        let whereClause = includeTrashed ? "" : "WHERE c.deletedAt IS NULL"
        let clipsSQL = """
            SELECT
                c.id,
                c.kind,
                c.copiedAt,
                c.firstCopiedAt,
                c.deletedAt,
                c.copySequenceID,
                c.copySequenceOrder,
                c.byteSize,
                c.copyCount,
                c.isFavorite,
                c.favoriteOrder,
                c.sourceAppName,
                c.sourceBundleIdentifier,
                c.sensitivity,
                c.isEncrypted,
                c.title,
                c.textPreview,
                c.htmlDigest,
                c.imageDigest,
                c.assetPath,
                c.filePathsData,
                c.linkPreviewData,
                cc.text,
                cc.qrCodeText,
                cc.rtf,
                cc.html,
                cc.clipId
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            \(whereClause)
            ORDER BY c.copiedAt DESC
            """

        var clipsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(sqliteDB, clipsSQL, -1, &clipsStmt, nil) == SQLITE_OK,
              let stmt = clipsStmt else {
            let msg = String(cString: sqlite3_errmsg(sqliteDB))
            throw RecoveryFailure.fatal("Failed preparing clips query: \(msg)")
        }
        defer {
            sqlite3_finalize(stmt)
        }

        var fallbackContentsStmt: OpaquePointer?
        let fallbackSQL = """
            SELECT text, qrCodeText, rtf, html
            FROM clip_contents
            WHERE clipId = ?1 OR clipId = ?2 OR clipId = ?3
            LIMIT 1
            """
        guard sqlite3_prepare_v2(sqliteDB, fallbackSQL, -1, &fallbackContentsStmt, nil) == SQLITE_OK,
              let contentsLookupStmt = fallbackContentsStmt else {
            let msg = String(cString: sqlite3_errmsg(sqliteDB))
            throw RecoveryFailure.fatal("Failed preparing clip_contents lookup query: \(msg)")
        }
        defer {
            sqlite3_finalize(contentsLookupStmt)
        }

        let jsonDecoder = RecoveryCryptoAndIO.makeDecoder()
        var activeItems: [ClipBookArchiveItem] = []
        var trashedItems: [ClipBookArchiveItem] = []
        var corruptedItemIDs: [String] = []
        var corruptedItemIDSet: Set<String> = []
        var usedPlainFileNames: Set<String> = []

        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_DONE {
                break
            }
            guard stepRC == SQLITE_ROW else {
                let msg = String(cString: sqlite3_errmsg(sqliteDB))
                throw RecoveryFailure.fatal("Error stepping clips table: \(msg)")
            }

            try autoreleasepool {
                guard let clipID = decodeUUIDColumn(stmt, index: 0) else {
                    throw RecoveryFailure.fatal("Encountered malformed primary key in clips.id.")
                }

                var rowWrittenAssets: [ResolvedRowAsset] = []
                do {
                    let (archiveItem, isTrashed) = try recoverClipRow(
                        stmt: stmt,
                        contentsLookupStmt: contentsLookupStmt,
                        clipID: clipID,
                        attachment: tagAttachmentsByClipID[clipID] ?? TagAttachment(),
                        supportDir: supportDir,
                        stagedImagesDir: stagedImagesDir,
                        stagedPreviewsDir: stagedPreviewsDir,
                        keys: keys,
                        decoder: jsonDecoder,
                        usedPlainFileNames: &usedPlainFileNames,
                        rowWrittenAssets: &rowWrittenAssets
                    )
                    if isTrashed {
                        trashedItems.append(archiveItem)
                    } else {
                        activeItems.append(archiveItem)
                    }
                } catch let rowError as RowCorruptionError {
                    for written in rowWrittenAssets {
                        RecoveryCryptoAndIO.secureUnlink(at: written.writtenURL)
                        usedPlainFileNames.remove(written.usedNameKey)
                    }
                    if strict {
                        throw RecoveryFailure.fatal(
                            "Strict mode aborted on corrupt item \(clipID.uuidString.lowercased()): \(describeRowError(rowError))"
                        )
                    }
                    let lowerID = clipID.uuidString.lowercased()
                    if corruptedItemIDSet.insert(lowerID).inserted {
                        corruptedItemIDs.append(lowerID)
                    }
                }
            }
        }

        let encoder = RecoveryCryptoAndIO.makeEncoder()
        let manifest = ClipBookArchiveManifest(
            formatVersion: 1,
            appName: "ClipBook",
            appVersion: nil,
            exportedAt: Date(),
            encryption: nil
        )

        let hasCorruptedItems = !corruptedItemIDs.isEmpty
        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(manifest),
            to: stagedArchiveURL.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(archiveTags),
            to: stagedArchiveURL.appendingPathComponent("tags.json", isDirectory: false)
        )
        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(activeItems),
            to: stagedArchiveURL.appendingPathComponent("history.json", isDirectory: false),
            sync: !includeTrashed && !hasCorruptedItems
        )

        if includeTrashed {
            try RecoveryCryptoAndIO.writePrivateFile(
                try encoder.encode(trashedItems),
                to: stagedArchiveURL.appendingPathComponent("trashed-history.json", isDirectory: false),
                sync: !hasCorruptedItems
            )
        }

        if hasCorruptedItems {
            try RecoveryCryptoAndIO.writePrivateFile(
                try encoder.encode(corruptedItemIDs),
                to: stagedArchiveURL.appendingPathComponent("corrupted-items.json", isDirectory: false),
                sync: true
            )
        }

        // Close SQLite before swapping output so WAL replay directory cleanup runs with zero open handles.
        if let openDB = db {
            _ = sqlite3_close_v2(openDB)
            db = nil
        }

        try RecoveryCryptoAndIO.swapStagedOutput(at: stagedArchiveURL, into: outputDir)

        if !corruptedItemIDs.isEmpty {
            writeStderr(
                "Warning: Recovered \(activeItems.count) active item(s), omitted \(corruptedItemIDs.count) corrupted item(s) (see corrupted-items.json).\n"
            )
            return ExitStatus.partialRecovery
        }

        return ExitStatus.success
    }

    // MARK: - Mode A Row & Asset Helpers

    private static func recoverClipRow(
        stmt: OpaquePointer,
        contentsLookupStmt: OpaquePointer,
        clipID: UUID,
        attachment: TagAttachment,
        supportDir: URL,
        stagedImagesDir: URL,
        stagedPreviewsDir: URL,
        keys: DerivedStoreKeys,
        decoder: JSONDecoder,
        usedPlainFileNames: inout Set<String>,
        rowWrittenAssets: inout [ResolvedRowAsset]
    ) throws -> (item: ClipBookArchiveItem, isTrashed: Bool) {
        let kind = try decodePlainTextColumn(stmt, index: 1, columnName: "clips.kind") ?? "text"
        guard let copiedAt = try decodeTimestampColumn(stmt, index: 2, columnName: "clips.copiedAt") else {
            throw RowCorruptionError.columnMalformed("clips.copiedAt")
        }
        let firstCopiedAt = try decodeTimestampColumn(stmt, index: 3, columnName: "clips.firstCopiedAt") ?? copiedAt
        let deletedAt = try decodeTimestampColumn(stmt, index: 4, columnName: "clips.deletedAt")
        let copySequenceID = try decodeTimestampColumn(stmt, index: 5, columnName: "clips.copySequenceID")
        let copySequenceOrder = decodeOptionalIntColumn(stmt, index: 6)
        let byteSize = decodeOptionalIntColumn(stmt, index: 7) ?? 0
        let copyCount = decodeOptionalIntColumn(stmt, index: 8) ?? 0
        let isFavorite = (decodeOptionalIntColumn(stmt, index: 9) ?? 0) != 0
        let favoriteOrder = decodeOptionalIntColumn(stmt, index: 10)
        let sourceAppName = try decodePlainTextColumn(stmt, index: 11, columnName: "clips.sourceAppName")
        let sourceBundleIdentifier = try decodePlainTextColumn(stmt, index: 12, columnName: "clips.sourceBundleIdentifier")
        let sensitivity = try decodePlainTextColumn(stmt, index: 13, columnName: "clips.sensitivity")

        guard sqlite3_column_type(stmt, 14) == SQLITE_INTEGER else {
            throw RowCorruptionError.columnMalformed("clips.isEncrypted")
        }
        let isEncrypted = sqlite3_column_int64(stmt, 14) != 0

        // Decrypt / decode all 7 protected clips columns (enforcing non-downgrade SQLITE_BLOB + 0x01 AEAD).
        let title = try decodeProtectedStringColumn(
            stmt: stmt,
            index: 15,
            table: "clips",
            column: "title",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        _ = try decodeProtectedStringColumn(
            stmt: stmt,
            index: 16,
            table: "clips",
            column: "textPreview",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        _ = try decodeProtectedStringColumn(
            stmt: stmt,
            index: 17,
            table: "clips",
            column: "htmlDigest",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        _ = try decodeProtectedStringColumn(
            stmt: stmt,
            index: 18,
            table: "clips",
            column: "imageDigest",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let rawAssetPath = try decodeProtectedStringColumn(
            stmt: stmt,
            index: 19,
            table: "clips",
            column: "assetPath",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        if isEncrypted, let rawAssetPath, !hasEncryptedExtension(rawAssetPath) {
            throw RowCorruptionError.columnAuthenticationFailed("clips.assetPath downgrade")
        }

        guard let filePathsJSON = try decodeProtectedDataColumn(
            stmt: stmt,
            index: 20,
            table: "clips",
            column: "filePathsData",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            throw RowCorruptionError.columnMalformed("clips.filePathsData")
        }
        let filePaths: [String]
        do {
            filePaths = try decoder.decode([String].self, from: filePathsJSON)
        } catch {
            throw RowCorruptionError.columnMalformed("clips.filePathsData JSON")
        }

        let storedLinkPreview: StoredLinkPreviewDetails?
        if let linkPreviewJSON = try decodeProtectedDataColumn(
            stmt: stmt,
            index: 21,
            table: "clips",
            column: "linkPreviewData",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) {
            do {
                storedLinkPreview = try decoder.decode(StoredLinkPreviewDetails.self, from: linkPreviewJSON)
            } catch {
                throw RowCorruptionError.columnMalformed("clips.linkPreviewData JSON")
            }
            if isEncrypted, let storedLinkPreview {
                if let imgPath = storedLinkPreview.imagePath, !hasEncryptedExtension(imgPath) {
                    throw RowCorruptionError.columnAuthenticationFailed("clips.linkPreviewData.imagePath downgrade")
                }
                if let favPath = storedLinkPreview.faviconPath, !hasEncryptedExtension(favPath) {
                    throw RowCorruptionError.columnAuthenticationFailed("clips.linkPreviewData.faviconPath downgrade")
                }
            }
        } else {
            storedLinkPreview = nil
        }

        let text: String?
        let qrCodeText: String?
        let rtfData: Data?
        let html: String?

        if sqlite3_column_type(stmt, 26) != SQLITE_NULL {
            (text, qrCodeText, rtfData, html) = try decodeClipContentsColumns(
                stmt: stmt,
                baseIndex: 22,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
        } else {
            (text, qrCodeText, rtfData, html) = try lookupFallbackClipContents(
                stmt: contentsLookupStmt,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            )
        }

        // Resolve and authenticate referenced external assets by lastPathComponent under Images/ & LinkPreviews/.
        let resolvedMainAsset = try resolveAndStageModeAAsset(
            rawPath: rawAssetPath,
            role: .image,
            clipID: clipID,
            isEncryptedRow: isEncrypted,
            defaultStem: clipID.uuidString,
            supportDir: supportDir,
            destinationDir: stagedImagesDir,
            keys: keys,
            usedPlainFileNames: &usedPlainFileNames,
            rowWrittenAssets: &rowWrittenAssets
        )

        let archiveLinkPreview: ClipBookArchiveLinkPreviewDetails?
        if let storedLinkPreview {
            let resolvedPreviewImage = try resolveAndStageModeAAsset(
                rawPath: storedLinkPreview.imagePath,
                role: .linkPreview,
                clipID: clipID,
                isEncryptedRow: isEncrypted,
                defaultStem: "\(clipID.uuidString)-preview",
                supportDir: supportDir,
                destinationDir: stagedPreviewsDir,
                keys: keys,
                usedPlainFileNames: &usedPlainFileNames,
                rowWrittenAssets: &rowWrittenAssets
            )
            let resolvedFavicon = try resolveAndStageModeAAsset(
                rawPath: storedLinkPreview.faviconPath,
                role: .linkFavicon,
                clipID: clipID,
                isEncryptedRow: isEncrypted,
                defaultStem: "\(clipID.uuidString)-favicon",
                supportDir: supportDir,
                destinationDir: stagedPreviewsDir,
                keys: keys,
                usedPlainFileNames: &usedPlainFileNames,
                rowWrittenAssets: &rowWrittenAssets
            )
            archiveLinkPreview = ClipBookArchiveLinkPreviewDetails(
                url: storedLinkPreview.url,
                title: storedLinkPreview.title,
                description: storedLinkPreview.description,
                imagePath: resolvedPreviewImage?.relativeArchivePath,
                faviconPath: resolvedFavicon?.relativeArchivePath,
                fetchedAt: storedLinkPreview.fetchedAt,
                imageExtension: nil,
                faviconExtension: nil
            )
        } else {
            archiveLinkPreview = nil
        }

        let tagIDs = attachment.tagIDs.map(String.init)
        let tagOrders: [String: Int]? = attachment.tagOrders.isEmpty
            ? nil
            : Dictionary(uniqueKeysWithValues: attachment.tagOrders.map { (String($0.key), $0.value) })

        let archiveItem = ClipBookArchiveItem(
            id: clipID,
            kind: kind,
            title: title,
            text: text,
            qrCodeText: qrCodeText,
            rtfBase64: rtfData?.base64EncodedString(),
            html: html,
            assetPath: resolvedMainAsset?.relativeArchivePath,
            assetExtension: nil,
            filePaths: filePaths,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: byteSize,
            isFavorite: isFavorite,
            tagIDs: tagIDs,
            tagNames: attachment.tagNames,
            copyCount: copyCount,
            linkPreviewDetails: archiveLinkPreview,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            tagOrders: tagOrders,
            sensitivity: sensitivity
        )

        return (archiveItem, deletedAt != nil)
    }

    private static func lookupFallbackClipContents(
        stmt: OpaquePointer,
        clipID: UUID,
        isEncrypted: Bool,
        keys: DerivedStoreKeys
    ) throws -> (String?, String?, Data?, String?) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        let upper = clipID.uuidString
        let lower = upper.lowercased()
        let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = upper.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqlTransient) }
        _ = lower.withCString { sqlite3_bind_text(stmt, 2, $0, -1, sqlTransient) }
        let uuidTuple = clipID.uuid
        withUnsafeBytes(of: uuidTuple) { rawBuffer in
            _ = sqlite3_bind_blob(stmt, 3, rawBuffer.baseAddress, 16, sqlTransient)
        }

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            return (nil, nil, nil, nil)
        }
        guard rc == SQLITE_ROW else {
            throw RowCorruptionError.columnMalformed("clip_contents lookup")
        }

        return try decodeClipContentsColumns(
            stmt: stmt,
            baseIndex: 0,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
    }

    private static func decodeClipContentsColumns(
        stmt: OpaquePointer,
        baseIndex: Int32,
        clipID: UUID,
        isEncrypted: Bool,
        keys: DerivedStoreKeys
    ) throws -> (String?, String?, Data?, String?) {
        let text = try decodeProtectedStringColumn(
            stmt: stmt,
            index: baseIndex,
            table: "clip_contents",
            column: "text",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let qrCodeText = try decodeProtectedStringColumn(
            stmt: stmt,
            index: baseIndex + 1,
            table: "clip_contents",
            column: "qrCodeText",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let rtfData = try decodeProtectedDataColumn(
            stmt: stmt,
            index: baseIndex + 2,
            table: "clip_contents",
            column: "rtf",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let html = try decodeProtectedStringColumn(
            stmt: stmt,
            index: baseIndex + 3,
            table: "clip_contents",
            column: "html",
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
        return (text, qrCodeText, rtfData, html)
    }

    private static func resolveAndStageModeAAsset(
        rawPath: String?,
        role: AssetRole,
        clipID: UUID,
        isEncryptedRow: Bool,
        defaultStem: String,
        supportDir: URL,
        destinationDir: URL,
        keys: DerivedStoreKeys,
        usedPlainFileNames: inout Set<String>,
        rowWrittenAssets: inout [ResolvedRowAsset]
    ) throws -> ResolvedRowAsset? {
        guard let rawPath, !rawPath.isEmpty else {
            return nil
        }
        guard !rawPath.hasSuffix("/"), !rawPath.contains("\0") else {
            throw RowCorruptionError.assetInvalidOrMissing(rawPath)
        }
        if isEncryptedRow && !hasEncryptedExtension(rawPath) {
            throw RowCorruptionError.assetInvalidOrMissing("downgraded non-.enc path: \(rawPath)")
        }

        let fileName = (rawPath as NSString).lastPathComponent
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/") else {
            throw RowCorruptionError.assetInvalidOrMissing(rawPath)
        }

        let requiresEncryptedAsset = isEncryptedRow || hasEncryptedExtension(rawPath)

        let managedSubdirURL = supportDir.appendingPathComponent(role.managedSubdirectory, isDirectory: true)
        let managedSubdirNoSlash = URL(fileURLWithPath: managedSubdirURL.path, isDirectory: false)
        if (try? managedSubdirNoSlash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RowCorruptionError.assetInvalidOrMissing(managedSubdirURL.path)
        }
        var dirStat = stat()
        if Darwin.lstat(managedSubdirNoSlash.path, &dirStat) != 0 {
            if errno == ENOENT,
               !requiresEncryptedAsset,
               !FileManager.default.fileExists(atPath: managedSubdirNoSlash.path) {
                return nil
            }
            throw RowCorruptionError.assetInvalidOrMissing(managedSubdirURL.path)
        }
        guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            throw RowCorruptionError.assetInvalidOrMissing(managedSubdirURL.path)
        }

        let sourceURL = managedSubdirURL.appendingPathComponent(fileName, isDirectory: false)
        if (try? sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RowCorruptionError.assetInvalidOrMissing(sourceURL.path)
        }
        var fileStat = stat()
        if Darwin.lstat(sourceURL.path, &fileStat) != 0 {
            if errno == ENOENT,
               !requiresEncryptedAsset,
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                return nil
            }
            throw RowCorruptionError.assetInvalidOrMissing(sourceURL.path)
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw RowCorruptionError.assetInvalidOrMissing(sourceURL.path)
        }

        let canonicalExpectedDir = RecoveryCryptoAndIO.canonicalDirectoryURL(managedSubdirURL)
        let canonicalActualDir = RecoveryCryptoAndIO.canonicalDirectoryURL(sourceURL.deletingLastPathComponent())
        guard canonicalActualDir == canonicalExpectedDir,
              (try? sourceURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw RowCorruptionError.assetInvalidOrMissing(sourceURL.path)
        }

        let rawFileData: Data
        do {
            rawFileData = try RecoveryCryptoAndIO.readRegularFileDataNoFollow(at: sourceURL, label: sourceURL.lastPathComponent)
        } catch {
            throw RowCorruptionError.assetInvalidOrMissing(sourceURL.path)
        }

        let magicCount = RecoveryCryptoAndIO.assetEncryptedMagic.count
        let hasEncMagic = rawFileData.count >= magicCount
            && rawFileData.prefix(magicCount) == RecoveryCryptoAndIO.assetEncryptedMagic
        let hasEncExt = sourceURL.pathExtension.lowercased() == "enc"

        let plainData: Data
        let sanitizedExtension: String
        if isEncryptedRow || hasEncExt || hasEncMagic {
            plainData = try RecoveryCryptoAndIO.openEncryptedAsset(
                rawFileData,
                role: role,
                clipID: clipID,
                keys: keys
            )
            sanitizedExtension = RecoveryCryptoAndIO.plainAssetExtension(preferred: nil, magicBytes: plainData)
        } else {
            plainData = rawFileData
            sanitizedExtension = RecoveryCryptoAndIO.plainAssetExtension(
                preferred: sourceURL.pathExtension,
                magicBytes: plainData
            )
        }

        let resolved = try RecoveryCryptoAndIO.writeDisambiguatedPlainAsset(
            plainData,
            archiveSubdirectory: role.archiveSubdirectory,
            rawStem: sourceURL.deletingPathExtension().lastPathComponent,
            defaultStem: defaultStem,
            fileExtension: sanitizedExtension,
            destinationDir: destinationDir,
            usedPlainFileNames: &usedPlainFileNames
        )
        rowWrittenAssets.append(resolved)
        return resolved
    }

    private static func hasEncryptedExtension(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "enc"
    }

    private static func describeRowError(_ error: RowCorruptionError) -> String {
        switch error {
        case .columnAuthenticationFailed(let detail):
            return "authentication failed on \(detail)"
        case .columnMalformed(let detail):
            return "malformed data in \(detail)"
        case .assetInvalidOrMissing(let detail):
            return "missing or unauthenticated asset (\(detail))"
        }
    }

    // MARK: - Mode A Master Key Resolution

    private static func resolveMasterKey(supportDir: URL, keySource: KeyInputSource) throws -> SymmetricKey {
        switch keySource {
        case .file(let path):
            let keyURL = URL(fileURLWithPath: path, isDirectory: false)
            var bytes = try RecoveryCryptoAndIO.readRegularFileBytesNoFollow(
                at: keyURL,
                maxBytes: 4096,
                label: "--key-file"
            )
            return try RecoveryCryptoAndIO.decodeMasterKeyFromRawInput(&bytes, sourceLabel: "--key-file")

        case .stdinHex:
            var bytes = try RecoveryCryptoAndIO.readFDBytes(
                fd: STDIN_FILENO,
                maxBytes: 4096,
                label: "--key-hex-stdin"
            )
            return try RecoveryCryptoAndIO.decodeMasterKeyFromRawInput(&bytes, sourceLabel: "--key-hex-stdin")

        case .auto:
            let devKeyURL = supportDir.appendingPathComponent(".devkey", isDirectory: false)
            var devKeyStat = stat()
            if Darwin.lstat(devKeyURL.path, &devKeyStat) == 0 {
                var bytes = try RecoveryCryptoAndIO.readRegularFileBytesNoFollow(
                    at: devKeyURL,
                    maxBytes: 4096,
                    label: ".devkey"
                )
                return try RecoveryCryptoAndIO.decodeMasterKeyFromRawInput(&bytes, sourceLabel: ".devkey")
            } else if errno != ENOENT {
                let err = errno
                throw RecoveryFailure.fatal("Unable to inspect \(devKeyURL.path): \(String(cString: strerror(err)))")
            }

            return try readMasterKeyFromLoginKeychain()
        }
    }

    private static func readMasterKeyFromLoginKeychain() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RecoveryCryptoAndIO.keychainService,
            kSecAttrAccount as String: RecoveryCryptoAndIO.keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed {
                throw RecoveryFailure.fatal(
                    "Keychain returned errSecInteractionNotAllowed (-25308). In headless/SSH sessions, unlock login.keychain-db, update the item's partition list, and pipe `security find-generic-password -w` into --key-hex-stdin."
                )
            }
            throw RecoveryFailure.fatal(
                "Unable to read master key from login.keychain-db (OSStatus \(status))."
            )
        }

        guard var keyData = item as? Data else {
            throw RecoveryFailure.fatal("Keychain item returned unexpected non-Data payload.")
        }
        defer {
            RecoveryCryptoAndIO.zeroData(&keyData)
        }

        var rawBytes = Array(keyData)
        return try RecoveryCryptoAndIO.decodeMasterKeyFromRawInput(&rawBytes, sourceLabel: "login.keychain-db")
    }

    // MARK: - Mode A SQLite Helpers

    private static func validateRegularSidecarOrDatabase(at url: URL, required: Bool, label: String) throws -> Int64? {
        let noSlash = URL(fileURLWithPath: url.path, isDirectory: false)
        if (try? noSlash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecoveryFailure.fatal("Refusing symbolic link for \(label): \(url.path)")
        }

        var st = stat()
        guard Darwin.lstat(noSlash.path, &st) == 0 else {
            let err = errno
            if !required && err == ENOENT {
                return nil
            }
            throw RecoveryFailure.fatal("Missing or inaccessible \(label) (\(url.path)): \(String(cString: strerror(err)))")
        }

        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryFailure.fatal("Expected regular file for \(label): \(url.path)")
        }
        return Int64(st.st_size)
    }

    @discardableResult
    private static func copyRegularFile0600(
        from sourceURL: URL,
        to destinationURL: URL,
        allowMissingSource: Bool
    ) throws -> Bool {
        let inFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard inFD >= 0 else {
            let err = errno
            if allowMissingSource && err == ENOENT {
                return false
            }
            throw RecoveryFailure.fatal("Unable to open \(sourceURL.path): \(String(cString: strerror(err)))")
        }
        defer {
            _ = Darwin.close(inFD)
        }

        var inStat = stat()
        guard Darwin.fstat(inFD, &inStat) == 0,
              (inStat.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryFailure.fatal("Expected regular file at \(sourceURL.path)")
        }

        let outFD = Darwin.open(destinationURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        guard outFD >= 0 else {
            let err = errno
            throw RecoveryFailure.fatal("Unable to create temp copy \(destinationURL.path): \(String(cString: strerror(err)))")
        }
        _ = Darwin.fchmod(outFD, mode_t(0o600))

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        defer {
            RecoveryCryptoAndIO.zeroBytes(&buffer)
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
                                let err = errno
                                throw RecoveryFailure.fatal("Failed writing temp copy: \(String(cString: strerror(err)))")
                            }
                        }
                    } else if bytesRead == 0 {
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        let err = errno
                        throw RecoveryFailure.fatal("Failed reading \(sourceURL.path): \(String(cString: strerror(err)))")
                    }
                }
            }
            _ = Darwin.close(outFD)
            return true
        } catch {
            _ = Darwin.close(outFD)
            RecoveryCryptoAndIO.secureUnlink(at: destinationURL)
            throw error
        }
    }

    private static func execSQL(_ db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            if let errMsg {
                sqlite3_free(errMsg)
            }
            throw RecoveryFailure.fatal("SQLite execution failed: \(detail)")
        }
    }

    private static func querySingleInt(_ db: OpaquePointer, sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw RecoveryFailure.fatal("Failed preparing SQL (\(sql)): \(String(cString: sqlite3_errmsg(db)))")
        }
        defer {
            sqlite3_finalize(prepared)
        }
        guard sqlite3_step(prepared) == SQLITE_ROW else {
            throw RecoveryFailure.fatal("Expected single integer result for SQL: \(sql)")
        }
        return Int(sqlite3_column_int64(prepared, 0))
    }

    private static func tableExists(_ db: OpaquePointer, name: String) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw RecoveryFailure.fatal("Failed querying sqlite_master: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer {
            sqlite3_finalize(prepared)
        }
        let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = name.withCString { sqlite3_bind_text(prepared, 1, $0, -1, sqlTransient) }
        return sqlite3_step(prepared) == SQLITE_ROW
    }

    private static func queryKeyVerifier(_ db: OpaquePointer) throws -> Data? {
        let sql = "SELECT value FROM store_metadata WHERE key = 'key_verifier_v1' LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw RecoveryFailure.fatal("Failed querying store_metadata: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer {
            sqlite3_finalize(prepared)
        }
        let rc = sqlite3_step(prepared)
        if rc == SQLITE_DONE {
            return nil
        }
        guard rc == SQLITE_ROW else {
            throw RecoveryFailure.fatal("Failed reading store_metadata: \(String(cString: sqlite3_errmsg(db)))")
        }
        guard sqlite3_column_type(prepared, 0) == SQLITE_BLOB else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(prepared, 0))
        guard count > 0, let ptr = sqlite3_column_blob(prepared, 0) else {
            return Data()
        }
        return Data(bytes: ptr, count: count)
    }

    private static func loadTags(_ db: OpaquePointer) throws -> [ClipBookArchiveTag] {
        guard try tableExists(db, name: "tags") else {
            return []
        }
        let sql = "SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE ASC, id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw RecoveryFailure.fatal("Failed preparing tags query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer {
            sqlite3_finalize(prepared)
        }

        var tags: [ClipBookArchiveTag] = []
        while true {
            let rc = sqlite3_step(prepared)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw RecoveryFailure.fatal("Error stepping tags table: \(String(cString: sqlite3_errmsg(db)))")
            }
            let id = sqlite3_column_int64(prepared, 0)
            guard let name = try? decodePlainTextColumn(prepared, index: 1, columnName: "tags.name"),
                  let color = try? decodePlainTextColumn(prepared, index: 2, columnName: "tags.color") else {
                throw RecoveryFailure.fatal("Malformed row in tags table.")
            }
            tags.append(ClipBookArchiveTag(id: String(id), name: name, color: color))
        }
        return tags
    }

    private static func loadTagAttachments(_ db: OpaquePointer) throws -> [UUID: TagAttachment] {
        guard try tableExists(db, name: "clip_tags"), try tableExists(db, name: "tags") else {
            return [:]
        }
        let sql = """
            SELECT ct.clipId, ct.tagId, ct.sortOrder, t.name
            FROM clip_tags ct
            JOIN tags t ON t.id = ct.tagId
            ORDER BY t.name COLLATE NOCASE ASC, t.id ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw RecoveryFailure.fatal("Failed preparing clip_tags query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer {
            sqlite3_finalize(prepared)
        }

        var attachments: [UUID: TagAttachment] = [:]
        while true {
            let rc = sqlite3_step(prepared)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw RecoveryFailure.fatal("Error stepping clip_tags table: \(String(cString: sqlite3_errmsg(db)))")
            }
            guard let clipID = decodeUUIDColumn(prepared, index: 0),
                  let tagName = try? decodePlainTextColumn(prepared, index: 3, columnName: "tags.name") else {
                continue
            }
            let tagID = sqlite3_column_int64(prepared, 1)
            let sortOrder = decodeOptionalIntColumn(prepared, index: 2)
            var entry = attachments[clipID] ?? TagAttachment()
            entry.tagIDs.append(tagID)
            entry.tagNames.append(tagName)
            if let sortOrder {
                entry.tagOrders[tagID] = sortOrder
            }
            attachments[clipID] = entry
        }
        return attachments
    }

    private static func decodeUUIDColumn(_ stmt: OpaquePointer, index: Int32) -> UUID? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            guard byteCount > 0, let rawPtr = sqlite3_column_text(stmt, index) else {
                return nil
            }
            let data = Data(bytes: rawPtr, count: byteCount)
            guard let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return UUID(uuidString: str)

        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            guard byteCount == 16, let blobPtr = sqlite3_column_blob(stmt, index) else {
                return nil
            }
            var rawUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &rawUUID) { dest in
                if let destBase = dest.baseAddress {
                    memcpy(destBase, blobPtr, 16)
                }
            }
            return UUID(uuid: rawUUID)

        default:
            return nil
        }
    }

    private static func decodeTimestampColumn(
        _ stmt: OpaquePointer,
        index: Int32,
        columnName: String
    ) throws -> Date? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_FLOAT, SQLITE_INTEGER:
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            guard let text = try decodePlainTextColumn(stmt, index: index, columnName: columnName) else {
                return nil
            }
            if let parsedISO = RecoveryCryptoAndIO.parseISO8601Date(text) {
                return parsedISO
            }
            if let numeric = Double(text) {
                return Date(timeIntervalSince1970: numeric)
            }
            throw RowCorruptionError.columnMalformed(columnName)
        default:
            throw RowCorruptionError.columnMalformed(columnName)
        }
    }

    private static func decodeOptionalIntColumn(_ stmt: OpaquePointer, index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private static func decodePlainTextColumn(
        _ stmt: OpaquePointer,
        index: Int32,
        columnName: String
    ) throws -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_TEXT:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            if byteCount == 0 {
                return ""
            }
            guard let rawPtr = sqlite3_column_text(stmt, index),
                  let str = String(data: Data(bytes: rawPtr, count: byteCount), encoding: .utf8) else {
                throw RowCorruptionError.columnMalformed(columnName)
            }
            return str
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            if byteCount == 0 {
                return ""
            }
            guard let blobPtr = sqlite3_column_blob(stmt, index),
                  let str = String(data: Data(bytes: blobPtr, count: byteCount), encoding: .utf8) else {
                throw RowCorruptionError.columnMalformed(columnName)
            }
            return str
        default:
            throw RowCorruptionError.columnMalformed(columnName)
        }
    }

    private static func decodeProtectedDataColumn(
        stmt: OpaquePointer,
        index: Int32,
        table: String,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: DerivedStoreKeys
    ) throws -> Data? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            let rawBlob: Data
            if byteCount == 0 {
                rawBlob = Data()
            } else if let ptr = sqlite3_column_blob(stmt, index) {
                rawBlob = Data(bytes: ptr, count: byteCount)
            } else {
                throw RowCorruptionError.columnMalformed("\(table).\(column)")
            }
            if isEncrypted {
                return try RecoveryCryptoAndIO.openColumn(
                    rawBlob,
                    table: table,
                    column: column,
                    clipID: clipID,
                    keys: keys
                )
            }
            return rawBlob
        case SQLITE_TEXT:
            if isEncrypted {
                throw RowCorruptionError.columnAuthenticationFailed("\(table).\(column) TEXT downgrade")
            }
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            if byteCount == 0 {
                return Data()
            }
            guard let ptr = sqlite3_column_text(stmt, index) else {
                throw RowCorruptionError.columnMalformed("\(table).\(column)")
            }
            return Data(bytes: ptr, count: byteCount)
        default:
            throw RowCorruptionError.columnAuthenticationFailed("\(table).\(column) storage type")
        }
    }

    private static func decodeProtectedStringColumn(
        stmt: OpaquePointer,
        index: Int32,
        table: String,
        column: String,
        clipID: UUID,
        isEncrypted: Bool,
        keys: DerivedStoreKeys
    ) throws -> String? {
        guard let data = try decodeProtectedDataColumn(
            stmt: stmt,
            index: index,
            table: table,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw RowCorruptionError.columnMalformed("\(table).\(column) UTF-8")
        }
        return string
    }
}

// MARK: - Mode B: Passphrase-Encrypted v2 .clipbookarchive Recovery

private enum EncryptedArchiveRecovery {
    static func run(
        archiveURL: URL,
        outputDir: URL,
        passphraseSource: PassphraseInputSource,
        allowTestIterations: Bool
    ) throws -> Int32 {
        let archiveNoSlash = URL(fileURLWithPath: archiveURL.path, isDirectory: false)
        if (try? archiveNoSlash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecoveryFailure.fatal("Refusing symbolic link for --archive: \(archiveURL.path)")
        }
        var archiveStat = stat()
        guard Darwin.lstat(archiveNoSlash.path, &archiveStat) == 0,
              (archiveStat.st_mode & S_IFMT) == S_IFDIR else {
            throw RecoveryFailure.fatal("Archive bundle does not exist or is not a directory: \(archiveURL.path)")
        }

        let decoder = RecoveryCryptoAndIO.makeDecoder()
        let encoder = RecoveryCryptoAndIO.makeEncoder()

        let manifestURL = try validateContainedArchiveFile(in: archiveURL, relativePath: "manifest.json")
        let rawManifestBytes = try RecoveryCryptoAndIO.readRegularFileDataNoFollow(at: manifestURL, label: "manifest.json")
        let manifest: ClipBookArchiveManifest
        do {
            manifest = try decoder.decode(ClipBookArchiveManifest.self, from: rawManifestBytes)
        } catch {
            throw RecoveryFailure.fatal("Invalid or corrupted manifest.json in \(archiveURL.path).")
        }

        guard manifest.formatVersion == 2, let encryption = manifest.encryption else {
            throw RecoveryFailure.fatal(
                "Expected encrypted ClipBook archive with formatVersion = 2 (found \(manifest.formatVersion))."
            )
        }

        let minIterations = allowTestIterations
            ? RecoveryCryptoAndIO.minimumTestKDFIterations
            : RecoveryCryptoAndIO.minimumProductionKDFIterations
        guard encryption.kdf == "PBKDF2-HMAC-SHA256",
              encryption.algorithm == "AES-256-GCM",
              let salt = Data(base64Encoded: encryption.saltBase64),
              salt.count == RecoveryCryptoAndIO.archiveSaltByteCount,
              (minIterations...RecoveryCryptoAndIO.maximumKDFIterations).contains(encryption.iterations) else {
            throw RecoveryFailure.fatal("Archive encryption parameters in manifest.json are invalid or unsupported.")
        }

        guard let verifier = Data(base64Encoded: encryption.keyVerifierBase64),
              verifier.count == SHA256.byteCount else {
            throw RecoveryFailure.fatal("Corrupted keyVerifierBase64 in manifest.json.")
        }

        let nfcPassphrase = try resolveNFCPassphrase(from: passphraseSource)
        let derivedKeys = try RecoveryCryptoAndIO.deriveArchiveKeys(
            nfcPassphrase: nfcPassphrase,
            salt: salt,
            iterations: encryption.iterations,
            archiveID: encryption.archiveID,
            allowTestIterations: allowTestIterations
        )

        guard RecoveryCryptoAndIO.verifyArchiveKeyVerifier(
            verifier,
            verifierKey: derivedKeys.verifierHMACKey,
            archiveID: encryption.archiveID
        ) else {
            throw RecoveryFailure.keyOrPassphraseMismatch("Incorrect archive passphrase.")
        }

        let manifestDigest = Data(SHA256.hash(data: rawManifestBytes))

        let archiveTags = try openAndDecodeEncryptedJSON(
            [ClipBookArchiveTag].self,
            relativePath: "tags.json.enc",
            in: archiveURL,
            key: derivedKeys.aeadKey,
            archiveID: encryption.archiveID,
            manifestDigest: manifestDigest,
            decoder: decoder
        )

        let encryptedPayload = try openAndDecodeEncryptedJSON(
            ClipBookEncryptedHistoryPayload.self,
            relativePath: "history.json.enc",
            in: archiveURL,
            key: derivedKeys.aeadKey,
            archiveID: encryption.archiveID,
            manifestDigest: manifestDigest,
            decoder: decoder
        )

        try verifyExpectedAssetsInventory(
            expectedAssets: encryptedPayload.expectedAssets,
            items: encryptedPayload.items,
            in: archiveURL
        )

        let layout = try RecoveryCryptoAndIO.prepareStagedV1ArchiveLayout(for: outputDir)
        let stagingRoot = layout.stagingRoot
        let stagedArchiveURL = layout.stagedArchiveURL
        let stagedImagesDir = layout.stagedImagesDir
        let stagedPreviewsDir = layout.stagedPreviewsDir
        defer {
            RecoveryCryptoAndIO.scrubAndRemoveDirectory(at: stagingRoot)
        }

        var usedPlainFileNames: Set<String> = []
        var recoveredItems: [ClipBookArchiveItem] = []
        recoveredItems.reserveCapacity(encryptedPayload.items.count)

        for item in encryptedPayload.items {
            let recoveredItem = try autoreleasepool { () throws -> ClipBookArchiveItem in
                var rewritten = item
                rewritten.assetPath = try decryptAndStageV2Asset(
                    relativePath: item.assetPath,
                    preferredExtension: item.assetExtension,
                    defaultStem: item.id.uuidString,
                    in: archiveURL,
                    archiveID: encryption.archiveID,
                    manifestDigest: manifestDigest,
                    aeadKey: derivedKeys.aeadKey,
                    stagedImagesDir: stagedImagesDir,
                    stagedPreviewsDir: stagedPreviewsDir,
                    usedPlainFileNames: &usedPlainFileNames
                )
                rewritten.assetExtension = nil

                if var details = item.linkPreviewDetails {
                    details.imagePath = try decryptAndStageV2Asset(
                        relativePath: details.imagePath,
                        preferredExtension: details.imageExtension,
                        defaultStem: "\(item.id.uuidString)-preview",
                        in: archiveURL,
                        archiveID: encryption.archiveID,
                        manifestDigest: manifestDigest,
                        aeadKey: derivedKeys.aeadKey,
                        stagedImagesDir: stagedImagesDir,
                        stagedPreviewsDir: stagedPreviewsDir,
                        usedPlainFileNames: &usedPlainFileNames
                    )
                    details.faviconPath = try decryptAndStageV2Asset(
                        relativePath: details.faviconPath,
                        preferredExtension: details.faviconExtension,
                        defaultStem: "\(item.id.uuidString)-favicon",
                        in: archiveURL,
                        archiveID: encryption.archiveID,
                        manifestDigest: manifestDigest,
                        aeadKey: derivedKeys.aeadKey,
                        stagedImagesDir: stagedImagesDir,
                        stagedPreviewsDir: stagedPreviewsDir,
                        usedPlainFileNames: &usedPlainFileNames
                    )
                    details.imageExtension = nil
                    details.faviconExtension = nil
                    rewritten.linkPreviewDetails = details
                }

                return rewritten
            }
            recoveredItems.append(recoveredItem)
        }

        let plainManifest = ClipBookArchiveManifest(
            formatVersion: 1,
            appName: manifest.appName,
            appVersion: manifest.appVersion,
            exportedAt: manifest.exportedAt,
            encryption: nil
        )

        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(plainManifest),
            to: stagedArchiveURL.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(archiveTags),
            to: stagedArchiveURL.appendingPathComponent("tags.json", isDirectory: false)
        )
        try RecoveryCryptoAndIO.writePrivateFile(
            try encoder.encode(recoveredItems),
            to: stagedArchiveURL.appendingPathComponent("history.json", isDirectory: false),
            sync: true
        )

        try RecoveryCryptoAndIO.swapStagedOutput(at: stagedArchiveURL, into: outputDir)
        return ExitStatus.success
    }

    // MARK: - Mode B Helpers

    private static func decryptAndStageV2Asset(
        relativePath: String?,
        preferredExtension: String?,
        defaultStem: String,
        in archiveURL: URL,
        archiveID: UUID,
        manifestDigest: Data,
        aeadKey: SymmetricKey,
        stagedImagesDir: URL,
        stagedPreviewsDir: URL,
        usedPlainFileNames: inout Set<String>
    ) throws -> String? {
        guard let relativePath, !relativePath.isEmpty else {
            return nil
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components[0] == "assets",
              components[1] == "images" || components[1] == "link-previews" else {
            throw RecoveryFailure.fatal("Invalid encrypted asset relative path: \(relativePath)")
        }
        let archiveSubdir = components[1]
        let destinationDir = (archiveSubdir == "images") ? stagedImagesDir : stagedPreviewsDir

        let sourceURL = try validateContainedArchiveFile(in: archiveURL, relativePath: relativePath)
        let sealedBytes = try RecoveryCryptoAndIO.readRegularFileDataNoFollow(at: sourceURL, label: relativePath)
        let plainBytes = try RecoveryCryptoAndIO.openArchiveEntry(
            sealedBytes,
            key: aeadKey,
            archiveID: archiveID,
            manifestDigest: manifestDigest,
            relativePath: relativePath
        )

        let sanitizedExt = RecoveryCryptoAndIO.plainAssetExtension(
            preferred: preferredExtension,
            magicBytes: plainBytes
        )
        let resolved = try RecoveryCryptoAndIO.writeDisambiguatedPlainAsset(
            plainBytes,
            archiveSubdirectory: archiveSubdir,
            rawStem: URL(fileURLWithPath: components[2]).deletingPathExtension().lastPathComponent,
            defaultStem: defaultStem,
            fileExtension: sanitizedExt,
            destinationDir: destinationDir,
            usedPlainFileNames: &usedPlainFileNames
        )
        return resolved.relativeArchivePath
    }

    private static func openAndDecodeEncryptedJSON<T: Decodable>(
        _ type: T.Type,
        relativePath: String,
        in archiveURL: URL,
        key: SymmetricKey,
        archiveID: UUID,
        manifestDigest: Data,
        decoder: JSONDecoder
    ) throws -> T {
        let encURL = try validateContainedArchiveFile(in: archiveURL, relativePath: relativePath)
        let sealedBytes = try RecoveryCryptoAndIO.readRegularFileDataNoFollow(at: encURL, label: relativePath)
        let decryptedBytes = try RecoveryCryptoAndIO.openArchiveEntry(
            sealedBytes,
            key: key,
            archiveID: archiveID,
            manifestDigest: manifestDigest,
            relativePath: relativePath
        )
        do {
            return try decoder.decode(T.self, from: decryptedBytes)
        } catch {
            throw RecoveryFailure.fatal("Corrupted decrypted \(relativePath) payload.")
        }
    }

    private static func verifyExpectedAssetsInventory(
        expectedAssets: [String: String],
        items: [ClipBookArchiveItem],
        in archiveURL: URL
    ) throws {
        var referencedPaths: Set<String> = []
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
            throw RecoveryFailure.fatal("Encrypted archive asset inventory (expectedAssets) does not match history.json.enc.")
        }

        for (relativePath, expectedHex) in expectedAssets {
            guard RecoveryCryptoAndIO.isValidLowercaseSHA256Hex(expectedHex) else {
                throw RecoveryFailure.fatal("Malformed SHA-256 digest in expectedAssets for \(relativePath).")
            }
            let fileURL = try validateContainedArchiveFile(in: archiveURL, relativePath: relativePath)
            let actualHex = try RecoveryCryptoAndIO.sha256LowercaseHexNoFollow(at: fileURL, label: relativePath)
            guard actualHex == expectedHex else {
                throw RecoveryFailure.fatal("SHA-256 integrity check failed for encrypted asset \(relativePath).")
            }
        }
    }

    private static func validateContainedArchiveFile(
        in archiveURL: URL,
        relativePath: String
    ) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
            throw RecoveryFailure.fatal("Invalid archive relative path: \(relativePath)")
        }

        let rawComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            throw RecoveryFailure.fatal("Invalid archive relative path: \(relativePath)")
        }
        for component in rawComponents {
            if component.isEmpty || component == "." || component == ".." {
                throw RecoveryFailure.fatal("Invalid path traversal component in archive path: \(relativePath)")
            }
        }

        var currentDirectoryURL = URL(fileURLWithPath: archiveURL.path, isDirectory: true)
        var targetURL = URL(fileURLWithPath: archiveURL.path, isDirectory: false)

        for (index, rawComponent) in rawComponents.enumerated() {
            let component = String(rawComponent)
            let isLeaf = (index == rawComponents.count - 1)
            let candidateURL = currentDirectoryURL.appendingPathComponent(component, isDirectory: false)

            // Check isSymbolicLink / lstat BEFORE fileExists so dangling symlinks are caught as path violations.
            if (try? candidateURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RecoveryFailure.fatal("Refusing symbolic link inside archive: \(relativePath)")
            }

            var componentStat = stat()
            if Darwin.lstat(candidateURL.path, &componentStat) == 0 {
                let mode = componentStat.st_mode & S_IFMT
                if mode == S_IFLNK {
                    throw RecoveryFailure.fatal("Refusing symbolic link inside archive: \(relativePath)")
                }
                if !isLeaf && mode != S_IFDIR {
                    throw RecoveryFailure.fatal("Expected directory component inside archive: \(relativePath)")
                }
                if isLeaf && mode != S_IFREG {
                    throw RecoveryFailure.fatal("Expected regular file inside archive: \(relativePath)")
                }
            } else {
                throw RecoveryFailure.fatal("Missing required archive file: \(relativePath)")
            }

            if isLeaf {
                targetURL = candidateURL
            } else {
                currentDirectoryURL = currentDirectoryURL.appendingPathComponent(component, isDirectory: true)
            }
        }

        let canonicalArchiveRoot = archiveURL.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalArchivePrefix = canonicalArchiveRoot.hasSuffix("/")
            ? canonicalArchiveRoot
            : (canonicalArchiveRoot + "/")
        let resolvedTargetURL = targetURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTargetURL.path.hasPrefix(canonicalArchivePrefix),
              (try? resolvedTargetURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw RecoveryFailure.fatal("Archive path escapes archive root: \(relativePath)")
        }

        return resolvedTargetURL
    }

    private static func resolveNFCPassphrase(from source: PassphraseInputSource) throws -> String {
        var rawBytes: [UInt8]
        switch source {
        case .file(let path):
            let fileURL = URL(fileURLWithPath: path, isDirectory: false)
            rawBytes = try RecoveryCryptoAndIO.readRegularFileBytesNoFollow(
                at: fileURL,
                maxBytes: 65_536,
                label: "--passphrase-file"
            )
        case .stdin:
            rawBytes = try RecoveryCryptoAndIO.readFDBytes(
                fd: STDIN_FILENO,
                maxBytes: 65_536,
                label: "--passphrase-stdin"
            )
        case .interactiveTTY:
            rawBytes = try promptPassphraseFromTTY()
        }

        defer {
            RecoveryCryptoAndIO.zeroBytes(&rawBytes)
        }

        // Strip at most a single trailing \r?\n before Unicode NFC normalization.
        if rawBytes.count >= 2,
           rawBytes[rawBytes.count - 2] == 0x0D,
           rawBytes[rawBytes.count - 1] == 0x0A {
            rawBytes.removeLast(2)
        } else if rawBytes.last == 0x0A {
            rawBytes.removeLast()
        }

        guard let decoded = String(bytes: rawBytes, encoding: .utf8) else {
            throw RecoveryFailure.fatal("Passphrase input is not valid UTF-8.")
        }
        let nfc = decoded.precomposedStringWithCanonicalMapping
        guard !nfc.isEmpty else {
            throw RecoveryFailure.fatal("Archive passphrase cannot be empty.")
        }
        return nfc
    }

    private static func promptPassphraseFromTTY() throws -> [UInt8] {
        let ttyFD = Darwin.open("/dev/tty", O_RDWR | O_NOFOLLOW)
        guard ttyFD >= 0 else {
            throw RecoveryFailure.fatal(
                "Interactive passphrase prompt requires /dev/tty; pass --passphrase-file or --passphrase-stdin."
            )
        }
        defer {
            _ = Darwin.close(ttyFD)
        }

        var original = termios()
        guard tcgetattr(ttyFD, &original) == 0 else {
            throw RecoveryFailure.fatal("Unable to inspect /dev/tty terminal attributes.")
        }

        activeTTYFD = ttyFD
        savedTTYTermios = original
        hasSavedTTYTermios = 1

        var prevSigInt = sigaction()
        var prevSigTerm = sigaction()
        var action = sigaction()
        action.__sigaction_u.__sa_handler = ttySignalRestoreHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        _ = sigaction(SIGINT, &action, &prevSigInt)
        _ = sigaction(SIGTERM, &action, &prevSigTerm)

        defer {
            var restored = original
            _ = tcsetattr(ttyFD, TCSANOW, &restored)
            hasSavedTTYTermios = 0
            activeTTYFD = -1
            _ = sigaction(SIGINT, &prevSigInt, nil)
            _ = sigaction(SIGTERM, &prevSigTerm, nil)
        }

        var noEcho = original
        noEcho.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(ttyFD, TCSAFLUSH, &noEcho) == 0 else {
            throw RecoveryFailure.fatal("Unable to disable terminal echo on /dev/tty.")
        }

        let prompt = Array("Enter archive passphrase: ".utf8)
        prompt.withUnsafeBytes { rawBuffer in
            if let base = rawBuffer.baseAddress {
                _ = Darwin.write(ttyFD, base, rawBuffer.count)
            }
        }

        var buffer: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(ttyFD, &byte, 1)
            if count == 1 {
                buffer.append(byte)
                if byte == 0x0A {
                    break
                }
                if buffer.count > 65_536 {
                    RecoveryCryptoAndIO.zeroBytes(&buffer)
                    var newline: UInt8 = 0x0A
                    _ = Darwin.write(ttyFD, &newline, 1)
                    throw RecoveryFailure.fatal("Passphrase exceeds maximum length.")
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                let err = errno
                RecoveryCryptoAndIO.zeroBytes(&buffer)
                var newline: UInt8 = 0x0A
                _ = Darwin.write(ttyFD, &newline, 1)
                throw RecoveryFailure.fatal("Failed reading passphrase from /dev/tty: \(String(cString: strerror(err)))")
            }
        }

        var newline: UInt8 = 0x0A
        _ = Darwin.write(ttyFD, &newline, 1)
        return buffer
    }
}

// MARK: - Top-Level Entrypoint

private func writeStderr(_ message: String) {
    let data = Data(message.utf8)
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
        _ = Darwin.write(STDERR_FILENO, base, rawBuffer.count)
    }
}

private func writeStdout(_ message: String) {
    let data = Data(message.utf8)
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
        _ = Darwin.write(STDOUT_FILENO, base, rawBuffer.count)
    }
}

private func runMain() -> Int32 {
    do {
        let cliArgs = Array(CommandLine.arguments.dropFirst())
        let command = try CLIParser.parse(arguments: cliArgs)
        switch command {
        case .help:
            writeStdout(CLIParser.usageText + "\n")
            return ExitStatus.success
        case let .supportDirectory(supportDir, outputDir, keySource, includeTrashed, strict):
            return try LocalStoreRecovery.run(
                supportDir: supportDir,
                outputDir: outputDir,
                keySource: keySource,
                includeTrashed: includeTrashed,
                strict: strict
            )
        case let .archive(archiveURL, outputDir, passphraseSource, allowTestIterations):
            return try EncryptedArchiveRecovery.run(
                archiveURL: archiveURL,
                outputDir: outputDir,
                passphraseSource: passphraseSource,
                allowTestIterations: allowTestIterations
            )
        }
    } catch let failure as RecoveryFailure {
        switch failure {
        case .usage(let message):
            writeStderr("Error: \(message)\n\n\(CLIParser.usageText)\n")
            return ExitStatus.fatalError
        case .fatal(let message):
            writeStderr("Error: \(message)\n")
            return ExitStatus.fatalError
        case .keyOrPassphraseMismatch(let message):
            writeStderr("Error: \(message)\n")
            return ExitStatus.keyOrPassphraseMismatch
        }
    } catch {
        writeStderr("Error: \(error.localizedDescription)\n")
        return ExitStatus.fatalError
    }
}

exit(runMain())
