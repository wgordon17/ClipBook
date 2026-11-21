@testable import ClipBook
import AppKit
import Foundation
import ImageIO
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Container suite for tests that mutate process-global state such as the `L10n` language,
/// `ImageDragFiles`, `ImageAssetThumbnailLoader.shared`, and `SVGImageRenderer.shared`.
/// Suites nested in `SharedProcessStateTests` run one after the other so process-wide caches,
/// temporary drag directories, and window/localization state never interleave across suites.
@Suite(.serialized)
enum SharedProcessStateTests {}

nonisolated enum TestSQLiteFixtureError: LocalizedError, Equatable, Sendable {
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .prepareFailed(let message):
            "Test SQLite prepare failed: \(message)"
        case .stepFailed(let message):
            "Test SQLite step failed: \(message)"
        }
    }
}

final class TestNoOpUpdateService: UpdateService {
    var isRelaunchingToInstallUpdate: Bool = false
    private(set) var automaticChecksEnabledValues: [Bool] = []

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticChecksEnabledValues.append(enabled)
    }

    func checkForUpdates(presenting window: NSWindow?) {}
}

/// Thread-safe `HistoryStore` wrapper that records `loadingContent`, `upsert`, and `fetchSearchTexts`
/// invocations and provides fault-injection / URL-interception seams for integration tests.
nonisolated final class SpyHistoryStore: HistoryStore, @unchecked Sendable {
    nonisolated struct LoadingContentCall: Equatable, Sendable {
        let id: UUID
        let scope: ClipboardContentScope
    }

    nonisolated struct FetchSearchTextsCall: Equatable, Sendable {
        let ids: [UUID]
        let trashed: Bool
        let tagNamesByID: [ClipBook.Tag.ID: String]
    }

    private nonisolated struct State: Sendable {
        var loadingContentCalls: [LoadingContentCall] = []
        var upsertCallIDs: [UUID] = []
        var fetchSearchTextsCalls: [FetchSearchTextsCall] = []
        var fetchItemsWhereCalls: Int = 0
        var shouldThrowOnFetchSearchTexts = false
        var suppressBrowserURLOnLoadingContent = false
        var resolvedBrowserURLsOnLoadingContent: [URL] = []
    }

    let base: GRDBHistoryStore
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(base: GRDBHistoryStore) {
        self.base = base
    }

    var loadingContentCalls: [LoadingContentCall] {
        state.withLock { $0.loadingContentCalls }
    }

    var upsertCallIDs: [UUID] {
        state.withLock { $0.upsertCallIDs }
    }

    var fetchSearchTextsCalls: [FetchSearchTextsCall] {
        state.withLock { $0.fetchSearchTextsCalls }
    }

    var fetchItemsWhereCalls: Int {
        state.withLock { $0.fetchItemsWhereCalls }
    }

    var resolvedBrowserURLsOnLoadingContent: [URL] {
        state.withLock { $0.resolvedBrowserURLsOnLoadingContent }
    }

    var shouldThrowOnFetchSearchTexts: Bool {
        get { state.withLock { $0.shouldThrowOnFetchSearchTexts } }
        set { state.withLock { $0.shouldThrowOnFetchSearchTexts = newValue } }
    }

    var suppressBrowserURLOnLoadingContent: Bool {
        get { state.withLock { $0.suppressBrowserURLOnLoadingContent } }
        set { state.withLock { $0.suppressBrowserURLOnLoadingContent = newValue } }
    }

    func resetRecordedCalls() {
        state.withLock {
            $0.loadingContentCalls.removeAll()
            $0.upsertCallIDs.removeAll()
            $0.fetchSearchTextsCalls.removeAll()
            $0.fetchItemsWhereCalls = 0
            $0.resolvedBrowserURLsOnLoadingContent.removeAll()
        }
    }

    var lockState: StoreLockState { base.lockState }
    var isOpen: Bool { base.isOpen }
    func retryUnlock() throws { try base.retryUnlock() }
    func flushPendingFreePageRelease() { base.flushPendingFreePageRelease() }
    func close() { base.close() }

    func computeImageDigest(forPNGData pngData: Data) -> String {
        base.computeImageDigest(forPNGData: pngData)
    }

    func writeManagedAsset(
        pngData: Data,
        role: AssetRole,
        clipID: UUID,
        encrypted: Bool,
        preferredPlainExtension: String?
    ) throws -> URL {
        try base.writeManagedAsset(
            pngData: pngData,
            role: role,
            clipID: clipID,
            encrypted: encrypted,
            preferredPlainExtension: preferredPlainExtension
        )
    }

    func finalizeRecognizedImage(
        id: UUID,
        content: RecognizedImageContent,
        sensitiveContentLifetime: Int
    ) throws -> (updated: ClipboardItem?, previous: ClipboardItem?, isTrashed: Bool, purged: Bool) {
        try base.finalizeRecognizedImage(
            id: id,
            content: content,
            sensitiveContentLifetime: sensitiveContentLifetime
        )
    }

    func fetchAll() throws -> [ClipboardItem] { try base.fetchAll() }
    func fetchTrashedItems() throws -> [ClipboardItem] { try base.fetchTrashedItems() }
    func fetchItems(trashedBefore date: Date) throws -> [ClipboardItem] { try base.fetchItems(trashedBefore: date) }
    func moveToTrash(ids: [UUID], at date: Date) throws { try base.moveToTrash(ids: ids, at: date) }
    func restoreFromTrash(ids: [UUID]) throws { try base.restoreFromTrash(ids: ids) }
    func fetchTags() throws -> [ClipBook.Tag] { try base.fetchTags() }
    func capture(_ item: ClipboardItem, updatesCopySequence: Bool) throws -> ClipboardItem {
        try base.capture(item, updatesCopySequence: updatesCopySequence)
    }

    func upsert(_ item: ClipboardItem) throws {
        state.withLock { $0.upsertCallIDs.append(item.id) }
        try base.upsert(item)
    }

    @discardableResult
    func saveAndReconcileItem(_ item: ClipboardItem, convertingExternalAssets: Bool) throws -> ClipboardItem {
        try base.saveAndReconcileItem(item, convertingExternalAssets: convertingExternalAssets)
    }

    func setSensitivity(_ sensitivity: ItemSensitivity?, for id: UUID) throws -> ClipboardItem? {
        try base.setSensitivity(sensitivity, for: id)
    }

    func loadingContent(of item: ClipboardItem, scope: ClipboardContentScope) throws -> ClipboardItem {
        let hydrated = try base.loadingContent(of: item, scope: scope)
        let shouldSuppressBrowserURL = state.withLock { state -> Bool in
            state.loadingContentCalls.append(LoadingContentCall(id: item.id, scope: scope))
            if let url = hydrated.browserURL {
                state.resolvedBrowserURLsOnLoadingContent.append(url)
            }
            return state.suppressBrowserURLOnLoadingContent
        }
        if shouldSuppressBrowserURL {
            var suppressed = hydrated
            suppressed.text = "not a valid url"
            return suppressed
        }
        return hydrated
    }

    func createTag(name: String, color: String) throws -> ClipBook.Tag { try base.createTag(name: name, color: color) }
    func updateTag(id: ClipBook.Tag.ID, name: String, color: String) throws -> ClipBook.Tag { try base.updateTag(id: id, name: name, color: color) }
    func deleteTag(id: ClipBook.Tag.ID) throws { try base.deleteTag(id: id) }
    func delete(_ id: UUID) throws { try base.delete(id) }
    func delete(ids: [UUID]) throws { try base.delete(ids: ids) }
    func clear() throws { try base.clear() }
    func clear(keepingFavoritesAndTaggedItems: Bool) throws { try base.clear(keepingFavoritesAndTaggedItems: keepingFavoritesAndTaggedItems) }
    func recordAction(_ id: UUID, copiedAt: Date?, incrementsCopyCount: Bool) throws -> ClipboardItem? {
        try base.recordAction(id, copiedAt: copiedAt, incrementsCopyCount: incrementsCopyCount)
    }
    func fetchItems(expiredBy policy: HistoryRetentionPolicy) throws -> [ClipboardItem] { try base.fetchItems(expiredBy: policy) }
    func fetchItems(expiringBy date: Date) throws -> [ClipboardItem] { try base.fetchItems(expiringBy: date) }
    func nextExpiryDate() throws -> Date? { try base.nextExpiryDate() }
    func fetchItem(kind: ClipboardKind, contentKey: String, htmlDigest: String?) throws -> ClipboardItem? {
        try base.fetchItem(kind: kind, contentKey: contentKey, htmlDigest: htmlDigest)
    }
    func fetchStoredFilePaths() throws -> Set<String> { try base.fetchStoredFilePaths() }

    func fetchSearchTexts(
        for ids: [UUID],
        trashed: Bool,
        tagNamesByID: [ClipBook.Tag.ID: String],
        isCancelled: () -> Bool
    ) throws -> [String?]? {
        let shouldThrow = state.withLock { state -> Bool in
            state.fetchSearchTextsCalls.append(
                FetchSearchTextsCall(ids: ids, trashed: trashed, tagNamesByID: tagNamesByID)
            )
            return state.shouldThrowOnFetchSearchTexts
        }
        if shouldThrow {
            throw TestSQLiteFixtureError.stepFailed("Simulated fetchSearchTexts failure")
        }
        return try base.fetchSearchTexts(
            for: ids,
            trashed: trashed,
            tagNamesByID: tagNamesByID,
            isCancelled: isCancelled
        )
    }

    func fetchItems(where isIncluded: (ClipboardItem) -> Bool) throws -> [ClipboardItem] {
        state.withLock { $0.fetchItemsWhereCalls += 1 }
        return try base.fetchItems(where: isIncluded)
    }

    func fetchMostRecentItem(where isIncluded: (ClipboardItem) -> Bool) throws -> ClipboardItem? {
        try base.fetchMostRecentItem(where: isIncluded)
    }

    func performInTransaction(_ body: () throws -> Void) throws {
        try base.performInTransaction(body)
    }
}

struct RenderedViewSnapshot {
    let image: NSImage
    let bitmap: NSBitmapImageRep
    let pngData: Data

    var pixelWidth: Int { bitmap.pixelsWide }
    var pixelHeight: Int { bitmap.pixelsHigh }
}

@MainActor
final class TestCoordinatorHarness {
    let coordinator: AppCoordinator
    let model: AppModel
    let historyStore: GRDBHistoryStore
    let preferencesStore: PreferencesStore
    let clipboardMonitor: PasteboardMonitor
    let globalShortcuts: GlobalShortcutService
    let updateService: TestNoOpUpdateService
    let pasteboard: NSPasteboard
    let userDefaultsSuiteName: String
    let supportDirectory: URL

    private var isCleanedUp = false

    init(
        coordinator: AppCoordinator,
        model: AppModel,
        historyStore: GRDBHistoryStore,
        preferencesStore: PreferencesStore,
        clipboardMonitor: PasteboardMonitor,
        globalShortcuts: GlobalShortcutService,
        updateService: TestNoOpUpdateService,
        pasteboard: NSPasteboard,
        userDefaultsSuiteName: String,
        supportDirectory: URL
    ) {
        self.coordinator = coordinator
        self.model = model
        self.historyStore = historyStore
        self.preferencesStore = preferencesStore
        self.clipboardMonitor = clipboardMonitor
        self.globalShortcuts = globalShortcuts
        self.updateService = updateService
        self.pasteboard = pasteboard
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.supportDirectory = supportDirectory
    }

    /// Stores `items` and loads them into the model, as if they had been captured earlier.
    func seedHistory(_ items: [ClipboardItem]) throws {
        for item in items {
            try historyStore.saveAndReconcileItem(item, convertingExternalAssets: true)
        }
        coordinator.loadHistory()
    }

    /// The item with `id` as the model currently shows it.
    func currentItem(_ id: ClipboardItem.ID) -> ClipboardItem? {
        model.items.first { $0.id == id }
    }

    func trashedIDs() throws -> [ClipboardItem.ID] {
        try historyStore.fetchTrashedItems().map(\.id)
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        coordinator.stopBackgroundWorkForTesting()
        coordinator.cancelBackgroundMaintenance()
        historyStore.close()
        pasteboard.releaseGlobally()
        TestSupport.removeDefaultsSuite(named: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: supportDirectory)
    }

    deinit {
        let suiteName = userDefaultsSuiteName
        let supportDir = supportDirectory
        if !isCleanedUp {
            coordinator.cancelOrphanedFileSweeps(waitUntilDone: true)
            historyStore.close()
            TestSupport.removeDefaultsSuite(named: suiteName)
            try? FileManager.default.removeItem(at: supportDir)
        }
    }
}

enum TestSupport {
    static let snapshotScale = 2

    @MainActor
    static func ensureAppKitInitialized() {
        _ = NSApplication.shared
    }

    /// Waits, letting the main actor run, until `condition` holds. Returns whether it did within `timeout`.
    @MainActor
    static func waitUntil(timeout: Duration = .seconds(45), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    static func keyDownEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    /// An empty 8-bit RGBA bitmap of the given pixel size.
    static func makeBitmap(pixelsWide: Int, pixelsHigh: Int) throws -> NSBitmapImageRep {
        try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
    }

    static func makePNGData(
        pixelWidth: Int = 32,
        pixelHeight: Int = 24,
        dpi: Double = 72.0,
        color: NSColor = .systemBlue
    ) throws -> Data {
        let rep = try makeBitmap(pixelsWide: pixelWidth, pixelsHigh: pixelHeight)
        rep.size = NSSize(
            width: Double(pixelWidth) * 72.0 / dpi,
            height: Double(pixelHeight) * 72.0 / dpi
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else {
            throw CocoaError(.coderInvalidValue)
        }
        let output = NSMutableData()
        let dest = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return output as Data
    }

    static func makePDFData(width: CGFloat = 64, height: CGFloat = 48) -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        if let consumer = CGDataConsumer(data: pdfData as CFMutableData),
           let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fill(mediaBox)
            context.endPDFPage()
            context.closePDF()
        }
        return pdfData as Data
    }

    static func makeRTFData(text: String) throws -> Data {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
        )
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // The helpers that tests with `await` in them use have a synchronous and an `async` form,
    // because a closure cannot be both. The setup and the cleanup are shared.

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    static func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    static func withTemporaryHistoryStore<T>(_ body: (GRDBHistoryStore, URL) throws -> T) throws -> T {
        try withTemporaryDirectory { directory in
            let store = GRDBHistoryStore(
                directory: directory,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { store.close() }
            return try body(store, directory)
        }
    }

    static func withUniquePasteboard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        return try body(pasteboard)
    }

    static func withUniquePasteboard<T>(_ body: (NSPasteboard) async throws -> T) async rethrows -> T {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        return try await body(pasteboard)
    }

    /// Removes the preferences of a test suite, and the empty property list that removing the domain leaves behind.
    nonisolated static func removeDefaultsSuite(named suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let propertyList = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: propertyList)
    }

    static func withIsolatedUserDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "com.ikryanov.clipbook.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { removeDefaultsSuite(named: suiteName) }
        return try body(defaults)
    }

    @MainActor
    static func makeTestCoordinator() throws -> TestCoordinatorHarness {
        ensureAppKitInitialized()
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ClipBookCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let suiteName = "com.ikryanov.clipbook.coordinator.tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        let pasteboard = NSPasteboard.withUniqueName()
        let historyStore = GRDBHistoryStore(
            directory: supportDirectory,
            keyProvider: InMemoryDatabaseKeyProvider()
        )
        let preferencesStore = PreferencesStore(userDefaults: userDefaults)

        var initialPreferences = AppPreferences()
        initialPreferences.warnOnClearHistory = false
        // The coordinator's sound service is not injectable, so tests that
        // delete, paste or merge would otherwise play real audio.
        initialPreferences.soundEffectsEnabled = false
        // Saving applies launch at login for real. Turned off, a save can only
        // unregister the Debug build, which is never registered, rather than add
        // it as a login item.
        initialPreferences.launchAtLogin = false
        // Keep link-preview network fetches off unless a test explicitly enables them.
        initialPreferences.showPreviewForLinks = false
        preferencesStore.save(initialPreferences)

        let model = AppModel()
        model.preferences = initialPreferences

        let globalShortcuts = GlobalShortcutService(isEnabled: false)
        let updateService = TestNoOpUpdateService()
        let licensingService = LicensingService()
        let clipboardMonitor = PasteboardMonitor(
            historyStore: historyStore,
            fileManager: fileManager,
            supportDirectory: supportDirectory,
            pasteboard: pasteboard
        )

        let pasteService = PasteService(
            pasteboard: pasteboard,
            loadContent: { [historyStore] item, scope in
                try historyStore.loadingContent(of: item, scope: scope)
            }
        )
        let coordinator = AppCoordinator(
            model: model,
            preferencesStore: preferencesStore,
            historyStore: historyStore,
            clipboardMonitor: clipboardMonitor,
            pasteService: pasteService,
            globalShortcuts: globalShortcuts,
            updateService: updateService,
            licensingService: licensingService,
            fileManager: fileManager,
            supportDirectory: supportDirectory
        )

        return TestCoordinatorHarness(
            coordinator: coordinator,
            model: model,
            historyStore: historyStore,
            preferencesStore: preferencesStore,
            clipboardMonitor: clipboardMonitor,
            globalShortcuts: globalShortcuts,
            updateService: updateService,
            pasteboard: pasteboard,
            userDefaultsSuiteName: suiteName,
            supportDirectory: supportDirectory
        )
    }

    @MainActor
    static func makeSpiedTestCoordinator(
        recognizeImageData: @escaping @Sendable (Data) -> RecognizedImageContent = ImageTextRecognizer.recognizeContent(ofPNGData:),
        recognizeImageFile: @escaping @Sendable (URL) -> RecognizedImageContent = ImageTextRecognizer.recognizeContent(ofImageAt:)
    ) throws -> (harness: TestCoordinatorHarness, spyStore: SpyHistoryStore, pasteService: PasteService) {
        ensureAppKitInitialized()
        let fileManager = FileManager.default
        let supportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ClipBookSpiedCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let suiteName = "com.ikryanov.clipbook.coordinator.tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        let pasteboard = NSPasteboard.withUniqueName()
        let baseStore = GRDBHistoryStore(
            directory: supportDirectory,
            keyProvider: InMemoryDatabaseKeyProvider()
        )
        let spyStore = SpyHistoryStore(base: baseStore)
        let preferencesStore = PreferencesStore(userDefaults: userDefaults)

        var initialPreferences = AppPreferences()
        initialPreferences.warnOnClearHistory = false
        initialPreferences.soundEffectsEnabled = false
        initialPreferences.launchAtLogin = false
        initialPreferences.showPreviewForLinks = false
        preferencesStore.save(initialPreferences)

        let model = AppModel()
        model.preferences = initialPreferences

        let globalShortcuts = GlobalShortcutService(isEnabled: false)
        let updateService = TestNoOpUpdateService()
        let licensingService = LicensingService()
        let clipboardMonitor = PasteboardMonitor(
            historyStore: spyStore,
            fileManager: fileManager,
            supportDirectory: supportDirectory,
            pasteboard: pasteboard,
            recognizeImageData: recognizeImageData,
            recognizeImageFile: recognizeImageFile
        )
        let pasteService = PasteService(
            pasteboard: pasteboard,
            loadContent: { [spyStore] item, scope in
                try spyStore.loadingContent(of: item, scope: scope)
            }
        )
        let coordinator = AppCoordinator(
            model: model,
            preferencesStore: preferencesStore,
            historyStore: spyStore,
            clipboardMonitor: clipboardMonitor,
            pasteService: pasteService,
            globalShortcuts: globalShortcuts,
            updateService: updateService,
            licensingService: licensingService,
            fileManager: fileManager,
            supportDirectory: supportDirectory
        )
        clipboardMonitor.delegate = coordinator
        clipboardMonitor.updatePreferences(initialPreferences)

        let harness = TestCoordinatorHarness(
            coordinator: coordinator,
            model: model,
            historyStore: baseStore,
            preferencesStore: preferencesStore,
            clipboardMonitor: clipboardMonitor,
            globalShortcuts: globalShortcuts,
            updateService: updateService,
            pasteboard: pasteboard,
            userDefaultsSuiteName: suiteName,
            supportDirectory: supportDirectory
        )
        return (harness, spyStore, pasteService)
    }

    @MainActor
    private static func collectDrainTargets(from roots: [AnyObject]) -> [AnyObject] {
        var visited = Set<ObjectIdentifier>()
        var collected: [AnyObject] = []

        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            collected.append(object)

            if let historyWindow = object as? HistoryWindow {
                visit(historyWindow.window)
            } else if let window = object as? NSWindow {
                if let contentVC = window.contentViewController {
                    visit(contentVC)
                }
                for accessory in window.titlebarAccessoryViewControllers {
                    visit(accessory)
                }
                if let contentView = window.contentView {
                    visit(contentView)
                }
            } else if let controller = object as? NSViewController {
                for child in controller.children {
                    visit(child)
                }
                for presented in controller.presentedViewControllers ?? [] {
                    visit(presented)
                }
                if controller.isViewLoaded {
                    visit(controller.view)
                }
            } else if let view = object as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        for root in roots {
            visit(root)
        }
        return collected
    }

    @MainActor
    static func drainDelayedPerforms(_ targets: [AnyObject]) {
        let allTargets = collectDrainTargets(from: targets)
        withExtendedLifetime((targets, allTargets)) {
            for target in allTargets {
                NSObject.cancelPreviousPerformRequests(withTarget: target)
            }
        }
    }

    @MainActor
    static func tearDownWindow(_ window: NSWindow, keepingAlive extraTargets: [AnyObject] = []) {
        drainDelayedPerforms([window] + extraTargets)
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
        drainDelayedPerforms([window] + extraTargets)
    }

    @MainActor
    static func tearDownHistoryWindow(_ historyWindow: HistoryWindow, keepingAlive extraTargets: [AnyObject] = []) {
        tearDownWindow(historyWindow.window, keepingAlive: [historyWindow] + extraTargets)
    }

    @MainActor
    @discardableResult
    static func renderOffscreenView(
        _ view: NSView,
        size: NSSize = NSSize(width: 480, height: 120),
        appearance: NSAppearance.Name = .aqua
    ) throws -> RenderedViewSnapshot {
        ensureAppKitInitialized()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.appearance = NSAppearance(named: appearance)
        view.frame = container.bounds
        view.appearance = NSAppearance(named: appearance)
        container.addSubview(view)
        window.contentView = container
        defer {
            window.orderOut(nil)
            NSObject.cancelPreviousPerformRequests(withTarget: view)
        }

        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        container.displayIfNeeded()

        // Render at a fixed 2x so that snapshots do not depend on the display this runs on.
        let bounds = container.bounds
        let bitmap = try makeBitmap(
            pixelsWide: Int(bounds.width) * snapshotScale,
            pixelsHigh: Int(bounds.height) * snapshotScale
        )
        bitmap.size = bounds.size
        container.cacheDisplay(in: bounds, to: bitmap)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

        return RenderedViewSnapshot(image: image, bitmap: bitmap, pngData: pngData)
    }

    @MainActor
    @discardableResult
    static func renderOffscreenSwiftUIView<Content: View>(
        _ rootView: Content,
        size: NSSize = NSSize(width: 640, height: 480),
        appearance: NSAppearance.Name = .aqua
    ) throws -> RenderedViewSnapshot {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        return try renderOffscreenView(
            hostingView,
            size: size,
            appearance: appearance
        )
    }
}

extension HistoryItemRowView {
    /// Configures the row the way a 480-point-wide history table does when sensitive
    /// content is detected and kept hidden.
    func configureForTest(
        item: ClipboardItem,
        quickPasteIndex: Int = 1,
        searchQuery: String = "",
        itemTags: [ClipBook.Tag] = [],
        linkPreview: LinkPreview? = nil,
        showsLinkPreview: Bool = false
    ) {
        configure(
            item: item,
            quickPasteIndex: quickPasteIndex,
            tableWidth: 480,
            searchQuery: searchQuery,
            itemTags: itemTags,
            linkPreview: linkPreview,
            showsLinkPreview: showsLinkPreview,
            detectsSensitiveContent: true,
            revealsSensitiveContent: false
        )
    }
}

extension ClipboardItem {
    static func fixture(
        id: UUID = UUID(),
        kind: ClipboardKind = .text,
        title: String? = nil,
        text: String? = "Sample clipboard text",
        qrCodeText: String? = nil,
        rtfData: Data? = nil,
        html: String? = nil,
        assetPath: String? = nil,
        imageDigest: String? = nil,
        filePaths: [String] = [],
        sourceAppName: String? = "TestApp",
        sourceBundleIdentifier: String? = "com.example.test",
        copiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        firstCopiedAt: Date? = nil,
        byteSize: Int? = nil,
        isFavorite: Bool = false,
        tags: [Int] = [],
        searchText: String? = nil,
        copyCount: Int = 1,
        linkPreviewDetails: LinkPreviewDetails? = nil,
        copySequenceID: Date? = nil,
        copySequenceOrder: Int? = nil,
        favoriteOrder: Int? = nil,
        sensitivity: ItemSensitivity? = nil,
        deletedAt: Date? = nil
    ) -> ClipboardItem {
        let computedByteSize = byteSize ?? (text?.utf8.count ?? 0)
        var item = ClipboardItem(
            id: id,
            kind: kind,
            title: title,
            text: text,
            qrCodeText: qrCodeText,
            rtfData: rtfData,
            html: html,
            assetPath: assetPath,
            imageDigest: imageDigest,
            filePaths: filePaths,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            copiedAt: copiedAt,
            firstCopiedAt: firstCopiedAt,
            byteSize: computedByteSize,
            isFavorite: isFavorite,
            tags: tags,
            searchText: searchText,
            copyCount: copyCount,
            linkPreviewDetails: linkPreviewDetails,
            copySequenceID: copySequenceID,
            copySequenceOrder: copySequenceOrder,
            favoriteOrder: favoriteOrder,
            sensitivity: sensitivity
        )
        item.deletedAt = deletedAt
        return item
    }
}

/// The helpers every other suite builds on.
@Suite
struct TestSupportTests {
    @Test
    func temporaryHistoryStoreIsIsolatedAndRemoved() throws {
        var removedDirectory: URL?
        try TestSupport.withTemporaryHistoryStore { store, directory in
            removedDirectory = directory
            let fixture = ClipboardItem.fixture(
                kind: .text,
                text: "Hello",
                sourceAppName: "TestApp",
                sourceBundleIdentifier: "com.example.test"
            )
            let captured = try store.capture(fixture, updatesCopySequence: false)
            #expect(captured.text == "Hello")
            #expect(captured.sourceAppName == "TestApp")
            #expect(captured.sourceBundleIdentifier == "com.example.test")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("History.sqlite").path))
            #expect(try store.fetchAll().map(\.id) == [captured.id])
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(removedDirectory).path))
    }

    @Test
    func uniquePasteboardIsNotTheGeneralPasteboard() {
        TestSupport.withUniquePasteboard { pasteboard in
            pasteboard.clearContents()
            #expect(pasteboard.setString("Hello", forType: .string))
            #expect(pasteboard.string(forType: .string) == "Hello")
            #expect(pasteboard.name != NSPasteboard.general.name)
        }
    }

    @Test
    func isolatedUserDefaultsKeepPreferencesApart() throws {
        try TestSupport.withIsolatedUserDefaults { defaults in
            let store = PreferencesStore(userDefaults: defaults)
            var preferences = store.load()
            preferences.historySortOption = HistorySortOption.size.rawValue
            store.save(preferences)
            #expect(store.load().historySortOption == HistorySortOption.size.rawValue)
        }
        try TestSupport.withIsolatedUserDefaults { defaults in
            #expect(PreferencesStore(userDefaults: defaults).load().historySortOption != HistorySortOption.size.rawValue)
        }
    }

    @Test
    @MainActor
    func coordinatorHarnessStartsQuietAndCleansUp() throws {
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }
        #expect(!harness.model.preferences.warnOnClearHistory)
        #expect(!harness.model.preferences.soundEffectsEnabled)
        #expect(!harness.model.preferences.showPreviewForLinks)

        harness.cleanup()
        #expect(!FileManager.default.fileExists(atPath: harness.supportDirectory.path))
    }

    @Test
    @MainActor
    func offscreenRenderingUsesAFixedScale() throws {
        let snapshot = try TestSupport.renderOffscreenView(
            NSTextField(labelWithString: "Hello"),
            size: NSSize(width: 240, height: 48),
            appearance: .aqua
        )
        #expect(snapshot.pixelWidth == 240 * TestSupport.snapshotScale)
        #expect(snapshot.pixelHeight == 48 * TestSupport.snapshotScale)
        #expect(!snapshot.pngData.isEmpty)
    }
}

