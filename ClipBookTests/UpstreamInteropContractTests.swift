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

    enum UpstreamAppAppearanceStub: String, Codable, Equatable {
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

    struct UpstreamArchiveManifestStub: Codable, Equatable {
        var formatVersion: Int
        var appName: String
        var appVersion: String?
        var exportedAt: Date
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

        let upstreamStub = try JSONDecoder().decode(UpstreamInteropStubs.UpstreamAppPreferencesStub.self, from: data)
        #expect(upstreamStub.appearance == .dark)
        #expect(["lastLocation", "activeScreenCenter", "activeWindowCenter", "screenWithCursor", "mouseCursor", "inputCursor"].contains(upstreamStub.openWindowStrategy))
        #expect(["Last Copy Time", "First Copy Time", "Number of Copies", "Size"].contains(upstreamStub.historySortOption))
        #expect(["select", "paste", "copy"].contains(upstreamStub.singleClickAction))
        #expect(["newLine", "space", "comma", "empty"].contains(upstreamStub.copyAndMergeSeparator))
        #expect(["none", "returnKey", "shiftReturn", "keyUp", "keyDown", "tab", "space", "commaSpace"].contains(upstreamStub.multiPasteKey))
        #expect(["paste", "copy"].contains(upstreamStub.doubleClickAction))
        #expect(["paste", "copy"].contains(upstreamStub.numberKeyAction))
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
            let clipAID = UUID()
            let clipBID = UUID()
            var createdTagID = 0

            do {
                let store = SQLiteHistoryStore(directory: supportDirectory)
                let tag = try store.createTag(name: "InteropTag", color: "#3366FF")
                createdTagID = tag.id

                var clipA = ClipboardItem.fixture(
                    id: clipAID,
                    kind: .text,
                    text: "Initial Fork Clip A",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    tags: [tag.id]
                )
                clipA.tagOrders = [tag.id: 4]

                let clipBPreviewFetchedAt = Date(timeIntervalSince1970: 1_700_000_210)
                let clipBSequenceID = Date(timeIntervalSince1970: 1_700_000_200)
                let clipBExpiresAt = Date(timeIntervalSince1970: 1_700_003_800)
                var clipB = ClipboardItem.fixture(
                    id: clipBID,
                    kind: .link,
                    text: "https://example.com/b",
                    qrCodeText: "https://qr.example/b",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://example.com/b",
                        title: "Example B",
                        description: "Preview summary",
                        imagePath: "LinkPreviews/b-preview.png",
                        faviconPath: "LinkPreviews/b-favicon.png",
                        fetchedAt: clipBPreviewFetchedAt
                    ),
                    copySequenceID: clipBSequenceID,
                    copySequenceOrder: 2,
                    favoriteOrder: 1,
                    sensitivity: .sensitive
                )
                clipB.expiresAt = clipBExpiresAt

                try store.upsert(clipA)
                try store.upsert(clipB)
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

                func execSQL(_ sql: String) throws {
                    var errorMessage: UnsafeMutablePointer<CChar>?
                    let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
                    if rc != SQLITE_OK {
                        let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(rc)"
                        sqlite3_free(errorMessage)
                        Issue.record("SQL failed (\(sql)): \(message)")
                        throw HistoryStoreError.stepFailed(message)
                    }
                }

                try execSQL("PRAGMA foreign_keys = OFF;")

                // 1. PRAGMA user_version == 4
                do {
                    var stmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    #expect(sqlite3_step(stmt) == SQLITE_ROW)
                    #expect(sqlite3_column_int(stmt, 0) == 4)
                }

                // 2. Only `clips` and `tags` user tables exist.
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
                    #expect(tables == ["clips", "tags"])
                }

                // 3. Exact column names and types on `clips` and `tags`.
                func tableColumns(_ table: String) -> [(name: String, type: String)] {
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
                        return []
                    }
                    defer { sqlite3_finalize(stmt) }
                    var cols: [(String, String)] = []
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                        let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                        cols.append((name, type))
                    }
                    return cols
                }

                let clipsColumns = tableColumns("clips")
                let expectedClipsColumns = [
                    ("id", "TEXT"),
                    ("kind", "TEXT"),
                    ("copiedAt", "REAL"),
                    ("favorite", "INTEGER"),
                    ("sourceApp", "TEXT"),
                    ("searchText", "TEXT"),
                    ("contentKey", "TEXT"),
                    ("payload", "BLOB"),
                    ("html", "TEXT"),
                    ("rtf", "BLOB"),
                    ("deletedAt", "REAL"),
                    ("expiresAt", "REAL")
                ]
                #expect(clipsColumns.map(\.name) == expectedClipsColumns.map(\.0))
                #expect(clipsColumns.map(\.type) == expectedClipsColumns.map(\.1))

                let tagsColumns = tableColumns("tags")
                let expectedTagsColumns = [
                    ("id", "INTEGER"),
                    ("name", "TEXT"),
                    ("color", "TEXT")
                ]
                #expect(tagsColumns.map(\.name) == expectedTagsColumns.map(\.0))
                #expect(tagsColumns.map(\.type) == expectedTagsColumns.map(\.1))

                // 4. Decode every `clips.payload` via `UpstreamClipboardItemStub`.
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var decodedByID: [UUID: UpstreamInteropStubs.UpstreamClipboardItemStub] = [:]

                do {
                    var stmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, "SELECT payload FROM clips;", -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let bytes = try #require(sqlite3_column_blob(stmt, 0))
                        let length = Int(sqlite3_column_bytes(stmt, 0))
                        let payloadData = Data(bytes: bytes, count: length)
                        let rawJSON = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
                        #expect(Set(rawJSON.keys).isSubset(of: UpstreamInteropStubs.expectedClipboardItemKeys))

                        let stub = try decoder.decode(
                            UpstreamInteropStubs.UpstreamClipboardItemStub.self,
                            from: payloadData
                        )
                        decodedByID[stub.id] = stub
                    }
                }

                var updatedClipA = try #require(decodedByID[clipAID])
                #expect(updatedClipA.tagOrders == [createdTagID: 4])
                let decodedClipB = try #require(decodedByID[clipBID])
                #expect(decodedClipB.sensitivity == ItemSensitivity.sensitive.rawValue)
                #expect(decodedClipB.expiresAt == Date(timeIntervalSince1970: 1_700_003_800))
                #expect(
                    decodedClipB.linkPreviewDetails
                        == UpstreamInteropStubs.UpstreamLinkPreviewDetailsStub(
                            url: "https://example.com/b",
                            title: "Example B",
                            description: "Preview summary",
                            imagePath: "LinkPreviews/b-preview.png",
                            faviconPath: "LinkPreviews/b-favicon.png",
                            fetchedAt: Date(timeIntervalSince1970: 1_700_000_210)
                        )
                )
                #expect(decodedClipB.copySequenceID == Date(timeIntervalSince1970: 1_700_000_200))
                #expect(decodedClipB.copySequenceOrder == 2)
                #expect(decodedClipB.favoriteOrder == 1)
                #expect(decodedClipB.qrCodeText == "https://qr.example/b")

                // 5. Simulate Upstream INSERT ... ON CONFLICT on clip A, DELETE on clip B, and VACUUM.
                updatedClipA.text = "Updated By Upstream Clip A"
                updatedClipA.searchText = "Updated By Upstream Clip A InteropTag TestApp"
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let updatedPayload = try encoder.encode(updatedClipA)

                do {
                    let upsertSQL = """
                    INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, contentKey, payload, html, rtf, deletedAt, expiresAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        copiedAt = excluded.copiedAt,
                        favorite = excluded.favorite,
                        sourceApp = excluded.sourceApp,
                        searchText = excluded.searchText,
                        contentKey = excluded.contentKey,
                        payload = excluded.payload;
                    """
                    var stmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(stmt, 1, clipAID.uuidString, -1, transient)
                    sqlite3_bind_text(stmt, 2, updatedClipA.kind.rawValue, -1, transient)
                    sqlite3_bind_double(stmt, 3, updatedClipA.copiedAt.timeIntervalSince1970)
                    sqlite3_bind_int(stmt, 4, updatedClipA.isFavorite ? 1 : 0)
                    sqlite3_bind_text(stmt, 5, updatedClipA.sourceAppName ?? "", -1, transient)
                    sqlite3_bind_text(stmt, 6, updatedClipA.searchText, -1, transient)
                    sqlite3_bind_text(stmt, 7, "text:Updated By Upstream Clip A", -1, transient)
                    _ = updatedPayload.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(stmt, 8, buffer.baseAddress, Int32(updatedPayload.count), transient)
                    }
                    #expect(sqlite3_step(stmt) == SQLITE_DONE)
                }

                do {
                    var stmt: OpaquePointer?
                    #expect(sqlite3_prepare_v2(db, "DELETE FROM clips WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(stmt) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(stmt, 1, clipBID.uuidString, -1, transient)
                    #expect(sqlite3_step(stmt) == SQLITE_DONE)
                }

                try execSQL("VACUUM;")
            }

            // Re-open with a fresh `SQLiteHistoryStore` after `rawDB` closed cleanly.
            do {
                let reopenedStore = SQLiteHistoryStore(directory: supportDirectory)
                let items = try reopenedStore.fetchAll()
                #expect(items.map(\.id) == [clipAID])
                #expect(items.first?.text == "Updated By Upstream Clip A")
                #expect(items.first?.tagOrders == [createdTagID: 4])
            }

            do {
                var checkDB: OpaquePointer?
                defer {
                    if let checkDB {
                        sqlite3_close(checkDB)
                    }
                }
                #expect(sqlite3_open(dbPath, &checkDB) == SQLITE_OK)
                var stmt: OpaquePointer?
                #expect(sqlite3_prepare_v2(checkDB, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                #expect(sqlite3_step(stmt) == SQLITE_ROW)
                #expect(sqlite3_column_int(stmt, 0) == 4)
            }
        }
    }

    @Test
    @MainActor
    func supportDirectoryIsolationAndArchiveFormatVersionOneLock() async throws {
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        let fileManager = FileManager.default
        let imagesDirectory = harness.supportDirectory.appendingPathComponent("Images", isDirectory: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let orphanSentinel = imagesDirectory.appendingPathComponent("orphan-sentinel.png")
        try Data("orphan".utf8).write(to: orphanSentinel)

        let forkDirectory = AppDirectories.forkSupportDirectory(in: harness.supportDirectory, fileManager: fileManager)
        #expect(forkDirectory.lastPathComponent == "Fork")
        let forkStateURL = forkDirectory.appendingPathComponent("state.json")
        let forkPayload = Data("{\"ok\":true}".utf8)
        try forkPayload.write(to: forkStateURL)

        let backdated = Date().addingTimeInterval(-20 * 60)
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: backdated,
            .modificationDate: backdated
        ]
        try fileManager.setAttributes(attributes, ofItemAtPath: orphanSentinel.path)
        try fileManager.setAttributes(attributes, ofItemAtPath: forkStateURL.path)

        harness.coordinator.loadHistory()
        let orphanRemoved = await TestSupport.waitUntil {
            !fileManager.fileExists(atPath: orphanSentinel.path)
        }
        #expect(orphanRemoved)
        #expect(fileManager.fileExists(atPath: forkStateURL.path))
        #expect(try Data(contentsOf: forkStateURL) == forkPayload)

        // `.clipbookarchive` formatVersion == 1 & `tagOrders` export/import round-trip.
        try TestSupport.withTemporaryDirectory { archiveWorkspace in
            let archiveURL = archiveWorkspace.appendingPathComponent("Export.clipbookarchive", isDirectory: true)
            let sourceSupport = archiveWorkspace.appendingPathComponent("SourceSupport", isDirectory: true)
            let destSupport = archiveWorkspace.appendingPathComponent("DestSupport", isDirectory: true)
            try fileManager.createDirectory(at: sourceSupport, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: destSupport, withIntermediateDirectories: true)

            let tag = Tag(id: 9, name: "ArchiveTag", color: "#00AA88")
            var item = ClipboardItem.fixture(
                kind: .text,
                text: "Archived clip with tagOrders",
                tags: [tag.id]
            )
            item.tagOrders = [tag.id: 7]

            let exportService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: sourceSupport)
            try exportService.export(items: [item], tags: [tag], to: archiveURL)

            let manifestData = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
            let manifestJSON = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            #expect(Set(manifestJSON.keys).isSubset(of: ["formatVersion", "appName", "appVersion", "exportedAt"]))

            let archiveDecoder = JSONDecoder()
            archiveDecoder.dateDecodingStrategy = .iso8601
            let manifest = try archiveDecoder.decode(
                UpstreamInteropStubs.UpstreamArchiveManifestStub.self,
                from: manifestData
            )
            #expect(manifest.formatVersion == 1)
            #expect(manifest.appName == "ClipBook")

            let destinationStore = SQLiteHistoryStore(directory: destSupport)
            let importService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: destSupport)
            let importResult = try importService.import(from: archiveURL, into: destinationStore)
            #expect(importResult.itemCount == 1)
            #expect(importResult.tagCount == 1)

            let importedTag = try #require(try destinationStore.fetchTags().first)
            let importedItem = try #require(try destinationStore.fetchAll().first)
            #expect(importedItem.id == item.id)
            #expect(importedItem.tagOrders == [importedTag.id: 7])
        }
    }

    @Test
    @MainActor
    func deferredSweepLoadHistorySweepsOrphanImagesAfterDeletionWhileSparingFork() async throws {
        let harness = try TestSupport.makeTestCoordinator()
        defer { harness.cleanup() }

        let fileManager = FileManager.default
        let imagesDirectory = harness.supportDirectory.appendingPathComponent("Images", isDirectory: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let keptID = UUID()
        let keptAssetURL = imagesDirectory.appendingPathComponent("\(keptID.uuidString).png")
        try Data("kept-image".utf8).write(to: keptAssetURL)
        let keptItem = ClipboardItem.fixture(
            id: keptID,
            kind: .image,
            text: nil,
            assetPath: keptAssetURL.path,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
            byteSize: 10
        )

        let deletedID = UUID()
        let deletedAssetURL = imagesDirectory.appendingPathComponent("\(deletedID.uuidString).png")
        try Data("deleted-image".utf8).write(to: deletedAssetURL)
        let deletedItem = ClipboardItem.fixture(
            id: deletedID,
            kind: .image,
            text: nil,
            assetPath: deletedAssetURL.path,
            copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            byteSize: 13
        )

        let orphanSentinel = imagesDirectory.appendingPathComponent("orphan-after-delete.png")
        try Data("orphan".utf8).write(to: orphanSentinel)

        let forkDirectory = AppDirectories.forkSupportDirectory(in: harness.supportDirectory, fileManager: fileManager)
        let forkStateURL = forkDirectory.appendingPathComponent("state.json")
        let forkPayload = Data("{\"ok\":true}".utf8)
        try forkPayload.write(to: forkStateURL)

        let backdated = Date().addingTimeInterval(-20 * 60)
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: backdated,
            .modificationDate: backdated
        ]
        try fileManager.setAttributes(attributes, ofItemAtPath: orphanSentinel.path)
        try fileManager.setAttributes(attributes, ofItemAtPath: forkStateURL.path)

        try harness.historyStore.upsert(keptItem)
        try harness.historyStore.upsert(deletedItem)

        // Deferred startup/import load (`sweepsCaches: false`) populates `model.items` without starting orphan sweep.
        #expect(harness.coordinator.loadHistory(sweepsCaches: false))
        #expect(Set(harness.model.items.map(\.id)) == [keptID, deletedID])
        #expect(fileManager.fileExists(atPath: orphanSentinel.path))

        // Post-load permanent deletion removes `deletedItem` from SQLite and `model.items` before sweeping.
        harness.model.preferences.trashRetentionDays = 0
        harness.coordinator.delete(deletedItem)
        #expect(harness.model.items.map(\.id) == [keptID])
        #expect(!fileManager.fileExists(atPath: deletedAssetURL.path))
        #expect(fileManager.fileExists(atPath: orphanSentinel.path))

        // Running `loadHistory()` (`sweepsCaches: true` -> `removeOrphanedStoredFiles()`) after deletion settles
        // sweeps the backdated orphan in `Images/` while sparing referenced assets and `Fork/`.
        #expect(harness.coordinator.loadHistory())
        let orphanRemoved = await TestSupport.waitUntil {
            !fileManager.fileExists(atPath: orphanSentinel.path)
        }
        #expect(orphanRemoved)
        #expect(fileManager.fileExists(atPath: keptAssetURL.path))
        #expect(fileManager.fileExists(atPath: forkStateURL.path))
        #expect(try Data(contentsOf: forkStateURL) == forkPayload)
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
