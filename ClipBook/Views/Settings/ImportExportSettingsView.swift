import Combine
import SwiftUI

enum SensitiveExportAlertAction {
    case encrypt
    case skipSensitive
    case includeSensitive
}

@MainActor
final class ImportExportArchiveFlowState: ObservableObject {
    @Published var encryptExportWithPassphrase = false
    @Published var activeSheet: ArchiveModalSheet?
    @Published var operationProgress: ArchiveOperationProgress?
    @Published var isSensitiveExportAlertPresented = false
    @Published var pendingConfirmedExportPassphrase: String?
    @Published var pendingVerifiedImport: (url: URL, passphrase: String)?

    func areArchiveControlsDisabled(storeLockState: StoreLockState) -> Bool {
        activeSheet != nil || operationProgress != nil || storeLockState != .unlocked
    }

    func confirmExportPassphrase(_ passphrase: String) {
        pendingConfirmedExportPassphrase = passphrase
        activeSheet = nil
    }

    func completeUnlockVerification(for url: URL, passphrase: String) {
        pendingVerifiedImport = (url, passphrase)
        activeSheet = nil
    }

    func closeProgress() {
        activeSheet = nil
        operationProgress = nil
    }

    func handleSheetDismissal(
        coordinator: AppCoordinator,
        itemCount: Int,
        exportDestinationURL: URL? = nil
    ) {
        if let passphrase = pendingConfirmedExportPassphrase {
            pendingConfirmedExportPassphrase = nil
            startExport(
                mode: .encrypted(passphrase: passphrase),
                coordinator: coordinator,
                itemCount: itemCount,
                destinationURL: exportDestinationURL
            )
        } else if let verifiedImport = pendingVerifiedImport {
            pendingVerifiedImport = nil
            startImport(
                from: verifiedImport.url,
                passphrase: verifiedImport.passphrase,
                coordinator: coordinator
            )
        }
    }

    func exportArchive(
        coordinator: AppCoordinator,
        itemCount: Int,
        destinationURL: URL? = nil
    ) {
        if encryptExportWithPassphrase {
            activeSheet = .createPassphrase
        } else if coordinator.exportableHistoryContainsSensitiveItems() {
            isSensitiveExportAlertPresented = true
        } else {
            startExport(
                mode: .unencryptedIncludingSensitive,
                coordinator: coordinator,
                itemCount: itemCount,
                destinationURL: destinationURL
            )
        }
    }

    func handleSensitiveExportChoice(
        _ action: SensitiveExportAlertAction,
        coordinator: AppCoordinator,
        itemCount: Int,
        destinationURL: URL? = nil
    ) {
        switch action {
        case .encrypt:
            activeSheet = .createPassphrase
        case .skipSensitive:
            startExport(
                mode: .unencryptedSkippingSensitive,
                coordinator: coordinator,
                itemCount: itemCount,
                destinationURL: destinationURL
            )
        case .includeSensitive:
            startExport(
                mode: .unencryptedIncludingSensitive,
                coordinator: coordinator,
                itemCount: itemCount,
                destinationURL: destinationURL
            )
        }
    }

    func startExport(
        mode: ArchiveExportMode,
        coordinator: AppCoordinator,
        itemCount: Int,
        destinationURL: URL? = nil
    ) {
        let initialTotalCount = itemCount

        let didStart = coordinator.beginExportHistoryArchive(
            mode: mode,
            destinationURL: destinationURL,
            progress: { [weak self] progress in
                self?.updateProgress(kind: .exportArchive, progress: progress)
            },
            completion: { [weak self] result in
                guard let self else { return }
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

    func importArchive(from url: URL, coordinator: AppCoordinator) {
        do {
            let inspection = try coordinator.inspectArchive(at: url)
            if inspection.isEncrypted {
                activeSheet = .unlockPassphrase(url)
            } else {
                startImport(from: url, passphrase: nil, coordinator: coordinator)
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

    func startImport(from url: URL, passphrase: String?, coordinator: AppCoordinator) {
        let didStart = coordinator.performImportHistoryArchive(
            from: url,
            passphrase: passphrase,
            progress: { [weak self] progress in
                self?.updateProgress(kind: .importArchive, progress: progress)
            },
            completion: { [weak self] result in
                guard let self else { return }
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

struct ImportExportSettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var flowState: ImportExportArchiveFlowState

    init(
        model: AppModel,
        flowState: ImportExportArchiveFlowState? = nil
    ) {
        self.model = model
        _flowState = StateObject(wrappedValue: flowState ?? ImportExportArchiveFlowState())
    }

    private var areArchiveControlsDisabled: Bool {
        flowState.areArchiveControlsDisabled(storeLockState: model.storeLockState)
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
                    isOn: $flowState.encryptExportWithPassphrase
                )
                .disabled(areArchiveControlsDisabled)

                SettingsRow(
                    title: L10n.string("Export history and tags"),
                    description: L10n.string("Create a ClipBook archive containing history items, tags, and copied image assets.")
                ) {
                    Button(L10n.string("Export...")) {
                        flowState.exportArchive(coordinator: coordinator, itemCount: model.items.count)
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
                        guard let url = coordinator.chooseImportArchiveURL() else {
                            return
                        }
                        flowState.importArchive(from: url, coordinator: coordinator)
                    }
                    .disabled(areArchiveControlsDisabled)
                }
            }
        }
        .sheet(
            item: $flowState.activeSheet,
            onDismiss: {
                flowState.handleSheetDismissal(coordinator: coordinator, itemCount: model.items.count)
            }
        ) { sheet in
            switch sheet {
            case .createPassphrase:
                ArchivePassphraseSheet(
                    mode: .create,
                    onCancel: {
                        flowState.activeSheet = nil
                    },
                    onConfirmExportPassphrase: { passphrase in
                        flowState.confirmExportPassphrase(passphrase)
                    },
                    verifyUnlockPassphrase: { _ in },
                    onUnlockVerified: { _ in }
                )
            case .unlockPassphrase(let url):
                ArchivePassphraseSheet(
                    mode: .unlock(url),
                    onCancel: {
                        flowState.activeSheet = nil
                    },
                    onConfirmExportPassphrase: { _ in },
                    verifyUnlockPassphrase: { passphrase in
                        try await coordinator.verifyArchivePassphrase(passphrase, for: url)
                    },
                    onUnlockVerified: { passphrase in
                        flowState.completeUnlockVerification(for: url, passphrase: passphrase)
                    }
                )
            case .progress:
                if let operationProgress = flowState.operationProgress {
                    ArchiveProgressSheet(
                        progress: operationProgress,
                        close: {
                            flowState.closeProgress()
                        }
                    )
                    .interactiveDismissDisabled(true)
                }
            }
        }
        .alert(
            L10n.string("Export Contains Sensitive Items"),
            isPresented: $flowState.isSensitiveExportAlertPresented
        ) {
            Button(L10n.string("Encrypt Archive...")) {
                flowState.handleSensitiveExportChoice(
                    .encrypt,
                    coordinator: coordinator,
                    itemCount: model.items.count
                )
            }
            Button(L10n.string("Skip Sensitive Items")) {
                flowState.handleSensitiveExportChoice(
                    .skipSensitive,
                    coordinator: coordinator,
                    itemCount: model.items.count
                )
            }
            Button(L10n.string("Export Unencrypted Anyway")) {
                flowState.handleSensitiveExportChoice(
                    .includeSensitive,
                    coordinator: coordinator,
                    itemCount: model.items.count
                )
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Your clipboard history includes sensitive items such as passwords, API keys, or protected images. Unencrypted archives store them in plain text."))
        }
    }
}

enum ArchiveModalSheet: Identifiable, Equatable {
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

enum ArchivePassphraseSheetMode: Equatable {
    case create
    case unlock(URL)
}

@MainActor
final class ArchivePassphraseSheetModel: ObservableObject {
    let mode: ArchivePassphraseSheetMode
    @Published var passphrase = "" {
        didSet {
            if oldValue != passphrase {
                errorMessage = nil
            }
        }
    }
    @Published var confirmPassphrase = "" {
        didSet {
            if oldValue != confirmPassphrase {
                errorMessage = nil
            }
        }
    }
    @Published private(set) var isVerifying = false
    @Published var errorMessage: String?

    init(mode: ArchivePassphraseSheetMode) {
        self.mode = mode
    }

    var nfcPassphrase: String {
        passphrase.precomposedStringWithCanonicalMapping
    }

    var nfcConfirmPassphrase: String {
        confirmPassphrase.precomposedStringWithCanonicalMapping
    }

    var isConfirmDisabled: Bool {
        switch mode {
        case .create:
            return nfcPassphrase.isEmpty || nfcPassphrase != nfcConfirmPassphrase
        case .unlock:
            return isVerifying || nfcPassphrase.isEmpty
        }
    }

    var showsMismatchWarning: Bool {
        if case .create = mode {
            return !confirmPassphrase.isEmpty && nfcPassphrase != nfcConfirmPassphrase
        }
        return false
    }

    @discardableResult
    func submit(
        onConfirmExportPassphrase: @escaping (String) -> Void,
        verifyUnlockPassphrase: @escaping (String) async throws -> Void,
        onUnlockVerified: @escaping (String) -> Void,
        onUnlockFailed: @escaping () -> Void = {}
    ) -> Task<Void, Never>? {
        switch mode {
        case .create:
            guard !nfcPassphrase.isEmpty else {
                errorMessage = PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase)
                return nil
            }
            guard nfcPassphrase == nfcConfirmPassphrase else {
                errorMessage = L10n.string("Passphrases do not match.")
                return nil
            }
            onConfirmExportPassphrase(nfcPassphrase)
            return nil
        case .unlock:
            guard !isVerifying else {
                return nil
            }
            guard !nfcPassphrase.isEmpty else {
                errorMessage = PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase)
                return nil
            }
            let submittedPassphrase = nfcPassphrase
            isVerifying = true
            errorMessage = nil
            return Task { @MainActor in
                do {
                    try await verifyUnlockPassphrase(submittedPassphrase)
                    isVerifying = false
                    onUnlockVerified(submittedPassphrase)
                } catch {
                    isVerifying = false
                    errorMessage = PersistenceErrorLocalization.message(for: error)
                    onUnlockFailed()
                }
            }
        }
    }
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

    @StateObject private var sheetModel: ArchivePassphraseSheetModel
    @FocusState private var focusedField: FocusedField?

    init(
        mode: ArchivePassphraseSheetMode,
        onCancel: @escaping () -> Void,
        onConfirmExportPassphrase: @escaping (String) -> Void,
        verifyUnlockPassphrase: @escaping (String) async throws -> Void,
        onUnlockVerified: @escaping (String) -> Void
    ) {
        self.mode = mode
        self.onCancel = onCancel
        self.onConfirmExportPassphrase = onConfirmExportPassphrase
        self.verifyUnlockPassphrase = verifyUnlockPassphrase
        self.onUnlockVerified = onUnlockVerified
        _sheetModel = StateObject(wrappedValue: ArchivePassphraseSheetModel(mode: mode))
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
                text: $sheetModel.passphrase
            )
            .textFieldStyle(.roundedBorder)
            .disabled(sheetModel.isVerifying)
            .focused($focusedField, equals: .passphrase)
            .onSubmit {
                switch mode {
                case .create:
                    if sheetModel.confirmPassphrase.isEmpty {
                        focusedField = .confirmPassphrase
                    } else if !sheetModel.isConfirmDisabled {
                        submit()
                    }
                case .unlock:
                    if !sheetModel.isConfirmDisabled {
                        submit()
                    }
                }
            }

            if case .create = mode {
                SecureField(
                    L10n.string("Confirm Passphrase"),
                    text: $sheetModel.confirmPassphrase
                )
                .textFieldStyle(.roundedBorder)
                .disabled(sheetModel.isVerifying)
                .focused($focusedField, equals: .confirmPassphrase)
                .onSubmit {
                    if !sheetModel.isConfirmDisabled {
                        submit()
                    }
                }

                if sheetModel.showsMismatchWarning {
                    Text(L10n.string("Passphrases do not match."))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage = sheetModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if sheetModel.isVerifying {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(L10n.string("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(sheetModel.isVerifying)

                Button(primaryButtonTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheetModel.isConfirmDisabled)
            }
        }
        .padding(18)
        .frame(width: 420)
        .interactiveDismissDisabled(sheetModel.isVerifying)
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
        sheetModel.submit(
            onConfirmExportPassphrase: onConfirmExportPassphrase,
            verifyUnlockPassphrase: verifyUnlockPassphrase,
            onUnlockVerified: onUnlockVerified,
            onUnlockFailed: {
                focusedField = .passphrase
                DispatchQueue.main.async {
                    focusedField = .passphrase
                }
            }
        )
    }
}

enum ArchiveOperationKind: Equatable {
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

enum ArchiveOperationResult: Equatable {
    case success(String)
    case failure(String)
}

struct ArchiveOperationProgress: Equatable {
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
