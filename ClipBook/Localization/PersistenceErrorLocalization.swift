import Foundation

@MainActor
enum PersistenceErrorLocalization {
    static func message(for error: Error) -> String {
        if let storeError = error as? HistoryStoreError {
            return historyStoreMessage(for: storeError)
        }
        if let archiveError = error as? ClipBookArchiveError {
            return archiveMessage(for: archiveError)
        }
        return error.localizedDescription
    }

    static func statusTitle(for state: StoreLockState) -> String {
        switch state {
        case .unlocked:
            return L10n.string("History Unlocked")
        case .locked:
            return L10n.string("History Locked")
        case .keyMismatch:
            return L10n.string("History Encryption Key Mismatch")
        }
    }

    static func statusMessage(for state: StoreLockState) -> String {
        switch state {
        case .unlocked:
            return ""
        case .locked(let reason):
            return L10n.string(
                "%@ Unlock Keychain and click Unlock History to resume clipboard capture.",
                keyUnavailableMessage(for: reason)
            )
        case .keyMismatch:
            return L10n.string(
                "The history database was encrypted with a different key than the current Keychain key. Restore the matching Keychain key and click Unlock History."
            )
        }
    }

    private static func historyStoreMessage(for error: HistoryStoreError) -> String {
        switch error {
        case .openFailed:
            return L10n.string("Unable to open the ClipBook history database.")
        case .encryptionKeyUnavailable(let reason):
            return keyUnavailableMessage(for: reason)
        case .encryptionKeyMismatch:
            return L10n.string("The history database was encrypted with a different key than the current Keychain key.")
        case .authenticationFailed:
            return L10n.string("Unable to verify or decrypt protected history data.")
        case .invalidArchiveKeyParameters:
            return L10n.string("The archive encryption passphrase or key derivation parameters are invalid.")
        case .migrationFailed(let message):
            return L10n.string("Unable to migrate the history database: %@", message)
        }
    }

    private static func keyUnavailableMessage(for reason: KeyUnavailableReason) -> String {
        switch reason {
        case .notFound:
            return L10n.string("The history encryption key could not be found in Keychain.")
        case .interactionNotAllowed:
            return L10n.string("Keychain is locked and cannot unlock the history encryption key right now.")
        case .userCanceled:
            return L10n.string("Access to the history encryption key in Keychain was canceled.")
        case .authFailed:
            return L10n.string("Keychain authentication failed while accessing the history encryption key.")
        case .corruptKeyData:
            return L10n.string("The stored history encryption key data is corrupted or invalid.")
        case .unexpectedStatus(let status):
            return L10n.string("Unable to access the history encryption key (Keychain status %@).", String(status))
        }
    }

    private static func archiveMessage(for error: ClipBookArchiveError) -> String {
        switch error {
        case .unsupportedVersion(let version):
            return L10n.string("ClipBook archive version %d is not supported.", version)
        case .missingFile(let fileName):
            return L10n.string("The archive is missing %@.", fileName)
        case .invalidAssetPath(let path):
            return L10n.string("The archive contains an invalid asset path: %@.", path)
        case .passphraseRequired:
            return L10n.string("A passphrase is required to unlock this encrypted ClipBook archive.")
        case .emptyPassphrase:
            return L10n.string("The archive passphrase cannot be empty.")
        case .incorrectPassphrase:
            return L10n.string("The archive passphrase is incorrect.")
        case .corruptedEncryptedArchive(let detail):
            return L10n.string("The encrypted ClipBook archive is damaged or was modified (%@).", detail)
        case .invalidKeyParameters:
            return L10n.string("The archive encryption parameters are invalid or unsupported.")
        }
    }
}
