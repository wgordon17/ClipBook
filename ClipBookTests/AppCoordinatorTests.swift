@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import Testing

@Suite
enum AppCoordinatorTests {
    @Suite
    struct HistoryMutationTests {
        private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        /// A text item copied `offset` seconds after `baseDate`.
        private static func textItem(_ text: String, at offset: TimeInterval, sensitivity: ItemSensitivity? = nil) -> ClipboardItem {
            .fixture(kind: .text, text: text, copiedAt: baseDate.addingTimeInterval(offset), sensitivity: sensitivity)
        }

        @Test
        @MainActor
        func mergingTextThatIsALinkJoinsTheExistingLinkItem() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let url = "https://example.com/docs"
            let existingLink = ClipboardItem.fixture(
                kind: .link,
                text: url,
                copiedAt: Self.baseDate.addingTimeInterval(10),
                firstCopiedAt: Self.baseDate
            )
            let part1 = Self.textItem(url, at: 30)
            let part2 = Self.textItem("   ", at: 20)
            try harness.seedHistory([Self.textItem("Unrelated clip", at: 40), part1, part2, existingLink])

            harness.coordinator.merge([part1, part2])

            let merged = try #require(harness.model.items.first)
            #expect(merged.kind == .link)
            #expect(!merged.isContentLoaded)
            #expect(merged.storedContentKey != nil)
            #expect(harness.model.items.filter { $0.kind == .link && $0.hasSameContent(as: merged) }.count == 1)
        }

        @Test
        @MainActor
        func mergingAHexColorWithBlankTextYieldsAColorItem() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let part1 = Self.textItem("#ff0000", at: 50)
            let part2 = Self.textItem("   ", at: 45)
            try harness.seedHistory([part1, part2])

            harness.coordinator.merge([part1, part2])

            #expect(harness.model.items.first?.kind == .color)
        }

        @Test
        @MainActor
        func splitClassifiesLinesAndPlacesAtTop() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let multiLineItem = Self.textItem("alpha\nbeta\nhttps://example.com", at: 200)
            try harness.seedHistory([multiLineItem])

            harness.coordinator.split(multiLineItem)

            let items = harness.model.items
            #expect(items.count == 4)
            #expect(items.allSatisfy { !$0.isContentLoaded })
            #expect(items[0].previewText == "alpha")
            #expect(items[1].previewText == "beta")
            #expect(items[2].kind == .link)
            #expect(items[2].previewText == "https://example.com")
            #expect(try harness.historyStore.loadingContent(of: items[0], scope: .body).text == "alpha")
        }

        @Test
        @MainActor
        func transformingFormattedTextAppliesEachTransformAndDropsTheFormatting() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let formatted = ClipboardItem.fixture(
                kind: .richText,
                text: "  Hello World  ",
                rtfData: Data("{\\rtf1\\ansi bold}".utf8),
                html: "<b>Hello World</b>",
                copiedAt: Self.baseDate.addingTimeInterval(200)
            )
            try harness.seedHistory([formatted])
            #expect(try #require(harness.currentItem(formatted.id)).hasFormatting)

            harness.coordinator.transform(try #require(harness.currentItem(formatted.id)), using: .trimSurroundingWhitespaces)
            harness.coordinator.transform(try #require(harness.currentItem(formatted.id)), using: .upperCase)

            let transformed = try #require(harness.currentItem(formatted.id))
            #expect(!transformed.isContentLoaded)
            #expect(transformed.previewText == "HELLO WORLD")
            #expect(try harness.historyStore.loadingContent(of: transformed, scope: .body).text == "HELLO WORLD")
            #expect(transformed.kind == .text)
            #expect(!transformed.hasFormatting)
        }

        @Test
        @MainActor
        func editingContentReclassifiesTheItem() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let item = Self.textItem("HELLO WORLD", at: 200)
            try harness.seedHistory([item])

            harness.coordinator.editContent(item, text: "user@example.com")

            #expect(harness.currentItem(item.id)?.kind == .email)
        }

        @Test
        @MainActor
        func editingContentToBlankTrashesTheItemAndUndoRestoresIt() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let item = Self.textItem("Soon blank", at: 200)
            try harness.seedHistory([item])

            harness.coordinator.editContent(item, text: "   \n  ")
            #expect(harness.currentItem(item.id) == nil)
            #expect(try harness.trashedIDs() == [item.id])

            harness.coordinator.undoHistoryChange()
            #expect(harness.currentItem(item.id) != nil)
            #expect(try harness.trashedIDs().isEmpty)
        }

        @Test
        @MainActor
        func sensitiveItemsAreDeletedPermanentlyInsteadOfTrashed() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let secretToken = ["sk", "-proj-", String(repeating: "aB3dE5fG", count: 4)].joined()
            let autoDetectedSecret = Self.textItem("API Key: \(secretToken)", at: 200)
            let markedSensitive = Self.textItem("Marked sensitive manually", at: 300, sensitivity: .sensitive)
            let normal = Self.textItem("Normal note", at: 100)
            try harness.seedHistory([normal, autoDetectedSecret, markedSensitive])

            harness.coordinator.delete([autoDetectedSecret, markedSensitive])

            #expect(harness.model.items.map(\.id) == [normal.id])
            #expect(try harness.trashedIDs().isEmpty)
        }

        @Test
        @MainActor
        func deletingMovesAnItemToTheTrashAndUndoAndRedoMoveItBack() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let item = Self.textItem("Normal note to trash", at: 100)
            try harness.seedHistory([item])

            harness.coordinator.delete(item)
            #expect(harness.currentItem(item.id) == nil)
            #expect(try harness.trashedIDs() == [item.id])

            harness.coordinator.undoHistoryChange()
            #expect(harness.currentItem(item.id) != nil)
            #expect(try harness.trashedIDs().isEmpty)

            harness.coordinator.redoHistoryChange()
            #expect(harness.currentItem(item.id) == nil)
            #expect(try harness.trashedIDs() == [item.id])
        }
    }

    @Suite
    struct RebootTests {
        private static let bootTime: TimeInterval = 1_800_000_000

        @Test
        func firstLaunchIsNotAReboot() {
            #expect(!AppCoordinator.isReboot(previousBootTime: nil, currentBootTime: Self.bootTime))
        }

        /// `previousOffset` is the stored boot time relative to the current one.
        /// A stored time ahead of the current one, such as `Date() - systemUptime`
        /// (which runs ahead of the real boot time by the time spent asleep) or a
        /// clock adjustment, never looks like a reboot.
        @Test(arguments: [
            (previousOffset: 86_400.0, isReboot: false),
            (previousOffset: 3_600.0, isReboot: false),
            (previousOffset: 1.0, isReboot: false),
            (previousOffset: 0.0, isReboot: false),
            (previousOffset: -59.0, isReboot: false),
            (previousOffset: -60.0, isReboot: false),
            (previousOffset: -61.0, isReboot: true),
            (previousOffset: -3_600.0, isReboot: true)
        ])
        func onlyALaterBootTimeIsAReboot(previousOffset: Double, isReboot: Bool) {
            #expect(
                AppCoordinator.isReboot(previousBootTime: Self.bootTime + previousOffset, currentBootTime: Self.bootTime)
                    == isReboot
            )
        }

        @Test
        @MainActor
        func systemBootTimeIsBeforeNowAndNotAfterTheUptimeEstimate() {
            let boot = AppCoordinator.systemBootTime()
            let now = Date()
            #expect(boot.timeIntervalSince1970 > 0)
            #expect(boot < now)
            // Uptime pauses during sleep, so `now - uptime` is never earlier than the real boot time.
            #expect(boot.timeIntervalSince1970 <= now.timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + 1)
        }

        @Test
        @MainActor
        func clearHistoryAfterRebootUsesInjectedDefaultsWithoutTouchingStandardDefaults() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let standardKernelBefore = UserDefaults.standard.object(forKey: PreferencesStore.kernelBootTimeKey) as? Double
            let standardLegacyBefore = UserDefaults.standard.object(forKey: PreferencesStore.legacyUptimeBootTimeKey) as? Double

            #expect(harness.preferencesStore.lastKnownKernelBootTime() == nil)
            harness.model.preferences.clearHistoryOnReboot = true
            let item = ClipboardItem.fixture(text: "First launch clip")
            try harness.seedHistory([item])

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_000_000,
                uptimeRelativeBootTime: 1_700_000_120
            )

            #expect((UserDefaults.standard.object(forKey: PreferencesStore.kernelBootTimeKey) as? Double) == standardKernelBefore)
            #expect((UserDefaults.standard.object(forKey: PreferencesStore.legacyUptimeBootTimeKey) as? Double) == standardLegacyBefore)
            #expect(harness.preferencesStore.lastKnownKernelBootTime() == 1_700_000_000)
            #expect(harness.preferencesStore.userDefaults.object(forKey: PreferencesStore.kernelBootTimeKey) as? Double == 1_700_000_000)
            #expect(harness.preferencesStore.userDefaults.object(forKey: PreferencesStore.legacyUptimeBootTimeKey) as? Double == 1_700_000_120)
            #expect(harness.model.items.map(\.id) == [item.id])
        }

        @Test
        @MainActor
        func sleepDriftKeepsLegacyBootTimeWarmWithoutClearingHistory() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            harness.model.preferences.clearHistoryOnReboot = true
            let item = ClipboardItem.fixture(text: "Survives sleep")
            try harness.seedHistory([item])

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_000_000,
                uptimeRelativeBootTime: 1_700_000_000
            )
            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_000_000,
                uptimeRelativeBootTime: 1_700_007_200
            )

            #expect(harness.model.items.map(\.id) == [item.id])
            #expect(harness.preferencesStore.userDefaults.object(forKey: PreferencesStore.kernelBootTimeKey) as? Double == 1_700_000_000)
            let legacyBootTime = try #require(
                harness.preferencesStore.userDefaults.object(forKey: PreferencesStore.legacyUptimeBootTimeKey) as? Double
            )
            #expect(legacyBootTime == 1_700_007_200)
            #expect(abs(legacyBootTime - 1_700_007_200) <= 60)
        }

        @Test
        @MainActor
        func advancingKernelBootTimePastThresholdClearsNonFavoritedHistoryWhenEnabled() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            harness.model.preferences.clearHistoryOnReboot = true
            harness.model.preferences.keepFavoritesOnClearHistory = true
            let favorite = ClipboardItem.fixture(text: "Pinned", isFavorite: true)
            let regular = ClipboardItem.fixture(text: "Ephemeral")
            try harness.seedHistory([favorite, regular])

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_000_000,
                uptimeRelativeBootTime: 1_700_007_200
            )
            #expect(harness.model.items.count == 2)

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_020_000,
                uptimeRelativeBootTime: 1_700_020_000
            )

            #expect(harness.model.items.map(\.id) == [favorite.id])
            #expect(harness.preferencesStore.lastKnownKernelBootTime() == 1_700_020_000)
            #expect(harness.preferencesStore.userDefaults.object(forKey: PreferencesStore.legacyUptimeBootTimeKey) as? Double == 1_700_020_000)
        }

        /// The first launch after updating from a build that stored only the
        /// uptime estimate: a restart since then clears the history.
        @Test
        @MainActor
        func firstLaunchAfterUpdateDetectsARebootFromTheLegacyBootTime() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            harness.model.preferences.clearHistoryOnReboot = true
            let item = ClipboardItem.fixture(text: "From before the restart")
            try harness.seedHistory([item])
            // Written by the earlier build: the boot time plus two hours of sleep.
            harness.preferencesStore.userDefaults.set(1_700_007_200.0, forKey: PreferencesStore.legacyUptimeBootTimeKey)
            #expect(harness.preferencesStore.lastKnownKernelBootTime() == nil)

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_100_000,
                uptimeRelativeBootTime: 1_700_100_000
            )

            #expect(harness.model.items.isEmpty)
            #expect(harness.preferencesStore.lastKnownKernelBootTime() == 1_700_100_000)
        }

        /// The legacy estimate runs ahead of the real boot time by the time spent
        /// asleep, so without a restart it never looks like a reboot.
        @Test
        @MainActor
        func firstLaunchAfterUpdateIgnoresSleepInTheLegacyBootTime() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            harness.model.preferences.clearHistoryOnReboot = true
            let item = ClipboardItem.fixture(text: "Survives the update")
            try harness.seedHistory([item])
            harness.preferencesStore.userDefaults.set(1_700_007_200.0, forKey: PreferencesStore.legacyUptimeBootTimeKey)

            harness.coordinator.clearHistoryAfterRebootIfNeeded(
                kernelBootTime: 1_700_000_000,
                uptimeRelativeBootTime: 1_700_010_800
            )

            #expect(harness.model.items.map(\.id) == [item.id])
            #expect(harness.preferencesStore.lastKnownKernelBootTime() == 1_700_000_000)
        }
    }

    @Suite
    struct PasteNextTests {
        @Test
        @MainActor
        func skipsPinnedFavoritesUnlessFavoritesFilterIsActive() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let favorite = ClipboardItem.fixture(text: "Favorite", isFavorite: true)
            let first = ClipboardItem.fixture(text: "First")
            let second = ClipboardItem.fixture(text: "Second")
            let items = [favorite, first, second]

            harness.model.preferences.pinFavoritesToTop = true
            #expect(harness.coordinator.historyItemsForPasteNext(in: items).map(\.id) == [first.id, second.id])

            harness.model.selectedHistoryFilterContentTypes = [.favorites]
            #expect(harness.coordinator.historyItemsForPasteNext(in: items).map(\.id) == items.map(\.id))

            harness.model.selectedHistoryFilterContentTypes = []
            harness.model.preferences.pinFavoritesToTop = false
            #expect(harness.coordinator.historyItemsForPasteNext(in: items).map(\.id) == items.map(\.id))
        }

        @Test
        @MainActor
        func fallsBackToAllItemsWhenOnlyFavoritesExist() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let favorites = [
                ClipboardItem.fixture(text: "Favorite A", isFavorite: true),
                ClipboardItem.fixture(text: "Favorite B", isFavorite: true)
            ]
            harness.model.preferences.pinFavoritesToTop = true

            #expect(harness.coordinator.historyItemsForPasteNext(in: favorites).map(\.id) == favorites.map(\.id))
            #expect(harness.coordinator.historyItemsForPasteNext(in: []).isEmpty)
        }
    }

    @Suite
    struct AppDelegateTests {
        @Test
        @MainActor
        func aTestRunUsesStorageOfItsOwnAndRemovesItWhenTheProcessTerminates() throws {
            let delegate = AppDelegate()
            let directory = try #require(delegate.scratchStorageForTests.directory)
            let suiteName = try #require(delegate.scratchStorageForTests.suiteName)
            #expect(suiteName.hasPrefix("com.ikryanov.clipbook.apptests."))
            #expect(directory.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
            #expect(directory.standardizedFileURL != AppDirectories.applicationSupport(fileManager: .default).standardizedFileURL)

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.set("kept until termination", forKey: "probe")
            #expect(defaults.string(forKey: "probe") == "kept until termination")

            // Removing the storage and stopping the coordinator are alternatives in `applicationWillTerminate`,
            // so the removal below also shows that the coordinator was not stopped.
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(UserDefaults(suiteName: suiteName)?.string(forKey: "probe") == nil)
        }
    }

    @Suite(.serialized)
    struct ZeroPlaintextAndSecurityCoordinatorTests {
        private static func makeSecretToken(tag: String) -> String {
            ["sk", "-proj-", tag, "-", String(repeating: "z8N4vR2k", count: 4)].joined()
        }

        private static func makeWiFiQRSecret(passwordTag: String) -> String {
            ["WIFI:S:Corp", passwordTag, ";T:WPA;P:secr3t-", passwordTag, "-2026;;"].joined()
        }

        private static func databaseDiskBytes(in supportDirectory: URL) -> Data {
            var combined = Data()
            for name in ["History.sqlite", "History.sqlite-wal"] {
                let url = supportDirectory.appendingPathComponent(name, isDirectory: false)
                if let fileData = try? Data(contentsOf: url) {
                    combined.append(fileData)
                }
            }
            return combined
        }

        nonisolated private final class OCRGate: @unchecked Sendable {
            private let lock = NSLock()
            private var shouldSuspend = false
            private var nextResult = RecognizedImageContent.empty
            private var enteredSemaphore = DispatchSemaphore(value: 0)
            private var resumeSemaphore = DispatchSemaphore(value: 0)

            func armSuspended(returning content: RecognizedImageContent) {
                lock.withLock {
                    shouldSuspend = true
                    nextResult = content
                    enteredSemaphore = DispatchSemaphore(value: 0)
                    resumeSemaphore = DispatchSemaphore(value: 0)
                }
            }

            func setImmediate(returning content: RecognizedImageContent) {
                lock.withLock {
                    shouldSuspend = false
                    nextResult = content
                }
            }

            func waitForEntry(timeout: DispatchTimeInterval = .seconds(5)) -> Bool {
                let sem = lock.withLock { enteredSemaphore }
                return sem.wait(timeout: .now() + timeout) == .success
            }

            func resume(returning overrideContent: RecognizedImageContent? = nil) {
                let sem: DispatchSemaphore = lock.withLock {
                    if let overrideContent {
                        nextResult = overrideContent
                    }
                    shouldSuspend = false
                    return resumeSemaphore
                }
                sem.signal()
            }

            func run() -> RecognizedImageContent {
                let (suspend, entered, resume): (Bool, DispatchSemaphore, DispatchSemaphore) = lock.withLock {
                    (shouldSuspend, enteredSemaphore, resumeSemaphore)
                }
                if suspend {
                    entered.signal()
                    _ = resume.wait(timeout: .now() + .seconds(15))
                }
                return lock.withLock { nextResult }
            }
        }

        @MainActor
        private static func makeCustomHarness(
            supportDirectory: URL? = nil,
            keyProvider: any DatabaseKeyProvider = InMemoryDatabaseKeyProvider(),
            probeStoreBeforeInit: Bool = false,
            now: @escaping @Sendable () -> Date = { Date() },
            recognizeImageData: @escaping @Sendable (Data) -> RecognizedImageContent = { _ in .empty },
            recognizeImageFile: @escaping @Sendable (URL) -> RecognizedImageContent = { _ in .empty },
            configureInitialPreferences: ((inout AppPreferences) -> Void)? = nil
        ) throws -> TestCoordinatorHarness {
            TestSupport.ensureAppKitInitialized()
            let fileManager = FileManager.default
            let resolvedSupportDir: URL
            if let supportDirectory {
                resolvedSupportDir = supportDirectory
                try fileManager.createDirectory(at: resolvedSupportDir, withIntermediateDirectories: true)
            } else {
                resolvedSupportDir = fileManager.temporaryDirectory
                    .appendingPathComponent("ClipBookC5Tests-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: resolvedSupportDir, withIntermediateDirectories: true)
            }

            let suiteName = "com.ikryanov.clipbook.c5tests.\(UUID().uuidString)"
            let userDefaults = try #require(UserDefaults(suiteName: suiteName))
            userDefaults.removePersistentDomain(forName: suiteName)

            let pasteboard = NSPasteboard.withUniqueName()
            let historyStore = GRDBHistoryStore(
                directory: resolvedSupportDir,
                keyProvider: keyProvider
            )
            if probeStoreBeforeInit {
                _ = try? historyStore.fetchAll()
            }
            let preferencesStore = PreferencesStore(userDefaults: userDefaults)

            var initialPreferences = AppPreferences()
            initialPreferences.warnOnClearHistory = false
            initialPreferences.soundEffectsEnabled = false
            initialPreferences.launchAtLogin = false
            initialPreferences.showPreviewForLinks = false
            configureInitialPreferences?(&initialPreferences)
            preferencesStore.save(initialPreferences)

            let model = AppModel()
            model.preferences = initialPreferences

            let globalShortcuts = GlobalShortcutService(isEnabled: false)
            let updateService = TestNoOpUpdateService()
            let licensingService = LicensingService()
            let clipboardMonitor = PasteboardMonitor(
                historyStore: historyStore,
                fileManager: fileManager,
                supportDirectory: resolvedSupportDir,
                pasteboard: pasteboard,
                now: now,
                recognizeImageData: recognizeImageData,
                recognizeImageFile: recognizeImageFile
            )
            clipboardMonitor.delegate = nil
            clipboardMonitor.updatePreferences(initialPreferences)

            let pasteService = PasteService(
                pasteboard: pasteboard,
                loadContent: { [historyStore] item, scope in
                    (try? historyStore.loadingContent(of: item, scope: scope)) ?? item
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
                supportDirectory: resolvedSupportDir
            )
            clipboardMonitor.delegate = coordinator

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
                supportDirectory: resolvedSupportDir
            )
        }

        @Test
        @MainActor
        func zeroPlaintextScreenshotLifecycleStagesEncryptedAndEnforcesAllPostOCROutcomes() async throws {
            defer { ImageDragFiles.removeAll() }

            let imageGate = OCRGate()
            let fileGate = OCRGate()
            let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_710_000_000))
            let harness = try Self.makeCustomHarness(
                now: { clock.withLock { $0 } },
                recognizeImageData: { _ in imageGate.run() },
                recognizeImageFile: { _ in fileGate.run() }
            )
            defer { harness.cleanup() }

            let imagesDir = harness.supportDirectory.appendingPathComponent("Images", isDirectory: true)
            let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

            // --- Outcome (a): Empty OCR demotes Images/<id>.enc -> Images/<id>.png and scrubs .enc ---
            let pngA = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 16, color: .systemRed)
            imageGate.armSuspended(returning: .empty)
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngA, forType: .png)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let itemA = try #require(harness.model.items.first)
            let enteredInFlightA = await Task.detached { imageGate.waitForEntry() }.value
            #expect(enteredInFlightA)
            #expect(harness.coordinator.isImageRecognitionPending(for: itemA.id))

            let inFlightEntriesA = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path)
            #expect(inFlightEntriesA == ["\(itemA.id.uuidString).enc"])
            #expect(inFlightEntriesA.allSatisfy { !$0.hasSuffix(".png") })
            let stagedEncURLA = imagesDir.appendingPathComponent("\(itemA.id.uuidString).enc")
            let stagedRawA = try Data(contentsOf: stagedEncURLA)
            #expect(stagedRawA.starts(with: ImageAssetStore.encryptedMagic))
            #expect(stagedRawA.firstRange(of: pngMagic) == nil)

            imageGate.resume()
            let demotedA = await TestSupport.waitUntil {
                !harness.coordinator.isImageRecognitionPending(for: itemA.id)
                    && harness.currentItem(itemA.id)?.assetPath?.hasSuffix(".png") == true
            }
            #expect(demotedA)
            #expect(!FileManager.default.fileExists(atPath: stagedEncURLA.path))
            let demotedPathA = try #require(harness.currentItem(itemA.id)?.assetPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: demotedPathA)) == pngA)

            // --- Outcome (b): Benign OCR demotes Images/<id>.enc -> Images/<id>.png ---
            clock.withLock { $0 = $0.addingTimeInterval(10) }
            let pngB = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 16, color: .systemGreen)
            imageGate.setImmediate(returning: RecognizedImageContent(text: "Benign quarterly chart", qrCodeText: nil))
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngB, forType: .png)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let itemB = try #require(harness.model.items.first)
            let demotedB = await TestSupport.waitUntil {
                harness.currentItem(itemB.id)?.assetPath?.hasSuffix(".png") == true
                    && harness.currentItem(itemB.id)?.previewText == "Benign quarterly chart"
            }
            #expect(demotedB)
            #expect(try harness.historyStore.loadingContent(of: try #require(harness.currentItem(itemB.id)), scope: .body).text == "Benign quarterly chart")
            #expect(!FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("\(itemB.id.uuidString).enc").path))

            // --- Outcome (c1): Active .image secret OCR/QR with sensitiveContentLifetime == .dontSave purges SQLite/WAL/.enc & scrubs ImageDragFiles ---
            harness.model.preferences.sensitiveContentLifetime = ContentLifetime.dontSave
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)
            clock.withLock { $0 = $0.addingTimeInterval(10) }

            let secretC1 = Self.makeSecretToken(tag: "ocr-c1")
            let qrSecretC1 = Self.makeWiFiQRSecret(passwordTag: "c1wifi")
            #expect(SensitiveContent.shouldEncryptAtRest(.fixture(kind: .image, text: secretC1)))
            #expect(SensitiveContent.shouldEncryptAtRest(.fixture(kind: .image, text: nil, qrCodeText: qrSecretC1)))

            let pngC1 = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 18, color: .systemOrange)
            imageGate.armSuspended(returning: RecognizedImageContent(text: "Bearer \(secretC1)", qrCodeText: qrSecretC1))
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngC1, forType: .png)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let itemC1 = try #require(harness.model.items.first)
            #expect(await Task.detached { imageGate.waitForEntry() }.value)
            let encURLC1 = imagesDir.appendingPathComponent("\(itemC1.id.uuidString).enc")
            #expect(FileManager.default.fileExists(atPath: encURLC1.path))

            // Simulate user dragging the pre-OCR image to create a named temp file before OCR finishes.
            let preOCRDragURL = try #require(
                ImageDragFiles.makeCopy(
                    of: encURLC1,
                    named: ".env-keys.png",
                    ownerClipID: itemC1.id,
                    requiresEncryption: false
                )
            )
            let preOCRDragFD = Darwin.open(preOCRDragURL.path, O_RDONLY)
            #expect(preOCRDragFD >= 0)
            defer {
                if preOCRDragFD >= 0 { Darwin.close(preOCRDragFD) }
            }

            imageGate.resume()
            let purgedC1 = await TestSupport.waitUntil {
                harness.currentItem(itemC1.id) == nil
                    && !FileManager.default.fileExists(atPath: encURLC1.path)
            }
            #expect(purgedC1)
            #expect(try !harness.historyStore.fetchAll().contains { $0.id == itemC1.id })
            #expect(!FileManager.default.fileExists(atPath: preOCRDragURL.path), "didRecognize purge must scrub ImageDragFiles")
            var dragZeroBuf = [UInt8](repeating: 0xFF, count: 16)
            #expect(Darwin.pread(preOCRDragFD, &dragZeroBuf, dragZeroBuf.count, 0) == dragZeroBuf.count)
            #expect(dragZeroBuf.allSatisfy { $0 == 0 })

            harness.historyStore.flushPendingFreePageRelease()
            let diskC1 = Self.databaseDiskBytes(in: harness.supportDirectory)
            #expect(diskC1.firstRange(of: Data(secretC1.utf8)) == nil)
            #expect(diskC1.firstRange(of: Data(qrSecretC1.utf8)) == nil)
            #expect(diskC1.firstRange(of: Data(encURLC1.path.utf8)) == nil)

            // --- Outcome (c2): Moved to Trash while model.isShowingTrash == false during in-flight OCR + .dontSave ---
            clock.withLock { $0 = $0.addingTimeInterval(10) }
            let secretC2 = Self.makeSecretToken(tag: "ocr-trash-c2")
            let pngC2 = try TestSupport.makePNGData(pixelWidth: 30, pixelHeight: 20, color: .systemPurple)
            imageGate.armSuspended(returning: RecognizedImageContent(text: "Secret \(secretC2)", qrCodeText: nil))
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngC2, forType: .png)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let itemC2 = try #require(harness.model.items.first)
            #expect(await Task.detached { imageGate.waitForEntry() }.value)
            let encURLC2 = imagesDir.appendingPathComponent("\(itemC2.id.uuidString).enc")

            // Move itemC2 to Trash before OCR completes while model.isShowingTrash == false.
            #expect(!harness.model.isShowingTrash)
            harness.coordinator.delete(itemC2)
            #expect(harness.currentItem(itemC2.id) == nil)
            #expect(try harness.trashedIDs().contains(itemC2.id))
            #expect(FileManager.default.fileExists(atPath: encURLC2.path))

            imageGate.resume()
            let purgedTrashedC2 = await TestSupport.waitUntil {
                ((try? harness.trashedIDs()) ?? [itemC2.id]).contains(itemC2.id) == false
                    && !FileManager.default.fileExists(atPath: encURLC2.path)
            }
            #expect(purgedTrashedC2)
            harness.historyStore.flushPendingFreePageRelease()
            let diskC2 = Self.databaseDiskBytes(in: harness.supportDirectory)
            #expect(diskC2.firstRange(of: Data(secretC2.utf8)) == nil)
            #expect(diskC2.firstRange(of: Data(encURLC2.path.utf8)) == nil)

            // --- Outcome (c3): Image .file clip with secret OCR/QR and sensitiveContentLifetime == .dontSave ---
            try await TestSupport.withTemporaryDirectory { externalDir in
                let externalImageURL = externalDir.appendingPathComponent("scan-invoice-c3.png")
                try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 32, color: .systemTeal).write(to: externalImageURL)

                // Warm ImageAssetThumbnailLoader.shared for the external file path so didRecognize must evict it.
                var warmedExternal = false
                if ImageAssetThumbnailLoader.shared.thumbnail(
                    for: externalImageURL,
                    maximumPixelSize: 128,
                    completion: { _ in warmedExternal = true }
                ) != nil {
                    warmedExternal = true
                }
                #expect(await TestSupport.waitUntil { warmedExternal })

                let secretC3 = Self.makeSecretToken(tag: "file-ocr-c3")
                fileGate.armSuspended(returning: RecognizedImageContent(text: nil, qrCodeText: "otpauth://totp/Corp?secret=\(secretC3)"))
                clock.withLock { $0 = $0.addingTimeInterval(10) }
                harness.pasteboard.clearContents()
                #expect(harness.pasteboard.writeObjects([externalImageURL as NSURL]))
                await harness.clipboardMonitor.pollAndWaitForDelivery()

                let fileItemC3 = try #require(harness.model.items.first)
                #expect(fileItemC3.kind == .file)
                #expect(await Task.detached { fileGate.waitForEntry() }.value)

                fileGate.resume()
                let purgedFileC3 = await TestSupport.waitUntil {
                    harness.currentItem(fileItemC3.id) == nil
                }
                #expect(purgedFileC3)
                #expect(FileManager.default.fileExists(atPath: externalImageURL.path), "User's external image file must never be deleted")
                #expect(
                    ImageAssetThumbnailLoader.shared.thumbnail(
                        for: externalImageURL,
                        maximumPixelSize: 128,
                        completion: { _ in }
                    ) == nil,
                    "Purged .file clip must evict its external path from ImageAssetThumbnailLoader.shared"
                )
                harness.historyStore.flushPendingFreePageRelease()
                let diskC3 = Self.databaseDiskBytes(in: harness.supportDirectory)
                #expect(diskC3.firstRange(of: Data(secretC3.utf8)) == nil)
                #expect(diskC3.firstRange(of: Data("scan-invoice-c3.png".utf8)) == nil)
            }

            // --- Outcome (d): Secret OCR/QR with sensitiveContentLifetime == 60 on both .image and image .file ---
            harness.model.preferences.sensitiveContentLifetime = 60
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)
            let copiedAtD = Date(timeIntervalSince1970: 2_000_000_000)
            clock.withLock { $0 = copiedAtD }

            let secretDImage = Self.makeSecretToken(tag: "ocr-d-img")
            let pngD = try TestSupport.makePNGData(pixelWidth: 26, pixelHeight: 26, color: .systemYellow)
            imageGate.setImmediate(returning: RecognizedImageContent(text: "Key \(secretDImage)", qrCodeText: nil))
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngD, forType: .png)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let itemD = try #require(harness.model.items.first)
            let finalizedD = await TestSupport.waitUntil {
                harness.currentItem(itemD.id)?.expiresAt == copiedAtD.addingTimeInterval(60)
            }
            #expect(finalizedD)
            let storedD = try #require(harness.currentItem(itemD.id))
            #expect(storedD.assetPath?.hasSuffix("\(itemD.id.uuidString).enc") == true)
            #expect(!FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("\(itemD.id.uuidString).png").path))

            harness.historyStore.flushPendingFreePageRelease()
            let diskDImage = Self.databaseDiskBytes(in: harness.supportDirectory)
            #expect(diskDImage.firstRange(of: Data(secretDImage.utf8)) == nil)
            #expect(diskDImage.firstRange(of: Data("\(itemD.id.uuidString).enc".utf8)) == nil)

            try await TestSupport.withTemporaryDirectory { externalDir in
                let externalFileD = externalDir.appendingPathComponent("secret-badge-d.png")
                try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemPink).write(to: externalFileD)

                let secretDFile = Self.makeSecretToken(tag: "ocr-d-file")
                fileGate.setImmediate(returning: RecognizedImageContent(text: "Token \(secretDFile)", qrCodeText: nil))
                let copiedFileAtD = copiedAtD.addingTimeInterval(5)
                clock.withLock { $0 = copiedFileAtD }
                harness.pasteboard.clearContents()
                #expect(harness.pasteboard.writeObjects([externalFileD as NSURL]))
                await harness.clipboardMonitor.pollAndWaitForDelivery()

                let fileItemD = try #require(harness.model.items.first)
                let finalizedFileD = await TestSupport.waitUntil {
                    harness.currentItem(fileItemD.id)?.expiresAt == copiedFileAtD.addingTimeInterval(60)
                }
                #expect(finalizedFileD)
                harness.historyStore.flushPendingFreePageRelease()
                let diskDFile = Self.databaseDiskBytes(in: harness.supportDirectory)
                #expect(diskDFile.firstRange(of: Data(secretDFile.utf8)) == nil)
                #expect(diskDFile.firstRange(of: Data("secret-badge-d.png".utf8)) == nil)
            }

            // --- Concealed image with confidentialContentLifetime == .keep and empty OCR stays kept & .enc ---
            harness.model.preferences.confidentialContentLifetime = ContentLifetime.keep
            harness.model.preferences.sensitiveContentLifetime = ContentLifetime.dontSave
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)
            clock.withLock { $0 = $0.addingTimeInterval(10) }

            let pngConcealedKeep = try TestSupport.makePNGData(pixelWidth: 22, pixelHeight: 22, color: .systemIndigo)
            imageGate.armSuspended(returning: .empty)
            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngConcealedKeep, forType: .png)
            harness.pasteboard.setData(Data(), forType: PasteboardReader.concealedType)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let concealedItem = try #require(harness.model.items.first)
            #expect(await Task.detached { imageGate.waitForEntry() }.value)
            imageGate.resume()
            let concealedSettled = await TestSupport.waitUntil {
                !harness.coordinator.isImageRecognitionPending(for: concealedItem.id)
            }
            #expect(concealedSettled)
            let updatedConcealed = try #require(harness.currentItem(concealedItem.id))
            #expect(updatedConcealed.sensitivity == .sensitive)
            #expect(updatedConcealed.assetPath?.hasSuffix("\(concealedItem.id.uuidString).enc") == true)
            #expect(!FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("\(concealedItem.id.uuidString).png").path))
        }

        @Test
        @MainActor
        func recopyRenameFragmentEditAndSetSensitiveConvertAssetsScrubDraggedImagesAndReconcileExpiry() async throws {
            defer { ImageDragFiles.removeAll() }

            let harness = try Self.makeCustomHarness(configureInitialPreferences: { prefs in
                prefs.confidentialContentLifetime = 300
                prefs.sensitiveContentLifetime = 60
            })
            defer { harness.cleanup() }

            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemBlue)
            let secretToken = Self.makeSecretToken(tag: "convert")

            // 1. Seed a plain .image and a plain .link with .png preview + favicon, then re-copy both with ConcealedType -> converts .png to .enc!
            let recopyImageID = UUID()
            let plainImageURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: recopyImageID,
                encrypted: false
            )
            let plainImageClip = ClipboardItem.fixture(
                id: recopyImageID,
                kind: .image,
                text: "Benign screenshot",
                assetPath: plainImageURL.path,
                imageDigest: harness.historyStore.computeImageDigest(forPNGData: pngData)
            )

            let recopyLinkID = UUID()
            let linkURLText = "https://docs.example.com/welcome"
            let plainLinkPreviewURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .linkPreview,
                clipID: recopyLinkID,
                encrypted: false
            )
            let plainLinkFaviconURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .linkFavicon,
                clipID: recopyLinkID,
                encrypted: false
            )
            var plainLinkClip = ClipboardItem.fixture(
                id: recopyLinkID,
                kind: .link,
                text: linkURLText
            )
            plainLinkClip.linkPreviewDetails = LinkPreviewDetails(
                url: ClipboardItem.normalizedLinkContentKey(for: try #require(URL(string: linkURLText))),
                title: "Welcome",
                description: "Public docs",
                imagePath: plainLinkPreviewURL.path,
                faviconPath: plainLinkFaviconURL.path,
                fetchedAt: Date()
            )
            try harness.seedHistory([plainImageClip, plainLinkClip])
            #expect(FileManager.default.fileExists(atPath: plainImageURL.path))
            #expect(FileManager.default.fileExists(atPath: plainLinkPreviewURL.path))
            #expect(FileManager.default.fileExists(atPath: plainLinkFaviconURL.path))

            // Stage a dragged file for plainImageClip before concealed re-copy upgrades it to encrypted.
            let recopyDragURL = try #require(
                ImageDragFiles.makeCopy(
                    of: plainImageURL,
                    named: ".recopy-drag.png",
                    ownerClipID: recopyImageID,
                    requiresEncryption: false
                )
            )
            #expect(FileManager.default.fileExists(atPath: recopyDragURL.path))

            harness.pasteboard.clearContents()
            harness.pasteboard.setData(pngData, forType: .png)
            harness.pasteboard.setData(Data(), forType: PasteboardReader.concealedType)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let upgradedImage = try #require(harness.currentItem(recopyImageID))
            #expect(upgradedImage.sensitivity == .sensitive)
            #expect(upgradedImage.assetPath?.hasSuffix(".enc") == true)
            #expect(!FileManager.default.fileExists(atPath: plainImageURL.path))
            #expect(!FileManager.default.fileExists(atPath: recopyDragURL.path), "0 -> 1 concealed image re-copy must scrub ImageDragFiles")

            harness.pasteboard.clearContents()
            harness.pasteboard.setString(linkURLText, forType: .string)
            harness.pasteboard.setData(Data(), forType: PasteboardReader.concealedType)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let upgradedLink = try #require(harness.currentItem(recopyLinkID))
            #expect(upgradedLink.sensitivity == .sensitive)
            #expect(upgradedLink.linkPreviewDetails?.imagePath?.hasSuffix(".enc") == true)
            #expect(upgradedLink.linkPreviewDetails?.faviconPath?.hasSuffix(".enc") == true)
            #expect(!FileManager.default.fileExists(atPath: plainLinkPreviewURL.path))
            #expect(!FileManager.default.fileExists(atPath: plainLinkFaviconURL.path))

            // 2. Renaming a plain .image with a secret title converts .png -> .enc via saveAndReconcileItem and scrubs ImageDragFiles!
            let renameImageID = UUID()
            let renamePngData = try TestSupport.makePNGData(pixelWidth: 18, pixelHeight: 18, color: .systemCyan)
            let renamePlainURL = try harness.historyStore.writeManagedAsset(
                pngData: renamePngData,
                role: .image,
                clipID: renameImageID,
                encrypted: false
            )
            let renameImageItem = ClipboardItem.fixture(
                id: renameImageID,
                kind: .image,
                text: nil,
                assetPath: renamePlainURL.path,
                imageDigest: harness.historyStore.computeImageDigest(forPNGData: renamePngData)
            )
            try harness.historyStore.saveAndReconcileItem(renameImageItem, convertingExternalAssets: true)
            harness.coordinator.loadHistory(sweepsCaches: false)

            let renameDragURL = try #require(
                ImageDragFiles.makeCopy(
                    of: renamePlainURL,
                    named: ".env-keys.png",
                    ownerClipID: renameImageID,
                    requiresEncryption: false
                )
            )
            let renameDragFD = Darwin.open(renameDragURL.path, O_RDONLY)
            #expect(renameDragFD >= 0)
            defer {
                if renameDragFD >= 0 { Darwin.close(renameDragFD) }
            }

            harness.coordinator.rename(
                try #require(harness.currentItem(renameImageID)),
                title: "Prod token \(secretToken)"
            )
            let renamedImage = try #require(harness.currentItem(renameImageID))
            #expect(SensitiveContent.shouldEncryptAtRest(renamedImage))
            #expect(renamedImage.assetPath?.hasSuffix(".enc") == true)
            #expect(!FileManager.default.fileExists(atPath: renamePlainURL.path))
            #expect(!FileManager.default.fileExists(atPath: renameDragURL.path))
            var renameDragZeros = [UInt8](repeating: 0xFF, count: 16)
            #expect(Darwin.pread(renameDragFD, &renameDragZeros, renameDragZeros.count, 0) == renameDragZeros.count)
            #expect(renameDragZeros.allSatisfy { $0 == 0 })

            // 3. #fragment-editing a plain .link with a secret converts its .png preview/favicon to .enc via saveAndReconcileItem!
            let fragmentLinkID = UUID()
            let fragPrevURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .linkPreview,
                clipID: fragmentLinkID,
                encrypted: false
            )
            let fragFavURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .linkFavicon,
                clipID: fragmentLinkID,
                encrypted: false
            )
            var fragmentLink = ClipboardItem.fixture(
                id: fragmentLinkID,
                kind: .link,
                text: "https://oauth.example.com/callback"
            )
            fragmentLink.linkPreviewDetails = LinkPreviewDetails(
                url: "https://oauth.example.com/callback",
                title: "OAuth Callback",
                description: "Redirect",
                imagePath: fragPrevURL.path,
                faviconPath: fragFavURL.path,
                fetchedAt: Date()
            )
            try harness.historyStore.saveAndReconcileItem(fragmentLink, convertingExternalAssets: true)
            harness.coordinator.loadHistory(sweepsCaches: false)

            harness.coordinator.editContent(
                try #require(harness.currentItem(fragmentLinkID)),
                text: "https://oauth.example.com/callback#access_token=\(secretToken)"
            )
            let editedFragmentLink = try #require(harness.currentItem(fragmentLinkID))
            #expect(SensitiveContent.shouldEncryptAtRest(editedFragmentLink))
            #expect(editedFragmentLink.linkPreviewDetails?.imagePath?.hasSuffix(".enc") == true)
            #expect(editedFragmentLink.linkPreviewDetails?.faviconPath?.hasSuffix(".enc") == true)
            #expect(!FileManager.default.fileExists(atPath: fragPrevURL.path))
            #expect(!FileManager.default.fileExists(atPath: fragFavURL.path))

            // 4. setSensitive(true) converts .png -> .enc and scrubs ImageDragFiles; setSensitive(false) clears sensitiveContentLifetime expiry while preserving confidentialContentLifetime expiry!
            let toggleImageID = UUID()
            let togglePlainURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: toggleImageID,
                encrypted: false
            )
            let toggleImage = ClipboardItem.fixture(
                id: toggleImageID,
                kind: .image,
                text: nil,
                assetPath: togglePlainURL.path,
                imageDigest: harness.historyStore.computeImageDigest(forPNGData: pngData)
            )
            let autoSecretExpiry = Date().addingTimeInterval(3_600)
            var autoSecretClip = ClipboardItem.fixture(
                kind: .text,
                text: "Auto secret \(secretToken)",
                sensitivity: nil
            )
            autoSecretClip.expiresAt = autoSecretExpiry

            let concealedExpiry = Date().addingTimeInterval(7_200)
            var concealedClip = ClipboardItem.fixture(
                kind: .text,
                text: "Concealed password",
                sensitivity: .sensitive
            )
            concealedClip.expiresAt = concealedExpiry
            try harness.historyStore.saveAndReconcileItem(toggleImage, convertingExternalAssets: true)
            try harness.historyStore.saveAndReconcileItem(autoSecretClip, convertingExternalAssets: true)
            try harness.historyStore.saveAndReconcileItem(concealedClip, convertingExternalAssets: true)
            harness.coordinator.loadHistory(sweepsCaches: false)

            let toggleDragURL = try #require(
                ImageDragFiles.makeCopy(
                    of: togglePlainURL,
                    named: ".sensitive-toggle.png",
                    ownerClipID: toggleImageID,
                    requiresEncryption: false
                )
            )
            let toggleDragFD = Darwin.open(toggleDragURL.path, O_RDONLY)
            #expect(toggleDragFD >= 0)
            defer {
                if toggleDragFD >= 0 { Darwin.close(toggleDragFD) }
            }

            harness.coordinator.setSensitive(true, for: try #require(harness.currentItem(toggleImageID)))
            let markedSensitiveImg = try #require(harness.currentItem(toggleImageID))
            #expect(markedSensitiveImg.sensitivity == .sensitive)
            #expect(markedSensitiveImg.assetPath?.hasSuffix(".enc") == true)
            #expect(!FileManager.default.fileExists(atPath: toggleDragURL.path))
            var toggleDragZeros = [UInt8](repeating: 0xFF, count: 16)
            #expect(Darwin.pread(toggleDragFD, &toggleDragZeros, toggleDragZeros.count, 0) == toggleDragZeros.count)
            #expect(toggleDragZeros.allSatisfy { $0 == 0 })

            harness.coordinator.setSensitive(false, for: try #require(harness.currentItem(autoSecretClip.id)))
            let clearedAuto = try #require(harness.currentItem(autoSecretClip.id))
            #expect(clearedAuto.sensitivity == .notSensitive)
            #expect(clearedAuto.expiresAt == nil, "setSensitive(false) must clear sensitiveContentLifetime-armed expiresAt when existing.sensitivity == nil")

            harness.coordinator.setSensitive(false, for: try #require(harness.currentItem(concealedClip.id)))
            let preservedConcealed = try #require(harness.currentItem(concealedClip.id))
            #expect(preservedConcealed.sensitivity == .notSensitive)
            #expect(
                abs((preservedConcealed.expiresAt?.timeIntervalSince1970 ?? 0) - concealedExpiry.timeIntervalSince1970) < 1,
                "setSensitive(false) must preserve confidentialContentLifetime-armed expiresAt when existing.sensitivity == .sensitive"
            )
        }

        @Test
        @MainActor
        func moveToTrashImmediateScrubConcealedExtractionOnboardingExportAndFileThumbnailEviction() async throws {
            defer { ImageDragFiles.removeAll() }

            let harness = try Self.makeCustomHarness()
            defer { harness.cleanup() }

            let secretToken = Self.makeSecretToken(tag: "trash-scrub")
            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemRed)

            // 1. Disable "Mask sensitive content" (detectSensitiveContent = false) and verify moveToTrash/delete STILL bypasses Trash for all rest-encrypted secrets!
            harness.model.preferences.detectSensitiveContent = false
            harness.model.preferences.trashRetentionDays = 30

            let ocrImageID = UUID()
            let ocrEncURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: ocrImageID,
                encrypted: true
            )
            let ocrSecretImage = ClipboardItem.fixture(
                id: ocrImageID,
                kind: .image,
                text: "OCR \(secretToken)",
                assetPath: ocrEncURL.path
            )
            let qrSecretFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                qrCodeText: Self.makeWiFiQRSecret(passwordTag: "trashqr"),
                filePaths: ["/tmp/nonexistent-qr-scan.png"]
            )
            let tailSecret220KB = ClipboardItem.fixture(
                kind: .text,
                text: String(repeating: "x", count: 220_000) + " " + secretToken
            )
            let htmlOnlySecret = ClipboardItem.fixture(
                kind: .richText,
                text: "Download Invoice",
                rtfData: try TestSupport.makeRTFData(text: "Download Invoice"),
                html: "<a href='https://billing.example.com?api_key=\(secretToken)'>Download Invoice</a>"
            )
            let unmaskedOverride = ClipboardItem.fixture(
                kind: .text,
                text: "Explicitly non-sensitive \(secretToken)",
                sensitivity: .notSensitive
            )
            #expect(SensitiveContent.shouldEncryptAtRest(ocrSecretImage))
            #expect(SensitiveContent.shouldEncryptAtRest(qrSecretFile))
            #expect(SensitiveContent.shouldEncryptAtRest(tailSecret220KB))
            #expect(SensitiveContent.shouldEncryptAtRest(htmlOnlySecret))
            #expect(!SensitiveContent.shouldEncryptAtRest(unmaskedOverride))

            try harness.seedHistory([ocrSecretImage, qrSecretFile, tailSecret220KB, htmlOnlySecret, unmaskedOverride])
            harness.coordinator.delete([ocrSecretImage, qrSecretFile, tailSecret220KB, htmlOnlySecret, unmaskedOverride])

            #expect(harness.model.items.isEmpty)
            #expect(try harness.trashedIDs() == [unmaskedOverride.id], "Only .notSensitive item may enter Trash; all rest-secret items must scrub immediately")
            #expect(!FileManager.default.fileExists(atPath: ocrEncURL.path))

            // 2. copyMerged and copyTextFromImage / copyTextFromQRCode propagate ConcealedType cleanly.
            let benignA = ClipboardItem.fixture(kind: .text, text: "Alpha line")
            let benignB = ClipboardItem.fixture(kind: .text, text: "Beta line")
            let sensitiveLine = ClipboardItem.fixture(kind: .text, text: "Concealed note", sensitivity: .sensitive)
            try harness.seedHistory([benignA, benignB, sensitiveLine])

            #expect(harness.coordinator.copyMerged([benignA, benignB]))
            #expect(!(harness.pasteboard.types ?? []).contains(PasteboardReader.concealedType))
            #expect(harness.pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")

            #expect(harness.coordinator.copyMerged([benignA, sensitiveLine]))
            #expect((harness.pasteboard.types ?? []).contains(PasteboardReader.concealedType))
            #expect(harness.pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")

            // Non-regex OCR & QR text on a .sensitive .image carries ConcealedType on copyTextFromImage / copyTextFromQRCode!
            let concealedImgID = UUID()
            let concealedImgURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: concealedImgID,
                encrypted: true
            )
            let concealedOCRText = "Internal whiteboard PIN 9482"
            let concealedQRText = "BADGE-DOOR-CODE-7710"
            let concealedImgItem = ClipboardItem.fixture(
                id: concealedImgID,
                kind: .image,
                text: concealedOCRText,
                qrCodeText: concealedQRText,
                assetPath: concealedImgURL.path,
                sensitivity: .sensitive
            )
            try harness.seedHistory([concealedImgItem])

            let contentVC = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([contentVC] + contentVC.children) }
            let ocrMenuItem = NSMenuItem()
            ocrMenuItem.representedObject = concealedImgItem
            contentVC.copyTextFromImageMenuItem(ocrMenuItem)
            #expect(harness.pasteboard.string(forType: .string) == concealedOCRText)
            #expect((harness.pasteboard.types ?? []).contains(PasteboardReader.concealedType))
            #expect(harness.pasteboard.string(forType: PasteboardMonitor.ghostType) == nil)

            // With confidentialContentLifetime == .dontSave, PasteboardMonitor skips the extracted concealed OCR text!
            harness.model.preferences.confidentialContentLifetime = ContentLifetime.dontSave
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)
            await harness.clipboardMonitor.pollAndWaitForDelivery()
            #expect(!harness.model.items.contains { $0.kind == .text && $0.previewText == concealedOCRText })

            // With confidentialContentLifetime == 120, copying QR text from the .sensitive image re-captures it with sensitivity == .sensitive, expiresAt, and isEncrypted == 1!
            harness.model.preferences.confidentialContentLifetime = 120
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)
            let qrMenuItem = NSMenuItem()
            qrMenuItem.representedObject = concealedImgItem
            contentVC.copyTextFromQRCodeMenuItem(qrMenuItem)
            #expect(harness.pasteboard.string(forType: .string) == concealedQRText)
            #expect((harness.pasteboard.types ?? []).contains(PasteboardReader.concealedType))

            await harness.clipboardMonitor.pollAndWaitForDelivery()
            let recapturedQR = try #require(harness.model.items.first { $0.kind == .text && $0.previewText == concealedQRText })
            #expect(!recapturedQR.isContentLoaded)
            #expect(try harness.historyStore.loadingContent(of: recapturedQR, scope: .body).text == concealedQRText)
            #expect(recapturedQR.sensitivity == .sensitive)
            #expect(recapturedQR.expiresAt != nil)
            harness.historyStore.flushPendingFreePageRelease()
            let diskAfterQRRecapture = Self.databaseDiskBytes(in: harness.supportDirectory)
            #expect(diskAfterQRRecapture.firstRange(of: Data(concealedQRText.utf8)) == nil)

            // 3. OnboardingModel.receivePaste decodes .enc images, and saveImageAsFile / export readAssetData validates .enc.
            let onboarding = OnboardingModel(appModel: harness.model, coordinator: harness.coordinator)
            onboarding.goForward() // .copyItems
            onboarding.goForward() // .openHistory
            onboarding.goForward() // .pasteBack
            #expect(onboarding.step == .pasteBack)

            let onboardingWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            onboardingWindow.isReleasedWhenClosed = false
            defer { onboardingWindow.orderOut(nil) }

            onboarding.receivePaste(of: concealedImgItem, in: onboardingWindow)
            #expect(onboarding.pastedImage != nil)

            let exportedData = try ImageAssetStore.readAssetData(
                at: concealedImgURL,
                role: .image,
                ownerClipID: concealedImgItem.id,
                requiresEncryption: SensitiveContent.shouldEncryptAtRest(concealedImgItem)
            )
            #expect(exportedData == pngData)

            // saveImageAsFile preflight rejects non-image and missing-file items cleanly without opening NSSavePanel.
            let missingImgItem = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                assetPath: harness.supportDirectory.appendingPathComponent("Images/missing.enc").path,
                sensitivity: .sensitive
            )
            #expect(!harness.coordinator.saveImageAsFile(missingImgItem, presenting: onboardingWindow))
            #expect(harness.model.lastError != nil)

            // 4. External .file paths are evicted from ImageAssetThumbnailLoader.shared on setSensitive(true), delete (removeFilePreviewFiles), and clearHistory().
            try await TestSupport.withTemporaryDirectory { extDir in
                let extFile1 = extDir.appendingPathComponent("ext1.png")
                let extFile2 = extDir.appendingPathComponent("ext2.png")
                try pngData.write(to: extFile1)
                try pngData.write(to: extFile2)

                let fileClip1 = ClipboardItem.fixture(kind: .file, text: nil, filePaths: [extFile1.path])
                let fileClip2 = ClipboardItem.fixture(kind: .file, text: nil, filePaths: [extFile2.path])
                try harness.seedHistory([fileClip1, fileClip2])

                @MainActor
                func warmThumbnail(_ url: URL) async throws {
                    var ready = false
                    if ImageAssetThumbnailLoader.shared.thumbnail(for: url, maximumPixelSize: 128, completion: { _ in ready = true }) != nil {
                        ready = true
                    }
                    #expect(await TestSupport.waitUntil { ready })
                    #expect(ImageAssetThumbnailLoader.shared.thumbnail(for: url, maximumPixelSize: 128, completion: { _ in }) != nil)
                }

                try await warmThumbnail(extFile1)
                harness.coordinator.setSensitive(true, for: try #require(harness.currentItem(fileClip1.id)))
                #expect(ImageAssetThumbnailLoader.shared.thumbnail(for: extFile1, maximumPixelSize: 128, completion: { _ in }) == nil)

                try await warmThumbnail(extFile1)
                harness.coordinator.delete(try #require(harness.currentItem(fileClip1.id)))
                #expect(ImageAssetThumbnailLoader.shared.thumbnail(for: extFile1, maximumPixelSize: 128, completion: { _ in }) == nil)

                try await warmThumbnail(extFile2)
                harness.coordinator.clearHistory()
                #expect(ImageAssetThumbnailLoader.shared.thumbnail(for: extFile2, maximumPixelSize: 128, completion: { _ in }) == nil)
            }
        }

        @Test
        @MainActor
        func orphanSweepCancellationConcurrentStoreCloseAndLockedStoreLifecycleGuards() async throws {
            defer { ImageDragFiles.removeAll() }

            // Part A: Backdated orphaned .enc scrubbing + archive import orphan preservation + concurrent close().
            do {
                let supportDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipBookC5Orphan-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: supportDir) }

                let masterKey = SymmetricKey(size: .bits256)
                let keyProvider = InMemoryDatabaseKeyProvider(key: masterKey)
                let harness = try Self.makeCustomHarness(supportDirectory: supportDir, keyProvider: keyProvider)
                defer { harness.cleanup() }

                let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24)
                let keptID = UUID()
                let keptEncURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: keptID, encrypted: true)
                let keptClip = ClipboardItem.fixture(id: keptID, kind: .image, text: nil, assetPath: keptEncURL.path, sensitivity: .sensitive)
                try harness.seedHistory([keptClip])

                let orphanID = UUID()
                let orphanEncURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: orphanID, encrypted: true)
                let freshOrphanID = UUID()
                let freshOrphanEncURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: freshOrphanID, encrypted: true)

                // Warm thumbnail cache for orphanEncURL and backdate orphanEncURL by 20 minutes (>10m threshold).
                var orphanWarm = false
                if ImageAssetThumbnailLoader.shared.thumbnail(
                    for: orphanEncURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: orphanID, requiresEncryption: true),
                    completion: { _ in orphanWarm = true }
                ) != nil {
                    orphanWarm = true
                }
                #expect(await TestSupport.waitUntil { orphanWarm })

                let orphanFD = Darwin.open(orphanEncURL.path, O_RDONLY)
                #expect(orphanFD >= 0)
                defer {
                    if orphanFD >= 0 { Darwin.close(orphanFD) }
                }

                let orphanEncPath = orphanEncURL.path
                let twentyMinutesAgo = Date().addingTimeInterval(-20 * 60)
                try FileManager.default.setAttributes([.modificationDate: twentyMinutesAgo], ofItemAtPath: orphanEncPath)

                #expect(harness.coordinator.loadHistory(sweepsCaches: true))
                let swept = await TestSupport.waitUntil {
                    !FileManager.default.fileExists(atPath: orphanEncPath)
                }
                #expect(swept)
                #expect(FileManager.default.fileExists(atPath: keptEncURL.path))
                #expect(FileManager.default.fileExists(atPath: freshOrphanEncURL.path))

                var zeroedOrphan = [UInt8](repeating: 0xFF, count: 16)
                #expect(Darwin.pread(orphanFD, &zeroedOrphan, zeroedOrphan.count, 0) == zeroedOrphan.count)
                #expect(zeroedOrphan.allSatisfy { $0 == 0 }, "Orphaned .enc file must be zero-filled via ImageAssetStore.secureUnlink")
                #expect(
                    ImageAssetThumbnailLoader.shared.thumbnail(
                        for: orphanEncURL,
                        maximumPixelSize: 128,
                        assetContext: .init(role: .image, ownerClipID: orphanID, requiresEncryption: true),
                        completion: { _ in }
                    ) == nil
                )

                // Verify cancelOrphanedFileSweeps + v1 archive import preserves >10m-old imported assets!
                let archiveParent = supportDir.appendingPathComponent("ArchiveTemp", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveParent, withIntermediateDirectories: true)
                do {
                    let archiveURL = archiveParent.appendingPathComponent("Export.clipbookarchive", isDirectory: true)
                    let importedID = UUID()
                    let exportDirImages = archiveParent.appendingPathComponent("SourceSupport/Images", isDirectory: true)
                    try FileManager.default.createDirectory(at: exportDirImages, withIntermediateDirectories: true)
                    let exportedSourcePNG = exportDirImages.appendingPathComponent("\(importedID.uuidString).png")
                    try pngData.write(to: exportedSourcePNG)
                    try FileManager.default.setAttributes([.modificationDate: twentyMinutesAgo], ofItemAtPath: exportedSourcePNG.path)

                    let sourceArchiveService = ClipBookArchiveService(
                        fileManager: .default,
                        supportDirectory: archiveParent.appendingPathComponent("SourceSupport", isDirectory: true)
                    )
                    let archiveItem = ClipboardItem.fixture(
                        id: importedID,
                        kind: .image,
                        text: "Imported v1 screenshot",
                        assetPath: exportedSourcePNG.path
                    )
                    try sourceArchiveService.export(items: [archiveItem], tags: [], to: archiveURL, progress: { _ in })

                    // Trigger an orphan sweep and cancel it immediately before importing, matching archive import flow.
                    _ = harness.coordinator.loadHistory(sweepsCaches: true)
                    harness.coordinator.cancelOrphanedFileSweeps(waitUntilDone: true)
                    let targetArchiveService = ClipBookArchiveService(fileManager: .default, supportDirectory: supportDir)
                    _ = try targetArchiveService.import(from: archiveURL, into: harness.historyStore, progress: { _ in })
                    #expect(harness.coordinator.loadHistory(sweepsCaches: false))
                    let importedStored = try #require(harness.currentItem(importedID))
                    let importedAssetPath = try #require(importedStored.assetPath)
                    #expect(FileManager.default.fileExists(atPath: importedAssetPath))
                }
            }

            // Concurrent GRDBHistoryStore.close() while background readers run must drain cleanly without reopening SQLite!
            do {
                let closeDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipBookC5Close-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: closeDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: closeDir) }

                let closeStore = GRDBHistoryStore(directory: closeDir, keyProvider: InMemoryDatabaseKeyProvider())
                var seededIDs: [UUID] = []
                try closeStore.performInTransaction {
                    for index in 0..<40 {
                        let item = ClipboardItem.fixture(kind: .text, text: "Concurrent row \(index)")
                        seededIDs.append(item.id)
                        try closeStore.upsert(item)
                    }
                }
                let idsSnapshot = seededIDs
                let readers = (0..<4).map { _ in
                    Task.detached {
                        for _ in 0..<25 {
                            _ = try? closeStore.fetchAll()
                            _ = try? closeStore.fetchSearchTexts(for: idsSnapshot, trashed: false, tagNamesByID: [:], isCancelled: { false })
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(10))
                closeStore.close()
                for reader in readers {
                    await reader.value
                }
                // After close(), removing the directory leaves History.sqlite absent even if late calls arrive.
                try FileManager.default.removeItem(at: closeDir)
                _ = try? closeStore.fetchAll()
                #expect(!FileManager.default.fileExists(atPath: closeDir.appendingPathComponent("History.sqlite").path))
            }

            // Part B: StoreLockState != .unlocked skips reboot-clear, quit-clear, retention, expiry, and orphan GC until retryUnlockHistoryStore() succeeds!
            do {
                let lockedDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipBookC5Locked-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: lockedDir) }

                let realMasterKey = SymmetricKey(size: .bits256)
                let seedKeyProvider = InMemoryDatabaseKeyProvider(key: realMasterKey)
                let pngData = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20)
                let survivingClip = ClipboardItem.fixture(
                    kind: .text,
                    text: "Must survive locked startup and quit",
                    copiedAt: Date().addingTimeInterval(-86_400 * 10)
                )
                var expiringClip = ClipboardItem.fixture(
                    kind: .text,
                    text: "Expired while locked"
                )
                expiringClip.expiresAt = Date().addingTimeInterval(-60)
                let backdatedOrphanID = UUID()
                var backdatedOrphanURL: URL!

                do {
                    let seedStore = GRDBHistoryStore(directory: lockedDir, keyProvider: seedKeyProvider)
                    defer { seedStore.close() }
                    try seedStore.saveAndReconcileItem(survivingClip, convertingExternalAssets: true)
                    try seedStore.saveAndReconcileItem(expiringClip, convertingExternalAssets: true)
                    backdatedOrphanURL = try seedStore.writeManagedAsset(
                        pngData: pngData,
                        role: .image,
                        clipID: backdatedOrphanID,
                        encrypted: true
                    )
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date().addingTimeInterval(-20 * 60)],
                        ofItemAtPath: backdatedOrphanURL.path
                    )
                }

                // Open a coordinator whose keyProvider initially fails with interactionNotAllowed.
                let toggleableKeyProvider = InMemoryDatabaseKeyProvider(
                    key: nil,
                    error: .encryptionKeyUnavailable(.interactionNotAllowed)
                )
                let lockedHarness = try Self.makeCustomHarness(
                    supportDirectory: lockedDir,
                    keyProvider: toggleableKeyProvider,
                    configureInitialPreferences: { prefs in
                        prefs.clearHistoryOnReboot = true
                        prefs.clearHistoryOnQuit = true
                        prefs.textRetentionDays = 1 // 1-day retention would wipe 10-day-old survivingClip if run while locked!
                    }
                )
                defer { lockedHarness.cleanup() }

                // Seed a stale kernel boot time so a normal unlocked start() would treat this launch as a reboot and clear history!
                let priorBootTime = 1_600_000_000.0
                lockedHarness.preferencesStore.recordBootTimes(
                    kernelBootTime: priorBootTime,
                    uptimeRelativeBootTime: priorBootTime
                )

                lockedHarness.coordinator.start()
                #expect(lockedHarness.historyStore.lockState == .locked(.interactionNotAllowed))
                #expect(lockedHarness.clipboardMonitor.isPaused)
                #expect(lockedHarness.model.lastError != nil)
                #expect(lockedHarness.model.items.isEmpty)
                #expect(
                    lockedHarness.preferencesStore.lastKnownKernelBootTime() == priorBootTime,
                    "Locked start() must not overwrite lastKnownKernelBootTime before history can be cleared"
                )

                // Toggling pause while locked must keep clipboardMonitor paused.
                lockedHarness.coordinator.togglePaused()
                #expect(lockedHarness.clipboardMonitor.isPaused)
                lockedHarness.coordinator.togglePaused()
                #expect(lockedHarness.clipboardMonitor.isPaused)

                // Stopping while locked with clearHistoryOnQuit == true must NOT clear SQLite!
                lockedHarness.coordinator.stop()
                try? await Task.sleep(for: .milliseconds(80))
                #expect(FileManager.default.fileExists(atPath: backdatedOrphanURL.path), "Orphan GC must not run while locked")

                // Test keyMismatch transition too before providing the real key.
                toggleableKeyProvider.setError(nil)
                toggleableKeyProvider.setKey(SymmetricKey(size: .bits256))
                #expect(!lockedHarness.coordinator.retryUnlockHistoryStore())
                #expect(lockedHarness.historyStore.lockState == .keyMismatch)
                #expect(lockedHarness.clipboardMonitor.isPaused)
                #expect(lockedHarness.model.lastError != nil)

                // Turn off reboot/retention destructive flags so we verify all surviving rows were still intact on disk, then unlock!
                lockedHarness.model.preferences.clearHistoryOnReboot = false
                lockedHarness.model.preferences.textRetentionDays = AppPreferences.unlimitedRetentionDays
                toggleableKeyProvider.setKey(realMasterKey)
                #expect(lockedHarness.coordinator.retryUnlockHistoryStore())
                #expect(lockedHarness.historyStore.lockState == .unlocked)
                #expect(lockedHarness.model.lastError == nil)
                #expect(!lockedHarness.clipboardMonitor.isPaused)
                #expect(lockedHarness.model.items.map(\.id) == [survivingClip.id], "Surviving clip stays intact while expired clip is cleaned on unlock")

                let backdatedOrphanPath = backdatedOrphanURL.path
                let orphanCleanedAfterUnlock = await TestSupport.waitUntil {
                    !FileManager.default.fileExists(atPath: backdatedOrphanPath)
                }
                #expect(orphanCleanedAfterUnlock)

                // Verify Combine trash observer was bound only once across start() + retryUnlockHistoryStore().
                lockedHarness.coordinator.delete(survivingClip)
                lockedHarness.model.selectedHistoryFilterContentTypes = [.trash]
                #expect(lockedHarness.model.trashedItems.map(\.id) == [survivingClip.id])
            }
        }

        @Test
        @MainActor
        func storeLockStateInitRetryUnlockAndArchiveExportImportModesEndToEnd() async throws {
            let fileManager = FileManager.default
            let workspace = fileManager.temporaryDirectory
                .appendingPathComponent("ClipBookC7Archive-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: workspace) }

            // Part 1: AppModel.storeLockState initialization, archive guard while locked/mismatched,
            // and retryUnlockHistoryStore() transitions (without calling start() or mutating global L10n!).
                do {
                    let lockedDir = workspace.appendingPathComponent("LockedStoreInit", isDirectory: true)
                    try fileManager.createDirectory(at: lockedDir, withIntermediateDirectories: true)

                    let masterKey = SymmetricKey(size: .bits256)
                    let seededItem = ClipboardItem.fixture(
                        kind: .text,
                        text: "Unlocked after retry item",
                        copiedAt: Date(timeIntervalSince1970: 1_710_500_100)
                    )
                    do {
                        let seedStore = GRDBHistoryStore(
                            directory: lockedDir,
                            keyProvider: InMemoryDatabaseKeyProvider(key: masterKey)
                        )
                        defer { seedStore.close() }
                        _ = try seedStore.saveAndReconcileItem(seededItem, convertingExternalAssets: true)
                    }

                    let toggleProvider = InMemoryDatabaseKeyProvider(
                        key: nil,
                        error: .encryptionKeyUnavailable(.interactionNotAllowed)
                    )
                    let lockedHarness = try Self.makeCustomHarness(
                        supportDirectory: lockedDir,
                        keyProvider: toggleProvider,
                        probeStoreBeforeInit: true
                    )
                    defer { lockedHarness.cleanup() }

                    // AppCoordinator.init initializes model.storeLockState directly from historyStore.lockState!
                    #expect(lockedHarness.model.storeLockState == .locked(.interactionNotAllowed))
                    let dummyArchiveURL = workspace.appendingPathComponent("ShouldNotStart.clipbookarchive", isDirectory: true)
                    #expect(
                        !lockedHarness.coordinator.beginExportHistoryArchive(
                            mode: .unencryptedIncludingSensitive,
                            destinationURL: dummyArchiveURL,
                            progress: { _ in },
                            completion: { _ in }
                        )
                    )
                    #expect(
                        !lockedHarness.coordinator.performImportHistoryArchive(
                            from: dummyArchiveURL,
                            passphrase: nil,
                            progress: { _ in },
                            completion: { _ in }
                        )
                    )

                    // Wrong key transitions model.storeLockState to .keyMismatch and keeps export/import blocked.
                    toggleProvider.setError(nil)
                    toggleProvider.setKey(SymmetricKey(size: .bits256))
                    #expect(!lockedHarness.coordinator.retryUnlockHistoryStore())
                    #expect(lockedHarness.model.storeLockState == .keyMismatch)
                    #expect(lockedHarness.model.lastError != nil)
                    #expect(lockedHarness.clipboardMonitor.isPaused)
                    #expect(
                        !lockedHarness.coordinator.beginExportHistoryArchive(
                            mode: .unencryptedIncludingSensitive,
                            destinationURL: dummyArchiveURL,
                            progress: { _ in },
                            completion: { _ in }
                        )
                    )

                    // Providing the matching master key unlocks the store, updates model.storeLockState, and loads history.
                    toggleProvider.setKey(masterKey)
                    #expect(lockedHarness.coordinator.retryUnlockHistoryStore())
                    #expect(lockedHarness.model.storeLockState == .unlocked)
                    #expect(lockedHarness.model.lastError == nil)
                    #expect(!lockedHarness.clipboardMonitor.isPaused)
                    #expect(lockedHarness.model.items.map(\.id) == [seededItem.id])
                }

                // Part 2: exportableHistoryContainsSensitiveItems(), all 3 ArchiveExportMode branches,
                // verifyArchivePassphrase (async throws), and performImportHistoryArchive end-to-end!
                let sourceDir = workspace.appendingPathComponent("ExportSource", isDirectory: true)
                let sourceHarness = try Self.makeCustomHarness(supportDirectory: sourceDir)
                defer { sourceHarness.cleanup() }

                #expect(sourceHarness.model.storeLockState == .unlocked)
                #expect(!sourceHarness.coordinator.exportableHistoryContainsSensitiveItems())

                let generalTag = try sourceHarness.historyStore.createTag(name: "GeneralExport", color: "#2196F3")
                let opsTag = try sourceHarness.historyStore.createTag(name: "OpsExport", color: "#E91E63")

                let plainTextItem = ClipboardItem.fixture(
                    kind: .text,
                    title: "Public Release Notes",
                    text: "PublicCoordPlainBody2026",
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_200),
                    tags: [generalTag.id]
                )

                let plainImageBytes = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 16, color: .systemGreen)
                let plainImageID = UUID()
                let plainImageURL = try sourceHarness.historyStore.writeManagedAsset(
                    pngData: plainImageBytes,
                    role: .image,
                    clipID: plainImageID,
                    encrypted: false
                )
                let plainImageItem = ClipboardItem.fixture(
                    id: plainImageID,
                    kind: .image,
                    title: "Public Diagram",
                    text: "PublicImageOCRText",
                    assetPath: plainImageURL.path,
                    imageDigest: sourceHarness.historyStore.computeImageDigest(forPNGData: plainImageBytes),
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_300),
                    tags: [generalTag.id]
                )

                let secretToken = ["sk", "-proj-", "COORD_EXPORT_SECRET_TOKEN_1122334455667788"].joined()
                let overriddenNotSensitive = ClipboardItem.fixture(
                    kind: .text,
                    text: "Overridden \(secretToken)",
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_350),
                    sensitivity: .notSensitive
                )
                var expiringSensitiveItem = ClipboardItem.fixture(
                    kind: .text,
                    text: "Ephemeral \(secretToken)",
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_360)
                )
                expiringSensitiveItem.expiresAt = Date().addingTimeInterval(600)

                // Verify expiring sensitive items and .notSensitive overrides do NOT trigger sensitive export warning!
                try sourceHarness.seedHistory([plainTextItem, plainImageItem, overriddenNotSensitive, expiringSensitiveItem])
                #expect(!sourceHarness.coordinator.exportableHistoryContainsSensitiveItems())

                // Add persistent sensitive text and sensitive .enc image -> exportableHistoryContainsSensitiveItems() == true!
                let sensitiveTextItem = ClipboardItem.fixture(
                    kind: .text,
                    title: "Prod Credential",
                    text: "Credential \(secretToken)",
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_400),
                    tags: [opsTag.id]
                )
                let sensitiveImageBytes = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 20, color: .systemRed)
                let sensitiveImageID = UUID()
                let sensitiveImageURL = try sourceHarness.historyStore.writeManagedAsset(
                    pngData: sensitiveImageBytes,
                    role: .image,
                    clipID: sensitiveImageID,
                    encrypted: true
                )
                let sensitiveImageItem = ClipboardItem.fixture(
                    id: sensitiveImageID,
                    kind: .image,
                    title: "Secret Screenshot",
                    text: "SecretImageOCRMarker",
                    assetPath: sensitiveImageURL.path,
                    imageDigest: sourceHarness.historyStore.computeImageDigest(forPNGData: sensitiveImageBytes),
                    copiedAt: Date(timeIntervalSince1970: 1_710_500_500),
                    tags: [opsTag.id],
                    sensitivity: .sensitive
                )
                _ = try sourceHarness.historyStore.saveAndReconcileItem(sensitiveTextItem, convertingExternalAssets: true)
                _ = try sourceHarness.historyStore.saveAndReconcileItem(sensitiveImageItem, convertingExternalAssets: false)
                #expect(sourceHarness.coordinator.loadHistory(sweepsCaches: false))
                #expect(sourceHarness.model.items.count == 6)
                #expect(sourceHarness.model.items.allSatisfy { !$0.isContentLoaded })
                #expect(sourceHarness.coordinator.exportableHistoryContainsSensitiveItems())

                // Helper to await beginExportHistoryArchive cleanly on @MainActor.
                @MainActor
                func runExport(
                    mode: ArchiveExportMode,
                    to destinationURL: URL
                ) async throws -> (result: ClipBookArchiveExportResult, progress: [ClipBookArchiveProgress]) {
                    var recordedProgress: [ClipBookArchiveProgress] = []
                    let outcome: Result<ClipBookArchiveExportResult, Error> = await withCheckedContinuation { continuation in
                        let started = sourceHarness.coordinator.beginExportHistoryArchive(
                            mode: mode,
                            destinationURL: destinationURL,
                            progress: { step in
                                recordedProgress.append(step)
                            },
                            completion: { completionResult in
                                continuation.resume(returning: completionResult)
                            }
                        )
                        #expect(started)
                    }
                    return (try outcome.get(), recordedProgress)
                }

                // Mode A: .encrypted(passphrase:) exports formatVersion == 2 (5 non-expiring items, 2 tags).
                let nfdPassphrase = "caf\u{0065}\u{0301}-coord"
                let nfcPassphrase = "caf\u{00E9}-coord"
                let encryptedArchiveURL = workspace.appendingPathComponent("ModeEncrypted.clipbookarchive", isDirectory: true)
                let (encExportResult, encProgress) = try await runExport(
                    mode: .encrypted(passphrase: nfdPassphrase),
                    to: encryptedArchiveURL
                )
                #expect(encExportResult == ClipBookArchiveExportResult(url: encryptedArchiveURL, itemCount: 5, tagCount: 2))
                #expect(encProgress.last == ClipBookArchiveProgress(completedItemCount: 5, totalItemCount: 5))
                #expect(
                    try sourceHarness.coordinator.inspectArchive(at: encryptedArchiveURL)
                        == ClipBookArchiveInspection(formatVersion: 2, isEncrypted: true)
                )

                // verifyArchivePassphrase (async throws): NFC succeeds, wrong throws .incorrectPassphrase, empty throws .emptyPassphrase.
                sourceHarness.clipboardMonitor.isPaused = false
                try await sourceHarness.coordinator.verifyArchivePassphrase(nfcPassphrase, for: encryptedArchiveURL)
                #expect(!sourceHarness.clipboardMonitor.isPaused)
                await #expect(throws: ClipBookArchiveError.incorrectPassphrase) {
                    try await sourceHarness.coordinator.verifyArchivePassphrase("wrong-passphrase", for: encryptedArchiveURL)
                }
                await #expect(throws: ClipBookArchiveError.emptyPassphrase) {
                    try await sourceHarness.coordinator.verifyArchivePassphrase("", for: encryptedArchiveURL)
                }

                // Mode B: .unencryptedSkippingSensitive omits the 2 sensitive items + expiring item (exports 3 plain items, retains 2 tags).
                let skipArchiveURL = workspace.appendingPathComponent("ModeSkipSensitive.clipbookarchive", isDirectory: true)
                let (skipExportResult, skipProgress) = try await runExport(
                    mode: .unencryptedSkippingSensitive,
                    to: skipArchiveURL
                )
                #expect(skipExportResult == ClipBookArchiveExportResult(url: skipArchiveURL, itemCount: 3, tagCount: 2))
                #expect(skipProgress.last == ClipBookArchiveProgress(completedItemCount: 3, totalItemCount: 3))
                #expect(
                    try sourceHarness.coordinator.inspectArchive(at: skipArchiveURL)
                        == ClipBookArchiveInspection(formatVersion: 1, isEncrypted: false)
                )
                let skipHistoryText = try String(
                    contentsOf: skipArchiveURL.appendingPathComponent("history.json"),
                    encoding: .utf8
                )
                #expect(!skipHistoryText.contains("Credential \(secretToken)"))
                #expect(!skipHistoryText.contains("SecretImageOCRMarker"))
                #expect(!skipHistoryText.contains("Ephemeral \(secretToken)"))
                #expect(skipHistoryText.contains("PublicCoordPlainBody2026"))

                // Mode C: .unencryptedIncludingSensitive exports all 5 non-expiring items as formatVersion == 1 (decrypting .enc image to .png).
                let includeArchiveURL = workspace.appendingPathComponent("ModeIncludeSensitive.clipbookarchive", isDirectory: true)
                let (inclExportResult, _) = try await runExport(
                    mode: .unencryptedIncludingSensitive,
                    to: includeArchiveURL
                )
                #expect(inclExportResult == ClipBookArchiveExportResult(url: includeArchiveURL, itemCount: 5, tagCount: 2))
                #expect(
                    try sourceHarness.coordinator.inspectArchive(at: includeArchiveURL)
                        == ClipBookArchiveInspection(formatVersion: 1, isEncrypted: false)
                )
                let inclHistoryText = try String(
                    contentsOf: includeArchiveURL.appendingPathComponent("history.json"),
                    encoding: .utf8
                )
                #expect(inclHistoryText.contains("Credential \(secretToken)"))
                #expect(!inclHistoryText.contains("Ephemeral \(secretToken)"))
                let decryptedV1ImageURL = includeArchiveURL
                    .appendingPathComponent("assets/images/\(sensitiveImageID.uuidString).png")
                #expect(try Data(contentsOf: decryptedV1ImageURL) == sensitiveImageBytes)

                // End-to-end performImportHistoryArchive into fresh destination coordinators!
                let destEncryptedHarness = try Self.makeCustomHarness(
                    supportDirectory: workspace.appendingPathComponent("ImportDestEncrypted", isDirectory: true)
                )
                defer { destEncryptedHarness.cleanup() }

                @MainActor
                func runImport(
                    into targetHarness: TestCoordinatorHarness,
                    from url: URL,
                    passphrase: String?
                ) async -> (outcome: Result<ClipBookArchiveImportResult, Error>, progress: [ClipBookArchiveProgress]) {
                    var steps: [ClipBookArchiveProgress] = []
                    let outcome: Result<ClipBookArchiveImportResult, Error> = await withCheckedContinuation { continuation in
                        let started = targetHarness.coordinator.performImportHistoryArchive(
                            from: url,
                            passphrase: passphrase,
                            progress: { step in
                                steps.append(step)
                            },
                            completion: { result in
                                continuation.resume(returning: result)
                            }
                        )
                        #expect(started)
                    }
                    return (outcome, steps)
                }

                // 1) Missing passphrase on v2 archive fails with .passphraseRequired and restores clipboardMonitor state.
                let (missingPassOutcome, _) = await runImport(
                    into: destEncryptedHarness,
                    from: encryptedArchiveURL,
                    passphrase: nil
                )
                #expect(throws: ClipBookArchiveError.passphraseRequired) {
                    _ = try missingPassOutcome.get()
                }
                #expect(destEncryptedHarness.model.items.isEmpty)
                #expect(!destEncryptedHarness.clipboardMonitor.isPaused)

                // 2) Wrong passphrase fails with .incorrectPassphrase.
                let (wrongPassOutcome, _) = await runImport(
                    into: destEncryptedHarness,
                    from: encryptedArchiveURL,
                    passphrase: "wrong"
                )
                #expect(throws: ClipBookArchiveError.incorrectPassphrase) {
                    _ = try wrongPassOutcome.get()
                }
                #expect(destEncryptedHarness.model.items.isEmpty)

                // 3) Valid NFC passphrase imports all 5 items & 2 tags, keeping headers unloaded and sensitive assets .enc!
                let (validV2Outcome, validV2Steps) = await runImport(
                    into: destEncryptedHarness,
                    from: encryptedArchiveURL,
                    passphrase: nfcPassphrase
                )
                let v2ImportResult = try validV2Outcome.get()
                #expect(v2ImportResult.itemCount == 5)
                #expect(v2ImportResult.tagCount == 2)
                #expect(validV2Steps.last == ClipBookArchiveProgress(completedItemCount: 5, totalItemCount: 5))
                #expect(destEncryptedHarness.model.items.count == 5)
                #expect(destEncryptedHarness.model.items.allSatisfy { !$0.isContentLoaded })
                #expect(destEncryptedHarness.model.tags.count == 2)
                #expect(!destEncryptedHarness.clipboardMonitor.isPaused)

                let destSensImg = try #require(destEncryptedHarness.currentItem(sensitiveImageID))
                let destSensImgURL = URL(fileURLWithPath: try #require(destSensImg.assetPath))
                #expect(destSensImgURL.pathExtension == "enc")
                #expect(
                    try ImageAssetStore.readAssetData(
                        at: destSensImgURL,
                        role: .image,
                        ownerClipID: sensitiveImageID,
                        requiresEncryption: true
                    ) == sensitiveImageBytes
                )
                let destPlainImg = try #require(destEncryptedHarness.currentItem(plainImageID))
                let destPlainImgURL = URL(fileURLWithPath: try #require(destPlainImg.assetPath))
                #expect(destPlainImgURL.pathExtension == "png")
                #expect(try Data(contentsOf: destPlainImgURL) == plainImageBytes)

                // 4) Unencrypted skip-sensitive v1 archive imports the 3 plain items & 2 tags cleanly.
                let destSkipHarness = try Self.makeCustomHarness(
                    supportDirectory: workspace.appendingPathComponent("ImportDestSkip", isDirectory: true)
                )
                defer { destSkipHarness.cleanup() }
                let (skipImportOutcome, _) = await runImport(
                    into: destSkipHarness,
                    from: skipArchiveURL,
                    passphrase: nil
                )
                let skipImportResult = try skipImportOutcome.get()
                #expect(skipImportResult.itemCount == 3)
                #expect(skipImportResult.tagCount == 2)
                #expect(
                    Set(destSkipHarness.model.items.map(\.id))
                        == Set([plainTextItem.id, plainImageID, overriddenNotSensitive.id])
                )
        }
    }
}

// Saving applies appearance and language, which are process-wide, and confirming
// the sensitive-content deletion alert runs NSApp's modal window loop.
extension SharedProcessStateTests {
    @Suite(.serialized)
    struct LazyConsumerHydrationMatrixTests {
        private static let sentinel = "TAIL_SENTINEL_AT_40KB"

        private static func make40KBBody(prefix: String = "") -> String {
            let padCount = max(0, 40_020 - prefix.count - sentinel.count)
            return prefix + String(repeating: "a", count: padCount) + sentinel
        }

        @Test
        @MainActor
        func pasteCoordinatorActionsMergeSplitLifetimeAndBatchTagUpdatesUseMinimalContentScopes() async throws {
            let (harness, spyStore, pasteService) = try TestSupport.makeSpiedTestCoordinator()
            defer { harness.cleanup() }

            let baseTime = Date(timeIntervalSince1970: 1_710_100_000)
            let text40KB = Self.make40KBBody()
            #expect(text40KB.count == 40_020)

            let richText40KB = Self.make40KBBody(prefix: "RichHead ")
            let richRTF40KB = try TestSupport.makeRTFData(text: richText40KB)
            let richHTML40KB = "<div class='rich'>\(richText40KB)</div>"

            let longURLString = "https://example.com/resource?blob="
                + String(repeating: "q", count: 40_000)
                + "_"
                + Self.sentinel

            let ocrText40KB = Self.make40KBBody(prefix: "OCR ")
            let qrText40KB = "https://qr.example.com/v?" + String(repeating: "z", count: 12_000) + Self.sentinel

            let pngBytes = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 24)
            let ocrImageID = UUID()
            let ocrImageURL = try spyStore.writeManagedAsset(pngData: pngBytes, role: .image, clipID: ocrImageID, encrypted: false)
            let plainImageID = UUID()
            let plainImageURL = try spyStore.writeManagedAsset(pngData: pngBytes, role: .image, clipID: plainImageID, encrypted: false)

            let sampleFileURL = harness.supportDirectory.appendingPathComponent("sample-doc.txt")
            try Data("file-bytes".utf8).write(to: sampleFileURL)

            let svgBody12KB = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"><!-- "
                + String(repeating: "s", count: 12_000)
                + " --><rect width=\"64\" height=\"64\" fill=\"#3366FF\"/></svg>"

            let seededText = ClipboardItem.fixture(
                kind: .text,
                text: text40KB,
                copiedAt: baseTime.addingTimeInterval(10)
            )
            let seededRich = ClipboardItem.fixture(
                kind: .richText,
                text: richText40KB,
                rtfData: richRTF40KB,
                html: richHTML40KB,
                copiedAt: baseTime.addingTimeInterval(20)
            )
            let seededHTMLOnlyRich = ClipboardItem.fixture(
                kind: .richText,
                text: "",
                rtfData: nil,
                html: "<p>HTMLOnly_\(Self.sentinel)</p>",
                copiedAt: baseTime.addingTimeInterval(25)
            )
            let seededLink = ClipboardItem.fixture(
                kind: .link,
                text: longURLString,
                copiedAt: baseTime.addingTimeInterval(30)
            )
            let seededOCRImage = ClipboardItem.fixture(
                id: ocrImageID,
                kind: .image,
                text: ocrText40KB,
                qrCodeText: qrText40KB,
                assetPath: ocrImageURL.path,
                copiedAt: baseTime.addingTimeInterval(40)
            )
            let seededPlainImage = ClipboardItem.fixture(
                id: plainImageID,
                kind: .image,
                text: nil,
                qrCodeText: nil,
                assetPath: plainImageURL.path,
                copiedAt: baseTime.addingTimeInterval(45)
            )
            let seededFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [sampleFileURL.path],
                copiedAt: baseTime.addingTimeInterval(50)
            )
            let seededSVG = ClipboardItem.fixture(
                kind: .text,
                text: svgBody12KB,
                copiedAt: baseTime.addingTimeInterval(55)
            )

            try harness.seedHistory([
                seededText,
                seededRich,
                seededHTMLOnlyRich,
                seededLink,
                seededOCRImage,
                seededPlainImage,
                seededFile,
                seededSVG,
            ])

            // Every item in AppModel after loadHistory() is an unloaded header with empty searchText.
            #expect(harness.model.items.count == 8)
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded && !$0.isFormattingLoaded && $0.searchText.isEmpty })

            let textHeader = try #require(harness.currentItem(seededText.id))
            let richHeader = try #require(harness.currentItem(seededRich.id))
            let htmlOnlyHeader = try #require(harness.currentItem(seededHTMLOnlyRich.id))
            let linkHeader = try #require(harness.currentItem(seededLink.id))
            let ocrImageHeader = try #require(harness.currentItem(seededOCRImage.id))
            let plainImageHeader = try #require(harness.currentItem(seededPlainImage.id))
            let fileHeader = try #require(harness.currentItem(seededFile.id))
            let svgHeader = try #require(harness.currentItem(seededSVG.id))
            #expect(svgHeader.isSVGText)
            #expect(textHeader.characterCount == 40_020)
            #expect(!(textHeader.textPreview?.contains(Self.sentinel) ?? true))
            #expect(linkHeader.browserURL == nil)

            // 1. PasteService minimal scope verification (.plainText vs .standard vs .filePath).
            spyStore.resetRecordedCalls()
            try pasteService.copy(textHeader, variant: .plainText)
            #expect(spyStore.loadingContentCalls == [.init(id: textHeader.id, scope: .body)])
            #expect(harness.pasteboard.string(forType: .string) == text40KB)

            spyStore.resetRecordedCalls()
            try pasteService.copy(richHeader, variant: .plainText)
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .body)])
            #expect(harness.pasteboard.string(forType: .string) == richText40KB)
            #expect(harness.pasteboard.data(forType: .rtf) == nil)
            #expect(harness.pasteboard.string(forType: .html) == nil)

            spyStore.resetRecordedCalls()
            try pasteService.copy(fileHeader, variant: .plainText)
            try pasteService.copy(fileHeader, variant: .filePath)
            try pasteService.copy(plainImageHeader, variant: .plainText)
            #expect(spyStore.loadingContentCalls.isEmpty)

            spyStore.resetRecordedCalls()
            try pasteService.copy(ocrImageHeader, variant: .plainText)
            #expect(spyStore.loadingContentCalls == [.init(id: ocrImageHeader.id, scope: .body)])
            #expect(harness.pasteboard.string(forType: .string) == ocrText40KB)

            spyStore.resetRecordedCalls()
            try pasteService.copy(htmlOnlyHeader, variant: .plainText)
            #expect(spyStore.loadingContentCalls == [.init(id: htmlOnlyHeader.id, scope: .full)])

            spyStore.resetRecordedCalls()
            try pasteService.copy(richHeader, variant: .standard)
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .full)])
            #expect(harness.pasteboard.string(forType: .string) == richText40KB)
            #expect(harness.pasteboard.data(forType: .rtf) == richRTF40KB)
            #expect(harness.pasteboard.string(forType: .html) == richHTML40KB)

            spyStore.resetRecordedCalls()
            try pasteService.copy(textHeader, variant: .standard)
            #expect(spyStore.loadingContentCalls == [.init(id: textHeader.id, scope: .body)])

            spyStore.resetRecordedCalls()
            try pasteService.copy(plainImageHeader, variant: .standard)
            try pasteService.copy(fileHeader, variant: .standard)
            #expect(spyStore.loadingContentCalls.isEmpty)
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })

            // 2. copyTextFromImage & copyTextFromQRCode hydrate with .body scope.
            let contentVC = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            let toolbar = HistoryToolbar()
            toolbar.delegate = contentVC
            contentVC.attachToolbar(toolbar)
            defer { TestSupport.drainDelayedPerforms([contentVC]) }
            _ = contentVC.view

            spyStore.resetRecordedCalls()
            let copyOCRMenu = NSMenuItem()
            copyOCRMenu.representedObject = ocrImageHeader
            contentVC.copyTextFromImageMenuItem(copyOCRMenu)
            #expect(spyStore.loadingContentCalls == [.init(id: ocrImageHeader.id, scope: .body)])
            #expect(harness.pasteboard.string(forType: .string) == ocrText40KB)

            spyStore.resetRecordedCalls()
            let copyQRMenu = NSMenuItem()
            copyQRMenu.representedObject = ocrImageHeader
            contentVC.copyTextFromQRCodeMenuItem(copyQRMenu)
            #expect(spyStore.loadingContentCalls == [.init(id: ocrImageHeader.id, scope: .body)])
            #expect(harness.pasteboard.string(forType: .string) == qrText40KB)
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })

            // 3. openInBrowser & openInAssociatedApplication on >8 KB URLs hydrate .body without launching any browser!
            let contextMenuBuilder = HistoryItemContextMenu(
                target: contentVC,
                availableTags: [],
                preferences: harness.model.preferences
            )
            spyStore.resetRecordedCalls()
            let linkMenuTitles = contextMenuBuilder.makeMenu(for: linkHeader).items.map(\.title)
            #expect(linkMenuTitles.contains(L10n.string("Open in Browser")))
            #expect(linkMenuTitles.contains(L10n.string("Transform")))
            #expect(spyStore.loadingContentCalls.isEmpty)

            spyStore.suppressBrowserURLOnLoadingContent = true
            defer { spyStore.suppressBrowserURLOnLoadingContent = false }

            spyStore.resetRecordedCalls()
            harness.coordinator.openInBrowser(linkHeader)
            #expect(spyStore.loadingContentCalls == [.init(id: linkHeader.id, scope: .body)])
            #expect(spyStore.resolvedBrowserURLsOnLoadingContent.map(\.absoluteString) == [longURLString])

            spyStore.resetRecordedCalls()
            harness.coordinator.openInAssociatedApplication(linkHeader)
            #expect(spyStore.loadingContentCalls == [.init(id: linkHeader.id, scope: .body)])
            #expect(spyStore.resolvedBrowserURLsOnLoadingContent.map(\.absoluteString) == [longURLString])
            spyStore.suppressBrowserURLOnLoadingContent = false
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })

            // 4. transform(..., using: .upperCase) hydrates .body (skipping html/rtf even on .richText) and keeps model unloaded.
            spyStore.resetRecordedCalls()
            harness.coordinator.transform(richHeader, using: .upperCase)
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .body)])
            let transformedRichHeader = try #require(harness.currentItem(richHeader.id))
            #expect(!transformedRichHeader.isContentLoaded)
            #expect(!transformedRichHeader.hasFormatting)
            let hydratedTransformed = try spyStore.base.loadingContent(of: transformedRichHeader, scope: .full)
            #expect(hydratedTransformed.text == richText40KB.uppercased())
            #expect(hydratedTransformed.html == nil)
            #expect(hydratedTransformed.rtfData == nil)

            // 5. canMerge (0 reads) + merge (.body scope + deleteExistingMatches spares favorite/tagged/titled!) + Copy & Merge onto unloaded target.
            spyStore.resetRecordedCalls()
            #expect(harness.coordinator.canMerge([textHeader, transformedRichHeader]))
            #expect(!harness.coordinator.canMerge([textHeader, ocrImageHeader]))
            #expect(spyStore.loadingContentCalls.isEmpty)

            let mergeTag = try spyStore.createTag(name: "KeepOnMerge", color: "#EE5522")
            harness.model.tags = [mergeTag]
            let mergePartA = ClipboardItem.fixture(
                kind: .text,
                text: String(repeating: "m", count: 20_000),
                copiedAt: baseTime.addingTimeInterval(60)
            )
            let mergePartB = ClipboardItem.fixture(
                kind: .text,
                text: "Joined_\(Self.sentinel)",
                copiedAt: baseTime.addingTimeInterval(61)
            )
            let expectedMergedBody = "\(String(repeating: "m", count: 20_000))\nJoined_\(Self.sentinel)"

            let plainDup = ClipboardItem.fixture(
                kind: .text,
                text: expectedMergedBody,
                copiedAt: baseTime.addingTimeInterval(56)
            )
            let favoritedSameText = ClipboardItem.fixture(
                kind: .text,
                text: expectedMergedBody,
                copiedAt: baseTime.addingTimeInterval(57),
                isFavorite: true
            )
            let taggedSameText = ClipboardItem.fixture(
                kind: .text,
                text: expectedMergedBody,
                copiedAt: baseTime.addingTimeInterval(58),
                tags: [mergeTag.id]
            )
            let titledSameText = ClipboardItem.fixture(
                kind: .text,
                title: "Protected User Title",
                text: expectedMergedBody,
                copiedAt: baseTime.addingTimeInterval(59)
            )
            for item in [plainDup, favoritedSameText, taggedSameText, titledSameText, mergePartA, mergePartB] {
                try spyStore.saveAndReconcileItem(item, convertingExternalAssets: true)
            }
            harness.coordinator.loadHistory(sweepsCaches: false)

            let partAHeader = try #require(harness.currentItem(mergePartA.id))
            let partBHeader = try #require(harness.currentItem(mergePartB.id))
            spyStore.resetRecordedCalls()
            harness.coordinator.merge([partAHeader, partBHeader])
            #expect(spyStore.loadingContentCalls.allSatisfy { $0.scope == .body })
            #expect(harness.currentItem(plainDup.id) == nil, "Plain unkept duplicate must be deduplicated by deleteExistingMatches")
            #expect(harness.currentItem(favoritedSameText.id) != nil, "Favorited item with identical text must NEVER be deleted on merge")
            #expect(harness.currentItem(taggedSameText.id) != nil, "Tagged item with identical text must NEVER be deleted on merge")
            #expect(harness.currentItem(titledSameText.id) != nil, "Titled item with identical text must NEVER be deleted on merge")
            let mergedTop = try #require(harness.model.items.first)
            #expect(!mergedTop.isContentLoaded)
            #expect(try spyStore.base.loadingContent(of: mergedTop, scope: .body).text == expectedMergedBody)

            // Double-copy Copy & Merge onto an unloaded >8 KB target item in SQLite.
            harness.model.preferences.copyAndMergeEnabled = true
            harness.model.preferences.copyAndMergeSeparator = CopyAndMergeSeparatorPreference.space.rawValue
            harness.model.preferences.copyToClipboardAfterMerge = true
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)

            harness.pasteboard.clearContents()
            harness.pasteboard.setString("DOUBLE_COPY_SUFFIX", forType: .string)
            await harness.clipboardMonitor.pollAndWaitForDelivery()
            harness.pasteboard.clearContents()
            harness.pasteboard.setString("DOUBLE_COPY_SUFFIX", forType: .string)
            await harness.clipboardMonitor.pollAndWaitForDelivery()

            let copyMergedHeader = try #require(harness.model.items.first)
            #expect(!copyMergedHeader.isContentLoaded)
            #expect(copyMergedHeader.storedContentKey != nil)
            #expect(
                try spyStore.base.loadingContent(of: copyMergedHeader, scope: .body).text
                    == "\(expectedMergedBody) DOUBLE_COPY_SUFFIX"
            )
            harness.model.preferences.copyAndMergeEnabled = false
            harness.clipboardMonitor.updatePreferences(harness.model.preferences)

            // 6. canSplit & split with newlines past char 10,000 keeps newly split items unloaded.
            let singleLineShort = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: "Single line without newline", copiedAt: baseTime.addingTimeInterval(70)),
                convertingExternalAssets: true
            )
            let splitPast10KText = String(repeating: "L", count: 10_500) + "\nSecondLine_\(Self.sentinel)"
            let splitSourceSaved = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: splitPast10KText, copiedAt: baseTime.addingTimeInterval(71)),
                convertingExternalAssets: true
            )
            harness.coordinator.loadHistory(sweepsCaches: false)

            let shortHeader = try #require(harness.currentItem(singleLineShort.id))
            let splitSourceHeader = try #require(harness.currentItem(splitSourceSaved.id))
            spyStore.resetRecordedCalls()
            #expect(!harness.coordinator.canSplit(shortHeader))
            #expect(spyStore.loadingContentCalls.isEmpty)

            #expect(harness.coordinator.canSplit(splitSourceHeader))
            #expect(spyStore.loadingContentCalls == [.init(id: splitSourceHeader.id, scope: .body)])

            spyStore.resetRecordedCalls()
            harness.coordinator.split(splitSourceHeader)
            #expect(spyStore.loadingContentCalls == [.init(id: splitSourceHeader.id, scope: .body)])
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })
            #expect(harness.model.items[0].characterCount == 10_500)
            #expect(
                try spyStore.base.loadingContent(of: harness.model.items[1], scope: .body).text
                    == "SecondLine_\(Self.sentinel)"
            )

            // 7. editContent (.body scope) + blank edit to Trash + Undo + restore preserve unloaded headers & full bodies.
            let editableRichSaved = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(
                    kind: .richText,
                    text: Self.make40KBBody(prefix: "BeforeEdit "),
                    rtfData: richRTF40KB,
                    html: richHTML40KB,
                    copiedAt: baseTime.addingTimeInterval(80)
                ),
                convertingExternalAssets: true
            )
            harness.coordinator.loadHistory(sweepsCaches: false)
            let editableHeader = try #require(harness.currentItem(editableRichSaved.id))
            let edited40KB = Self.make40KBBody(prefix: "AfterEdit ")

            spyStore.resetRecordedCalls()
            harness.coordinator.editContent(editableHeader, text: edited40KB)
            #expect(spyStore.loadingContentCalls == [.init(id: editableHeader.id, scope: .body)])
            let afterEditHeader = try #require(harness.currentItem(editableHeader.id))
            #expect(!afterEditHeader.isContentLoaded)
            #expect(!afterEditHeader.hasFormatting)
            #expect(try spyStore.base.loadingContent(of: afterEditHeader, scope: .body).text == edited40KB)

            // Blank edit moves to Trash; Undo and explicit putBack keep headers unloaded while preserving 40 KB body.
            harness.coordinator.editContent(afterEditHeader, text: "   \n ")
            #expect(harness.currentItem(editableHeader.id) == nil)
            harness.model.trashedItems = try spyStore.fetchTrashedItems()
            #expect(harness.model.trashedItems.allSatisfy { !$0.isContentLoaded })

            harness.coordinator.undoHistoryChange()
            let restoredByUndo = try #require(harness.currentItem(editableHeader.id))
            #expect(!restoredByUndo.isContentLoaded)
            #expect(try spyStore.base.loadingContent(of: restoredByUndo, scope: .body).text == edited40KB)

            harness.coordinator.delete(restoredByUndo)
            harness.model.trashedItems = try spyStore.fetchTrashedItems()
            let trashedHeader = try #require(harness.model.trashedItems.first { $0.id == editableHeader.id })
            #expect(!trashedHeader.isContentLoaded)
            harness.coordinator.putBack([trashedHeader])
            let restoredExplicit = try #require(harness.currentItem(editableHeader.id))
            #expect(!restoredExplicit.isContentLoaded)
            #expect(try spyStore.base.loadingContent(of: restoredExplicit, scope: .body).text == edited40KB)

            // 8. setSensitiveContentLifetime(.dontSave) catches a secret at char 250,000 via containsRestSecret!
            let secretToken250K = ["ghp", "_", String(repeating: "k9M2pQ4r", count: 5)].joined()
            let tailSecret250KText = String(repeating: "p", count: 250_000) + " " + secretToken250K
            let tailSecretSaved = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: tailSecret250KText, copiedAt: baseTime.addingTimeInterval(90)),
                convertingExternalAssets: true
            )
            harness.coordinator.loadHistory(sweepsCaches: false)
            let tailSecretHeader = try #require(harness.currentItem(tailSecretSaved.id))
            #expect(!tailSecretHeader.isContentLoaded)
            #expect(!tailSecretHeader.containsPreviewSecret)
            #expect(tailSecretHeader.containsRestSecret)

            let confirmDeletionModal = OSAllocatedUnfairLock(initialState: true)
            RunLoop.main.perform(inModes: [.modalPanel]) {
                guard confirmDeletionModal.withLock({ state in
                    defer { state = false }
                    return state
                }) else { return }
                MainActor.assumeIsolated {
                    if NSApp.modalWindow != nil {
                        NSApp.stopModal(withCode: .alertFirstButtonReturn)
                    }
                }
            }
            harness.coordinator.setSensitiveContentLifetime(ContentLifetime.dontSave)
            confirmDeletionModal.withLock { $0 = false }
            #expect(harness.currentItem(tailSecretSaved.id) == nil)
            #expect(try !spyStore.base.fetchAll().contains { $0.id == tailSecretSaved.id })
            harness.coordinator.setSensitiveContentLifetime(ContentLifetime.keep)

            // 9. Tag rename & delete update both model.items and model.trashedItems in one batch with 0 N+1 upserts!
            let batchTag = try spyStore.createTag(name: "InitialBatchTag", color: "#00AA88")
            harness.model.tags = try spyStore.fetchTags()

            let activeTaggedA = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: "Active tagged A", copiedAt: baseTime.addingTimeInterval(100), tags: [batchTag.id]),
                convertingExternalAssets: true
            )
            let activeTaggedB = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: "Active tagged B", copiedAt: baseTime.addingTimeInterval(101), tags: [batchTag.id]),
                convertingExternalAssets: true
            )
            let trashedTagged = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(kind: .text, text: "Trashed tagged C", copiedAt: baseTime.addingTimeInterval(102), tags: [batchTag.id]),
                convertingExternalAssets: true
            )
            try spyStore.moveToTrash(ids: [trashedTagged.id], at: baseTime.addingTimeInterval(103))
            harness.coordinator.loadHistory(sweepsCaches: false)
            harness.model.trashedItems = try spyStore.fetchTrashedItems()

            let revActiveBefore = try #require(harness.currentItem(activeTaggedA.id)).searchRevision
            let revTrashedBefore = try #require(harness.model.trashedItems.first { $0.id == trashedTagged.id }).searchRevision

            spyStore.resetRecordedCalls()
            harness.coordinator.updateTag(batchTag, name: "RenamedBatchTag", color: .systemOrange)
            #expect(spyStore.upsertCallIDs.isEmpty, "updateTag must not run N+1 upserts")
            #expect(spyStore.loadingContentCalls.isEmpty, "updateTag must not hydrate bodies")
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })
            #expect(harness.model.trashedItems.allSatisfy { !$0.isContentLoaded })
            #expect(try #require(harness.currentItem(activeTaggedA.id)).searchRevision != revActiveBefore)
            #expect(try #require(harness.model.trashedItems.first { $0.id == trashedTagged.id }).searchRevision != revTrashedBefore)

            // Headless search immediately matches RenamedBatchTag in both Active and Trash.
            harness.model.searchQuery = "RenamedBatchTag"
            #expect(Set(harness.model.filteredItems.map(\.id)) == [activeTaggedA.id, activeTaggedB.id])
            harness.model.selectedHistoryFilterContentTypes = [.trash]
            #expect(harness.model.filteredItems.map(\.id) == [trashedTagged.id])
            harness.model.selectedHistoryFilterContentTypes = []
            harness.model.searchQuery = ""

            let renamedTag = try #require(harness.model.tags.first { $0.id == batchTag.id })
            spyStore.resetRecordedCalls()
            harness.coordinator.deleteTag(renamedTag)
            #expect(spyStore.upsertCallIDs.isEmpty, "deleteTag must not run N+1 upserts")
            #expect(spyStore.loadingContentCalls.isEmpty, "deleteTag must not hydrate bodies")
            #expect(try #require(harness.currentItem(activeTaggedA.id)).tags.isEmpty)
            #expect(try #require(harness.model.trashedItems.first { $0.id == trashedTagged.id }).tags.isEmpty)

            harness.model.searchQuery = "RenamedBatchTag"
            #expect(harness.model.filteredItems.isEmpty)
            harness.model.searchQuery = ""
        }
    }

    @Suite
    struct PreferencesSavingTests {
        struct ShortcutRow: Sendable, CustomTestStringConvertible {
            let identifier: GlobalShortcutIdentifier
            var hasDefault = true
            let edit: @MainActor @Sendable (inout AppPreferences) -> Void

            var testDescription: String { "\(identifier)" }
        }

        private static let shortcutRows = [
            ShortcutRow(identifier: .showHistory) { $0.showHistoryShortcut = "ctrl+shift+cmd+a" },
            ShortcutRow(identifier: .pauseCapture, hasDefault: false) { $0.pauseShortcut = "ctrl+shift+cmd+b" },
            ShortcutRow(identifier: .pasteNext) { $0.pasteNextShortcut = "ctrl+shift+cmd+c" },
            ShortcutRow(identifier: .pasteNextRich) { $0.pasteNextRichShortcut = "ctrl+shift+cmd+d" },
            ShortcutRow(identifier: .pasteNextAndDelete) { $0.pasteNextAndDeleteShortcut = "ctrl+shift+cmd+e" },
            ShortcutRow(identifier: .pasteNextRichAndDelete) { $0.pasteNextRichAndDeleteShortcut = "ctrl+shift+cmd+f" }
        ]

        @Test
        func everyGlobalShortcutHasARowAndAListedPreference() {
            #expect(Set(Self.shortcutRows.map(\.identifier)) == Set(GlobalShortcutIdentifier.allCases))
            #expect(AppPreferences().globalShortcuts.count == GlobalShortcutIdentifier.allCases.count)
        }

        /// Every configured global shortcut is registered by `configureShortcuts()`, and `savePreferences()`
        /// registers them again when `AppPreferences.globalShortcuts` changes.
        @Test(arguments: shortcutRows)
        @MainActor
        func changingAGlobalShortcutRegistersTheHotKeysAgain(row: ShortcutRow) throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.coordinator.savePreferences()
            #expect(harness.globalShortcuts.hasHandler(for: row.identifier) == row.hasDefault)
            let passes = harness.globalShortcuts.unregisterAllCallCount

            row.edit(&harness.model.preferences)
            harness.coordinator.savePreferences()

            #expect(harness.globalShortcuts.unregisterAllCallCount == passes + 1)
            #expect(harness.globalShortcuts.hasHandler(for: row.identifier))
        }

        struct ChangeRow: Sendable, CustomTestStringConvertible {
            let label: String
            let edit: @MainActor @Sendable (inout AppPreferences) -> Void
            let expected: AppCoordinator.PreferenceChanges

            var testDescription: String { label }
        }

        private static let none = AppCoordinator.PreferenceChanges(
            appearance: false, language: false, launchAtLogin: false, automaticUpdateChecks: false, globalShortcuts: false
        )

        private static let changeRows: [ChangeRow] = {
            func only(_ keyPath: WritableKeyPath<AppCoordinator.PreferenceChanges, Bool>) -> AppCoordinator.PreferenceChanges {
                var changes = none
                changes[keyPath: keyPath] = true
                return changes
            }
            return [
                ChangeRow(label: "nothing", edit: { _ in }, expected: none),
                ChangeRow(label: "an unrelated setting", edit: { $0.warnOnClearHistory.toggle() }, expected: none),
                ChangeRow(label: "appearance", edit: { $0.appearance = $0.appearance == .dark ? .light : .dark }, expected: only(\.appearance)),
                ChangeRow(label: "language", edit: { $0.language = $0.language == "de" ? "en" : "de" }, expected: only(\.language)),
                ChangeRow(label: "launch at login", edit: { $0.launchAtLogin.toggle() }, expected: only(\.launchAtLogin)),
                ChangeRow(label: "update checks", edit: { $0.checkForUpdatesAutomatically.toggle() }, expected: only(\.automaticUpdateChecks)),
                ChangeRow(label: "a global shortcut", edit: { $0.pauseShortcut = "ctrl+shift+cmd+b" }, expected: only(\.globalShortcuts)),
            ]
        }()

        @Test(arguments: changeRows)
        @MainActor
        func preferenceChangesListOnlyWhatChanged(row: ChangeRow) {
            let previous = AppPreferences()
            var current = previous
            row.edit(&current)
            #expect(AppCoordinator.preferenceChanges(from: previous, to: current) == row.expected)
        }

        @Test
        @MainActor
        func everythingCountsAsChangedBeforeTheFirstSave() {
            #expect(
                AppCoordinator.preferenceChanges(from: nil, to: AppPreferences())
                    == AppCoordinator.PreferenceChanges(
                        appearance: true, language: true, launchAtLogin: true, automaticUpdateChecks: true, globalShortcuts: true
                    )
            )
        }

        @Test
        @MainActor
        func savePreferencesReappliesOnlyChangedSettings() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            let coordinator = harness.coordinator

            let checksForUpdates = harness.model.preferences.checkForUpdatesAutomatically

            // The first save applies everything.
            coordinator.savePreferences()
            #expect(harness.updateService.automaticChecksEnabledValues == [checksForUpdates])
            let shortcutPasses = harness.globalShortcuts.unregisterAllCallCount

            // An unrelated setting leaves the update check and the hotkeys alone.
            harness.model.preferences.warnOnClearHistory.toggle()
            coordinator.savePreferences()
            coordinator.savePreferences()
            #expect(harness.updateService.automaticChecksEnabledValues == [checksForUpdates])
            #expect(harness.globalShortcuts.unregisterAllCallCount == shortcutPasses)

            // Changing the update check applies it once.
            harness.model.preferences.checkForUpdatesAutomatically = !checksForUpdates
            coordinator.savePreferences()
            coordinator.savePreferences()
            #expect(harness.updateService.automaticChecksEnabledValues == [checksForUpdates, !checksForUpdates])
            #expect(harness.globalShortcuts.unregisterAllCallCount == shortcutPasses)

            // Changing a global shortcut registers the hotkeys again, once.
            harness.model.preferences.pauseShortcut = "shift+cmd+o"
            coordinator.savePreferences()
            coordinator.savePreferences()
            #expect(harness.globalShortcuts.unregisterAllCallCount == shortcutPasses + 1)
        }
    }
}
