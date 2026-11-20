import SwiftUI

struct ImportExportSettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var encryptExportWithPassphrase = false
    @State private var activeSheet: ArchiveModalSheet?
    @State private var operationProgress: ArchiveOperationProgress?
    @State private var isSensitiveExportAlertPresented = false
    @State private var pendingConfirmedExportPassphrase: String?
    @State private var pendingVerifiedImport: (url: URL, passphrase: String)?

    private var areArchiveControlsDisabled: Bool {
        activeSheet != nil || operationProgress != nil || model.storeLockState != .unlocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Move ClipBook history and tags between ClipBook installations. Settings are not included."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            if model.storeLockState != .unlocked {
                SettingsSectionGroup(L10n.string("History Locked")) {
                    SettingsRow(
                        title: PersistenceErrorLocalization.statusTitle(for: model.storeLockState),
                        description: PersistenceErrorLocalization.statusMessage(for: model.storeLockState)
                    ) {
                        Button(L10n.string("Unlock History")) {
                            coordinator.retryUnlockHistoryStore()
                        }
                    }
                }
            }

            SettingsSectionGroup(L10n.string("Export")) {
                SettingsToggle(
                    title: L10n.string("Encrypt archive with passphrase"),
                    description: L10n.string("Protect exported history items, tags, and copied image assets with AES-256-GCM encryption."),
                    isOn: $encryptExportWithPassphrase
                )
                .disabled(areArchiveControlsDisabled)

                SettingsRow(
                    title: L10n.string("Export history and tags"),
                    description: L10n.string("Create a ClipBook archive containing history items, tags, and copied image assets.")
                ) {
                    Button(L10n.string("Export...")) {
                        exportArchive()
                    }
                    .disabled(areArchiveControlsDisabled)
                }
            }

            SettingsSectionGroup(L10n.string("Import")) {
                SettingsRow(
                    title: L10n.string("Import history and tags"),
                    description: L10n.string("Import a ClipBook archive. Existing matching items are updated, and existing tags are reused by name.")
                ) {
                    Button(L10n.string("Import...")) {
                        importArchive()
                    }
                    .disabled(areArchiveControlsDisabled)
                }
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismissal) { sheet in
            switch sheet {
            case .createPassphrase:
                ArchivePassphraseSheet(
                    mode: .create,
                    onCancel: {
                        activeSheet = nil
                    },
                    onConfirmExportPassphrase: { passphrase in
                        pendingConfirmedExportPassphrase = passphrase
                        activeSheet = nil
                    },
                    verifyUnlockPassphrase: { _ in },
                    onUnlockVerified: { _ in }
                )
            case .unlockPassphrase(let url):
                ArchivePassphraseSheet(
                    mode: .unlock(url),
                    onCancel: {
                        activeSheet = nil
                    },
                    onConfirmExportPassphrase: { _ in },
                    verifyUnlockPassphrase: { passphrase in
                        try await coordinator.verifyArchivePassphrase(passphrase, for: url)
                    },
                    onUnlockVerified: { passphrase in
                        pendingVerifiedImport = (url, passphrase)
                        activeSheet = nil
                    }
                )
            case .progress:
                if let operationProgress {
                    ArchiveProgressSheet(
                        progress: operationProgress,
                        close: {
                            self.activeSheet = nil
                            self.operationProgress = nil
                        }
                    )
                    .interactiveDismissDisabled(true)
                }
            }
        }
        .alert(
            L10n.string("Export Contains Sensitive Items"),
            isPresented: $isSensitiveExportAlertPresented
        ) {
            Button(L10n.string("Encrypt Archive...")) {
                activeSheet = .createPassphrase
            }
            Button(L10n.string("Skip Sensitive Items")) {
                startExport(mode: .unencryptedSkippingSensitive)
            }
            Button(L10n.string("Export Unencrypted Anyway")) {
                startExport(mode: .unencryptedIncludingSensitive)
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Your clipboard history includes sensitive items such as passwords, API keys, or protected images. Unencrypted archives store them in plain text."))
        }
    }

    private func handleSheetDismissal() {
        if let passphrase = pendingConfirmedExportPassphrase {
            pendingConfirmedExportPassphrase = nil
            startExport(mode: .encrypted(passphrase: passphrase))
        } else if let verifiedImport = pendingVerifiedImport {
            pendingVerifiedImport = nil
            startImport(from: verifiedImport.url, passphrase: verifiedImport.passphrase)
        }
    }

    private func exportArchive() {
        if encryptExportWithPassphrase {
            activeSheet = .createPassphrase
        } else if coordinator.exportableHistoryContainsSensitiveItems() {
            isSensitiveExportAlertPresented = true
        } else {
            startExport(mode: .unencryptedIncludingSensitive)
        }
    }

    private func startExport(mode: ArchiveExportMode) {
        let initialTotalCount: Int
        switch mode {
        case .unencryptedSkippingSensitive:
            initialTotalCount = model.items.filter {
                $0.expiresAt == nil
                    && !SensitiveContent.shouldEncryptAtRest($0)
                    && !$0.hasUnverifiedEncryptedImageAsset
            }.count
        case .unencryptedIncludingSensitive, .encrypted:
            initialTotalCount = model.items.filter { $0.expiresAt == nil }.count
        }

        let didStart = coordinator.beginExportHistoryArchive(
            mode: mode,
            progress: { progress in
                updateProgress(kind: .exportArchive, progress: progress)
            },
            completion: { result in
                switch result {
                case .success(let exportResult):
                    operationProgress = ArchiveOperationProgress(
                        kind: .exportArchive,
                        completedItemCount: exportResult.itemCount,
                        totalItemCount: exportResult.itemCount,
                        result: .success(
                            L10n.string(
                                "Exported %d items and %d tags to %@.",
                                exportResult.itemCount,
                                exportResult.tagCount,
                                exportResult.url.lastPathComponent
                            )
                        )
                    )
                case .failure(let error):
                    let message = PersistenceErrorLocalization.message(for: error)
                    operationProgress = (operationProgress ?? ArchiveOperationProgress(
                        kind: .exportArchive,
                        completedItemCount: 0,
                        totalItemCount: initialTotalCount
                    )).completed(with: .failure(message))
                }
            }
        )
        if didStart {
            operationProgress = ArchiveOperationProgress(
                kind: .exportArchive,
                completedItemCount: 0,
                totalItemCount: initialTotalCount
            )
            activeSheet = .progress
        }
    }

    private func importArchive() {
        guard let url = coordinator.chooseImportArchiveURL() else {
            return
        }
        do {
            let inspection = try coordinator.inspectArchive(at: url)
            if inspection.isEncrypted {
                activeSheet = .unlockPassphrase(url)
            } else {
                startImport(from: url, passphrase: nil)
            }
        } catch {
            operationProgress = ArchiveOperationProgress(
                kind: .importArchive,
                completedItemCount: 0,
                totalItemCount: 0,
                result: .failure(PersistenceErrorLocalization.message(for: error))
            )
            activeSheet = .progress
        }
    }

    private func startImport(from url: URL, passphrase: String?) {
        let didStart = coordinator.performImportHistoryArchive(
            from: url,
            passphrase: passphrase,
            progress: { progress in
                updateProgress(kind: .importArchive, progress: progress)
            },
            completion: { result in
                switch result {
                case .success(let importResult):
                    operationProgress = ArchiveOperationProgress(
                        kind: .importArchive,
                        completedItemCount: importResult.itemCount,
                        totalItemCount: importResult.itemCount,
                        result: .success(
                            L10n.string("Imported %d items and %d tags.", importResult.itemCount, importResult.tagCount)
                        )
                    )
                case .failure(let error):
                    let message = PersistenceErrorLocalization.message(for: error)
                    operationProgress = (operationProgress ?? ArchiveOperationProgress(
                        kind: .importArchive,
                        completedItemCount: 0,
                        totalItemCount: 0
                    )).completed(with: .failure(message))
                }
            }
        )
        if didStart {
            operationProgress = ArchiveOperationProgress(
                kind: .importArchive,
                completedItemCount: 0,
                totalItemCount: 0
            )
            activeSheet = .progress
        }
    }

    private func updateProgress(kind: ArchiveOperationKind, progress: ClipBookArchiveProgress) {
        operationProgress = ArchiveOperationProgress(
            kind: kind,
            completedItemCount: progress.completedItemCount,
            totalItemCount: progress.totalItemCount,
            result: operationProgress?.result
        )
    }
}

private enum ArchiveModalSheet: Identifiable {
    case createPassphrase
    case unlockPassphrase(URL)
    case progress

    var id: String {
        switch self {
        case .createPassphrase:
            return "create"
        case .unlockPassphrase:
            return "unlock"
        case .progress:
            return "progress"
        }
    }
}

private enum ArchivePassphraseSheetMode {
    case create
    case unlock(URL)
}

private struct ArchivePassphraseSheet: View {
    private enum FocusedField: Hashable {
        case passphrase
        case confirmPassphrase
    }

    let mode: ArchivePassphraseSheetMode
    let onCancel: () -> Void
    let onConfirmExportPassphrase: (String) -> Void
    let verifyUnlockPassphrase: (String) async throws -> Void
    let onUnlockVerified: (String) -> Void

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusedField?

    private var nfcPassphrase: String {
        passphrase.precomposedStringWithCanonicalMapping
    }

    private var nfcConfirmPassphrase: String {
        confirmPassphrase.precomposedStringWithCanonicalMapping
    }

    private var isConfirmDisabled: Bool {
        switch mode {
        case .create:
            return nfcPassphrase.isEmpty || nfcPassphrase != nfcConfirmPassphrase
        case .unlock:
            return isVerifying || nfcPassphrase.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            Text(descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(
                L10n.string("Passphrase"),
                text: Binding(
                    get: { passphrase },
                    set: { newValue in
                        passphrase = newValue
                        errorMessage = nil
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(isVerifying)
            .focused($focusedField, equals: .passphrase)
            .onSubmit {
                switch mode {
                case .create:
                    if confirmPassphrase.isEmpty {
                        focusedField = .confirmPassphrase
                    } else if !isConfirmDisabled {
                        submit()
                    }
                case .unlock:
                    if !isConfirmDisabled {
                        submit()
                    }
                }
            }

            if case .create = mode {
                SecureField(
                    L10n.string("Confirm Passphrase"),
                    text: Binding(
                        get: { confirmPassphrase },
                        set: { newValue in
                            confirmPassphrase = newValue
                            errorMessage = nil
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(isVerifying)
                .focused($focusedField, equals: .confirmPassphrase)
                .onSubmit {
                    if !isConfirmDisabled {
                        submit()
                    }
                }

                if !confirmPassphrase.isEmpty && nfcPassphrase != nfcConfirmPassphrase {
                    Text(L10n.string("Passphrases do not match."))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(L10n.string("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isVerifying)

                Button(primaryButtonTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConfirmDisabled)
            }
        }
        .padding(18)
        .frame(width: 420)
        .interactiveDismissDisabled(isVerifying)
        .onAppear {
            focusedField = .passphrase
        }
    }

    private var title: String {
        switch mode {
        case .create:
            return L10n.string("Encrypt Archive")
        case .unlock:
            return L10n.string("Unlock Encrypted Archive")
        }
    }

    private var descriptionText: String {
        switch mode {
        case .create:
            return L10n.string("Enter a passphrase to encrypt this archive. You will need the same passphrase to import or recover it later.")
        case .unlock(let url):
            return L10n.string("Enter the passphrase for %@.", url.lastPathComponent)
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .create:
            return L10n.string("Export...")
        case .unlock:
            return L10n.string("Unlock")
        }
    }

    private func submit() {
        switch mode {
        case .create:
            guard !nfcPassphrase.isEmpty else {
                errorMessage = PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase)
                return
            }
            guard nfcPassphrase == nfcConfirmPassphrase else {
                errorMessage = L10n.string("Passphrases do not match.")
                return
            }
            onConfirmExportPassphrase(nfcPassphrase)
        case .unlock:
            guard !nfcPassphrase.isEmpty else {
                errorMessage = PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase)
                return
            }
            let submittedPassphrase = nfcPassphrase
            isVerifying = true
            errorMessage = nil
            Task { @MainActor in
                do {
                    try await verifyUnlockPassphrase(submittedPassphrase)
                    isVerifying = false
                    onUnlockVerified(submittedPassphrase)
                } catch {
                    isVerifying = false
                    errorMessage = PersistenceErrorLocalization.message(for: error)
                    focusedField = .passphrase
                    DispatchQueue.main.async {
                        focusedField = .passphrase
                    }
                }
            }
        }
    }
}

private enum ArchiveOperationKind {
    case importArchive
    case exportArchive

    var title: String {
        switch self {
        case .importArchive:
            return L10n.string("Importing History")
        case .exportArchive:
            return L10n.string("Exporting History")
        }
    }

    var completedTitle: String {
        switch self {
        case .importArchive:
            return L10n.string("History Imported")
        case .exportArchive:
            return L10n.string("History Exported")
        }
    }

    var failedTitle: String {
        switch self {
        case .importArchive:
            return L10n.string("Import Failed")
        case .exportArchive:
            return L10n.string("Export Failed")
        }
    }
}

private enum ArchiveOperationResult {
    case success(String)
    case failure(String)
}

private struct ArchiveOperationProgress {
    var kind: ArchiveOperationKind
    var completedItemCount: Int
    var totalItemCount: Int
    var result: ArchiveOperationResult?

    var isCompleted: Bool {
        result != nil
    }

    var title: String {
        switch result {
        case .success:
            return kind.completedTitle
        case .failure:
            return kind.failedTitle
        case nil:
            return kind.title
        }
    }

    var fractionCompleted: Double? {
        guard totalItemCount > 0 else {
            return isCompleted ? 1 : nil
        }
        return Double(completedItemCount) / Double(totalItemCount)
    }

    var itemCountText: String {
        L10n.string("(%d/%d)", completedItemCount, totalItemCount)
    }

    var resultText: String? {
        switch result {
        case .success(let message), .failure(let message):
            return message
        case nil:
            return nil
        }
    }

    func completed(with result: ArchiveOperationResult) -> ArchiveOperationProgress {
        ArchiveOperationProgress(
            kind: kind,
            completedItemCount: completedItemCount,
            totalItemCount: totalItemCount,
            result: result
        )
    }
}

private struct ArchiveProgressSheet: View {
    let progress: ArchiveOperationProgress
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.title)
                .font(.headline)

            if let fractionCompleted = progress.fractionCompleted {
                ProgressView(value: fractionCompleted, total: 1)
            } else {
                ProgressView()
            }

            HStack(alignment: .center, spacing: 12) {
                statusLabel

                Spacer()

                if progress.isCompleted {
                    Button(L10n.string("Close"), action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch progress.result {
        case .success(let message):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
            }
            .font(.body)
        case .failure(let message):
            Text(message)
                .font(.body)
        case nil:
            Text(progress.itemCountText)
                .font(.body)
        }
    }
}
