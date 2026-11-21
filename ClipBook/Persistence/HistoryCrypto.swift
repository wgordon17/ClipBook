import CommonCrypto
import CryptoKit
import Darwin
import Foundation

nonisolated enum AssetRole: String, Sendable {
    case image = "image"
    case linkPreview = "link-preview"
    case linkFavicon = "link-favicon"
}

nonisolated struct ClipBookDerivedKeys: Sendable {
    static let hkdfSalt = Data("com.ikryanov.clipbook.v2.hkdf.v1".utf8)

    let dbColumnAEADKey: SymmetricKey
    let assetFileAEADKey: SymmetricKey
    let contentKeyHMACKey: SymmetricKey
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
        self.contentKeyHMACKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Self.hkdfSalt,
            info: Data("clipbook.db.contentkey.hmacsha256.v1".utf8),
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

nonisolated struct ClipBookArchiveDerivedKeys: Sendable {
    let aeadKey: SymmetricKey
    let verifierHMACKey: SymmetricKey
}

nonisolated enum HistoryCrypto {
    static let columnFormatVersion: UInt8 = 0x01
    static let aadFormatVersion: UInt8 = 0x01
    static let archiveFormatVersion: UInt8 = 0x02
    static let contentKeyFormatVersion: UInt8 = 0x01
    static let minimumSealedColumnLength = 29
    static let archiveEntryMagic = Data("CBARC02\0".utf8)
    static let minimumSealedArchiveEntryLength = 36
    static let keyVerifierContext = Data("clipbook-key-verifier-v1".utf8)
    static let archiveKeyVerifierPrefix = "clipbook-archive-v2-verifier\0"
    static let imageDigestDomainPrefix = Data("image-v1\0".utf8)

    static let productionKDFIterations = 600_000
    static let minimumProductionKDFIterations = 100_000
    static let minimumTestKDFIterations = 1_000
    static let maximumKDFIterations = 10_000_000
    static let archiveSaltByteCount = 32
    static let archiveDerivedKeyByteCount = 32
    static let archiveAEADHKDFInfo = Data("clipbook.archive.aes256gcm.v2".utf8)
    static let archiveKeyVerifierHKDFInfo = Data("clipbook.archive.keyverifier.hmacsha256.v2".utf8)

    static func columnAAD(table: String, column: String, clipID: UUID) -> Data {
        let tableUTF8 = Data(table.utf8)
        let columnUTF8 = Data(column.utf8)
        precondition(tableUTF8.count <= Int(UInt8.max), "Table identifier exceeds UInt8 length bound")
        precondition(columnUTF8.count <= Int(UInt8.max), "Column identifier exceeds UInt8 length bound")

        var aad = Data(capacity: 1 + 1 + tableUTF8.count + 1 + columnUTF8.count + 16)
        aad.append(aadFormatVersion)
        aad.append(UInt8(tableUTF8.count))
        aad.append(tableUTF8)
        aad.append(UInt8(columnUTF8.count))
        aad.append(columnUTF8)
        withUnsafeBytes(of: clipID.uuid) { uuidBytes in
            aad.append(contentsOf: uuidBytes)
        }
        return aad
    }

    static func assetAAD(role: AssetRole, clipID: UUID) -> Data {
        let roleUTF8 = Data(role.rawValue.utf8)
        precondition(roleUTF8.count <= Int(UInt8.max), "Asset role identifier exceeds UInt8 length bound")

        var aad = Data(capacity: 1 + 1 + roleUTF8.count + 16)
        aad.append(aadFormatVersion)
        aad.append(UInt8(roleUTF8.count))
        aad.append(roleUTF8)
        withUnsafeBytes(of: clipID.uuid) { uuidBytes in
            aad.append(contentsOf: uuidBytes)
        }
        return aad
    }

    static func sealColumn(
        _ plaintext: Data,
        table: String,
        column: String,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        let aad = columnAAD(table: table, column: column, clipID: clipID)
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: keys.dbColumnAEADKey,
                nonce: nonce,
                authenticating: aad
            )
        } catch {
            throw HistoryStoreError.authenticationFailed
        }

        guard let combined = sealedBox.combined else {
            throw HistoryStoreError.authenticationFailed
        }

        var blob = Data(capacity: 1 + combined.count)
        blob.append(columnFormatVersion)
        blob.append(combined)
        return blob
    }

    static func openColumn(
        _ blob: Data,
        table: String,
        column: String,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        guard blob.count >= minimumSealedColumnLength,
              blob.first == columnFormatVersion else {
            throw HistoryStoreError.authenticationFailed
        }

        let aad = columnAAD(table: table, column: column, clipID: clipID)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(blob.dropFirst()))
            return try AES.GCM.open(
                sealedBox,
                using: keys.dbColumnAEADKey,
                authenticating: aad
            )
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
    }

    static func makeKeyVerifier(keys: ClipBookDerivedKeys) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: keyVerifierContext,
            using: keys.keyVerifierHMACKey
        )
        return Data(mac)
    }

    static func verifyKeyVerifier(_ verifier: Data, keys: ClipBookDerivedKeys) -> Bool {
        guard verifier.count == SHA256.byteCount else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            verifier,
            authenticating: keyVerifierContext,
            using: keys.keyVerifierHMACKey
        )
    }

    static func imageDigest(forPNGData pngData: Data, keys: ClipBookDerivedKeys) -> String {
        var hmac = HMAC<SHA256>(key: keys.contentKeyHMACKey)
        hmac.update(data: imageDigestDomainPrefix)
        hmac.update(data: pngData)
        let mac = hmac.finalize()
        return lowercaseHexString(mac)
    }

    static func contentKey(
        kind: ClipboardKind,
        canonicalContent: String,
        htmlDigest: String?,
        keys: ClipBookDerivedKeys
    ) -> Data {
        let kindUTF8 = Data(kind.rawValue.utf8)
        precondition(kindUTF8.count <= Int(UInt8.max), "ClipboardKind identifier exceeds UInt8 length bound")

        let htmlDigestUTF8 = Data((htmlDigest ?? "").utf8)
        precondition(UInt64(htmlDigestUTF8.count) <= UInt64(UInt32.max), "htmlDigest exceeds UInt32 length bound")

        var header = Data(capacity: 1 + 1 + kindUTF8.count + 4)
        header.append(contentKeyFormatVersion)
        header.append(UInt8(kindUTF8.count))
        header.append(kindUTF8)
        var htmlDigestLengthBE = UInt32(htmlDigestUTF8.count).bigEndian
        withUnsafeBytes(of: &htmlDigestLengthBE) { lengthBytes in
            header.append(contentsOf: lengthBytes)
        }

        var hmac = HMAC<SHA256>(key: keys.contentKeyHMACKey)
        hmac.update(data: header)
        hmac.update(data: htmlDigestUTF8)
        hmac.update(data: Data(canonicalContent.utf8))
        return Data(hmac.finalize())
    }

    static func deriveArchiveKeys(
        passphrase: String,
        salt: Data,
        iterations: Int,
        archiveID: UUID,
        allowTestIterations: Bool = false
    ) throws -> ClipBookArchiveDerivedKeys {
        let nfc = passphrase.precomposedStringWithCanonicalMapping
        let minIterations = allowTestIterations ? minimumTestKDFIterations : minimumProductionKDFIterations
        guard !nfc.isEmpty,
              salt.count == archiveSaltByteCount,
              (minIterations...maximumKDFIterations).contains(iterations) else {
            throw HistoryStoreError.invalidArchiveKeyParameters
        }

        var nfcCString = nfc.utf8CString
        defer {
            nfcCString.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
        }

        var derivedBytes = [UInt8](repeating: 0, count: archiveDerivedKeyByteCount)
        defer {
            derivedBytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
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
            throw HistoryStoreError.invalidArchiveKeyParameters
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
        return ClipBookArchiveDerivedKeys(aeadKey: aeadKey, verifierHMACKey: verifierHMACKey)
    }

    static func deriveArchiveAEADKey(
        passphrase: String,
        salt: Data,
        iterations: Int,
        archiveID: UUID,
        allowTestIterations: Bool = false
    ) throws -> SymmetricKey {
        try deriveArchiveKeys(
            passphrase: passphrase,
            salt: salt,
            iterations: iterations,
            archiveID: archiveID,
            allowTestIterations: allowTestIterations
        ).aeadKey
    }

    static func archiveEntryAAD(
        archiveID: UUID,
        manifestDigest: Data,
        relativePath: String
    ) throws -> Data {
        let pathUTF8 = Data(relativePath.utf8)
        guard manifestDigest.count == SHA256.byteCount,
              pathUTF8.count <= Int(UInt16.max) else {
            throw HistoryStoreError.invalidArchiveKeyParameters
        }

        var aad = Data(capacity: 1 + 16 + SHA256.byteCount + 2 + pathUTF8.count)
        aad.append(archiveFormatVersion)
        withUnsafeBytes(of: archiveID.uuid) { uuidBytes in
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

    static func sealArchiveEntry(
        _ plaintext: Data,
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
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: aad
            )
        } catch {
            throw HistoryStoreError.authenticationFailed
        }

        guard let combined = sealedBox.combined else {
            throw HistoryStoreError.authenticationFailed
        }

        var blob = Data(capacity: archiveEntryMagic.count + combined.count)
        blob.append(archiveEntryMagic)
        blob.append(combined)
        return blob
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
            throw HistoryStoreError.authenticationFailed
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(archiveEntryMagic.count)))
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: aad
            )
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
    }

    static func makeArchiveKeyVerifier(verifierKey: SymmetricKey, archiveID: UUID) -> Data {
        let context = Data((archiveKeyVerifierPrefix + archiveID.uuidString.lowercased()).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: context, using: verifierKey)
        return Data(mac)
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

    private static func lowercaseHexString<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var ascii = [UInt8]()
        ascii.reserveCapacity(64)
        for byte in bytes {
            let high = byte >> 4
            let low = byte & 0x0F
            ascii.append(high < 10 ? (0x30 + high) : (0x61 + (high - 10)))
            ascii.append(low < 10 ? (0x30 + low) : (0x61 + (low - 10)))
        }
        return String(decoding: ascii, as: UTF8.self)
    }
}
