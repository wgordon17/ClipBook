import CryptoKit
import Darwin
import Foundation
import os
import Security

nonisolated protocol DatabaseKeyProvider: Sendable {
    func loadOrCreateMasterKey(canCreateNewKey: Bool) throws -> SymmetricKey
}

nonisolated enum MasterKeyHexCodec {
    static let rawKeyByteCount = 32
    static let encodedHexByteCount = 64

    static func encode(_ key: SymmetricKey) -> Data {
        var hexBytes = [UInt8](repeating: 0, count: encodedHexByteCount)
        defer {
            hexBytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
        }

        key.withUnsafeBytes { rawBuffer in
            precondition(rawBuffer.count == rawKeyByteCount)
            for index in 0..<rawKeyByteCount {
                let byte = rawBuffer[index]
                hexBytes[index * 2] = lowercaseHexASCII(forNibble: byte >> 4)
                hexBytes[index * 2 + 1] = lowercaseHexASCII(forNibble: byte & 0x0F)
            }
        }

        return Data(hexBytes)
    }

    static func decode(_ data: Data) throws -> SymmetricKey {
        guard data.count == encodedHexByteCount else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        return try data.withUnsafeBytes { rawBuffer in
            try decodeHexBuffer(rawBuffer)
        }
    }

    fileprivate static func decodeHexBuffer(_ rawBuffer: UnsafeRawBufferPointer) throws -> SymmetricKey {
        guard rawBuffer.count == encodedHexByteCount else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        var decoded = [UInt8](repeating: 0, count: rawKeyByteCount)
        defer {
            decoded.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
        }

        for index in 0..<rawKeyByteCount {
            guard let high = nibble(forLowercaseHexASCII: rawBuffer[index * 2]),
                  let low = nibble(forLowercaseHexASCII: rawBuffer[index * 2 + 1]) else {
                throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
            }
            decoded[index] = (high << 4) | low
        }

        return decoded.withUnsafeBytes { SymmetricKey(data: $0) }
    }

    private static func lowercaseHexASCII(forNibble nibble: UInt8) -> UInt8 {
        nibble < 10 ? (0x30 + nibble) : (0x61 + (nibble - 10))
    }

    private static func nibble(forLowercaseHexASCII ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39:
            return ascii - 0x30
        case 0x61...0x66:
            return ascii - 0x61 + 10
        default:
            return nil
        }
    }
}

nonisolated struct SecItemClient: Sendable {
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    init(
        copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) },
        add: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemAdd($0, $1) }
    ) {
        self.copyMatching = copyMatching
        self.add = add
    }

    static let live = SecItemClient()
}

nonisolated struct SystemKeychainKeyProvider: DatabaseKeyProvider, Sendable {
    static let service = "com.ikryanov.clipbook.v2.encryption"
    static let account = "master-key-v1"

    private let client: SecItemClient
    private let allowsTestClient: Bool

    init(client: SecItemClient = .live, allowsTestClient: Bool = false) {
        precondition((!AppDelegate.isRunningTests && !AppDirectories.usesIsolatedDebugStorage) || allowsTestClient)
        self.client = client
        self.allowsTestClient = allowsTestClient
    }

    func loadOrCreateMasterKey(canCreateNewKey: Bool) throws -> SymmetricKey {
        precondition((!AppDelegate.isRunningTests && !AppDirectories.usesIsolatedDebugStorage) || allowsTestClient)

        if let existingKey = try readExistingKey() {
            return existingKey
        }

        guard canCreateNewKey else {
            throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
        }

        let newKey = SymmetricKey(size: .bits256)
        let hexData = MasterKeyHexCodec.encode(newKey)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: hexData,
        ]

        let addStatus = client.add(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return newKey
        case errSecDuplicateItem:
            if let racedKey = try readExistingKey() {
                return racedKey
            }
            throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
        default:
            throw HistoryStoreError.encryptionKeyUnavailable(Self.mapStatus(addStatus))
        }
    }

    private func readExistingKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
            }
            return try MasterKeyHexCodec.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw HistoryStoreError.encryptionKeyUnavailable(Self.mapStatus(status))
        }
    }

    static func mapStatus(_ status: OSStatus) -> KeyUnavailableReason {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed
        case errSecUserCanceled:
            return .userCanceled
        case errSecAuthFailed:
            return .authFailed
        default:
            return .unexpectedStatus(status)
        }
    }
}

nonisolated struct FileDatabaseKeyProvider: DatabaseKeyProvider, Sendable {
    static let fileName = ".devkey"

    let supportDirectory: URL

    var keyFileURL: URL {
        supportDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    func loadOrCreateMasterKey(canCreateNewKey: Bool) throws -> SymmetricKey {
        if let existingKey = try readExistingKey() {
            return existingKey
        }

        guard canCreateNewKey else {
            throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
        }

        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        var dirStat = stat()
        guard Darwin.lstat(supportDirectory.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        let newKey = SymmetricKey(size: .bits256)
        var hexData = MasterKeyHexCodec.encode(newKey)
        defer {
            hexData.resetBytes(in: 0..<hexData.count)
        }

        let path = keyFileURL.path
        let fd = Darwin.open(path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 {
            let err = errno
            if err == EEXIST {
                if let racedKey = try readExistingKey() {
                    return racedKey
                }
                throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
            }
            if err == ELOOP {
                throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
            }
            throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(err)))
        }

        do {
            _ = Darwin.fchmod(fd, mode_t(0o600))
            try hexData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var writtenTotal = 0
                while writtenTotal < rawBuffer.count {
                    let result = Darwin.write(fd, baseAddress.advanced(by: writtenTotal), rawBuffer.count - writtenTotal)
                    if result > 0 {
                        writtenTotal += result
                    } else if result < 0 && errno == EINTR {
                        continue
                    } else {
                        throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(errno)))
                    }
                }
            }
            if Darwin.fcntl(fd, F_FULLFSYNC) != 0 {
                _ = Darwin.fsync(fd)
            }
            if Darwin.close(fd) != 0 {
                throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(errno)))
            }
        } catch {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(path)
            throw error
        }

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var url = keyFileURL
        try? url.setResourceValues(resourceValues)

        return newKey
    }

    private func readExistingKey() throws -> SymmetricKey? {
        let path = keyFileURL.path
        var linkStat = stat()
        if Darwin.lstat(path, &linkStat) != 0 {
            let err = errno
            if err == ENOENT {
                return nil
            }
            throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(err)))
        }

        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            let err = errno
            if err == ENOENT {
                return nil
            }
            if err == ELOOP {
                throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
            }
            throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(err)))
        }
        defer {
            _ = Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size == off_t(MasterKeyHexCodec.encodedHexByteCount) else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        var readBuffer = [UInt8](repeating: 0, count: MasterKeyHexCodec.encodedHexByteCount + 1)
        defer {
            readBuffer.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
        }

        var totalRead = 0
        try readBuffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while totalRead < rawBuffer.count {
                let count = Darwin.read(fd, baseAddress.advanced(by: totalRead), rawBuffer.count - totalRead)
                if count > 0 {
                    totalRead += count
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    throw HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(OSStatus(errno)))
                }
            }
        }

        guard totalRead == MasterKeyHexCodec.encodedHexByteCount else {
            throw HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData)
        }

        return try readBuffer.withUnsafeBytes { rawBuffer in
            let prefix = UnsafeRawBufferPointer(rebasing: rawBuffer.prefix(MasterKeyHexCodec.encodedHexByteCount))
            return try MasterKeyHexCodec.decodeHexBuffer(prefix)
        }
    }
}

nonisolated final class InMemoryDatabaseKeyProvider: DatabaseKeyProvider, Sendable {
    private struct State: Sendable {
        var key: SymmetricKey?
        var error: HistoryStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(key: SymmetricKey? = SymmetricKey(size: .bits256), error: HistoryStoreError? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State(key: key, error: error))
    }

    func setKey(_ key: SymmetricKey?) {
        state.withLock { $0.key = key }
    }

    func setError(_ error: HistoryStoreError?) {
        state.withLock { $0.error = error }
    }

    func loadOrCreateMasterKey(canCreateNewKey: Bool) throws -> SymmetricKey {
        try state.withLock { state in
            if let error = state.error {
                throw error
            }
            if let key = state.key {
                return key
            }
            guard canCreateNewKey else {
                throw HistoryStoreError.encryptionKeyUnavailable(.notFound)
            }
            let newKey = SymmetricKey(size: .bits256)
            state.key = newKey
            return newKey
        }
    }
}
