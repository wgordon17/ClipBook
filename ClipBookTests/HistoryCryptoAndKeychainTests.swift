@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import Security
import Testing

nonisolated private final class MockSecItemKeychain: Sendable {
    enum StoredPayload: Sendable {
        case data(Data)
        case nonDataString(String)
    }

    struct RecordedQuery: Sendable {
        var secClass: String?
        var service: String?
        var account: String?
        var synchronizable: Bool?
        var hasDataProtectionFlag: Bool
        var valueData: Data?

        init(cfDictionary: CFDictionary) {
            let dict = (cfDictionary as? [String: Any]) ?? [:]
            self.secClass = dict[kSecClass as String] as? String
            self.service = dict[kSecAttrService as String] as? String
            self.account = dict[kSecAttrAccount as String] as? String
            self.synchronizable = dict[kSecAttrSynchronizable as String] as? Bool
            self.hasDataProtectionFlag = dict[kSecUseDataProtectionKeychain as String] != nil
            self.valueData = dict[kSecValueData as String] as? Data
        }
    }

    private struct State: Sendable {
        var storedPayload: StoredPayload?
        var copyMatchingOverrideStatuses: [OSStatus] = []
        var addOverrideStatuses: [OSStatus] = []
        var onDuplicatePopulateData: Data?
        var copyMatchingQueries: [RecordedQuery] = []
        var addQueries: [RecordedQuery] = []
        var deleteCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(initialData: Data? = nil) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(storedPayload: initialData.map { .data($0) })
        )
    }

    func setStoredNonDataString(_ value: String) {
        state.withLock { $0.storedPayload = .nonDataString(value) }
    }

    func enqueueCopyMatchingStatuses(_ statuses: [OSStatus]) {
        state.withLock { $0.copyMatchingOverrideStatuses.append(contentsOf: statuses) }
    }

    func enqueueAddStatuses(_ statuses: [OSStatus], populateOnDuplicate data: Data? = nil) {
        state.withLock {
            $0.addOverrideStatuses.append(contentsOf: statuses)
            $0.onDuplicatePopulateData = data
        }
    }

    var recordedAddQueries: [RecordedQuery] {
        state.withLock { $0.addQueries }
    }

    var recordedCopyMatchingQueries: [RecordedQuery] {
        state.withLock { $0.copyMatchingQueries }
    }

    var storedData: Data? {
        state.withLock {
            if case .data(let data) = $0.storedPayload {
                return data
            }
            return nil
        }
    }

    func makeClient() -> SecItemClient {
        SecItemClient(
            copyMatching: { [state] query, result in
                let recorded = RecordedQuery(cfDictionary: query)
                let outcome: (status: OSStatus, payload: StoredPayload?) = state.withLock { state in
                    state.copyMatchingQueries.append(recorded)
                    if !state.copyMatchingOverrideStatuses.isEmpty {
                        return (state.copyMatchingOverrideStatuses.removeFirst(), nil)
                    }
                    guard let payload = state.storedPayload else {
                        return (errSecItemNotFound, nil)
                    }
                    return (errSecSuccess, payload)
                }
                if let payload = outcome.payload {
                    switch payload {
                    case .data(let data):
                        result?.pointee = data as CFData
                    case .nonDataString(let string):
                        result?.pointee = string as CFString
                    }
                }
                return outcome.status
            },
            add: { [state] query, _ in
                let recorded = RecordedQuery(cfDictionary: query)
                return state.withLock { state in
                    state.addQueries.append(recorded)
                    if !state.addOverrideStatuses.isEmpty {
                        let nextStatus = state.addOverrideStatuses.removeFirst()
                        if nextStatus == errSecDuplicateItem, let racedData = state.onDuplicatePopulateData {
                            state.storedPayload = .data(racedData)
                        }
                        return nextStatus
                    }
                    if state.storedPayload != nil {
                        return errSecDuplicateItem
                    }
                    if let data = recorded.valueData {
                        state.storedPayload = .data(data)
                    }
                    return errSecSuccess
                }
            },
            delete: { [state] _ in
                state.withLock { state in
                    state.deleteCount += 1
                    guard state.storedPayload != nil else {
                        return errSecItemNotFound
                    }
                    state.storedPayload = nil
                    return errSecSuccess
                }
            }
        )
    }
}

nonisolated private enum CryptoTestHelpers {
    static func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func deterministicMasterKey(seed: UInt8) -> SymmetricKey {
        let bytes = (0..<32).map { index in seed &+ UInt8(truncatingIfNeeded: index &* 7) }
        return SymmetricKey(data: Data(bytes))
    }

    static func sampleSequentialHex64(offset: UInt8 = 0) -> String {
        (0..<32).map { String(format: "%02x", offset &+ UInt8($0)) }.joined()
    }

    static func makeSampleICOData() -> Data {
        // ICONDIR (6 bytes): reserved=0, type=1 (ICO), count=1
        // ICONDIRENTRY (16 bytes) + synthetic 32-byte payload
        var data = Data([
            0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x10, 0x10, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00,
            0x20, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00,
        ])
        data.append(Data("CLIPBOOK-ICO-BODY-PAYLOAD-BYTES!".utf8))
        return data
    }
}

@Suite
struct HistoryCryptoAndKeychainTests {
    // MARK: - 1. ClipBookDerivedKeys & Key Verifier

    @Test
    func derivedSubkeysArePairwiseDistinctDeterministicAndVerifyMasterKey() async {
        let masterA1 = CryptoTestHelpers.deterministicMasterKey(seed: 0x10)
        let masterA2 = CryptoTestHelpers.deterministicMasterKey(seed: 0x10)
        let masterB = CryptoTestHelpers.deterministicMasterKey(seed: 0x90)

        let keysA1 = ClipBookDerivedKeys(masterKey: masterA1)
        let keysA2 = ClipBookDerivedKeys(masterKey: masterA2)
        let keysB = ClipBookDerivedKeys(masterKey: masterB)

        let subkeysA1 = [
            CryptoTestHelpers.keyBytes(keysA1.dbColumnAEADKey),
            CryptoTestHelpers.keyBytes(keysA1.assetFileAEADKey),
            CryptoTestHelpers.keyBytes(keysA1.contentKeyHMACKey),
            CryptoTestHelpers.keyBytes(keysA1.keyVerifierHMACKey),
        ]
        for subkey in subkeysA1 {
            #expect(subkey.count == 32)
        }
        // All 6 pairs across the 4 subkeys must be pairwise distinct.
        #expect(Set(subkeysA1).count == 4)

        // Deterministic for identical masterKey bytes.
        #expect(keysA1.dbColumnAEADKey == keysA2.dbColumnAEADKey)
        #expect(keysA1.assetFileAEADKey == keysA2.assetFileAEADKey)
        #expect(keysA1.contentKeyHMACKey == keysA2.contentKeyHMACKey)
        #expect(keysA1.keyVerifierHMACKey == keysA2.keyVerifierHMACKey)

        // Distinct masterKey produces distinct subkeys across every role.
        #expect(keysA1.dbColumnAEADKey != keysB.dbColumnAEADKey)
        #expect(keysA1.assetFileAEADKey != keysB.assetFileAEADKey)
        #expect(keysA1.contentKeyHMACKey != keysB.contentKeyHMACKey)
        #expect(keysA1.keyVerifierHMACKey != keysB.keyVerifierHMACKey)

        // Key verifier succeeds for matching masterKey and rejects different/corrupted verifiers.
        let verifierA = HistoryCrypto.makeKeyVerifier(keys: keysA1)
        #expect(verifierA.count == SHA256.byteCount)
        #expect(HistoryCrypto.verifyKeyVerifier(verifierA, keys: keysA2))
        #expect(!HistoryCrypto.verifyKeyVerifier(verifierA, keys: keysB))

        var flippedVerifier = verifierA
        flippedVerifier[0] ^= 0x01
        #expect(!HistoryCrypto.verifyKeyVerifier(flippedVerifier, keys: keysA1))
        #expect(!HistoryCrypto.verifyKeyVerifier(Data(), keys: keysA1))
        #expect(!HistoryCrypto.verifyKeyVerifier(verifierA.dropLast(), keys: keysA1))
        #expect(!HistoryCrypto.verifyKeyVerifier(verifierA + Data([0x00]), keys: keysA1))

        // Exercise nonisolated Sendable execution off MainActor.
        let detachedVerified = await Task.detached {
            let detachedKeys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x10))
            return HistoryCrypto.verifyKeyVerifier(verifierA, keys: detachedKeys)
        }.value
        #expect(detachedVerified)
    }

    // MARK: - 2. Column AEAD & ImageAssetStore AEAD Round-Trips, Nonces, Anti-Transplant, Symlinks & Bit-Flips

    @Test
    func columnSealAndOpenRoundTripNoncesAntiTransplantAndBitFlips() throws {
        let keys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x22))
        let wrongKeys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x23))
        let clipID = UUID()
        let otherClipID = UUID()

        let payloads: [Data] = [
            Data(),
            Data("Plain clipboard body".utf8),
            Data([0x00, 0x61, 0x00, 0xFF, 0x00, 0x7A, 0x00]),
            Data("leading\0middle\0trailing\0".utf8),
        ]

        for payload in payloads {
            let sealed1 = try HistoryCrypto.sealColumn(
                payload,
                table: "clip_contents",
                column: "text",
                clipID: clipID,
                keys: keys
            )
            let sealed2 = try HistoryCrypto.sealColumn(
                payload,
                table: "clip_contents",
                column: "text",
                clipID: clipID,
                keys: keys
            )

            #expect(sealed1.first == HistoryCrypto.columnFormatVersion)
            #expect(sealed1.count == 1 + 12 + payload.count + 16)
            // Fresh CSPRNG nonce per seal produces distinct nonces and sealed blobs.
            #expect(sealed1.subdata(in: 1..<13) != sealed2.subdata(in: 1..<13))
            #expect(sealed1 != sealed2)

            let opened1 = try HistoryCrypto.openColumn(
                sealed1,
                table: "clip_contents",
                column: "text",
                clipID: clipID,
                keys: keys
            )
            let opened2 = try HistoryCrypto.openColumn(
                sealed2,
                table: "clip_contents",
                column: "text",
                clipID: clipID,
                keys: keys
            )
            #expect(opened1 == payload)
            #expect(opened2 == payload)
        }

        let nonEmptyPlaintext = Data("secret-column-\0-payload".utf8)
        let sealed = try HistoryCrypto.sealColumn(
            nonEmptyPlaintext,
            table: "clip_contents",
            column: "text",
            clipID: clipID,
            keys: keys
        )

        // Anti-transplant across clipID, column, table, length-prefix boundary, and wrong keys.
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(sealed, table: "clip_contents", column: "text", clipID: otherClipID, keys: keys)
        }
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(sealed, table: "clip_contents", column: "html", clipID: clipID, keys: keys)
        }
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(sealed, table: "clips", column: "text", clipID: clipID, keys: keys)
        }
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(sealed, table: "clip_contents", column: "text", clipID: clipID, keys: wrongKeys)
        }

        let boundarySealed = try HistoryCrypto.sealColumn(
            nonEmptyPlaintext,
            table: "ab",
            column: "c",
            clipID: clipID,
            keys: keys
        )
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(boundarySealed, table: "a", column: "bc", clipID: clipID, keys: keys)
        }

        // Truncated blobs below minimumSealedColumnLength (29) fail closed.
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(Data(), table: "clip_contents", column: "text", clipID: clipID, keys: keys)
        }
        #expect(throws: HistoryStoreError.authenticationFailed) {
            _ = try HistoryCrypto.openColumn(sealed.prefix(28), table: "clip_contents", column: "text", clipID: clipID, keys: keys)
        }

        // 1-bit flips in version (0), 12-byte nonce (1), ciphertext (13), and 16-byte GCM tag (last byte).
        let bitFlipOffsets = [0, 1, 13, sealed.count - 1]
        for offset in bitFlipOffsets {
            var tampered = sealed
            tampered[offset] ^= 0x01
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try HistoryCrypto.openColumn(
                    tampered,
                    table: "clip_contents",
                    column: "text",
                    clipID: clipID,
                    keys: keys
                )
            }
        }
    }

    @Test
    func imageAssetStoreRoundTripsMissingKeysAntiTransplantDowngradeSymlinkAndBitFlips() throws {
        try TestSupport.withTemporaryDirectory { tempDir in
            let supportDir = tempDir.appendingPathComponent("Support", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let store = ImageAssetStore(supportDirectory: supportDir)

            let keys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x34))
            let wrongKeys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x35))
            let clipID = UUID()
            let otherClipID = UUID()

            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 16, color: .systemTeal)
            let nulData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x41, 0x00, 0xFF, 0x00])
            let emptyData = Data()

            // Round-trips across empty, embedded NUL, and real PNG data.
            for sample in [emptyData, nulData, pngData] {
                let id = UUID()
                let encURL = try store.writeAsset(
                    pngData: sample,
                    role: .image,
                    clipID: id,
                    encrypted: true,
                    keys: keys
                )
                #expect(encURL.pathExtension == "enc")
                let readBackEnc = try store.readPNGData(
                    at: encURL,
                    role: .image,
                    clipID: id,
                    keys: keys,
                    requiresEncryption: true
                )
                #expect(readBackEnc == sample)

                let plainID = UUID()
                let plainURL = try store.writeAsset(
                    pngData: sample,
                    role: .image,
                    clipID: plainID,
                    encrypted: false,
                    keys: nil
                )
                #expect(plainURL.pathExtension == "png")
                let readBackPlain = try store.readPNGData(
                    at: plainURL,
                    role: .image,
                    clipID: plainID,
                    keys: nil,
                    requiresEncryption: false
                )
                #expect(readBackPlain == sample)
            }

            // Two encrypted writes of identical plaintext produce distinct nonces/ciphertexts.
            let encURL1 = try store.writeAsset(pngData: pngData, role: .image, clipID: clipID, encrypted: true, keys: keys)
            let rawEnc1 = try Data(contentsOf: encURL1)
            let encURL2 = try store.writeAsset(pngData: pngData, role: .image, clipID: clipID, encrypted: true, keys: keys)
            let rawEnc2 = try Data(contentsOf: encURL2)

            var fileStat = stat()
            #expect(Darwin.lstat(encURL2.path, &fileStat) == 0)
            #expect((fileStat.st_mode & 0o777) == 0o600)
            #expect(rawEnc1.prefix(8) == ImageAssetStore.encryptedMagic)
            #expect(rawEnc2.prefix(8) == ImageAssetStore.encryptedMagic)
            #expect(rawEnc1.subdata(in: 8..<20) != rawEnc2.subdata(in: 8..<20))
            #expect(rawEnc1 != rawEnc2)

            // loadImage succeeds on valid encrypted/plain PNGs and returns nil on auth/key failure.
            #expect(store.loadImage(at: encURL2, role: .image, clipID: clipID, keys: keys, requiresEncryption: true) != nil)
            #expect(store.loadImage(at: encURL2, role: .image, clipID: clipID, keys: nil, requiresEncryption: true) == nil)
            #expect(store.loadImage(at: encURL2, role: .linkPreview, clipID: clipID, keys: keys, requiresEncryption: true) == nil)

            // Nil keys on encrypted write or encrypted read throws .encryptionKeyUnavailable(.notFound).
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                _ = try store.writeAsset(pngData: pngData, role: .image, clipID: UUID(), encrypted: true, keys: nil)
            }
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                _ = try store.readPNGData(at: encURL2, role: .image, clipID: clipID, keys: nil, requiresEncryption: false)
            }

            // Anti-transplant across clipID, AssetRole, and wrong keys.
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: encURL2, role: .image, clipID: otherClipID, keys: keys)
            }
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: encURL2, role: .linkPreview, clipID: clipID, keys: keys)
            }
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: encURL2, role: .linkFavicon, clipID: clipID, keys: keys)
            }
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: encURL2, role: .image, clipID: clipID, keys: wrongKeys)
            }

            // Plaintext .png downgrade when requiresEncryption == true fails closed.
            let plainPNGURL = try store.writeAsset(
                pngData: pngData,
                role: .linkPreview,
                clipID: clipID,
                encrypted: false,
                keys: nil
            )
            #expect(plainPNGURL.lastPathComponent == "\(clipID.uuidString)-preview.png")
            #expect(store.loadImage(at: plainPNGURL, role: .linkPreview, clipID: clipID, keys: nil, requiresEncryption: false) != nil)
            #expect(store.loadImage(at: plainPNGURL, role: .linkPreview, clipID: clipID, keys: keys, requiresEncryption: true) == nil)
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(
                    at: plainPNGURL,
                    role: .linkPreview,
                    clipID: clipID,
                    keys: keys,
                    requiresEncryption: true
                )
            }

            // Plaintext bytes disguised with .enc extension fail closed even when requiresEncryption == false.
            let fakeEncURL = tempDir.appendingPathComponent("disguised.enc")
            try pngData.write(to: fakeEncURL)
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: fakeEncURL, role: .image, clipID: clipID, keys: keys, requiresEncryption: false)
            }

            // Truncated .enc file shorter than minimumEncryptedFileLength (36) fails closed.
            let truncatedEncURL = tempDir.appendingPathComponent("truncated.enc")
            try (ImageAssetStore.encryptedMagic + Data(repeating: 0xAA, count: 10)).write(to: truncatedEncURL)
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: truncatedEncURL, role: .image, clipID: clipID, keys: keys)
            }

            // Symlinks are rejected across readPNGData, loadImage, encryptAssetIfNeeded, and decryptAssetIfNeeded.
            let symlinkEncURL = tempDir.appendingPathComponent("symlink-asset.enc")
            try FileManager.default.createSymbolicLink(at: symlinkEncURL, withDestinationURL: encURL2)
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: symlinkEncURL, role: .image, clipID: clipID, keys: keys)
            }
            #expect(store.loadImage(at: symlinkEncURL, role: .image, clipID: clipID, keys: keys) == nil)

            let symlinkPlainURL = tempDir.appendingPathComponent("symlink-plain.png")
            try FileManager.default.createSymbolicLink(at: symlinkPlainURL, withDestinationURL: plainPNGURL)
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.readPNGData(at: symlinkPlainURL, role: .linkPreview, clipID: clipID, keys: nil)
            }
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.encryptAssetIfNeeded(at: symlinkPlainURL.path, role: .linkPreview, clipID: clipID, keys: keys)
            }
            #expect(throws: HistoryStoreError.authenticationFailed) {
                _ = try store.decryptAssetIfNeeded(at: symlinkEncURL.path, role: .image, clipID: clipID, keys: keys)
            }

            // 1-bit flips in 8-byte CBENC01\0 magic (0 and 7), 12-byte nonce (8), ciphertext (20), and 16-byte GCM tag (last).
            let tamperedURL = tempDir.appendingPathComponent("tampered.enc")
            let flipIndices = [0, 7, 8, 20, rawEnc2.count - 1]
            for index in flipIndices {
                var mutated = rawEnc2
                mutated[index] ^= 0x01
                try mutated.write(to: tamperedURL, options: .atomic)
                #expect(throws: HistoryStoreError.authenticationFailed) {
                    _ = try store.readPNGData(
                        at: tamperedURL,
                        role: .image,
                        clipID: clipID,
                        keys: keys,
                        requiresEncryption: true
                    )
                }
            }
        }
    }

    // MARK: - 3. Keyed contentKey & imageDigest

    @Test
    func contentKeyDistinguishesKindHtmlDigestFramingLargeLegacyDigestsAndKeyedImageDigest() throws {
        let keysA = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x41))
        let keysB = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x42))

        let hex64 = CryptoTestHelpers.sampleSequentialHex64(offset: 0x10)
        let textWithEmbeddedNewlineAndHex = HistoryCrypto.contentKey(
            kind: .text,
            canonicalContent: "hello\n" + hex64,
            htmlDigest: nil,
            keys: keysA
        )
        let richTextWithSeparateDigest = HistoryCrypto.contentKey(
            kind: .richText,
            canonicalContent: "hello",
            htmlDigest: hex64,
            keys: keysA
        )
        let richTextWithoutDigest = HistoryCrypto.contentKey(
            kind: .richText,
            canonicalContent: "hello\n" + hex64,
            htmlDigest: nil,
            keys: keysA
        )
        let linkSameBody = HistoryCrypto.contentKey(
            kind: .link,
            canonicalContent: "hello\n" + hex64,
            htmlDigest: nil,
            keys: keysA
        )

        #expect(textWithEmbeddedNewlineAndHex.count == SHA256.byteCount)
        #expect(textWithEmbeddedNewlineAndHex != richTextWithSeparateDigest)
        #expect(richTextWithoutDigest != richTextWithSeparateDigest)
        #expect(textWithEmbeddedNewlineAndHex != linkSameBody)
        #expect(
            textWithEmbeddedNewlineAndHex
                != HistoryCrypto.contentKey(
                    kind: .text,
                    canonicalContent: "hello\n" + hex64,
                    htmlDigest: nil,
                    keys: keysB
                )
        )

        // >255-byte legacy htmlDigest strings succeed without UInt8 overflow trapping and preserve full length framing.
        let longDigestA = String(repeating: "a", count: 320) + "-tail-1"
        let longDigestB = String(repeating: "a", count: 320) + "-tail-2"
        #expect(longDigestA.utf8.count > Int(UInt8.max))
        let longKeyA = HistoryCrypto.contentKey(
            kind: .richText,
            canonicalContent: "hello",
            htmlDigest: longDigestA,
            keys: keysA
        )
        let longKeyB = HistoryCrypto.contentKey(
            kind: .richText,
            canonicalContent: "hello",
            htmlDigest: longDigestB,
            keys: keysA
        )
        let shiftedBoundaryKey = HistoryCrypto.contentKey(
            kind: .richText,
            canonicalContent: "-tail-1hello",
            htmlDigest: String(repeating: "a", count: 320),
            keys: keysA
        )
        #expect(longKeyA.count == 32)
        #expect(longKeyA != longKeyB)
        #expect(longKeyA != shiftedBoundaryKey)

        // imageDigest produces 64 lowercase hex chars keyed specifically by contentKeyHMACKey.
        let pngData = try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16, color: .systemOrange)
        let digestA = HistoryCrypto.imageDigest(forPNGData: pngData, keys: keysA)
        let digestA2 = HistoryCrypto.imageDigest(forPNGData: pngData, keys: keysA)
        let digestB = HistoryCrypto.imageDigest(forPNGData: pngData, keys: keysB)

        #expect(digestA.count == 64)
        #expect(digestA == digestA2)
        #expect(digestA != digestB)
        #expect(digestA.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })

        var expectedHMAC = HMAC<SHA256>(key: keysA.contentKeyHMACKey)
        expectedHMAC.update(data: Data("image-v1\0".utf8))
        expectedHMAC.update(data: pngData)
        let expectedHex = expectedHMAC.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digestA == expectedHex)

        let unkeyedSHA256Hex = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        #expect(digestA != unkeyedSHA256Hex)
    }

    // MARK: - 4. Archive Passphrase KDF (NFC Normalization, 600,000 Production Rounds & Bounds)

    @Test
    func deriveArchiveAEADKeyNormalizesNFCValidatesBoundsAndRunsProductionIterations() throws {
        let salt = Data((0..<32).map { UInt8(0xA0 &+ $0) })
        let otherSalt = Data((0..<32).map { UInt8(0xB0 &+ $0) })
        let archiveID = UUID()
        let otherArchiveID = UUID()

        let nfcCafe = "Caf\u{00E9}"
        let nfdCafe = "Cafe\u{0301}"
        #expect(Array(nfcCafe.unicodeScalars).count == 4)
        #expect(Array(nfdCafe.unicodeScalars).count == 5)

        let keyFromNFC = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: nfcCafe,
            salt: salt,
            iterations: HistoryCrypto.minimumTestKDFIterations,
            archiveID: archiveID,
            allowTestIterations: true
        )
        let keyFromNFD = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: nfdCafe,
            salt: salt,
            iterations: HistoryCrypto.minimumTestKDFIterations,
            archiveID: archiveID,
            allowTestIterations: true
        )
        #expect(CryptoTestHelpers.keyBytes(keyFromNFC).count == 32)
        #expect(keyFromNFC == keyFromNFD)

        // Different salt or archiveID yields distinct keys.
        let keyDifferentSalt = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: nfcCafe,
            salt: otherSalt,
            iterations: HistoryCrypto.minimumTestKDFIterations,
            archiveID: archiveID,
            allowTestIterations: true
        )
        let keyDifferentArchiveID = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: nfcCafe,
            salt: salt,
            iterations: HistoryCrypto.minimumTestKDFIterations,
            archiveID: otherArchiveID,
            allowTestIterations: true
        )
        #expect(keyFromNFC != keyDifferentSalt)
        #expect(keyFromNFC != keyDifferentArchiveID)

        // Production KDF iterations (600,000) succeeds with allowTestIterations == false.
        #expect(HistoryCrypto.productionKDFIterations == 600_000)
        let prodPhrase = ["correct", "horse", "archive", "phrase"].joined(separator: "-")
        let prodKey = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: prodPhrase,
            salt: salt,
            iterations: HistoryCrypto.productionKDFIterations,
            archiveID: archiveID
        )
        #expect(CryptoTestHelpers.keyBytes(prodKey).count == 32)
        #expect(prodKey != keyFromNFC)

        // Boundary at minimumProductionKDFIterations (100,000) succeeds.
        let minProdKey = try HistoryCrypto.deriveArchiveAEADKey(
            passphrase: nfcCafe,
            salt: salt,
            iterations: HistoryCrypto.minimumProductionKDFIterations,
            archiveID: archiveID,
            allowTestIterations: false
        )
        #expect(CryptoTestHelpers.keyBytes(minProdKey).count == 32)

        // Invalid parameters throw .invalidArchiveKeyParameters.
        #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
            _ = try HistoryCrypto.deriveArchiveAEADKey(
                passphrase: "",
                salt: salt,
                iterations: HistoryCrypto.minimumProductionKDFIterations,
                archiveID: archiveID
            )
        }
        for invalidSaltLength in [0, 16, 31, 33, 64] {
            #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
                _ = try HistoryCrypto.deriveArchiveAEADKey(
                    passphrase: nfcCafe,
                    salt: Data(repeating: 0x11, count: invalidSaltLength),
                    iterations: HistoryCrypto.minimumProductionKDFIterations,
                    archiveID: archiveID
                )
            }
        }
        for tooLowProductionIterations in [-1, 0, 999, 1_000, 99_999] {
            #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
                _ = try HistoryCrypto.deriveArchiveAEADKey(
                    passphrase: nfcCafe,
                    salt: salt,
                    iterations: tooLowProductionIterations,
                    archiveID: archiveID,
                    allowTestIterations: false
                )
            }
        }
        #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
            _ = try HistoryCrypto.deriveArchiveAEADKey(
                passphrase: nfcCafe,
                salt: salt,
                iterations: 999,
                archiveID: archiveID,
                allowTestIterations: true
            )
        }
        for tooHighIterations in [10_000_001, Int.max] {
            #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
                _ = try HistoryCrypto.deriveArchiveAEADKey(
                    passphrase: nfcCafe,
                    salt: salt,
                    iterations: tooHighIterations,
                    archiveID: archiveID,
                    allowTestIterations: false
                )
            }
            #expect(throws: HistoryStoreError.invalidArchiveKeyParameters) {
                _ = try HistoryCrypto.deriveArchiveAEADKey(
                    passphrase: nfcCafe,
                    salt: salt,
                    iterations: tooHighIterations,
                    archiveID: archiveID,
                    allowTestIterations: true
                )
            }
        }
    }

    // MARK: - 5. SystemKeychainKeyProvider Mock SecItemClient & OSStatus Mapping

    @Test
    func systemKeychainKeyProviderCreatesLowercaseHexHandlesDuplicateRaceAndMapsStatuses() throws {
        // 1. Creation & persistence of 64-char lowercase ASCII hex without Data Protection Keychain attributes.
        let mock = MockSecItemKeychain()
        let provider = SystemKeychainKeyProvider(client: mock.makeClient(), allowsTestClient: true)

        #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
            _ = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
        }
        #expect(mock.recordedAddQueries.isEmpty)

        let createdKey = try provider.loadOrCreateMasterKey(canCreateNewKey: true)
        #expect(CryptoTestHelpers.keyBytes(createdKey).count == 32)
        #expect(mock.recordedAddQueries.count == 1)

        let addQuery = try #require(mock.recordedAddQueries.first)
        #expect(addQuery.secClass == (kSecClassGenericPassword as String))
        #expect(addQuery.service == SystemKeychainKeyProvider.service)
        #expect(addQuery.account == SystemKeychainKeyProvider.account)
        #expect(addQuery.synchronizable == false)
        #expect(!addQuery.hasDataProtectionFlag)

        let storedHexData = try #require(mock.storedData)
        #expect(storedHexData.count == 64)
        let storedHexString = try #require(String(data: storedHexData, encoding: .utf8))
        #expect(storedHexString.wholeMatch(of: /^[0-9a-f]{64}$/) != nil)

        let reloadedKey = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
        #expect(reloadedKey == createdKey)
        #expect(mock.recordedAddQueries.count == 1)

        // 2. errSecDuplicateItem race recovery re-reads the winning key via copyMatching.
        let winningKey = CryptoTestHelpers.deterministicMasterKey(seed: 0x55)
        let winningHex = MasterKeyHexCodec.encode(winningKey)
        let raceMock = MockSecItemKeychain()
        raceMock.enqueueAddStatuses([errSecDuplicateItem], populateOnDuplicate: winningHex)
        let raceProvider = SystemKeychainKeyProvider(client: raceMock.makeClient(), allowsTestClient: true)

        let recoveredKey = try raceProvider.loadOrCreateMasterKey(canCreateNewKey: true)
        #expect(recoveredKey == winningKey)
        #expect(raceMock.recordedCopyMatchingQueries.count == 2)

        // Duplicate item where concurrent deleter removed the item before re-read maps to .notFound.
        let vanishedRaceMock = MockSecItemKeychain()
        vanishedRaceMock.enqueueAddStatuses([errSecDuplicateItem], populateOnDuplicate: nil)
        let vanishedProvider = SystemKeychainKeyProvider(client: vanishedRaceMock.makeClient(), allowsTestClient: true)
        #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
            _ = try vanishedProvider.loadOrCreateMasterKey(canCreateNewKey: true)
        }

        // 3. OSStatus mapping on BOTH copyMatching and add.
        let statusExpectations: [(OSStatus, KeyUnavailableReason)] = [
            (errSecInteractionNotAllowed, .interactionNotAllowed),
            (errSecUserCanceled, .userCanceled),
            (errSecAuthFailed, .authFailed),
            (errSecIO, .unexpectedStatus(errSecIO)),
        ]

        for (status, expectedReason) in statusExpectations {
            let copyFailMock = MockSecItemKeychain()
            copyFailMock.enqueueCopyMatchingStatuses([status])
            let copyFailProvider = SystemKeychainKeyProvider(client: copyFailMock.makeClient(), allowsTestClient: true)
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(expectedReason)) {
                _ = try copyFailProvider.loadOrCreateMasterKey(canCreateNewKey: true)
            }

            let addFailMock = MockSecItemKeychain()
            addFailMock.enqueueAddStatuses([status])
            let addFailProvider = SystemKeychainKeyProvider(client: addFailMock.makeClient(), allowsTestClient: true)
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(expectedReason)) {
                _ = try addFailProvider.loadOrCreateMasterKey(canCreateNewKey: true)
            }
        }

        // 4. Malformed, uppercase, wrong-length, and non-Data Keychain payloads map to .corruptKeyData.
        let corruptPayloads: [Data] = [
            Data(),
            Data(repeating: 0xAA, count: 32), // raw binary 32-byte key instead of 64-char hex
            Data(String(repeating: "a", count: 63).utf8), // 63 chars
            Data((String(repeating: "a", count: 64) + "\n").utf8), // 65 chars
            Data(String(repeating: "A", count: 64).utf8), // uppercase hex
            Data((CryptoTestHelpers.sampleSequentialHex64().dropLast() + "A").utf8), // single uppercase nibble
            Data(("g" + String(repeating: "0", count: 63)).utf8), // non-hex ASCII
            Data([UInt8](repeating: 0xFF, count: 64)), // invalid UTF-8 / non-hex bytes
        ]

        for badData in corruptPayloads {
            let badMock = MockSecItemKeychain(initialData: badData)
            let badProvider = SystemKeychainKeyProvider(client: badMock.makeClient(), allowsTestClient: true)
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                _ = try badProvider.loadOrCreateMasterKey(canCreateNewKey: true)
            }
        }

        let nonDataMock = MockSecItemKeychain()
        nonDataMock.setStoredNonDataString("not-cfdata")
        let nonDataProvider = SystemKeychainKeyProvider(client: nonDataMock.makeClient(), allowsTestClient: true)
        #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
            _ = try nonDataProvider.loadOrCreateMasterKey(canCreateNewKey: false)
        }

        // Verify LocalizedError plain descriptions are non-empty for every new error case.
        let errorsToDescribe: [HistoryStoreError] = [
            .encryptionKeyUnavailable(.notFound),
            .encryptionKeyUnavailable(.interactionNotAllowed),
            .encryptionKeyUnavailable(.userCanceled),
            .encryptionKeyUnavailable(.authFailed),
            .encryptionKeyUnavailable(.corruptKeyData),
            .encryptionKeyUnavailable(.unexpectedStatus(errSecIO)),
            .encryptionKeyMismatch,
            .authenticationFailed,
            .invalidArchiveKeyParameters,
            .migrationFailed("v4 step"),
        ]
        for err in errorsToDescribe {
            #expect(err.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - 6. FileDatabaseKeyProvider & InMemoryDatabaseKeyProvider

    @Test
    func fileAndInMemoryDatabaseKeyProvidersEnforcePermissionsBackupExclusionAndValidation() throws {
        try TestSupport.withTemporaryDirectory { tempDir in
            let supportDir = tempDir.appendingPathComponent("IsolatedSupport", isDirectory: true)
            let provider = FileDatabaseKeyProvider(supportDirectory: supportDir)

            // Missing .devkey with canCreateNewKey == false throws .notFound without creating the file.
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                _ = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
            }
            #expect(!FileManager.default.fileExists(atPath: provider.keyFileURL.path))

            // Creating .devkey writes 0o600 regular file excluded from backup and round-trips.
            let createdKey = try provider.loadOrCreateMasterKey(canCreateNewKey: true)
            var st = stat()
            #expect(Darwin.lstat(provider.keyFileURL.path, &st) == 0)
            #expect((st.st_mode & S_IFMT) == S_IFREG)
            #expect((st.st_mode & 0o777) == 0o600)
            #expect(Int(st.st_size) == MasterKeyHexCodec.encodedHexByteCount)

            let resourceValues = try provider.keyFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(resourceValues.isExcludedFromBackup == true)

            let reloadedKey = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
            #expect(reloadedKey == createdKey)

            // Corrupt hex (wrong length, uppercase, non-hex) is rejected with .corruptKeyData.
            let corruptSamples: [Data] = [
                Data(),
                Data("short".utf8),
                Data(String(repeating: "F", count: 64).utf8),
                Data(String(repeating: "z", count: 64).utf8),
                Data(String(repeating: "a", count: 65).utf8),
            ]
            for corrupt in corruptSamples {
                try corrupt.write(to: provider.keyFileURL, options: .atomic)
                #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                    _ = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
                }
                #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                    _ = try provider.loadOrCreateMasterKey(canCreateNewKey: true)
                }
            }

            // Symlinked .devkey is rejected with .corruptKeyData.
            try FileManager.default.removeItem(at: provider.keyFileURL)
            let targetKeyFile = tempDir.appendingPathComponent("external-key-target")
            try MasterKeyHexCodec.encode(createdKey).write(to: targetKeyFile)
            try FileManager.default.createSymbolicLink(at: provider.keyFileURL, withDestinationURL: targetKeyFile)
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                _ = try provider.loadOrCreateMasterKey(canCreateNewKey: false)
            }
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                _ = try provider.loadOrCreateMasterKey(canCreateNewKey: true)
            }

            // Symlinked supportDirectory is also rejected on creation with .corruptKeyData.
            let realSupportTarget = tempDir.appendingPathComponent("RealDir", isDirectory: true)
            try FileManager.default.createDirectory(at: realSupportTarget, withIntermediateDirectories: true)
            let symlinkSupportDir = tempDir.appendingPathComponent("SymlinkSupportDir")
            try FileManager.default.createSymbolicLink(at: symlinkSupportDir, withDestinationURL: realSupportTarget)
            let symlinkDirProvider = FileDatabaseKeyProvider(supportDirectory: symlinkSupportDir)
            #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)) {
                _ = try symlinkDirProvider.loadOrCreateMasterKey(canCreateNewKey: true)
            }
        }

        // InMemoryDatabaseKeyProvider returns configured key, creates on demand, or throws injected error.
        let fixedKey = CryptoTestHelpers.deterministicMasterKey(seed: 0x77)
        let inMemory = InMemoryDatabaseKeyProvider(key: fixedKey)
        #expect(try inMemory.loadOrCreateMasterKey(canCreateNewKey: false) == fixedKey)

        inMemory.setError(.encryptionKeyUnavailable(.interactionNotAllowed))
        #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.interactionNotAllowed)) {
            _ = try inMemory.loadOrCreateMasterKey(canCreateNewKey: true)
        }

        inMemory.setError(nil)
        inMemory.setKey(nil)
        #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
            _ = try inMemory.loadOrCreateMasterKey(canCreateNewKey: false)
        }
        let generatedKey = try inMemory.loadOrCreateMasterKey(canCreateNewKey: true)
        #expect(try inMemory.loadOrCreateMasterKey(canCreateNewKey: false) == generatedKey)

        let failingInMemory = InMemoryDatabaseKeyProvider(key: nil, error: .encryptionKeyMismatch)
        #expect(throws: HistoryStoreError.encryptionKeyMismatch) {
            _ = try failingInMemory.loadOrCreateMasterKey(canCreateNewKey: true)
        }
    }

    // MARK: - 7. ImageAssetStore .png/.ico <-> .enc Conversion, Idempotency, Zero-Fill Scrubbing & External Preservation

    @Test
    func imageAssetStoreConversionsIdempotencyZeroFillScrubbingAndExternalPreservation() throws {
        try TestSupport.withTemporaryDirectory { supportDir in
            try TestSupport.withTemporaryDirectory { externalDir in
                let store = ImageAssetStore(supportDirectory: supportDir)
                let keys = ClipBookDerivedKeys(masterKey: CryptoTestHelpers.deterministicMasterKey(seed: 0x88))

                // 1. Missing and empty paths return nil cleanly.
                #expect(try store.encryptAssetIfNeeded(at: "", role: .image, clipID: UUID(), keys: keys) == nil)
                #expect(try store.decryptAssetIfNeeded(at: "", role: .image, clipID: UUID(), keys: keys) == nil)
                let missingPath = supportDir.appendingPathComponent("Images/nonexistent.png").path
                #expect(try store.encryptAssetIfNeeded(at: missingPath, role: .image, clipID: UUID(), keys: keys) == nil)
                #expect(try store.decryptAssetIfNeeded(at: missingPath, role: .image, clipID: UUID(), keys: keys) == nil)

                // 2. .png -> .enc -> .png byte-identical conversion with zero PNG magic inside .enc
                //    plus hard-link verification that managed source inode is zero-filled before unlink.
                let pngClipID = UUID()
                let pngData = try TestSupport.makePNGData(pixelWidth: 40, pixelHeight: 30, color: .systemPurple)
                let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                #expect(pngData.starts(with: pngMagic))

                let managedPNGURL = try store.writeAsset(
                    pngData: pngData,
                    role: .image,
                    clipID: pngClipID,
                    encrypted: false,
                    keys: nil
                )
                let observerHardLink = externalDir.appendingPathComponent("png-inode-observer.bin")
                #expect(Darwin.link(managedPNGURL.path, observerHardLink.path) == 0)

                let encryptedPNGPath = try #require(
                    try store.encryptAssetIfNeeded(
                        at: managedPNGURL.path,
                        role: .image,
                        clipID: pngClipID,
                        keys: keys
                    )
                )
                let encryptedPNGURL = URL(fileURLWithPath: encryptedPNGPath)
                #expect(encryptedPNGURL.pathExtension == "enc")
                #expect(!FileManager.default.fileExists(atPath: managedPNGURL.path))

                // Verify secureUnlink scrubbed the managed .png inode with zeroes before unlinking.
                let scrubbedInodeBytes = try Data(contentsOf: observerHardLink)
                #expect(scrubbedInodeBytes.count == pngData.count)
                #expect(scrubbedInodeBytes.allSatisfy { $0 == 0 })

                // Verify zero PNG magic or PNG chunk markers inside .enc.
                let rawEncPNG = try Data(contentsOf: encryptedPNGURL)
                #expect(rawEncPNG.starts(with: ImageAssetStore.encryptedMagic))
                #expect(rawEncPNG.firstRange(of: pngMagic) == nil)
                #expect(rawEncPNG.firstRange(of: Data("IHDR".utf8)) == nil)
                #expect(rawEncPNG.firstRange(of: Data("IEND".utf8)) == nil)

                // Repeated idempotent encryptAssetIfNeeded preserves file intact (same inode & bytes).
                var encStatBefore = stat()
                #expect(Darwin.lstat(encryptedPNGPath, &encStatBefore) == 0)
                let secondEncryptedPNGPath = try #require(
                    try store.encryptAssetIfNeeded(
                        at: encryptedPNGPath,
                        role: .image,
                        clipID: pngClipID,
                        keys: keys
                    )
                )
                var encStatAfter = stat()
                #expect(Darwin.lstat(secondEncryptedPNGPath, &encStatAfter) == 0)
                #expect(secondEncryptedPNGPath == encryptedPNGPath)
                #expect(encStatBefore.st_ino == encStatAfter.st_ino)
                #expect(try Data(contentsOf: encryptedPNGURL) == rawEncPNG)

                // Convert .enc -> .png and verify byte-identical restoration + idempotent decryptAssetIfNeeded.
                let decryptedPNGPath = try #require(
                    try store.decryptAssetIfNeeded(
                        at: encryptedPNGPath,
                        role: .image,
                        clipID: pngClipID,
                        keys: keys
                    )
                )
                let decryptedPNGURL = URL(fileURLWithPath: decryptedPNGPath)
                #expect(decryptedPNGURL.pathExtension == "png")
                #expect(!FileManager.default.fileExists(atPath: encryptedPNGURL.path))
                #expect(try Data(contentsOf: decryptedPNGURL) == pngData)

                var decStatBefore = stat()
                #expect(Darwin.lstat(decryptedPNGPath, &decStatBefore) == 0)
                let secondDecryptedPNGPath = try #require(
                    try store.decryptAssetIfNeeded(
                        at: decryptedPNGPath,
                        role: .image,
                        clipID: pngClipID,
                        keys: keys
                    )
                )
                var decStatAfter = stat()
                #expect(Darwin.lstat(secondDecryptedPNGPath, &decStatAfter) == 0)
                #expect(secondDecryptedPNGPath == decryptedPNGPath)
                #expect(decStatBefore.st_ino == decStatAfter.st_ino)
                #expect(try Data(contentsOf: decryptedPNGURL) == pngData)

                // 3. .ico -> .enc -> .ico byte-identical conversion preserving .ico extension and hiding ICO magic/payload.
                let icoClipID = UUID()
                let icoData = CryptoTestHelpers.makeSampleICOData()
                let icoHeader16 = icoData.prefix(16)
                let icoBodyMarker = Data("CLIPBOOK-ICO-BODY-PAYLOAD-BYTES!".utf8)

                let managedICOURL = try store.writeAsset(
                    pngData: icoData,
                    role: .linkFavicon,
                    clipID: icoClipID,
                    encrypted: false,
                    keys: nil
                )
                #expect(managedICOURL.lastPathComponent == "\(icoClipID.uuidString)-favicon.ico")

                let encryptedICOPath = try #require(
                    try store.encryptAssetIfNeeded(
                        at: managedICOURL.path,
                        role: .linkFavicon,
                        clipID: icoClipID,
                        keys: keys
                    )
                )
                let encryptedICOURL = URL(fileURLWithPath: encryptedICOPath)
                #expect(encryptedICOURL.lastPathComponent == "\(icoClipID.uuidString)-favicon.enc")
                #expect(!FileManager.default.fileExists(atPath: managedICOURL.path))

                let rawEncICO = try Data(contentsOf: encryptedICOURL)
                #expect(rawEncICO.starts(with: ImageAssetStore.encryptedMagic))
                #expect(rawEncICO.prefix(4) != Data([0x00, 0x00, 0x01, 0x00]))
                #expect(rawEncICO.firstRange(of: icoHeader16) == nil)
                #expect(rawEncICO.firstRange(of: icoBodyMarker) == nil)

                let decryptedICOPath = try #require(
                    try store.decryptAssetIfNeeded(
                        at: encryptedICOPath,
                        role: .linkFavicon,
                        clipID: icoClipID,
                        keys: keys
                    )
                )
                let decryptedICOURL = URL(fileURLWithPath: decryptedICOPath)
                #expect(decryptedICOURL.lastPathComponent == "\(icoClipID.uuidString)-favicon.ico")
                #expect(!FileManager.default.fileExists(atPath: encryptedICOURL.path))
                #expect(try Data(contentsOf: decryptedICOURL) == icoData)

                // Idempotent decrypt on .ico preserves .ico intact.
                let secondDecryptedICOPath = try #require(
                    try store.decryptAssetIfNeeded(
                        at: decryptedICOPath,
                        role: .linkFavicon,
                        clipID: icoClipID,
                        keys: keys
                    )
                )
                #expect(secondDecryptedICOPath == decryptedICOPath)
                #expect(try Data(contentsOf: decryptedICOURL) == icoData)

                // 4. Direct multi-chunk (>64 KB) secureUnlink zero-fill + symlink-target safety check.
                let multiChunkURL = supportDir.appendingPathComponent("Images/large-scrub-target.bin")
                let largePayload = Data(repeating: 0x5A, count: 150 * 1024)
                try largePayload.write(to: multiChunkURL)
                let largeObserverURL = externalDir.appendingPathComponent("large-inode-observer.bin")
                #expect(Darwin.link(multiChunkURL.path, largeObserverURL.path) == 0)

                ImageAssetStore.secureUnlink(at: multiChunkURL)
                #expect(!FileManager.default.fileExists(atPath: multiChunkURL.path))
                let scrubbedLarge = try Data(contentsOf: largeObserverURL)
                #expect(scrubbedLarge.count == largePayload.count)
                #expect(scrubbedLarge.allSatisfy { $0 == 0 })

                // secureUnlink on a symlink removes only the symlink and never zeroes the target file.
                let protectedTargetURL = externalDir.appendingPathComponent("protected-target.png")
                try pngData.write(to: protectedTargetURL)
                let symlinkToProtectedURL = supportDir.appendingPathComponent("Images/link-to-protected.png")
                try FileManager.default.createSymbolicLink(at: symlinkToProtectedURL, withDestinationURL: protectedTargetURL)
                ImageAssetStore.secureUnlink(at: symlinkToProtectedURL)
                #expect(!FileManager.default.fileExists(atPath: symlinkToProtectedURL.path))
                #expect(try Data(contentsOf: protectedTargetURL) == pngData)

                // 5. External source paths outside supportDirectory are NEVER unlinked or scrubbed.
                let externalPNGURL = externalDir.appendingPathComponent("user-fixture.png")
                try pngData.write(to: externalPNGURL)
                #expect(!store.isManagedAssetURL(externalPNGURL))

                let importedEncClipID = UUID()
                let importedEncPath = try #require(
                    try store.encryptAssetIfNeeded(
                        at: externalPNGURL.path,
                        role: .image,
                        clipID: importedEncClipID,
                        keys: keys
                    )
                )
                #expect(FileManager.default.fileExists(atPath: externalPNGURL.path))
                #expect(try Data(contentsOf: externalPNGURL) == pngData)
                #expect(
                    try store.readPNGData(
                        at: URL(fileURLWithPath: importedEncPath),
                        role: .image,
                        clipID: importedEncClipID,
                        keys: keys,
                        requiresEncryption: true
                    ) == pngData
                )

                let externalPlainClipID = UUID()
                let importedPlainPath = try #require(
                    try store.decryptAssetIfNeeded(
                        at: externalPNGURL.path,
                        role: .linkPreview,
                        clipID: externalPlainClipID,
                        keys: keys
                    )
                )
                #expect(FileManager.default.fileExists(atPath: externalPNGURL.path))
                #expect(try Data(contentsOf: externalPNGURL) == pngData)
                #expect(try Data(contentsOf: URL(fileURLWithPath: importedPlainPath)) == pngData)
            }
        }
    }
}
