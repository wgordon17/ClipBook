import Foundation
import Security

nonisolated enum KeyUnavailableReason: Equatable, Sendable {
    case notFound
    case interactionNotAllowed
    case userCanceled
    case authFailed
    case corruptKeyData
    case unexpectedStatus(OSStatus)
}

nonisolated enum HistoryStoreError: LocalizedError, Equatable, Sendable {
    case openFailed
    case encryptionKeyUnavailable(KeyUnavailableReason)
    case encryptionKeyMismatch
    case authenticationFailed
    case invalidArchiveKeyParameters
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            "Unable to open the ClipBook history database."
        case .encryptionKeyUnavailable(let reason):
            switch reason {
            case .notFound:
                "The history encryption key could not be found in Keychain."
            case .interactionNotAllowed:
                "Keychain is locked and cannot unlock the history encryption key right now."
            case .userCanceled:
                "Access to the history encryption key in Keychain was canceled."
            case .authFailed:
                "Keychain authentication failed while accessing the history encryption key."
            case .corruptKeyData:
                "The stored history encryption key data is corrupted or invalid."
            case .unexpectedStatus(let status):
                "Unable to access the history encryption key (Keychain status \(status))."
            }
        case .encryptionKeyMismatch:
            "The history database was encrypted with a different key than the current Keychain key."
        case .authenticationFailed:
            "Unable to verify or decrypt protected history data."
        case .invalidArchiveKeyParameters:
            "The archive encryption passphrase or key derivation parameters are invalid."
        case .migrationFailed(let message):
            "Unable to migrate the history database: \(message)"
        }
    }
}
