@testable import ClipBook
import AppKit
import Foundation
import SQLite3
import SwiftUI
import Testing

enum UpstreamInteropStubs {
    static let expectedAppPreferencesKeys: Set<String> = [
        "appearance",
        "language",
        "launchAtLogin",
        "showMainWindowAtStartup",
        "checkForUpdatesAutomatically",
        "soundEffectsEnabled",
        "playSoundOnCopy",
        "playSoundOnPaste",
        "playSoundOnDelete",
        "playSoundOnSelectionAdd",
        "playSoundOnSelectionRemove",
        "showMenuBarIcon",
        "openHistoryOnMenuBarIconClick",
        "hideOnFocusLoss",
        "openWindowStrategy",
        "historyWindowX",
        "historyWindowY",
        "historyWindowWidth",
        "historyWindowHeight",
        "settingsWindowX",
        "settingsWindowY",
        "settingsWindowWidth",
        "settingsWindowHeight",
        "historySortOption",
        "isHistorySortReversed",
        "copySequenceModeEnabled",
        "pinFavoritesToTop",
        "singleClickAction",
        "updateHistoryAfterAction",
        "rememberHistorySelection",
        "copyAndMergeEnabled",
        "copyToClipboardAfterMerge",
        "copyAndMergeSeparator",
        "multiPasteKey",
        "showPreviewForLinks",
        "highlightCodeSyntax",
        "showCommandNumberShortcut",
        "showHistoryDividers",
        "showPreviewPane",
        "showPreviewPaneDetails",
        "showImagesAsTiles",
        "compactHistory",
        "previewPaneHeight",
        "previewPaneWidthRatio",
        "treatDigitNumbersAsColor",
        "preferPastingAsPlainText",
        "doubleClickAction",
        "numberKeyAction",
        "ignoreTransientContent",
        "confidentialContentLifetime",
        "detectSensitiveContent",
        "sensitiveContentLifetime",
        "showDuringScreenSharing",
        "ignoredAppsText",
        "textRetentionDays",
        "richTextRetentionDays",
        "imageRetentionDays",
        "fileRetentionDays",
        "linkRetentionDays",
        "emailRetentionDays",
        "colorRetentionDays",
        "keepFavoritesOnClearHistory",
        "trashRetentionDays",
        "warnOnClearHistory",
        "clearHistoryOnQuit",
        "clearHistoryOnReboot",
        "showHistoryShortcut",
        "pauseShortcut",
        "pasteNextShortcut",
        "pasteNextRichShortcut",
        "pasteNextAndDeleteShortcut",
        "pasteNextRichAndDeleteShortcut",
        "closeHistoryShortcut",
        "closeHistorySecondaryShortcut",
        "closeHistoryTertiaryShortcut",
        "selectNextItemShortcut",
        "selectPreviousItemShortcut",
        "pasteSelectedShortcut",
        "pasteSelectedSecondaryShortcut",
        "pasteAndDeleteSelectedShortcut",
        "pasteAndDeleteSelectedSecondaryShortcut",
        "copySelectedShortcut",
        "copySelectedSecondaryShortcut",
        "deleteItemShortcut",
        "toggleFavoriteShortcut",
        "showInFinderShortcut",
        "openInBrowserShortcut",
        "editItemShortcut",
        "renameItemShortcut",
        "transformItemShortcut",
        "focusSearchFieldShortcut",
        "openSettingsShortcut",
        "showCommandPaletteShortcut",
        "showInHistoryShortcut",
        "togglePreviewPaneShortcut",
        "toggleDetailsShortcut",
        "toggleSensitiveContentShortcut",
        "licenseKey",
        "hasMigratedV1LicenseKey",
        "hasClearedLegacyPauseShortcut",
        "hasCompletedOnboarding",
        "hasProvidedTrialExpiredFeedback",
        "trialExpiredAt",
        "trialDiscountOfferedAt",
        "dismissedTrialNoticeDaysLeft"
    ]

    static let expectedClipboardItemKeys: Set<String> = [
        "id",
        "kind",
        "title",
        "text",
        "qrCodeText",
        "rtfData",
        "html",
        "hasFormatting",
        "htmlDigest",
        "imageDigest",
        "assetPath",
        "filePaths",
        "sourceAppName",
        "sourceBundleIdentifier",
        "copiedAt",
        "firstCopiedAt",
        "byteSize",
        "isFavorite",
        "tags",
        "searchText",
        "copyCount",
        "linkPreviewDetails",
        "copySequenceID",
        "copySequenceOrder",
        "favoriteOrder",
        "tagOrders",
        "sensitivity",
        "expiresAt"
    ]

    enum UpstreamAppAppearanceStub: String, Codable, CaseIterable, Equatable {
        case system
        case light
        case dark
    }

    struct UpstreamAppPreferencesStub: Codable, Equatable {
        var appearance: UpstreamAppAppearanceStub
        var language: String
        var launchAtLogin: Bool
        var showMainWindowAtStartup: Bool
        var checkForUpdatesAutomatically: Bool
        var soundEffectsEnabled: Bool
        var playSoundOnCopy: Bool
        var playSoundOnPaste: Bool
        var playSoundOnDelete: Bool
        var playSoundOnSelectionAdd: Bool
        var playSoundOnSelectionRemove: Bool
        var showMenuBarIcon: Bool
        var openHistoryOnMenuBarIconClick: Bool
        var hideOnFocusLoss: Bool
        var openWindowStrategy: String
        var historyWindowX: Double?
        var historyWindowY: Double?
        var historyWindowWidth: Double?
        var historyWindowHeight: Double?
        var settingsWindowX: Double?
        var settingsWindowY: Double?
        var settingsWindowWidth: Double?
        var settingsWindowHeight: Double?
        var historySortOption: String
        var isHistorySortReversed: Bool
        var copySequenceModeEnabled: Bool
        var pinFavoritesToTop: Bool
        var singleClickAction: String
        var updateHistoryAfterAction: Bool
        var rememberHistorySelection: Bool
        var copyAndMergeEnabled: Bool
        var copyToClipboardAfterMerge: Bool
        var copyAndMergeSeparator: String
        var multiPasteKey: String
        var showPreviewForLinks: Bool
        var highlightCodeSyntax: Bool
        var showCommandNumberShortcut: Bool
        var showHistoryDividers: Bool
        var showPreviewPane: Bool
        var showPreviewPaneDetails: Bool
        var showImagesAsTiles: Bool
        var compactHistory: Bool
        var previewPaneHeight: Double?
        var previewPaneWidthRatio: Double?
        var treatDigitNumbersAsColor: Bool
        var preferPastingAsPlainText: Bool
        var doubleClickAction: String
        var numberKeyAction: String
        var ignoreTransientContent: Bool
        var confidentialContentLifetime: Int
        var detectSensitiveContent: Bool
        var sensitiveContentLifetime: Int
        var showDuringScreenSharing: Bool
        var ignoredAppsText: String
        var textRetentionDays: Int
        var richTextRetentionDays: Int
        var imageRetentionDays: Int
        var fileRetentionDays: Int
        var linkRetentionDays: Int
        var emailRetentionDays: Int
        var colorRetentionDays: Int
        var keepFavoritesOnClearHistory: Bool
        var trashRetentionDays: Int
        var warnOnClearHistory: Bool
        var clearHistoryOnQuit: Bool
        var clearHistoryOnReboot: Bool
        var showHistoryShortcut: String
        var pauseShortcut: String
        var pasteNextShortcut: String
        var pasteNextRichShortcut: String
        var pasteNextAndDeleteShortcut: String
        var pasteNextRichAndDeleteShortcut: String
        var closeHistoryShortcut: String
        var closeHistorySecondaryShortcut: String
        var closeHistoryTertiaryShortcut: String
        var selectNextItemShortcut: String
        var selectPreviousItemShortcut: String
        var pasteSelectedShortcut: String
        var pasteSelectedSecondaryShortcut: String
        var pasteAndDeleteSelectedShortcut: String
        var pasteAndDeleteSelectedSecondaryShortcut: String
        var copySelectedShortcut: String
        var copySelectedSecondaryShortcut: String
        var deleteItemShortcut: String
        var toggleFavoriteShortcut: String
        var showInFinderShortcut: String
        var openInBrowserShortcut: String
        var editItemShortcut: String
        var renameItemShortcut: String
        var transformItemShortcut: String
        var focusSearchFieldShortcut: String
        var openSettingsShortcut: String
        var showCommandPaletteShortcut: String
        var showInHistoryShortcut: String
        var togglePreviewPaneShortcut: String
        var toggleDetailsShortcut: String
        var toggleSensitiveContentShortcut: String
        var licenseKey: String
        var hasMigratedV1LicenseKey: Bool
        var hasClearedLegacyPauseShortcut: Bool
        var hasCompletedOnboarding: Bool
        var hasProvidedTrialExpiredFeedback: Bool
        var trialExpiredAt: Date?
        var trialDiscountOfferedAt: Date?
        var dismissedTrialNoticeDaysLeft: Int?
    }

    enum UpstreamClipboardKindStub: String, Codable, CaseIterable, Equatable {
        case text
        case richText
        case image
        case file
        case link
        case email
        case color
    }

    struct UpstreamLinkPreviewDetailsStub: Codable, Equatable {
        var url: String
        var title: String?
        var description: String?
        var imagePath: String?
        var faviconPath: String?
        var fetchedAt: Date
    }

    struct UpstreamClipboardItemStub: Codable, Equatable {
        var id: UUID
        var kind: UpstreamClipboardKindStub
        var title: String?
        var text: String?
        var qrCodeText: String?
        var rtfData: Data?
        var html: String?
        var hasFormatting: Bool?
        var htmlDigest: String?
        var imageDigest: String?
        var assetPath: String?
        var filePaths: [String]
        var sourceAppName: String?
        var sourceBundleIdentifier: String?
        var copiedAt: Date
        var firstCopiedAt: Date?
        var byteSize: Int
        var isFavorite: Bool
        var tags: [Int]
        var searchText: String
        var copyCount: Int
        var linkPreviewDetails: UpstreamLinkPreviewDetailsStub?
        var copySequenceID: Date?
        var copySequenceOrder: Int?
        var favoriteOrder: Int?
        var tagOrders: [Int: Int]?
        var sensitivity: String?
        var expiresAt: Date?
    }

    static let expectedArchiveManifestKeys: Set<String> = [
        "formatVersion",
        "appName",
        "appVersion",
        "exportedAt"
    ]

    static let expectedArchiveTagKeys: Set<String> = [
        "id",
        "name",
        "color"
    ]

    static let expectedArchiveLinkPreviewDetailsKeys: Set<String> = [
        "url",
        "title",
        "description",
        "imagePath",
        "faviconPath",
        "fetchedAt"
    ]

    static let expectedArchiveItemKeys: Set<String> = [
        "id",
        "kind",
        "title",
        "text",
        "qrCodeText",
        "rtfBase64",
        "html",
        "assetPath",
        "filePaths",
        "sourceAppName",
        "sourceBundleIdentifier",
        "copiedAt",
        "firstCopiedAt",
        "byteSize",
        "isFavorite",
        "tagIDs",
        "tagNames",
        "copyCount",
        "linkPreviewDetails",
        "copySequenceID",
        "copySequenceOrder",
        "favoriteOrder",
        "tagOrders",
        "sensitivity"
    ]

    struct UpstreamArchiveManifestStub: Codable, Equatable {
        var formatVersion: Int
        var appName: String
        var appVersion: String?
        var exportedAt: Date
    }

    struct UpstreamArchiveTagStub: Codable, Equatable {
        var id: String
        var name: String
        var color: String
    }

    struct UpstreamArchiveItemStub: Codable, Equatable {
        var id: UUID
        var kind: String
        var title: String?
        var text: String?
        var qrCodeText: String?
        var rtfBase64: String?
        var html: String?
        var assetPath: String?
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
        var linkPreviewDetails: UpstreamLinkPreviewDetailsStub?
        var copySequenceID: Date?
        var copySequenceOrder: Int?
        var favoriteOrder: Int?
        var tagOrders: [String: Int]?
        var sensitivity: String?
    }

    static func makeFullyPopulatedPreferences() -> AppPreferences {
        var prefs = AppPreferences()
        prefs.appearance = .dark
        prefs.historyWindowX = 120
        prefs.historyWindowY = 140
        prefs.historyWindowWidth = 640
        prefs.historyWindowHeight = 720
        prefs.settingsWindowX = 200
        prefs.settingsWindowY = 220
        prefs.settingsWindowWidth = 680
        prefs.settingsWindowHeight = 720
        prefs.rememberHistorySelection = true // sets updateHistoryAfterAction = false
        prefs.previewPaneHeight = 260
        prefs.previewPaneWidthRatio = 0.45
        prefs.trialExpiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.trialDiscountOfferedAt = Date(timeIntervalSince1970: 1_700_000_600)
        prefs.dismissedTrialNoticeDaysLeft = 3
        return prefs
    }
}

@Suite
struct UpstreamInteropContractTests {
    @Test
    @MainActor
    func appPreferencesWireLockAndForkPreferencesCoordinatorRoundTrip() throws {
        let populated = UpstreamInteropStubs.makeFullyPopulatedPreferences()
        #expect(!populated.updateHistoryAfterAction)
        #expect(populated.rememberHistorySelection)

        let data = try JSONEncoder().encode(populated)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(jsonObject.keys) == UpstreamInteropStubs.expectedAppPreferencesKeys)

        #expect(
            Set(AppAppearance.allCases.map(\.rawValue))
                == Set(UpstreamInteropStubs.UpstreamAppAppearanceStub.allCases.map(\.rawValue))
        )
        #expect(Set(AppAppearance.allCases.map(\.rawValue)) == ["system", "light", "dark"])
        #expect(
            Set(HistoryWindowOpenStrategy.allCases.map(\.rawValue))
                == ["lastLocation", "activeScreenCenter", "activeWindowCenter", "screenWithCursor", "mouseCursor", "inputCursor"]
        )
        #expect(
            Set(HistorySortOption.allCases.map(\.rawValue))
                == ["Last Copy Time", "First Copy Time", "Number of Copies", "Size"]
        )
        #expect(
            Set(HistoryItemClickActionPreference.allCases.map(\.rawValue))
                == ["select", "paste", "copy"]
        )
        #expect(
            Set(CopyAndMergeSeparatorPreference.allCases.map(\.rawValue))
                == ["newLine", "space", "comma", "empty"]
        )
        #expect(
            Set(PasteInterItemAction.allCases.map(\.rawValue))
                == ["none", "returnKey", "shiftReturn", "keyUp", "keyDown", "tab", "space", "commaSpace"]
        )
        #expect(
            Set(HistoryItemActionPreference.allCases.map(\.rawValue))
                == ["paste", "copy"]
        )

        let upstreamStub = try JSONDecoder().decode(UpstreamInteropStubs.UpstreamAppPreferencesStub.self, from: data)
        #expect(upstreamStub.appearance == .dark)
        #expect(upstreamStub.openWindowStrategy == "activeScreenCenter")
        #expect(upstreamStub.historySortOption == "Last Copy Time")
        #expect(upstreamStub.singleClickAction == "select")
        #expect(upstreamStub.copyAndMergeSeparator == "newLine")
        #expect(upstreamStub.multiPasteKey == "shiftReturn")
        #expect(upstreamStub.doubleClickAction == "paste")
        #expect(upstreamStub.numberKeyAction == "paste")
        #expect(upstreamStub.hasClearedLegacyPauseShortcut)

        // Defensive decoding of ClipBookForkPreferencesV1 on missing, empty, forward-compatible, or malformed payloads.
        try TestSupport.withIsolatedUserDefaults { defaults in
            let store = PreferencesStore(userDefaults: defaults)
            #expect(store.loadForkPreferences() == ForkPreferences())

            defaults.set(Data("{}".utf8), forKey: ForkPreferences.userDefaultsKey)
            #expect(store.loadForkPreferences() == ForkPreferences())

            defaults.set(Data("{\"schemaVersion\": 2, \"futureFlag\": true}".utf8), forKey: ForkPreferences.userDefaultsKey)
            #expect(store.loadForkPreferences() == ForkPreferences(schemaVersion: 2))

            defaults.set(Data("{\"schemaVersion\": \"invalid\"}".utf8), forKey: ForkPreferences.userDefaultsKey)
            #expect(store.loadForkPreferences() == ForkPreferences())

            defaults.set(Data("not-valid-json".utf8), forKey: ForkPreferences.userDefaultsKey)
            #expect(store.loadForkPreferences() == ForkPreferences())
        }

        // Coordinator persistPreferences() -> simulated Upstream edit -> loadAndReconcilePreferences().
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        harness.model.forkPreferences = ForkPreferences(schemaVersion: 2)
        harness.coordinator.persistPreferences()

        let rawMainPrefs = try #require(harness.preferencesStore.userDefaults.data(forKey: "ClipBookPreferencesV2"))
        var editedByUpstream = try JSONDecoder().decode(
            UpstreamInteropStubs.UpstreamAppPreferencesStub.self,
            from: rawMainPrefs
        )
        editedByUpstream.compactHistory = true
        harness.preferencesStore.userDefaults.set(
            try JSONEncoder().encode(editedByUpstream),
            forKey: "ClipBookPreferencesV2"
        )

        harness.model.preferences.compactHistory = false
        harness.model.forkPreferences = ForkPreferences(schemaVersion: 1)
        harness.coordinator.loadAndReconcilePreferences()

        #expect(harness.model.preferences.compactHistory == true)
        #expect(harness.model.forkPreferences.schemaVersion == 2)
    }

    @Test
    @MainActor
    func bootTimeKeyThreeHopContractAcrossForkAndUpstream() throws {
        #expect(PreferencesStore.kernelBootTimeKey == "ClipBookLastKnownKernelBootTime")
        #expect(PreferencesStore.legacyUptimeBootTimeKey == "ClipBookLastKnownBootTime")

        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        let seededFavorite = ClipboardItem.fixture(
            text: "Pinned reboot interop sentinel",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_050),
            isFavorite: true
        )
        let seeded = ClipboardItem.fixture(
            text: "Reboot interop sentinel",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try harness.seedHistory([seededFavorite, seeded])

        harness.model.preferences.clearHistoryOnReboot = true
        harness.model.preferences.warnOnClearHistory = false
        harness.model.preferences.keepFavoritesOnClearHistory = true
        harness.model.preferences.trashRetentionDays = 0

        let defaults = harness.preferencesStore.userDefaults
        // Pre-existing Upstream `ClipBookLastKnownBootTime` before first Fork upgrade launch.
        defaults.set(1_700_003_600.0, forKey: "ClipBookLastKnownBootTime")
        #expect(harness.preferencesStore.lastKnownKernelBootTime() == nil)

        // Hop 1: First Fork launch after Upstream upgrade with 2h prior sleep drift does not wipe history.
        harness.coordinator.clearHistoryAfterRebootIfNeeded(
            kernelBootTime: 1_700_000_000,
            uptimeRelativeBootTime: 1_700_007_200
        )
        #expect(Set(harness.model.items.map(\.id)) == [seededFavorite.id, seeded.id])
        #expect(defaults.object(forKey: "ClipBookLastKnownKernelBootTime") as? Double == 1_700_000_000)
        #expect(defaults.object(forKey: "ClipBookLastKnownBootTime") as? Double == 1_700_007_200)

        // Hop 2: Simulated Upstream <=2.5.2 and Upstream 3b6d73c check `ClipBookLastKnownBootTime`.
        let prevLegacy = defaults.double(forKey: "ClipBookLastKnownBootTime")
        let upstreamCheckBootTime: TimeInterval = 1_700_007_205
        #expect((abs(prevLegacy - upstreamCheckBootTime) > 60) == false)
        // Upstream 3b6d73c also checks `systemUptime` against `ClipBookLastKnownBootTime` and updates it.
        defaults.set(upstreamCheckBootTime, forKey: "ClipBookLastKnownBootTime")
        #expect(Set(harness.model.items.map(\.id)) == [seededFavorite.id, seeded.id])

        // Hop 3: Fork relaunches after another hour of sleep; kernelBootTime is unchanged.
        #expect(harness.preferencesStore.lastKnownKernelBootTime() == 1_700_000_000)
        harness.coordinator.clearHistoryAfterRebootIfNeeded(
            kernelBootTime: 1_700_000_000,
            uptimeRelativeBootTime: 1_700_010_800
        )
        #expect(Set(harness.model.items.map(\.id)) == [seededFavorite.id, seeded.id])
        #expect(defaults.object(forKey: "ClipBookLastKnownKernelBootTime") as? Double == 1_700_000_000)
        #expect(defaults.object(forKey: "ClipBookLastKnownBootTime") as? Double == 1_700_010_800)

        // Hop 4: Actual kernel reboot clears non-favorited history while preserving favorited items.
        harness.coordinator.clearHistoryAfterRebootIfNeeded(
            kernelBootTime: 1_700_020_000,
            uptimeRelativeBootTime: 1_700_020_010
        )
        #expect(harness.model.items.map(\.id) == [seededFavorite.id])
        #expect(defaults.object(forKey: "ClipBookLastKnownKernelBootTime") as? Double == 1_700_020_000)
        #expect(defaults.object(forKey: "ClipBookLastKnownBootTime") as? Double == 1_700_020_010)
    }

    @Test
    func sqliteSchemaVersionFourPayloadWireLockAndVacuumRoundTrip() throws {
        #expect(
            Set(ClipboardKind.allCases.map(\.rawValue))
                == Set(UpstreamInteropStubs.UpstreamClipboardKindStub.allCases.map(\.rawValue))
        )

        try TestSupport.withTemporaryDirectory { supportDirectory in
            let fileManager = FileManager.default
            let keyProvider = InMemoryDatabaseKeyProvider()
            let clipAID = UUID()
            let clipBID = UUID()
            let clipCID = UUID()
            let clipARtfData = Data(#"{\rtf1\ansi\b Initial Fork Clip A\b0}"#.utf8)
            let clipAHtml = "<b>Initial Fork Clip A</b>"

            let sourcePreviewURL = supportDirectory.appendingPathComponent("b-preview.png")
            let sourceFaviconURL = supportDirectory.appendingPathComponent("b-favicon.ico")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA]).write(to: sourcePreviewURL)
            try Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00]).write(to: sourceFaviconURL)

            var createdTagID = 0
            let clipBPreviewFetchedAt = Date(timeIntervalSince1970: 1_700_000_210)
            let clipBSequenceID = Date(timeIntervalSince1970: 1_700_000_200)
            let clipBExpiresAt = Date(timeIntervalSince1970: 1_700_003_800)

            var clipA: ClipboardItem!
            var clipB: ClipboardItem!
            var clipC: ClipboardItem!

            do {
                let store = GRDBHistoryStore(directory: supportDirectory, keyProvider: keyProvider)
                defer { store.close() }

                let tag = try store.createTag(name: "InteropTag", color: "#3366FF")
                createdTagID = tag.id

                clipA = ClipboardItem.fixture(
                    id: clipAID,
                    kind: .richText,
                    title: "Initial Title A",
                    text: "Initial Fork Clip A",
                    rtfData: clipARtfData,
                    html: clipAHtml,
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_050),
                    tags: [tag.id]
                )
                clipA.tagOrders = [tag.id: 4]

                clipB = ClipboardItem.fixture(
                    id: clipBID,
                    kind: .link,
                    text: "https://example.com/b",
                    qrCodeText: "https://qr.example/b",
                    filePaths: ["/Users/alice/Documents/notes.txt"],
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    isFavorite: true,
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://example.com/b",
                        title: "Example B",
                        description: "Preview summary",
                        imagePath: sourcePreviewURL.path,
                        faviconPath: sourceFaviconURL.path,
                        fetchedAt: clipBPreviewFetchedAt
                    ),
                    copySequenceID: clipBSequenceID,
                    copySequenceOrder: 2,
                    favoriteOrder: 1,
                    sensitivity: .sensitive
                )
                clipB.expiresAt = clipBExpiresAt

                clipC = ClipboardItem.fixture(
                    id: clipCID,
                    kind: .image,
                    text: nil,
                    assetPath: "Images/\(clipCID.uuidString).png",
                    imageDigest: "sha256-clip-c",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_150),
                    byteSize: 512
                )

                // Lock ClipboardItem Codable wire schema for v0-v4 migration & v1 archives (28 keys).
                let wireEncoder = JSONEncoder()
                wireEncoder.dateEncodingStrategy = .iso8601
                let wireDecoder = JSONDecoder()
                wireDecoder.dateDecodingStrategy = .iso8601
                var unionOfEncodedKeys: Set<String> = []
                for candidate in [clipA!, clipB!, clipC!] {
                    let encoded = try wireEncoder.encode(candidate)
                    let rawJSON = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                    let rowKeys = Set(rawJSON.keys)
                    #expect(rowKeys.isSubset(of: UpstreamInteropStubs.expectedClipboardItemKeys))
                    unionOfEncodedKeys.formUnion(rowKeys)
                    if let previewJSON = rawJSON["linkPreviewDetails"] as? [String: Any] {
                        #expect(Set(previewJSON.keys) == UpstreamInteropStubs.expectedArchiveLinkPreviewDetailsKeys)
                    }
                    let decodedStub = try wireDecoder.decode(
                        UpstreamInteropStubs.UpstreamClipboardItemStub.self,
                        from: encoded
                    )
                    #expect(decodedStub.id == candidate.id)
                }
                #expect(unionOfEncodedKeys == UpstreamInteropStubs.expectedClipboardItemKeys)

                try store.upsert(clipA)
                try store.upsert(clipB)
                try store.upsert(clipC)
            }

            let dbPath = supportDirectory.appendingPathComponent("History.sqlite").path
            do {
                var rawDB: OpaquePointer?
                defer {
                    if let rawDB {
                        sqlite3_close(rawDB)
                    }
                }
                #expect(sqlite3_open(dbPath, &rawDB) == SQLITE_OK)
                let db = try #require(rawDB)

                // 1. PRAGMA user_version == 5
                do {
                    var stmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    #expect(sqlite3_step(stmt) == SQLITE_ROW)
                    #expect(sqlite3_column_int(stmt, 0) == 5)
                }

                // 2. Normalized v5 tables exist (`clips`, `clip_contents`, `clip_tags`, `tags`, `store_metadata`).
                do {
                    var stmt: OpaquePointer?
                    let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
                    #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    var tables: Set<String> = []
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let namePtr = sqlite3_column_text(stmt, 0) {
                            tables.insert(String(cString: namePtr))
                        }
                    }
                    #expect(tables == ["clips", "clip_contents", "clip_tags", "tags", "store_metadata"])
                }

                // 3. `clips` omits `payload`, `html`, `rtf`, and `searchText` (`SEC-006`), so legacy Upstream
                //    `SELECT payload FROM clips` fails `sqlite3_prepare_v2` cleanly before `removeOrphanedStoredFiles()` can run.
                do {
                    var infoStmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, "PRAGMA table_info(clips);", -1, &infoStmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(infoStmt) }
                    var clipColumnNames: Set<String> = []
                    while sqlite3_step(infoStmt) == SQLITE_ROW {
                        if let colPtr = sqlite3_column_text(infoStmt, 1) {
                            clipColumnNames.insert(String(cString: colPtr))
                        }
                    }
                    #expect(!clipColumnNames.contains("payload"))
                    #expect(!clipColumnNames.contains("html"))
                    #expect(!clipColumnNames.contains("rtf"))
                    #expect(!clipColumnNames.contains("searchText"))

                    var legacyPayloadStmt: OpaquePointer?
                    let prepareRC = sqlite3_prepare_v2(db, "SELECT payload FROM clips;", -1, &legacyPayloadStmt, nil)
                    defer { sqlite3_finalize(legacyPayloadStmt) }
                    #expect(prepareRC == SQLITE_ERROR)
                    let errMessage = String(cString: sqlite3_errmsg(db))
                    #expect(errMessage.localizedCaseInsensitiveContains("payload"))

                    var legacyBatchStmt: OpaquePointer?
                    let batchPrepareRC = sqlite3_prepare_v2(db, "SELECT payload, html, rtf FROM clips;", -1, &legacyBatchStmt, nil)
                    defer { sqlite3_finalize(legacyBatchStmt) }
                    #expect(batchPrepareRC == SQLITE_ERROR)
                }
            }

            // Re-open with `GRDBHistoryStore` sharing the same key provider and verify round-trip fidelity.
            do {
                let reopenedStore = GRDBHistoryStore(directory: supportDirectory, keyProvider: keyProvider)
                defer { reopenedStore.close() }

                let items = try reopenedStore.fetchAll()
                #expect(items.map(\.id) == [clipBID, clipCID, clipAID])
                let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

                let reopenedClipA = try #require(itemsByID[clipAID])
                #expect(!reopenedClipA.isContentLoaded)
                #expect(reopenedClipA.title == "Initial Title A")
                #expect(reopenedClipA.hasFormatting)
                #expect(reopenedClipA.htmlDigest != nil)
                #expect(reopenedClipA.tagOrders == [createdTagID: 4])
                let hydratedClipA = try reopenedStore.loadingContent(of: reopenedClipA, scope: .full)
                #expect(hydratedClipA.text == "Initial Fork Clip A")
                #expect(hydratedClipA.html == clipAHtml)
                #expect(hydratedClipA.rtfData == clipARtfData)

                let reopenedClipB = try #require(itemsByID[clipBID])
                #expect(!reopenedClipB.isContentLoaded)
                #expect(reopenedClipB.sensitivity == .sensitive)
                #expect(reopenedClipB.expiresAt == clipBExpiresAt)
                #expect(reopenedClipB.copySequenceID == clipBSequenceID)
                #expect(reopenedClipB.copySequenceOrder == 2)
                #expect(reopenedClipB.favoriteOrder == 1)
                #expect(try reopenedStore.loadingContent(of: reopenedClipB, scope: .body).qrCodeText == "https://qr.example/b")
                #expect(reopenedClipB.linkPreviewDetails?.title == "Example B")
                #expect(reopenedClipB.linkPreviewDetails?.imagePath?.hasSuffix(".enc") == true)
                #expect(reopenedClipB.linkPreviewDetails?.faviconPath?.hasSuffix(".enc") == true)
                if let encPreviewPath = reopenedClipB.linkPreviewDetails?.imagePath {
                    #expect(fileManager.fileExists(atPath: encPreviewPath))
                }

                let reopenedClipC = try #require(itemsByID[clipCID])
                #expect(reopenedClipC.assetPath == "Images/\(clipCID.uuidString).png")
                #expect(reopenedClipC.imageDigest == "sha256-clip-c")
            }
        }
    }

    @Test
    @MainActor
    func supportDirectoryIsolationSweepsOrphanImagesWhileSparingFork() async throws {
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        let fileManager = FileManager.default
        let sentinels = try stageBackdatedOrphanAndForkSentinels(
            in: harness.supportDirectory,
            fileManager: fileManager
        )
        #expect(sentinels.forkDirectory.lastPathComponent == "Fork")

        harness.coordinator.loadHistory()
        let orphanRemoved = await TestSupport.waitUntil {
            !fileManager.fileExists(atPath: sentinels.orphanSentinelURL.path)
        }
        #expect(orphanRemoved)
        #expect(fileManager.fileExists(atPath: sentinels.forkStateURL.path))
        #expect(try Data(contentsOf: sentinels.forkStateURL) == sentinels.forkPayload)
    }

    @Test
    func archiveFormatVersionOneAndWireSchemaRoundTrip() throws {
        let fileManager = FileManager.default
        try TestSupport.withTemporaryDirectory { archiveWorkspace in
            let archiveURL = archiveWorkspace.appendingPathComponent("Export.clipbookarchive", isDirectory: true)
            let sourceSupport = archiveWorkspace.appendingPathComponent("SourceSupport", isDirectory: true)
            let destSupport = archiveWorkspace.appendingPathComponent("DestSupport", isDirectory: true)
            try fileManager.createDirectory(at: sourceSupport, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: destSupport, withIntermediateDirectories: true)

            let sourceImagesDir = sourceSupport.appendingPathComponent("Images", isDirectory: true)
            let sourcePreviewsDir = sourceSupport.appendingPathComponent("LinkPreviews", isDirectory: true)
            try fileManager.createDirectory(at: sourceImagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sourcePreviewsDir, withIntermediateDirectories: true)

            let sourceStore = GRDBHistoryStore(
                directory: sourceSupport,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { sourceStore.close() }

            let sourceImageURL = sourceImagesDir.appendingPathComponent("clip-image.png")
            let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x11, 0x22])
            let previewBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x33, 0x44])
            let faviconBytes = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
            try imageBytes.write(to: sourceImageURL)

            let linkItemID = UUID()
            let sourcePreviewURL = try sourceStore.writeManagedAsset(
                pngData: previewBytes,
                role: .linkPreview,
                clipID: linkItemID,
                encrypted: true
            )
            let sourceFaviconURL = try sourceStore.writeManagedAsset(
                pngData: faviconBytes,
                role: .linkFavicon,
                clipID: linkItemID,
                encrypted: true
            )

            let tag = Tag(id: 9, name: "ArchiveTag", color: "#00AA88")
            let rtfPayload = Data(#"{\rtf1\ansi\b Archived clip with tagOrders\b0}"#.utf8)
            var richItem = ClipboardItem.fixture(
                kind: .richText,
                title: "Formatted Spec",
                text: "Archived clip with tagOrders",
                rtfData: rtfPayload,
                html: "<b>Archived clip with tagOrders</b>",
                copiedAt: Date(timeIntervalSince1970: 1_700_001_000),
                firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_500),
                isFavorite: true,
                tags: [tag.id],
                copyCount: 3,
                favoriteOrder: 2
            )
            richItem.tagOrders = [tag.id: 7]

            let imageItem = ClipboardItem.fixture(
                kind: .image,
                title: "QR Diagram",
                text: "OCR Diagram",
                qrCodeText: "https://qr.example/archive",
                assetPath: sourceImageURL.path,
                imageDigest: ContentDigest.sha256(imageBytes),
                copiedAt: Date(timeIntervalSince1970: 1_700_001_010),
                firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_510),
                byteSize: imageBytes.count,
                tags: [tag.id]
            )

            let linkItem = ClipboardItem.fixture(
                id: linkItemID,
                kind: .link,
                text: "https://example.com/archive",
                copiedAt: Date(timeIntervalSince1970: 1_700_001_020),
                firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_520),
                linkPreviewDetails: LinkPreviewDetails(
                    url: "https://example.com/archive",
                    title: "Archive Preview",
                    description: "Preview body",
                    imagePath: sourcePreviewURL.path,
                    faviconPath: sourceFaviconURL.path,
                    fetchedAt: Date(timeIntervalSince1970: 1_700_001_015)
                ),
                copySequenceID: Date(timeIntervalSince1970: 1_700_001_000),
                copySequenceOrder: 1,
                sensitivity: .sensitive
            )

            let exportService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: sourceSupport)
            try exportService.export(items: [richItem, imageItem, linkItem], tags: [tag], to: archiveURL)

            let manifestURL = archiveURL.appendingPathComponent("manifest.json")
            let tagsURL = archiveURL.appendingPathComponent("tags.json")
            let historyURL = archiveURL.appendingPathComponent("history.json")

            let manifestData = try Data(contentsOf: manifestURL)
            let manifestJSON = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            #expect(Set(manifestJSON.keys).isSubset(of: UpstreamInteropStubs.expectedArchiveManifestKeys))
            #expect(Set(["formatVersion", "appName", "exportedAt"]).isSubset(of: Set(manifestJSON.keys)))

            let tagsData = try Data(contentsOf: tagsURL)
            let tagsJSON = try #require(try JSONSerialization.jsonObject(with: tagsData) as? [[String: Any]])
            #expect(tagsJSON.count == 1)
            for tagObject in tagsJSON {
                #expect(Set(tagObject.keys) == UpstreamInteropStubs.expectedArchiveTagKeys)
            }

            let historyData = try Data(contentsOf: historyURL)
            let historyJSON = try #require(try JSONSerialization.jsonObject(with: historyData) as? [[String: Any]])
            #expect(historyJSON.count == 3)
            var unionOfHistoryKeys: Set<String> = []
            for itemObject in historyJSON {
                let itemKeys = Set(itemObject.keys)
                #expect(itemKeys.isSubset(of: UpstreamInteropStubs.expectedArchiveItemKeys))
                unionOfHistoryKeys.formUnion(itemKeys)
                if let previewObject = itemObject["linkPreviewDetails"] as? [String: Any] {
                    #expect(Set(previewObject.keys) == UpstreamInteropStubs.expectedArchiveLinkPreviewDetailsKeys)
                }
            }
            #expect(unionOfHistoryKeys == UpstreamInteropStubs.expectedArchiveItemKeys)

            let archiveDecoder = JSONDecoder()
            archiveDecoder.dateDecodingStrategy = .iso8601
            let manifest = try archiveDecoder.decode(
                UpstreamInteropStubs.UpstreamArchiveManifestStub.self,
                from: manifestData
            )
            #expect(manifest.formatVersion == 1)
            #expect(manifest.appName == "ClipBook")

            let decodedTags = try archiveDecoder.decode(
                [UpstreamInteropStubs.UpstreamArchiveTagStub].self,
                from: tagsData
            )
            #expect(decodedTags == [UpstreamInteropStubs.UpstreamArchiveTagStub(id: "9", name: "ArchiveTag", color: "#00AA88")])

            let decodedItems = try archiveDecoder.decode(
                [UpstreamInteropStubs.UpstreamArchiveItemStub].self,
                from: historyData
            )
            let decodedByID = Dictionary(uniqueKeysWithValues: decodedItems.map { ($0.id, $0) })

            let decodedRich = try #require(decodedByID[richItem.id])
            #expect(decodedRich.kind == ClipboardKind.richText.rawValue)
            #expect(decodedRich.title == "Formatted Spec")
            #expect(decodedRich.text == "Archived clip with tagOrders")
            #expect(decodedRich.rtfBase64 == rtfPayload.base64EncodedString())
            #expect(decodedRich.html == "<b>Archived clip with tagOrders</b>")
            #expect(decodedRich.copiedAt == Date(timeIntervalSince1970: 1_700_001_000))
            #expect(decodedRich.firstCopiedAt == Date(timeIntervalSince1970: 1_700_000_500))
            #expect(decodedRich.isFavorite)
            #expect(decodedRich.tagIDs == ["9"])
            #expect(decodedRich.tagNames == ["ArchiveTag"])
            #expect(decodedRich.copyCount == 3)
            #expect(decodedRich.favoriteOrder == 2)
            #expect(decodedRich.tagOrders == ["9": 7])

            let decodedImage = try #require(decodedByID[imageItem.id])
            #expect(decodedImage.kind == ClipboardKind.image.rawValue)
            #expect(decodedImage.qrCodeText == "https://qr.example/archive")
            #expect(decodedImage.assetPath == "assets/images/clip-image.png")

            let decodedLink = try #require(decodedByID[linkItem.id])
            #expect(decodedLink.kind == ClipboardKind.link.rawValue)
            #expect(decodedLink.copySequenceID == Date(timeIntervalSince1970: 1_700_001_000))
            #expect(decodedLink.copySequenceOrder == 1)
            #expect(decodedLink.sensitivity == ItemSensitivity.sensitive.rawValue)
            #expect(
                decodedLink.linkPreviewDetails
                    == UpstreamInteropStubs.UpstreamLinkPreviewDetailsStub(
                        url: "https://example.com/archive",
                        title: "Archive Preview",
                        description: "Preview body",
                        imagePath: "assets/link-previews/\(linkItemID.uuidString)-preview.png",
                        faviconPath: "assets/link-previews/\(linkItemID.uuidString)-favicon.ico",
                        fetchedAt: Date(timeIntervalSince1970: 1_700_001_015)
                    )
            )

            // Re-encode via frozen Upstream stubs to prove Upstream-written archive JSON imports cleanly.
            let archiveEncoder = JSONEncoder()
            archiveEncoder.dateEncodingStrategy = .iso8601
            try archiveEncoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try archiveEncoder.encode(decodedTags).write(to: tagsURL, options: .atomic)
            try archiveEncoder.encode(decodedItems).write(to: historyURL, options: .atomic)

            let destinationStore = GRDBHistoryStore(
                directory: destSupport,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { destinationStore.close() }
            let importService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: destSupport)
            let importResult = try importService.import(from: archiveURL, into: destinationStore)
            #expect(importResult.itemCount == 3)
            #expect(importResult.tagCount == 1)

            let importedTag = try #require(try destinationStore.fetchTags().first)
            #expect(importedTag.name == "ArchiveTag")
            #expect(importedTag.color == "#00AA88")

            let importedByID = Dictionary(uniqueKeysWithValues: try destinationStore.fetchAll().map { ($0.id, $0) })
            let importedRich = try destinationStore.loadingContent(of: try #require(importedByID[richItem.id]), scope: .full)
            #expect(importedRich.tagOrders == [importedTag.id: 7])
            #expect(importedRich.favoriteOrder == 2)
            #expect(importedRich.rtfData == rtfPayload)
            #expect(importedRich.html == "<b>Archived clip with tagOrders</b>")

            let importedImageHeader = try #require(importedByID[imageItem.id])
            #expect(!importedImageHeader.isContentLoaded)
            let importedImage = try destinationStore.loadingContent(of: importedImageHeader, scope: .body)
            #expect(importedImage.qrCodeText == "https://qr.example/archive")
            #expect(importedImage.imageDigest == destinationStore.computeImageDigest(forPNGData: imageBytes))
            let importedAssetPath = try #require(importedImage.assetPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: importedAssetPath)) == imageBytes)

            let importedLink = try #require(importedByID[linkItem.id])
            #expect(importedLink.sensitivity == .sensitive)
            #expect(importedLink.copySequenceID == Date(timeIntervalSince1970: 1_700_001_000))
            #expect(importedLink.copySequenceOrder == 1)
            #expect(importedLink.linkPreviewDetails?.title == "Archive Preview")
            #expect(importedLink.linkPreviewDetails?.description == "Preview body")
            #expect(importedLink.linkPreviewDetails?.fetchedAt == Date(timeIntervalSince1970: 1_700_001_015))
            let destPreviewURL = URL(fileURLWithPath: try #require(importedLink.linkPreviewDetails?.imagePath))
            let destFaviconURL = URL(fileURLWithPath: try #require(importedLink.linkPreviewDetails?.faviconPath))
            #expect(destPreviewURL.pathExtension == "enc")
            #expect(destFaviconURL.pathExtension == "enc")
            #expect(
                try ImageAssetStore.readAssetData(
                    at: destPreviewURL,
                    role: .linkPreview,
                    ownerClipID: linkItem.id,
                    requiresEncryption: true
                ) == previewBytes
            )
            #expect(
                try ImageAssetStore.readAssetData(
                    at: destFaviconURL,
                    role: .linkFavicon,
                    ownerClipID: linkItem.id,
                    requiresEncryption: true
                ) == faviconBytes
            )
        }
    }

    @Test
    func unencryptedV1ExportDecryptsLocalEncAssetsForUpstreamInterop() throws {
        let fileManager = FileManager.default
        try TestSupport.withTemporaryDirectory { workspace in
            let sourceSupport = workspace.appendingPathComponent("SourceSupport", isDirectory: true)
            let archiveURL = workspace.appendingPathComponent("UpstreamV1.clipbookarchive", isDirectory: true)
            let sourceImagesDir = sourceSupport.appendingPathComponent("Images", isDirectory: true)
            try fileManager.createDirectory(at: sourceImagesDir, withIntermediateDirectories: true)

            let sourceStore = GRDBHistoryStore(
                directory: sourceSupport,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { sourceStore.close() }

            let opsTag = try sourceStore.createTag(name: "OpsInterop", color: "#FF6F00")
            let secTag = try sourceStore.createTag(name: "SecInterop", color: "#3949AB")

            let screenshotPNG = try TestSupport.makePNGData(pixelWidth: 30, pixelHeight: 18, color: .systemIndigo)
            let previewPNG = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 12, color: .systemMint)
            let faviconICO = Data([
                0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10,
                0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x55, 0xAA
            ])

            let screenshotID = UUID()
            let initialPlainScreenshotURL = sourceImagesDir.appendingPathComponent("\(screenshotID.uuidString).png")
            try screenshotPNG.write(to: initialPlainScreenshotURL)

            let secretOCR = ["gh", "p_", "UPSTREAM_V1_ENC_SCREENSHOT_5566778899001122"].joined()
            var screenshotItem = ClipboardItem.fixture(
                id: screenshotID,
                kind: .image,
                title: "Encrypted Screenshot For V1 Export",
                text: "Token \(secretOCR)",
                qrCodeText: "https://vault.example/qr",
                assetPath: initialPlainScreenshotURL.path,
                copiedAt: Date(timeIntervalSince1970: 1_710_400_200),
                firstCopiedAt: Date(timeIntervalSince1970: 1_710_400_100),
                isFavorite: true,
                tags: [opsTag.id, secTag.id],
                favoriteOrder: 1,
                sensitivity: .sensitive
            )
            screenshotItem.tagOrders = [opsTag.id: 3, secTag.id: 9]
            let savedScreenshot = try sourceStore.saveAndReconcileItem(screenshotItem, convertingExternalAssets: true)
            let localEncScreenshotURL = URL(fileURLWithPath: try #require(savedScreenshot.assetPath))
            #expect(localEncScreenshotURL.pathExtension == "enc")
            #expect(try Data(contentsOf: localEncScreenshotURL).prefix(ImageAssetStore.encryptedMagic.count) == ImageAssetStore.encryptedMagic)

            let sensitiveLinkID = UUID()
            let localEncPreviewURL = try sourceStore.writeManagedAsset(
                pngData: previewPNG,
                role: .linkPreview,
                clipID: sensitiveLinkID,
                encrypted: true
            )
            let localEncFaviconURL = try sourceStore.writeManagedAsset(
                pngData: faviconICO,
                role: .linkFavicon,
                clipID: sensitiveLinkID,
                encrypted: true
            )
            #expect(localEncPreviewURL.pathExtension == "enc")
            #expect(localEncFaviconURL.pathExtension == "enc")

            var sensitiveLinkItem = ClipboardItem.fixture(
                id: sensitiveLinkID,
                kind: .link,
                text: "https://internal.example/portal",
                copiedAt: Date(timeIntervalSince1970: 1_710_400_300),
                firstCopiedAt: Date(timeIntervalSince1970: 1_710_400_150),
                tags: [opsTag.id],
                linkPreviewDetails: LinkPreviewDetails(
                    url: "https://internal.example/portal",
                    title: "Internal Portal",
                    description: "Sensitive preview",
                    imagePath: localEncPreviewURL.path,
                    faviconPath: localEncFaviconURL.path,
                    fetchedAt: Date(timeIntervalSince1970: 1_710_400_290)
                ),
                sensitivity: .sensitive
            )
            sensitiveLinkItem.tagOrders = [opsTag.id: 0]
            _ = try sourceStore.saveAndReconcileItem(sensitiveLinkItem, convertingExternalAssets: false)

            let exportService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: sourceSupport)
            try exportService.export(
                items: try sourceStore.fetchAll(),
                tags: try sourceStore.fetchTags(),
                to: archiveURL,
                passphrase: nil,
                loadItem: { try sourceStore.loadingContent(of: $0, scope: .full) }
            )

            #expect(try exportService.inspect(at: archiveURL) == ClipBookArchiveInspection(formatVersion: 1, isEncrypted: false))

            // Verify manifest.json has formatVersion == 1, encryption == nil, and matches Upstream manifest keys.
            let manifestBytes = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
            let manifestObj = try #require(try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
            #expect(Set(manifestObj.keys).isSubset(of: UpstreamInteropStubs.expectedArchiveManifestKeys))
            #expect(manifestObj["encryption"] == nil)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decodedFullManifest = try decoder.decode(ClipBookArchiveManifest.self, from: manifestBytes)
            #expect(decodedFullManifest.formatVersion == 1)
            #expect(decodedFullManifest.encryption == nil)
            let upstreamManifest = try decoder.decode(UpstreamInteropStubs.UpstreamArchiveManifestStub.self, from: manifestBytes)
            #expect(upstreamManifest.formatVersion == 1)

            // Verify raw history.json contains ZERO v2-only keys and decodes cleanly under [UpstreamArchiveItemStub]!
            let historyBytes = try Data(contentsOf: archiveURL.appendingPathComponent("history.json"))
            let rawHistoryUTF8 = try #require(String(data: historyBytes, encoding: .utf8))
            for forbiddenV2Key in ["assetExtension", "imageExtension", "faviconExtension", "expectedAssets"] {
                #expect(!rawHistoryUTF8.contains("\"\(forbiddenV2Key)\""), "v1 history.json must omit v2 key \(forbiddenV2Key)")
            }

            let historyJSONArray = try #require(try JSONSerialization.jsonObject(with: historyBytes) as? [[String: Any]])
            #expect(historyJSONArray.count == 2)
            for itemDict in historyJSONArray {
                #expect(Set(itemDict.keys).isSubset(of: UpstreamInteropStubs.expectedArchiveItemKeys))
                if let previewDict = itemDict["linkPreviewDetails"] as? [String: Any] {
                    #expect(Set(previewDict.keys).isSubset(of: UpstreamInteropStubs.expectedArchiveLinkPreviewDetailsKeys))
                }
            }

            let upstreamItems = try decoder.decode([UpstreamInteropStubs.UpstreamArchiveItemStub].self, from: historyBytes)
            let upstreamByID = Dictionary(uniqueKeysWithValues: upstreamItems.map { ($0.id, $0) })

            let exportedScreenshot = try #require(upstreamByID[screenshotID])
            #expect(exportedScreenshot.tagIDs == [String(opsTag.id), String(secTag.id)])
            #expect(exportedScreenshot.tagNames == ["OpsInterop", "SecInterop"])
            #expect(exportedScreenshot.tagOrders == [String(opsTag.id): 3, String(secTag.id): 9])
            #expect(exportedScreenshot.sensitivity == ItemSensitivity.sensitive.rawValue)
            let relImagePath = try #require(exportedScreenshot.assetPath)
            #expect(relImagePath == "assets/images/\(screenshotID.uuidString).png")
            let exportedImageData = try Data(contentsOf: archiveURL.appendingPathComponent(relImagePath))
            #expect(exportedImageData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            #expect(exportedImageData == screenshotPNG)

            let exportedLink = try #require(upstreamByID[sensitiveLinkID])
            #expect(exportedLink.tagOrders == [String(opsTag.id): 0])
            let relPreviewPath = try #require(exportedLink.linkPreviewDetails?.imagePath)
            let relFaviconPath = try #require(exportedLink.linkPreviewDetails?.faviconPath)
            #expect(relPreviewPath == "assets/link-previews/\(sensitiveLinkID.uuidString)-preview.png")
            #expect(relFaviconPath == "assets/link-previews/\(sensitiveLinkID.uuidString)-favicon.ico")
            let exportedPreviewData = try Data(contentsOf: archiveURL.appendingPathComponent(relPreviewPath))
            let exportedFaviconData = try Data(contentsOf: archiveURL.appendingPathComponent(relFaviconPath))
            #expect(exportedPreviewData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            #expect(exportedFaviconData.prefix(4) == Data([0x00, 0x00, 0x01, 0x00]))
            #expect(exportedPreviewData == previewPNG)
            #expect(exportedFaviconData == faviconICO)
        }
    }

    @Test
    @MainActor
    func deferredSweepLoadHistorySweepsOrphanImagesAfterDeletionWhileSparingFork() async throws {
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        let fileManager = FileManager.default
        let sentinels = try stageBackdatedOrphanAndForkSentinels(
            in: harness.supportDirectory,
            orphanFileName: "orphan-after-delete.png",
            fileManager: fileManager
        )

        let keptID = UUID()
        let keptAssetURL = sentinels.imagesDirectory.appendingPathComponent("\(keptID.uuidString).png")
        try Data("kept-image".utf8).write(to: keptAssetURL)
        let backdated = Date().addingTimeInterval(-20 * 60)
        try fileManager.setAttributes(
            [.creationDate: backdated, .modificationDate: backdated],
            ofItemAtPath: keptAssetURL.path
        )
        let keptItem = ClipboardItem.fixture(
            id: keptID,
            kind: .image,
            text: nil,
            assetPath: keptAssetURL.path,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
            byteSize: 10
        )

        let deletedID = UUID()
        let deletedAssetURL = sentinels.imagesDirectory.appendingPathComponent("\(deletedID.uuidString).png")
        try Data("deleted-image".utf8).write(to: deletedAssetURL)
        let deletedItem = ClipboardItem.fixture(
            id: deletedID,
            kind: .image,
            text: nil,
            assetPath: deletedAssetURL.path,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            byteSize: 13
        )

        try harness.historyStore.upsert(keptItem)
        try harness.historyStore.upsert(deletedItem)

        // Deferred startup/import load (`sweepsCaches: false`) populates `model.items` without starting orphan sweep.
        #expect(harness.coordinator.loadHistory(sweepsCaches: false))
        #expect(Set(harness.model.items.map(\.id)) == [keptID, deletedID])
        #expect(fileManager.fileExists(atPath: sentinels.orphanSentinelURL.path))

        // Post-load permanent deletion removes `deletedItem` from SQLite and `model.items` before sweeping.
        harness.model.preferences.trashRetentionDays = 0
        harness.coordinator.delete(deletedItem)
        #expect(harness.model.items.map(\.id) == [keptID])
        #expect(!fileManager.fileExists(atPath: deletedAssetURL.path))
        #expect(fileManager.fileExists(atPath: sentinels.orphanSentinelURL.path))

        // Running `loadHistory()` (`sweepsCaches: true` -> `removeOrphanedStoredFiles()`) after deletion settles
        // sweeps the backdated orphan in `Images/` while sparing referenced assets and `Fork/`.
        #expect(harness.coordinator.loadHistory())
        let orphanRemoved = await TestSupport.waitUntil {
            !fileManager.fileExists(atPath: sentinels.orphanSentinelURL.path)
        }
        #expect(orphanRemoved)
        #expect(fileManager.fileExists(atPath: keptAssetURL.path))
        #expect(fileManager.fileExists(atPath: sentinels.forkStateURL.path))
        #expect(try Data(contentsOf: sentinels.forkStateURL) == sentinels.forkPayload)
    }

    private struct StagedSupportSentinels {
        let imagesDirectory: URL
        let orphanSentinelURL: URL
        let forkDirectory: URL
        let forkStateURL: URL
        let forkPayload: Data
    }

    private func stageBackdatedOrphanAndForkSentinels(
        in supportDirectory: URL,
        orphanFileName: String = "orphan-sentinel.png",
        fileManager: FileManager = .default
    ) throws -> StagedSupportSentinels {
        let imagesDirectory = supportDirectory.appendingPathComponent("Images", isDirectory: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let orphanSentinelURL = imagesDirectory.appendingPathComponent(orphanFileName)
        try Data("orphan".utf8).write(to: orphanSentinelURL)

        let forkDirectory = AppDirectories.forkSupportDirectory(in: supportDirectory, fileManager: fileManager)
        let forkStateURL = forkDirectory.appendingPathComponent("state.json")
        let forkPayload = Data("{\"ok\":true}".utf8)
        try forkPayload.write(to: forkStateURL)

        let backdated = Date().addingTimeInterval(-20 * 60)
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: backdated,
            .modificationDate: backdated
        ]
        try fileManager.setAttributes(attributes, ofItemAtPath: orphanSentinelURL.path)
        try fileManager.setAttributes(attributes, ofItemAtPath: forkStateURL.path)

        return StagedSupportSentinels(
            imagesDirectory: imagesDirectory,
            orphanSentinelURL: orphanSentinelURL,
            forkDirectory: forkDirectory,
            forkStateURL: forkStateURL,
            forkPayload: forkPayload
        )
    }
}

extension SharedProcessStateTests {
    @Suite(.serialized)
    struct ForkPreferencesSavingTests {
        @Test
        @MainActor
        func savePreferencesPersistsForkSidecarWithoutAlteringMainPreferencesSchema() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            harness.model.forkPreferences = ForkPreferences(schemaVersion: 3)
            harness.coordinator.savePreferences()

            #expect(harness.preferencesStore.loadForkPreferences() == ForkPreferences(schemaVersion: 3))

            let forkData = try #require(
                harness.preferencesStore.userDefaults.data(forKey: ForkPreferences.userDefaultsKey)
            )
            let decodedFork = try JSONDecoder().decode(ForkPreferences.self, from: forkData)
            #expect(decodedFork == ForkPreferences(schemaVersion: 3))

            let mainData = try #require(
                harness.preferencesStore.userDefaults.data(forKey: "ClipBookPreferencesV2")
            )
            let mainJSON = try #require(try JSONSerialization.jsonObject(with: mainData) as? [String: Any])
            #expect(Set(mainJSON.keys).isSubset(of: UpstreamInteropStubs.expectedAppPreferencesKeys))
            #expect(mainJSON["schemaVersion"] == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func mutatingForkPreferencesInMountedSettingsViewPersistsSidecarOnly() async throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let hostingView = NSHostingView(
                rootView: SettingsView(model: harness.model).environmentObject(harness.coordinator)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = hostingView
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            hostingView.layoutSubtreeIfNeeded()

            #expect(harness.preferencesStore.loadForkPreferences().schemaVersion == 1)

            harness.model.forkPreferences = ForkPreferences(schemaVersion: 4)
            let saved = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.preferencesStore.loadForkPreferences().schemaVersion == 4
            }
            #expect(saved, "SettingsView did not persist mutated model.forkPreferences")

            let mainData = try #require(
                harness.preferencesStore.userDefaults.data(forKey: "ClipBookPreferencesV2")
            )
            let mainJSON = try #require(try JSONSerialization.jsonObject(with: mainData) as? [String: Any])
            #expect(Set(mainJSON.keys).isSubset(of: UpstreamInteropStubs.expectedAppPreferencesKeys))
            #expect(mainJSON["schemaVersion"] == nil)
        }
    }
}
