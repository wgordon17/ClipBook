@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import Security
import SQLite3
import Testing

@Suite
enum SQLiteHistoryStoreAndArchiveTests {
    @Suite
    struct GRDBHistoryStoreTests {
        @Test
        func capturePreservesMetadataAndRevivesTrash() throws {
            try TestSupport.withTemporaryHistoryStore { store, _ in
                let tag = try store.createTag(name: "Reference", color: "#3B85ED")
                let initialTime = Date(timeIntervalSince1970: 1_700_000_100.125)
                let sequenceID = Date(timeIntervalSince1970: 1_700_000_100.000)

                let original = ClipboardItem.fixture(
                    kind: .image,
                    title: "Custom Diagram Title",
                    text: "Recognized OCR Text From Vision",
                    qrCodeText: "https://example.com/qr",
                    assetPath: "/Users/alice/Pictures/diagram.png",
                    imageDigest: "sha256-diagram-digest-001",
                    sourceAppName: "Preview",
                    sourceBundleIdentifier: "com.apple.Preview",
                    copiedAt: initialTime,
                    firstCopiedAt: initialTime,
                    byteSize: 4096,
                    isFavorite: true,
                    tags: [tag.id],
                    copyCount: 1,
                    copySequenceID: sequenceID,
                    copySequenceOrder: 2
                )
                let firstCaptured = try store.capture(original, updatesCopySequence: true)
                #expect(firstCaptured.id == original.id)
                #expect(firstCaptured.copySequenceID == sequenceID)
                #expect(firstCaptured.copySequenceOrder == 2)

                let trashedAt = Date(timeIntervalSince1970: 1_700_000_200.500)
                try store.moveToTrash(ids: [original.id], at: trashedAt)
                #expect(try store.fetchAll().isEmpty)
                #expect(try store.fetchTrashedItems().map(\.id) == [original.id])

                let recopyTime = Date(timeIntervalSince1970: 1_700_000_300.875)
                let recopyWithoutOCR = ClipboardItem.fixture(
                    kind: .image,
                    title: nil,
                    text: nil,
                    qrCodeText: nil,
                    assetPath: "/Users/alice/Pictures/diagram-recopy.png",
                    imageDigest: "sha256-diagram-digest-001",
                    sourceAppName: "Safari",
                    sourceBundleIdentifier: "com.apple.Safari",
                    copiedAt: recopyTime,
                    byteSize: 4096,
                    copyCount: 1
                )

                let revived = try store.capture(recopyWithoutOCR, updatesCopySequence: false)
                #expect(revived.id == original.id)
                #expect(revived.title == "Custom Diagram Title")
                #expect(revived.text == "Recognized OCR Text From Vision")
                #expect(revived.qrCodeText == "https://example.com/qr")
                #expect(revived.copyCount == 2)
                #expect(revived.deletedAt == nil)
                #expect(revived.searchText.localizedCaseInsensitiveContains("Custom Diagram Title"))
                #expect(revived.searchText.localizedCaseInsensitiveContains("Recognized OCR Text From Vision"))
                #expect(revived.searchText.localizedCaseInsensitiveContains("Reference"))

                #expect(try store.fetchTrashedItems().isEmpty)
                let activeItems = try store.fetchAll()
                #expect(activeItems.count == 1)
                let fetched = try #require(activeItems.first)
                #expect(fetched.id == original.id)
                #expect(!fetched.isContentLoaded)
                #expect(fetched.title == "Custom Diagram Title")
                let hydratedFetched = try store.loadingContent(of: fetched, scope: .body)
                #expect(hydratedFetched.text == "Recognized OCR Text From Vision")
                #expect(hydratedFetched.qrCodeText == "https://example.com/qr")
            }
        }

        @Test
        func subSecondCopiedAtPrecisionRoundTrip() throws {
            try TestSupport.withTemporaryHistoryStore { store, _ in
                let baseEpoch = 1_700_000_000.000
                var expectedIDsInDescOrder: [UUID] = []

                for offsetMs in 0..<10 {
                    let copied = Date(timeIntervalSince1970: baseEpoch + 10.0 + Double(offsetMs) * 0.001)
                    let item = ClipboardItem.fixture(
                        kind: .text,
                        text: "Millisecond clip #\(offsetMs)",
                        copiedAt: copied
                    )
                    try store.upsert(item)
                    expectedIDsInDescOrder.insert(item.id, at: 0)
                }

                let fetched = try store.fetchAll()
                #expect(fetched.map(\.id) == expectedIDsInDescOrder)

                for (reverseIndex, item) in fetched.enumerated() {
                    let offsetMs = 9 - reverseIndex
                    let expectedCopied = baseEpoch + 10.0 + Double(offsetMs) * 0.001
                    #expect(abs(item.copiedAt.timeIntervalSince1970 - expectedCopied) < 0.000_5)
                }
            }
        }

        @Test
        func lazyFormattingAndUpsertPreservation() throws {
            try TestSupport.withTemporaryHistoryStore { store, _ in
                let html = "<strong>Rich HTML Body</strong>"
                let rtfData = Data(#"{\rtf1\ansi\b Rich HTML Body\b0}"#.utf8)
                let richItem = ClipboardItem.fixture(
                    kind: .richText,
                    text: "Rich HTML Body",
                    rtfData: rtfData,
                    html: html
                )
                #expect(richItem.hasFormatting)
                #expect(richItem.isFormattingLoaded)

                try store.upsert(richItem)

                let fetchedUnloaded = try Self.fetchItem(richItem.id, from: store)
                #expect(fetchedUnloaded.hasFormatting)
                #expect(!fetchedUnloaded.isFormattingLoaded)
                #expect(fetchedUnloaded.html == nil)
                #expect(fetchedUnloaded.rtfData == nil)
                #expect(fetchedUnloaded.htmlDigest == richItem.htmlDigest)

                var mutatedUnloaded = fetchedUnloaded
                mutatedUnloaded.isFavorite = true
                mutatedUnloaded.title = "Pinned Rich Clip"
                try store.upsert(mutatedUnloaded)

                let reloadedUnloaded = try Self.fetchItem(richItem.id, from: store)
                #expect(reloadedUnloaded.isFavorite)
                #expect(reloadedUnloaded.title == "Pinned Rich Clip")
                #expect(!reloadedUnloaded.isFormattingLoaded)

                let withFormatting = try store.loadingContent(of: reloadedUnloaded, scope: .full)
                #expect(withFormatting.isContentLoaded)
                #expect(withFormatting.isFormattingLoaded)
                #expect(withFormatting.text == "Rich HTML Body")
                #expect(withFormatting.html == html)
                #expect(withFormatting.rtfData == rtfData)

                var stripped = withFormatting
                stripped.removeFormatting()
                #expect(!stripped.hasFormatting)
                try store.upsert(stripped)

                let afterStrip = try Self.fetchItem(richItem.id, from: store)
                #expect(!afterStrip.hasFormatting)
                let loadedAfterStrip = try store.loadingContent(of: afterStrip, scope: .full)
                #expect(loadedAfterStrip.html == nil)
                #expect(loadedAfterStrip.rtfData == nil)
            }
        }

        @Test(arguments: [0, 2, 3, 4])
        func cleanRoomMigrationScrubsLegacySecretsAndPreservesAllFields(legacyVersion: Int) throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let walURL = directory.appendingPathComponent("History.sqlite-wal")
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                let linkPreviewsDir = directory.appendingPathComponent("LinkPreviews", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: linkPreviewsDir, withIntermediateDirectories: true)

                let masterKey = SymmetricKey(size: .bits256)
                let derivedKeys = ClipBookDerivedKeys(masterKey: masterKey)
                let keyProvider = InMemoryDatabaseKeyProvider(key: masterKey)

                // Unique canary markers and runtime-concatenated secret triggers (never literal token prefixes).
                let canaryFreelist = "CANARY_FREELIST_918273"
                let canaryWAL = "CANARY_WAL_918273"
                let canaryText = ["CANARY_TEXT_", "9182734567890123"].joined()
                let canaryHTML = ["CANARY_HTML_", "9182734567890123"].joined()
                let canaryRTF = ["CANARY_RTF_", "9182734567890123"].joined()
                let canaryQR = ["CANARY_QR_", "9182734567890123"].joined()
                let canaryOG = ["CANARY_OG_", "9182734567890123"].joined()
                let canarySecretPath = ["CANARY_SECRET_PATH_", "918273456"].joined()
                let allCanaries = [
                    canaryFreelist,
                    canaryWAL,
                    canaryText,
                    canaryHTML,
                    canaryRTF,
                    canaryQR,
                    canaryOG,
                    canarySecretPath,
                ]

                let secretPlainText = ["Authorization", ": Bearer ", canaryText].joined()
                let secretHTML = ["<a href=\"https://svc", ":", canaryHTML, "@internal.example.com\">Spec</a>"].joined()
                let secretRTFString = ["{\\rtf1\\ansi ", "api_key", "=", canaryRTF, "}"].joined()
                let secretRTFData = Data(secretRTFString.utf8)
                let secretQRText = ["otpauth://totp/Vault?secret=", "JBSWY3DPEHPK3PXP", "JBSWY3DP", "&issuer=", canaryQR].joined()
                let secretOGTitle = ["Dashboard ", "token", "=", canaryOG].joined()
                let secretFilePath = ["/Users/alice/.creds/prod_", "password", "=", canarySecretPath, ".env"].joined()

                let secretTextID = UUID()
                let secretRichID = UUID()
                let sensitiveImageID = UUID()
                let sensitiveLinkID = UUID()
                let sensitiveFileID = UUID()
                let plainImageID = UUID()
                let orphanTagTrashedID = UUID()
                let v2UnmigratedStringTagID = UUID()

                let sensitiveImagePNG = try TestSupport.makePNGData(pixelWidth: 40, pixelHeight: 30, color: .systemPurple)
                let plainImagePNG = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 16, color: .systemGreen)
                let ogPreviewPNG = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 20, color: .systemOrange)
                let ogFaviconICO = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])

                let sensitiveImageURL = imagesDir.appendingPathComponent("\(sensitiveImageID.uuidString).png")
                let plainImageURL = imagesDir.appendingPathComponent("\(plainImageID.uuidString).png")
                let ogPreviewURL = linkPreviewsDir.appendingPathComponent("\(sensitiveLinkID.uuidString)-preview.png")
                let ogFaviconURL = linkPreviewsDir.appendingPathComponent("\(sensitiveLinkID.uuidString)-favicon.ico")

                try sensitiveImagePNG.write(to: sensitiveImageURL)
                try plainImagePNG.write(to: plainImageURL)
                try ogPreviewPNG.write(to: ogPreviewURL)
                try ogFaviconICO.write(to: ogFaviconURL)

                let subSecondCopiedAt = 1_700_000_123.789
                let sequenceID = Date(timeIntervalSince1970: 1_700_000_100)
                let linkExpiresAt = Date(timeIntervalSince1970: 1_700_050_000.500)
                let linkFetchedAt = Date(timeIntervalSince1970: 1_700_000_400)
                let trashedDeletedAt = Date(timeIntervalSince1970: 1_700_000_999.250)

                // Sanity-check that every secret fixture genuinely triggers SensitiveContent.shouldEncryptAtRest.
                #expect(SensitiveContent.shouldEncryptAtRest(ClipboardItem.fixture(kind: .text, text: secretPlainText)))
                #expect(SensitiveContent.shouldEncryptAtRest(
                    ClipboardItem.fixture(kind: .richText, text: "Benign Rich Heading", rtfData: secretRTFData, html: secretHTML)
                ))
                #expect(SensitiveContent.shouldEncryptAtRest(
                    ClipboardItem.fixture(kind: .image, text: "Badge", qrCodeText: secretQRText, assetPath: sensitiveImageURL.path)
                ))
                #expect(SensitiveContent.shouldEncryptAtRest(
                    ClipboardItem.fixture(
                        kind: .link,
                        text: "https://portal.example.com/overview",
                        linkPreviewDetails: LinkPreviewDetails(
                            url: "https://portal.example.com/overview",
                            title: secretOGTitle,
                            description: "Private portal",
                            imagePath: ogPreviewURL.path,
                            faviconPath: ogFaviconURL.path,
                            fetchedAt: linkFetchedAt
                        )
                    )
                ))
                #expect(SensitiveContent.shouldEncryptAtRest(
                    ClipboardItem.fixture(kind: .file, text: nil, filePaths: [secretFilePath])
                ))

                try Self.createSynthesizedLegacyDatabase(
                    at: dbURL,
                    walURL: walURL,
                    legacyVersion: legacyVersion,
                    canaryFreelist: canaryFreelist,
                    canaryWAL: canaryWAL,
                    secretTextID: secretTextID,
                    secretPlainText: secretPlainText,
                    subSecondCopiedAt: subSecondCopiedAt,
                    sequenceID: sequenceID,
                    secretRichID: secretRichID,
                    secretHTML: secretHTML,
                    secretRTFData: secretRTFData,
                    sensitiveImageID: sensitiveImageID,
                    sensitiveImagePath: sensitiveImageURL.path,
                    secretQRText: secretQRText,
                    sensitiveLinkID: sensitiveLinkID,
                    secretOGTitle: secretOGTitle,
                    ogPreviewPath: ogPreviewURL.path,
                    ogFaviconPath: ogFaviconURL.path,
                    linkFetchedAt: linkFetchedAt,
                    linkExpiresAt: linkExpiresAt,
                    sensitiveFileID: sensitiveFileID,
                    secretFilePath: secretFilePath,
                    plainImageID: plainImageID,
                    plainImagePath: plainImageURL.path,
                    orphanTagTrashedID: orphanTagTrashedID,
                    trashedDeletedAt: trashedDeletedAt,
                    v2UnmigratedStringTagID: v2UnmigratedStringTagID
                )

                // Pre-migration proof: dirty freelist pages, uncheckpointed WAL frames, and PNG magic exist on disk.
                let preMigrationDBBytes = try Data(contentsOf: dbURL)
                let preMigrationWALBytes = try Data(contentsOf: walURL)
                let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
                #expect(preMigrationDBBytes.range(of: Data(canaryFreelist.utf8)) != nil)
                #expect(preMigrationWALBytes.range(of: Data(canaryWAL.utf8)) != nil)
                #expect(try Data(contentsOf: sensitiveImageURL).starts(with: pngMagic))

                let expectedHTMLDigest = ClipboardItem.fixture(
                    kind: .richText,
                    text: "Benign Rich Heading",
                    rtfData: secretRTFData,
                    html: secretHTML
                ).htmlDigest
                let expectedSensitiveImageDigest = HistoryCrypto.imageDigest(forPNGData: sensitiveImagePNG, keys: derivedKeys)
                let expectedPlainImageDigest = HistoryCrypto.imageDigest(forPNGData: plainImagePNG, keys: derivedKeys)

                // Run clean-room migration on GRDBHistoryStore initialization.
                do {
                    let store = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { store.close() }
                    #expect(store.lockState == .unlocked)

                    // 1. Recursive raw-disk byte scan across EVERY file in supportDirectory.
                    let allFiles = try Self.allRegularFilesRecursively(in: directory)
                    #expect(!allFiles.isEmpty)
                    for fileURL in allFiles {
                        let name = fileURL.lastPathComponent
                        #expect(!name.contains(".migrating"))
                        #expect(!name.hasSuffix(".scrubbing"))

                        let rawBytes = try Data(contentsOf: fileURL)
                        for canary in allCanaries {
                            for (encodingLabel, needle) in Self.canaryBytePatterns(for: canary) {
                                #expect(
                                    rawBytes.range(of: needle) == nil,
                                    "Found \(canary) (\(encodingLabel)) in \(fileURL.path)"
                                )
                            }
                        }

                        // Sensitive .enc assets and History.sqlite* must contain 0 PNG magic headers.
                        if fileURL.resolvingSymlinksInPath().standardizedFileURL != plainImageURL.resolvingSymlinksInPath().standardizedFileURL {
                            #expect(
                                rawBytes.range(of: pngMagic) == nil,
                                "Unexpected PNG magic header in \(fileURL.path)"
                            )
                        }
                    }

                    // Plain sensitive source files were securely unlinked; non-sensitive PNG stayed plain.
                    #expect(!fileManager.fileExists(atPath: sensitiveImageURL.path))
                    #expect(!fileManager.fileExists(atPath: ogPreviewURL.path))
                    #expect(!fileManager.fileExists(atPath: ogFaviconURL.path))
                    #expect(fileManager.fileExists(atPath: plainImageURL.path))
                    #expect(try Data(contentsOf: plainImageURL) == plainImagePNG)

                    let (schemaVersion, hasFTSTable, hasPayloadCol) = try Self.inspectDatabaseState(at: dbURL)
                    #expect(schemaVersion == 5)
                    #expect(!hasFTSTable)
                    #expect(!hasPayloadCol)

                    // 2. Verify tags (v0 string-tag -> #3B85ED Tag.ID mapping vs v2+ non-rerun).
                    let migratedTags = try store.fetchTags()
                    let tagByName = Dictionary(uniqueKeysWithValues: migratedTags.map { ($0.name, $0) })
                    let legacyTag = try #require(tagByName["LegacyTag"])
                    let opsTag = try #require(tagByName["OpsTag"])
                    if legacyVersion == 0 {
                        #expect(legacyTag.color == "#3B85ED")
                        #expect(opsTag.color == "#3B85ED")
                        #expect(migratedTags.count == 2)
                    } else {
                        #expect(tagByName["UnmigratedV2StringTag"] == nil)
                        #expect(migratedTags.count == 2)
                    }

                    // 3. Verify all hydrated items, digests, dimensions, ordering, expiry, and Trash state.
                    let activeItems = try store.fetchAll()
                    let activeByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })

                    let migratedSecretText = try #require(activeByID[secretTextID])
                    #expect(!migratedSecretText.isContentLoaded)
                    #expect(try store.loadingContent(of: migratedSecretText, scope: .body).text == secretPlainText)
                    #expect(migratedSecretText.isFavorite)
                    #expect(migratedSecretText.favoriteOrder == 3)
                    #expect(abs(migratedSecretText.copiedAt.timeIntervalSince1970 - subSecondCopiedAt) < 0.000_5)
                    #expect(migratedSecretText.copySequenceID == sequenceID)
                    #expect(migratedSecretText.copySequenceOrder == 1)
                    #expect(Set(migratedSecretText.tags) == Set([legacyTag.id, opsTag.id]))
                    if legacyVersion >= 2 {
                        #expect(migratedSecretText.tagOrders == [legacyTag.id: 5, opsTag.id: 2])
                    }

                    let migratedSecretRich = try #require(activeByID[secretRichID])
                    #expect(!migratedSecretRich.isContentLoaded)
                    #expect(migratedSecretRich.hasFormatting)
                    #expect(migratedSecretRich.htmlDigest == expectedHTMLDigest)
                    let hydratedRich = try store.loadingContent(of: migratedSecretRich, scope: .full)
                    #expect(hydratedRich.text == "Benign Rich Heading")
                    #expect(hydratedRich.html == secretHTML)
                    #expect(hydratedRich.rtfData == secretRTFData)

                    let migratedSensImage = try #require(activeByID[sensitiveImageID])
                    #expect(!migratedSensImage.isContentLoaded)
                    #expect(try store.loadingContent(of: migratedSensImage, scope: .body).qrCodeText == secretQRText)
                    #expect(migratedSensImage.imageDigest == expectedSensitiveImageDigest)
                    #expect(migratedSensImage.imageDimensions?.width == 40)
                    #expect(migratedSensImage.imageDimensions?.height == 30)
                    let sensEncPath = try #require(migratedSensImage.assetPath)
                    #expect(sensEncPath.hasSuffix(".enc"))
                    let assetReader = ImageAssetStore(supportDirectory: directory)
                    #expect(
                        try assetReader.readPNGData(
                            at: URL(fileURLWithPath: sensEncPath),
                            role: .image,
                            clipID: sensitiveImageID,
                            keys: derivedKeys,
                            requiresEncryption: true
                        ) == sensitiveImagePNG
                    )

                    let migratedSensLink = try #require(activeByID[sensitiveLinkID])
                    let expectedLinkExpiresAt = legacyVersion >= 4 ? linkExpiresAt.timeIntervalSince1970 : 1_700_050_000.0
                    #expect(abs((migratedSensLink.expiresAt?.timeIntervalSince1970 ?? 0) - expectedLinkExpiresAt) < 0.000_5)
                    let migratedPreview = try #require(migratedSensLink.linkPreviewDetails)
                    #expect(migratedPreview.title == secretOGTitle)
                    let encPreviewPath = try #require(migratedPreview.imagePath)
                    let encFaviconPath = try #require(migratedPreview.faviconPath)
                    #expect(encPreviewPath.hasSuffix(".enc"))
                    #expect(encFaviconPath.hasSuffix(".enc"))
                    #expect(
                        try assetReader.readPNGData(
                            at: URL(fileURLWithPath: encPreviewPath),
                            role: .linkPreview,
                            clipID: sensitiveLinkID,
                            keys: derivedKeys,
                            requiresEncryption: true
                        ) == ogPreviewPNG
                    )
                    #expect(
                        try assetReader.readPNGData(
                            at: URL(fileURLWithPath: encFaviconPath),
                            role: .linkFavicon,
                            clipID: sensitiveLinkID,
                            keys: derivedKeys,
                            requiresEncryption: true
                        ) == ogFaviconICO
                    )

                    let migratedSensFile = try #require(activeByID[sensitiveFileID])
                    #expect(migratedSensFile.filePaths == [secretFilePath])

                    let migratedPlainImage = try #require(activeByID[plainImageID])
                    #expect(migratedPlainImage.assetPath == plainImageURL.path)
                    #expect(migratedPlainImage.imageDigest == expectedPlainImageDigest)
                    #expect(migratedPlainImage.imageDimensions?.width == 24)
                    #expect(migratedPlainImage.imageDimensions?.height == 16)

                    if legacyVersion == 4 {
                        #expect(activeByID[orphanTagTrashedID] == nil)
                        let trashed = try store.fetchTrashedItems()
                        #expect(trashed.map(\.id) == [orphanTagTrashedID])
                        let trashedItem = try #require(trashed.first)
                        #expect(trashedItem.tags.isEmpty)
                        #expect(abs((trashedItem.deletedAt?.timeIntervalSince1970 ?? 0) - trashedDeletedAt.timeIntervalSince1970) < 0.000_5)
                    } else {
                        let nonTrashedOrphan = try #require(activeByID[orphanTagTrashedID])
                        #expect(nonTrashedOrphan.tags.isEmpty)
                    }

                    // 4. Re-copy deduplication matches migrated keyed contentKey (both text & image).
                    let recopiedSecretText = try store.capture(
                        ClipboardItem.fixture(
                            kind: .text,
                            text: secretPlainText,
                            copiedAt: Date(timeIntervalSince1970: 1_700_002_000)
                        ),
                        updatesCopySequence: false
                    )
                    #expect(recopiedSecretText.id == secretTextID)
                    #expect(recopiedSecretText.copyCount == 3)

                    let recopiedPlainImage = try store.capture(
                        ClipboardItem.fixture(
                            kind: .image,
                            text: nil,
                            assetPath: plainImageURL.path,
                            imageDigest: expectedPlainImageDigest,
                            copiedAt: Date(timeIntervalSince1970: 1_700_002_001)
                        ),
                        updatesCopySequence: false
                    )
                    #expect(recopiedPlainImage.id == plainImageID)
                    #expect(recopiedPlainImage.copyCount == 2)
                }

                // 5. v5 close-and-reopen idempotence check sharing the same InMemoryDatabaseKeyProvider.
                do {
                    let reopenedStore = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { reopenedStore.close() }
                    #expect(reopenedStore.lockState == .unlocked)

                    let reopenedActive = try reopenedStore.fetchAll()
                    let reopenedByID = Dictionary(uniqueKeysWithValues: reopenedActive.map { ($0.id, $0) })
                    let reopenedSecretTextHeader = try #require(reopenedByID[secretTextID])
                    #expect(!reopenedSecretTextHeader.isContentLoaded)
                    #expect(reopenedSecretTextHeader.copyCount == 3)
                    #expect(try reopenedStore.loadingContent(of: reopenedSecretTextHeader, scope: .body).text == secretPlainText)
                    #expect(reopenedByID[sensitiveImageID]?.imageDigest == expectedSensitiveImageDigest)
                    #expect(reopenedByID[plainImageID]?.copyCount == 2)

                    let reopenedRich = try reopenedStore.loadingContent(
                        of: try #require(reopenedByID[secretRichID]),
                        scope: .full
                    )
                    #expect(reopenedRich.html == secretHTML)
                    #expect(reopenedRich.rtfData == secretRTFData)

                    if legacyVersion == 4 {
                        #expect(try reopenedStore.fetchTrashedItems().map(\.id) == [orphanTagTrashedID])
                    }
                }
            }
        }

        @Test
        func nestedPerformInTransactionReentrancyCommitAndRollback() throws {
            try TestSupport.withTemporaryHistoryStore { store, _ in
                // 1. Nested performInTransaction commit + uncommitted write visibility inside transaction.
                var committedOuterID: UUID?
                var committedInnerID: UUID?
                var committedTagID: ClipBook.Tag.ID?

                try store.performInTransaction {
                    let tag = try store.createTag(name: "NestedCommitTag", color: "#11AA44")
                    committedTagID = tag.id
                    #expect(try store.fetchTags().map(\.id) == [tag.id])

                    let outerItem = try store.capture(
                        ClipboardItem.fixture(
                            kind: .text,
                            text: "Outer transaction clip",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                            tags: [tag.id]
                        ),
                        updatesCopySequence: false
                    )
                    committedOuterID = outerItem.id
                    #expect(try store.fetchAll().map(\.id) == [outerItem.id])

                    try store.performInTransaction {
                        let innerItem = try store.capture(
                            ClipboardItem.fixture(
                                kind: .text,
                                text: "Inner transaction clip",
                                copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                                tags: [tag.id]
                            ),
                            updatesCopySequence: false
                        )
                        committedInnerID = innerItem.id
                        #expect(try store.fetchAll().count == 2)
                    }

                    #expect(try store.fetchAll().count == 2)
                }

                #expect(try store.fetchTags().map(\.id) == [try #require(committedTagID)])
                #expect(try store.fetchAll().map(\.id) == [try #require(committedInnerID), try #require(committedOuterID)])

                // 2. Nested performInTransaction mid-flight throw rolls back outer + inner writes cleanly.
                struct IntentionalMidFlightRollback: Error {}

                #expect(throws: IntentionalMidFlightRollback.self) {
                    try store.performInTransaction {
                        let transientTag = try store.createTag(name: "RolledBackTag", color: "#EE3322")
                        _ = try store.capture(
                            ClipboardItem.fixture(
                                kind: .text,
                                text: "Uncommitted outer clip",
                                copiedAt: Date(timeIntervalSince1970: 1_700_000_300),
                                tags: [transientTag.id]
                            ),
                            updatesCopySequence: false
                        )
                        #expect(try store.fetchTags().count == 2)
                        #expect(try store.fetchAll().count == 3)

                        try store.performInTransaction {
                            _ = try store.capture(
                                ClipboardItem.fixture(
                                    kind: .text,
                                    text: "Uncommitted inner clip",
                                    copiedAt: Date(timeIntervalSince1970: 1_700_000_400),
                                    tags: [transientTag.id]
                                ),
                                updatesCopySequence: false
                            )
                            #expect(try store.fetchAll().count == 4)
                            throw IntentionalMidFlightRollback()
                        }
                    }
                }

                #expect(try store.fetchTags().map(\.id) == [try #require(committedTagID)])
                #expect(try store.fetchAll().map(\.id) == [try #require(committedInnerID), try #require(committedOuterID)])
            }
        }

        @Test
        func unloadedHeadersScopedLoadingContentAndUpsertPreservation() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let keyProvider = InMemoryDatabaseKeyProvider()
                let store = GRDBHistoryStore(
                    directory: directory,
                    keyProvider: keyProvider
                )
                defer { store.close() }

                // 1. 50 KB unloaded header preservation + storedContentKey + deduplication.
                let body50KB = "FirstHeading\n" + String(repeating: "k", count: 50_000)
                let saved50KB = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        kind: .text,
                        text: body50KB,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_100)
                    ),
                    convertingExternalAssets: true
                )
                #expect(saved50KB.storedContentKey != nil)

                var unloaded50KB = try #require(try store.fetchAll().first { $0.id == saved50KB.id })
                #expect(!unloaded50KB.isContentLoaded)
                #expect(unloaded50KB.text == nil)
                #expect(unloaded50KB.characterCount == body50KB.count)
                #expect(unloaded50KB.storedContentKey == saved50KB.storedContentKey)
                #expect(unloaded50KB.searchText.isEmpty)

                unloaded50KB.isFavorite = true
                unloaded50KB.title = "Pinned 50KB Header"
                try store.upsert(unloaded50KB)

                let hydratedAfterUpsert = try store.loadingContent(of: unloaded50KB, scope: .body)
                #expect(hydratedAfterUpsert.isContentLoaded)
                #expect(hydratedAfterUpsert.text == body50KB)

                // Even if storedContentKey is nil on an unloaded header, upsert recomputes it from clip_contents.text.
                var clearedKeyHeader = try #require(try store.fetchAll().first { $0.id == saved50KB.id })
                clearedKeyHeader.storedContentKey = nil
                clearedKeyHeader.favoriteOrder = 9
                try store.upsert(clearedKeyHeader)

                let deduped50KB = try store.capture(
                    ClipboardItem.fixture(
                        kind: .text,
                        text: body50KB,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_150)
                    ),
                    updatesCopySequence: false
                )
                #expect(deduped50KB.id == saved50KB.id)
                #expect(deduped50KB.copyCount == 2)

                // 2. saveAndReconcileItem .png <-> .enc reconciliation & storedContentKey population.
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                let imgID = UUID()
                let plainImgURL = imagesDir.appendingPathComponent("\(imgID.uuidString).png")
                let imgBytes = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20, color: .systemTeal)
                try imgBytes.write(to: plainImgURL)

                var sensitiveImg = ClipboardItem.fixture(
                    id: imgID,
                    kind: .image,
                    text: nil,
                    assetPath: plainImgURL.path,
                    imageDigest: "digest-reconcile-img",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    sensitivity: .sensitive
                )
                sensitiveImg = try store.saveAndReconcileItem(sensitiveImg, convertingExternalAssets: true)
                #expect(sensitiveImg.storedContentKey != nil)
                #expect(sensitiveImg.assetPath?.hasSuffix(".enc") == true)
                #expect(!fileManager.fileExists(atPath: plainImgURL.path))
                #expect(fileManager.fileExists(atPath: try #require(sensitiveImg.assetPath)))

                sensitiveImg.sensitivity = .notSensitive
                let decryptedImg = try store.saveAndReconcileItem(sensitiveImg, convertingExternalAssets: true)
                #expect(decryptedImg.assetPath == plainImgURL.path)
                #expect(try Data(contentsOf: plainImgURL) == imgBytes)

                // 3. upsert detaches removed tags from clip_tags without truncating -wal when needsFreePageRelease == false.
                let tagOne = try store.createTag(name: "AlphaTag", color: "#112233")
                let tagTwo = try store.createTag(name: "BetaTag", color: "#445566")
                var taggedPlain = ClipboardItem.fixture(
                    kind: .text,
                    text: "Ordinary non-sensitive tagged note",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_250),
                    tags: [tagOne.id, tagTwo.id]
                )
                taggedPlain.tagOrders = [tagOne.id: 1, tagTwo.id: 2]
                try store.upsert(taggedPlain)

                // Drain any prior free-page release from earlier steps so needsFreePageRelease starts false.
                store.flushPendingFreePageRelease()

                taggedPlain.tags = [tagOne.id]
                try store.upsert(taggedPlain)
                store.flushPendingFreePageRelease()

                let walURL = directory.appendingPathComponent("History.sqlite-wal")
                let walSizeAfterPlainTagDetach = (try? fileManager.attributesOfItem(atPath: walURL.path)[.size] as? Int64) ?? 0
                #expect(walSizeAfterPlainTagDetach > 0)

                let fetchedTagged = try #require(try store.fetchAll().first { $0.id == taggedPlain.id })
                #expect(fetchedTagged.tags == [tagOne.id])
                #expect(fetchedTagged.tagOrders == [tagOne.id: 1])

                // 4. Scoped loadingContent(of:scope:) (.body, .preview, .full) + upsert formatting preservation.
                let rtfBytes = try TestSupport.makeRTFData(text: "Scoped Rich Body")
                let htmlMarkup = "<section><h2>Scoped Rich Body</h2><p>Paragraph</p></section>"
                let richItem = ClipboardItem.fixture(
                    kind: .richText,
                    title: "Initial Scoped Title",
                    text: "Scoped Rich Body",
                    qrCodeText: "https://clipbook.app/scoped-qr",
                    rtfData: rtfBytes,
                    html: htmlMarkup,
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_300),
                    tags: [tagOne.id]
                )
                try store.upsert(richItem)

                let richHeader1 = try #require(try store.fetchAll().first { $0.id == richItem.id })
                #expect(!richHeader1.isContentLoaded)
                #expect(richHeader1.hasFormatting)
                #expect(!richHeader1.isPreviewFormattingLoaded)
                #expect(!richHeader1.isFormattingLoaded)
                #expect(richHeader1.rtfData == nil)
                #expect(richHeader1.html == nil)

                var bodyOnly = try store.loadingContent(of: richHeader1, scope: .body)
                #expect(bodyOnly.isContentLoaded)
                #expect(bodyOnly.text == "Scoped Rich Body")
                #expect(bodyOnly.qrCodeText == "https://clipbook.app/scoped-qr")
                #expect(bodyOnly.searchText.localizedCaseInsensitiveContains("AlphaTag"))
                #expect(bodyOnly.rtfData == nil)
                #expect(bodyOnly.html == nil)
                #expect(!bodyOnly.isPreviewFormattingLoaded)
                #expect(!bodyOnly.isFormattingLoaded)

                bodyOnly.title = "Updated After Body Scope"
                try store.upsert(bodyOnly)

                let richHeader2 = try #require(try store.fetchAll().first { $0.id == richItem.id })
                #expect(richHeader2.title == "Updated After Body Scope")
                var previewOnly = try store.loadingContent(of: richHeader2, scope: .preview)
                #expect(previewOnly.isContentLoaded)
                #expect(previewOnly.rtfData == rtfBytes)
                #expect(previewOnly.html == nil)
                #expect(previewOnly.isPreviewFormattingLoaded)
                #expect(!previewOnly.isFormattingLoaded)

                previewOnly.title = "Updated After Preview Scope"
                try store.upsert(previewOnly)

                let richHeader3 = try #require(try store.fetchAll().first { $0.id == richItem.id })
                #expect(richHeader3.title == "Updated After Preview Scope")
                let upgradedFromPreview = try store.loadingContent(of: previewOnly, scope: .full)
                #expect(upgradedFromPreview.isFormattingLoaded)
                #expect(upgradedFromPreview.rtfData == rtfBytes)
                #expect(upgradedFromPreview.html == htmlMarkup)

                let fullFromUnloaded = try store.loadingContent(of: richHeader3, scope: .full)
                #expect(fullFromUnloaded.isFormattingLoaded)
                #expect(fullFromUnloaded.rtfData == rtfBytes)
                #expect(fullFromUnloaded.html == htmlMarkup)
            }
        }

        @Test
        func fetchSearchTextsPositionalAlignmentCursorScanEncryptionAndCancellation() throws {
            try TestSupport.withTemporaryHistoryStore { store, directory in
                let fileManager = FileManager.default
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                let secretTag = try store.createTag(name: "InfraVault", color: "#9933CC")
                let batchTag = try store.createTag(name: "BulkTag", color: "#2288EE")
                let tagNamesByID = [
                    secretTag.id: secretTag.name,
                    batchTag.id: batchTag.name,
                ]

                let secretToken = ["Authorization", ": Bearer ", "SEARCH_ENCRYPTED_", "TOKEN_445566"].joined()
                let encryptedTextItem = ClipboardItem.fixture(
                    kind: .text,
                    title: "Encrypted Webhook Label",
                    text: secretToken,
                    qrCodeText: "QR_SECRET_MARKER_7788",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_010),
                    tags: [secretTag.id]
                )
                #expect(SensitiveContent.shouldEncryptAtRest(encryptedTextItem))
                try store.upsert(encryptedTextItem)

                let encImageID = UUID()
                let encImageSrcURL = imagesDir.appendingPathComponent("\(encImageID.uuidString).png")
                try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16).write(to: encImageSrcURL)
                let encryptedImageItem = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: encImageID,
                        kind: .image,
                        title: "Diagram Caption",
                        text: "Vision OCR Payload",
                        assetPath: encImageSrcURL.path,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_020),
                        sensitivity: .sensitive
                    ),
                    convertingExternalAssets: true
                )
                #expect(encryptedImageItem.assetPath?.hasSuffix(".enc") == true)

                let trashedItem = ClipboardItem.fixture(
                    kind: .text,
                    text: "Trashed Searchable Note",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_030)
                )
                try store.upsert(trashedItem)
                try store.moveToTrash(ids: [trashedItem.id], at: Date(timeIntervalSince1970: 1_700_000_040))

                let missingID = UUID()

                // 1. <= 500 IDs (`IN (...)` path) with missing, trashed-mismatched, encrypted, image, and duplicate IDs.
                let smallQueryIDs = [
                    missingID,
                    encryptedTextItem.id,
                    trashedItem.id,
                    encryptedImageItem.id,
                    encryptedTextItem.id,
                ]
                let smallActiveResults = try #require(
                    try store.fetchSearchTexts(
                        for: smallQueryIDs,
                        trashed: false,
                        tagNamesByID: tagNamesByID,
                        isCancelled: { false }
                    )
                )
                #expect(smallActiveResults.count == smallQueryIDs.count)
                #expect(smallActiveResults[0] == nil)
                #expect(smallActiveResults[2] == nil)
                #expect(smallActiveResults[1] == smallActiveResults[4])

                let decryptedSearch = try #require(smallActiveResults[1])
                #expect(decryptedSearch.contains("SEARCH_ENCRYPTED_TOKEN_445566"))
                #expect(decryptedSearch.contains("Encrypted Webhook Label"))
                #expect(decryptedSearch.contains("QR_SECRET_MARKER_7788"))
                #expect(decryptedSearch.contains("InfraVault"))

                let imageSearch = try #require(smallActiveResults[3])
                #expect(imageSearch.contains("Vision OCR Payload"))
                #expect(imageSearch.contains("Diagram Caption"))
                #expect(!imageSearch.localizedCaseInsensitiveContains(encImageID.uuidString))
                #expect(!imageSearch.localizedCaseInsensitiveContains(".enc"))

                // Trashed == true flips visibility: trashedItem resolves while active items return nil.
                let smallTrashedResults = try #require(
                    try store.fetchSearchTexts(
                        for: [encryptedTextItem.id, trashedItem.id, missingID],
                        trashed: true,
                        tagNamesByID: tagNamesByID,
                        isCancelled: { false }
                    )
                )
                #expect(smallTrashedResults[0] == nil)
                #expect(smallTrashedResults[1]?.contains("Trashed Searchable Note") == true)
                #expect(smallTrashedResults[2] == nil)

                // 2. 1,200-ID sequential LEFT JOIN cursor scan (> 500 batch threshold).
                var bulkIDs: [UUID] = []
                bulkIDs.reserveCapacity(1_198)
                try store.performInTransaction {
                    for index in 0..<1_198 {
                        let id = UUID()
                        bulkIDs.append(id)
                        let isEncryptedRow = (index % 250 == 0)
                        let rowText = isEncryptedRow
                            ? ["api_key", "=", "BULK_SECRET_", "\(index)_990011223344"].joined()
                            : "BulkCursorEntry_\(index)"
                        let clip = ClipboardItem.fixture(
                            id: id,
                            kind: .text,
                            text: rowText,
                            copiedAt: Date(timeIntervalSince1970: 1_700_010_000 + Double(index)),
                            tags: (index % 100 == 0) ? [batchTag.id] : []
                        )
                        try store.upsert(clip)
                    }
                }

                // Build a 1,200-element ID array in reverse order with a missing ID at 333 and trashed ID at 777.
                var cursorQueryIDs = Array(bulkIDs.reversed())
                cursorQueryIDs.insert(missingID, at: 333)
                cursorQueryIDs.insert(trashedItem.id, at: 777)
                #expect(cursorQueryIDs.count == 1_200)

                let cursorResults = try #require(
                    try store.fetchSearchTexts(
                        for: cursorQueryIDs,
                        trashed: false,
                        tagNamesByID: tagNamesByID,
                        isCancelled: { false }
                    )
                )
                #expect(cursorResults.count == 1_200)
                #expect(cursorResults[333] == nil)
                #expect(cursorResults[777] == nil)

                // Verify positional alignment across both plain and encrypted rows in the 1,200-item result.
                for (pos, queriedID) in cursorQueryIDs.enumerated() {
                    if pos == 333 || pos == 777 {
                        #expect(cursorResults[pos] == nil)
                        continue
                    }
                    let slot = try #require(cursorResults[pos])
                    if let originalIndex = bulkIDs.firstIndex(of: queriedID),
                       (originalIndex == 0 || originalIndex == 500 || originalIndex == 1_000 || originalIndex == 1_197) {
                        if originalIndex % 250 == 0 {
                            #expect(slot.contains("BULK_SECRET_\(originalIndex)_990011223344"))
                        } else {
                            #expect(slot.contains("BulkCursorEntry_\(originalIndex)"))
                        }
                        if originalIndex % 100 == 0 {
                            #expect(slot.contains("BulkTag"))
                        }
                    }
                }

                // 3. Cancellation returns outer nil (both immediate and mid-cursor scan).
                #expect(
                    try store.fetchSearchTexts(
                        for: smallQueryIDs,
                        trashed: false,
                        tagNamesByID: tagNamesByID,
                        isCancelled: { true }
                    ) == nil
                )

                var cancelCheckCount = 0
                let midScanCancelled = try store.fetchSearchTexts(
                    for: cursorQueryIDs,
                    trashed: false,
                    tagNamesByID: tagNamesByID,
                    isCancelled: {
                        cancelCheckCount += 1
                        return cancelCheckCount >= 3
                    }
                )
                #expect(midScanCancelled == nil)
                #expect(cancelCheckCount >= 3)
            }
        }

        @Test
        func setSensitivityRoundTripExpiryRulesAndConcurrentReaderWALScrubbing() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let walURL = directory.appendingPathComponent("History.sqlite-wal")
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                let keyProvider = InMemoryDatabaseKeyProvider()
                let store = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                defer { store.close() }

                // 1. .none -> .sensitive -> .notSensitive -> .sensitive DB + .png <-> .enc round-trip.
                let imgID = UUID()
                let plainImgURL = imagesDir.appendingPathComponent("\(imgID.uuidString).png")
                let encImgURL = imagesDir.appendingPathComponent("\(imgID.uuidString).enc")
                let pngBytes = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 20, color: .systemIndigo)
                let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
                try pngBytes.write(to: plainImgURL)

                let initialImage = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: imgID,
                        kind: .image,
                        title: "Toggle Sensitivity Image",
                        text: "Benign OCR",
                        assetPath: plainImgURL.path,
                        imageDigest: "img-toggle-digest",
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        sensitivity: nil
                    ),
                    convertingExternalAssets: true
                )
                #expect(initialImage.sensitivity == nil)
                #expect(initialImage.assetPath == plainImgURL.path)
                #expect(fileManager.fileExists(atPath: plainImgURL.path))
                #expect(!fileManager.fileExists(atPath: encImgURL.path))

                let markedSensitive1 = try #require(try store.setSensitivity(.sensitive, for: imgID))
                #expect(markedSensitive1.sensitivity == .sensitive)
                #expect(markedSensitive1.assetPath == encImgURL.path)
                #expect(!fileManager.fileExists(atPath: plainImgURL.path))
                #expect(fileManager.fileExists(atPath: encImgURL.path))
                #expect(try Data(contentsOf: encImgURL).range(of: pngMagic) == nil)
                #expect(try Self.queryInt(at: dbURL, "SELECT isEncrypted FROM clips WHERE id = '\(imgID.uuidString)';") == 1)

                let markedNotSensitive = try #require(try store.setSensitivity(.notSensitive, for: imgID))
                #expect(markedNotSensitive.sensitivity == .notSensitive)
                #expect(markedNotSensitive.assetPath == plainImgURL.path)
                #expect(fileManager.fileExists(atPath: plainImgURL.path))
                #expect(!fileManager.fileExists(atPath: encImgURL.path))
                #expect(try Data(contentsOf: plainImgURL) == pngBytes)
                #expect(try Self.queryInt(at: dbURL, "SELECT isEncrypted FROM clips WHERE id = '\(imgID.uuidString)';") == 0)

                let markedSensitive2 = try #require(try store.setSensitivity(.sensitive, for: imgID))
                #expect(markedSensitive2.sensitivity == .sensitive)
                #expect(markedSensitive2.assetPath == encImgURL.path)
                #expect(!fileManager.fileExists(atPath: plainImgURL.path))
                #expect(fileManager.fileExists(atPath: encImgURL.path))
                #expect(try Self.queryInt(at: dbURL, "SELECT isEncrypted FROM clips WHERE id = '\(imgID.uuidString)';") == 1)

                // 2. expiresAt clearing rules on setSensitivity(.notSensitive, for:):
                //    - existing.sensitivity == nil (auto-detected secret) -> clears expiresAt to nil
                //    - existing.sensitivity == .sensitive (ConcealedType) -> preserves expiresAt
                let autoExpiry = Date(timeIntervalSince1970: 1_700_005_000)
                var autoSecretItem = ClipboardItem.fixture(
                    kind: .text,
                    text: ["Authorization", ": Bearer ", "AUTO_EXPIRY_", "SECRET_11223344"].joined(),
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    sensitivity: nil
                )
                autoSecretItem.expiresAt = autoExpiry
                #expect(SensitiveContent.shouldEncryptAtRest(autoSecretItem))
                try store.upsert(autoSecretItem)

                let clearedAuto = try #require(try store.setSensitivity(.notSensitive, for: autoSecretItem.id))
                #expect(clearedAuto.sensitivity == .notSensitive)
                #expect(clearedAuto.expiresAt == nil)

                let concealedExpiry = Date(timeIntervalSince1970: 1_700_006_000)
                var concealedItem = ClipboardItem.fixture(
                    kind: .text,
                    text: "Concealed clipboard value",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_250),
                    sensitivity: .sensitive
                )
                concealedItem.expiresAt = concealedExpiry
                try store.upsert(concealedItem)

                let preservedConcealed = try #require(try store.setSensitivity(.notSensitive, for: concealedItem.id))
                #expect(preservedConcealed.sensitivity == .notSensitive)
                #expect(preservedConcealed.expiresAt == concealedExpiry)

                // 3. Concurrent-reader WAL scrubbing:
                //    Seed plaintext canaries into both History.sqlite and History.sqlite-wal, hold an active
                //    DatabasePool reader snapshot via fetchItems(where:), verify delete + 0 -> 1 encryption
                //    upgrade return without blocking on the reader, then release the reader and flush to
                //    truncate History.sqlite-wal to 0 bytes with 0 plaintext canary occurrences on disk.
                let canaryDeleteMain = "CANARY_CONCURRENT_DELETE_MAIN_314159"
                let canaryDeleteWAL = "CANARY_CONCURRENT_DELETE_WAL_314159"
                let canaryUpgradePlain = "CANARY_CONCURRENT_UPGRADE_PLAIN_314159"

                var deleteTarget = ClipboardItem.fixture(
                    kind: .text,
                    text: canaryDeleteMain,
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_300)
                )
                let upgradeTarget = ClipboardItem.fixture(
                    kind: .text,
                    text: canaryUpgradePlain,
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_310)
                )
                try store.upsert(deleteTarget)
                try store.upsert(upgradeTarget)

                // Flush once so canaryDeleteMain and canaryUpgradePlain reside in History.sqlite main pages,
                // then write canaryDeleteWAL into History.sqlite-wal.
                try store.delete(autoSecretItem.id)
                store.flushPendingFreePageRelease()
                deleteTarget.text = canaryDeleteWAL
                try store.upsert(deleteTarget)

                #expect(try Data(contentsOf: dbURL).range(of: Data(canaryUpgradePlain.utf8)) != nil)
                #expect(try Data(contentsOf: walURL).range(of: Data(canaryDeleteWAL.utf8)) != nil)

                let readerSnapshotAcquired = DispatchSemaphore(value: 0)
                let releaseReaderSnapshot = DispatchSemaphore(value: 0)
                let readerCompleted = DispatchSemaphore(value: 0)
                let didPauseOnce = OSAllocatedUnfairLock(initialState: false)

                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? store.fetchItems { _ in
                        let shouldPause = didPauseOnce.withLock { paused -> Bool in
                            if paused { return false }
                            paused = true
                            return true
                        }
                        if shouldPause {
                            readerSnapshotAcquired.signal()
                            _ = releaseReaderSnapshot.wait(timeout: .now() + 10)
                        }
                        return true
                    }
                    readerCompleted.signal()
                }

                #expect(readerSnapshotAcquired.wait(timeout: .now() + 5) == .success)

                // Both writes must complete immediately while the DatabasePool reader is still blocked!
                let writeStart = ContinuousClock.now
                try store.delete(deleteTarget.id)
                let upgradedWhileReaderActive = try #require(
                    try store.setSensitivity(.sensitive, for: upgradeTarget.id)
                )
                let writeDuration = ContinuousClock.now - writeStart
                #expect(upgradedWhileReaderActive.sensitivity == .sensitive)
                #expect(writeDuration < .seconds(2))

                // Now let the active reader snapshot finish and drain the barrier free-page + WAL truncation pass.
                releaseReaderSnapshot.signal()
                #expect(readerCompleted.wait(timeout: .now() + 5) == .success)
                store.flushPendingFreePageRelease()

                let walSizeAfterFlush = (try? fileManager.attributesOfItem(atPath: walURL.path)[.size] as? Int64) ?? 0
                #expect(walSizeAfterFlush == 0)

                for checkURL in [dbURL, walURL] where fileManager.fileExists(atPath: checkURL.path) {
                    let rawBytes = try Data(contentsOf: checkURL)
                    for canary in [canaryDeleteMain, canaryDeleteWAL, canaryUpgradePlain] {
                        for (label, needle) in Self.canaryBytePatterns(for: canary) {
                            #expect(
                                rawBytes.range(of: needle) == nil,
                                "Found \(canary) (\(label)) in \(checkURL.lastPathComponent)"
                            )
                        }
                    }
                }

                // Upgraded item still decrypts cleanly via GRDBHistoryStore.
                let fetchedUpgraded = try #require(try store.fetchAll().first { $0.id == upgradeTarget.id })
                #expect(!fetchedUpgraded.isContentLoaded)
                #expect(try store.loadingContent(of: fetchedUpgraded, scope: .body).text == canaryUpgradePlain)
            }
        }

        @Test
        func clipTagsCascadeDeleteOnTrashedItems() throws {
            try TestSupport.withTemporaryHistoryStore { store, directory in
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let tagKeep = try store.createTag(name: "CascadeKeep", color: "#1188CC")
                let tagDrop = try store.createTag(name: "CascadeDrop", color: "#CC4411")

                let trashedOne = ClipboardItem.fixture(
                    kind: .text,
                    text: "Trashed clip one",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    isFavorite: true,
                    tags: [tagKeep.id, tagDrop.id]
                )
                let trashedTwo = ClipboardItem.fixture(
                    kind: .text,
                    text: "Trashed clip two",
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    tags: [tagKeep.id]
                )
                try store.upsert(trashedOne)
                try store.upsert(trashedTwo)
                try store.moveToTrash(
                    ids: [trashedOne.id, trashedTwo.id],
                    at: Date(timeIntervalSince1970: 1_700_000_300)
                )

                // Deleting a tag cascades into clip_tags even on trashed items.
                try store.deleteTag(id: tagDrop.id)
                let afterTagDelete = try #require(try store.fetchTrashedItems().first { $0.id == trashedOne.id })
                #expect(afterTagDelete.tags == [tagKeep.id])

                // Deleting a trashed clip cascades into clip_tags and clip_contents.
                try store.delete(trashedOne.id)
                store.flushPendingFreePageRelease()
                #expect(
                    try Self.queryInt(
                        at: dbURL,
                        "SELECT count(*) FROM clip_tags WHERE clipId = '\(trashedOne.id.uuidString)';"
                    ) == 0
                )
                #expect(
                    try Self.queryInt(
                        at: dbURL,
                        "SELECT count(*) FROM clip_contents WHERE clipId = '\(trashedOne.id.uuidString)';"
                    ) == 0
                )

                // clear(keepingFavoritesAndTaggedItems: true) deletes remaining trashed items and cascades clip_tags.
                try store.clear(keepingFavoritesAndTaggedItems: true)
                store.flushPendingFreePageRelease()
                #expect(try store.fetchTrashedItems().isEmpty)
                #expect(
                    try Self.queryInt(
                        at: dbURL,
                        "SELECT count(*) FROM clip_tags WHERE clipId = '\(trashedTwo.id.uuidString)';"
                    ) == 0
                )
            }
        }

        @Test
        func rowTamperAndPlaintextDowngradeIsolation() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                let masterKey = SymmetricKey(size: .bits256)
                let derivedKeys = ClipBookDerivedKeys(masterKey: masterKey)
                let keyProvider = InMemoryDatabaseKeyProvider(key: masterKey)

                let healthyID = UUID()
                let tamperedTextID = UUID()
                let tamperedTitleID = UUID()
                let plainAssetPathID = UUID()
                let downgradedPNGPathID = UUID()

                for id in [plainAssetPathID, downgradedPNGPathID] {
                    let imgURL = imagesDir.appendingPathComponent("\(id.uuidString).png")
                    try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16).write(to: imgURL)
                }

                // Seed 1 healthy item + 4 encrypted items to tamper individually.
                do {
                    let seedStore = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { seedStore.close() }

                    try seedStore.upsert(
                        ClipboardItem.fixture(
                            id: healthyID,
                            kind: .text,
                            text: "Healthy surviving item",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_500)
                        )
                    )

                    let tamperedTextItem = ClipboardItem.fixture(
                        id: tamperedTextID,
                        kind: .text,
                        title: "Valid Title",
                        text: ["Authorization", ": Bearer ", "TAMPER_TEXT_", "1111222233334444"].joined(),
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_400)
                    )
                    let tamperedTitleItem = ClipboardItem.fixture(
                        id: tamperedTitleID,
                        kind: .text,
                        title: "Encrypted Title To Tamper",
                        text: ["Authorization", ": Bearer ", "TAMPER_TITLE_", "2222333344445555"].joined(),
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_300)
                    )
                    let plainAssetPathItem = ClipboardItem.fixture(
                        id: plainAssetPathID,
                        kind: .image,
                        title: "Encrypted Image 1",
                        assetPath: imagesDir.appendingPathComponent("\(plainAssetPathID.uuidString).png").path,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                        sensitivity: .sensitive
                    )
                    let downgradedPNGPathItem = ClipboardItem.fixture(
                        id: downgradedPNGPathID,
                        kind: .image,
                        title: "Encrypted Image 2",
                        assetPath: imagesDir.appendingPathComponent("\(downgradedPNGPathID.uuidString).png").path,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        sensitivity: .sensitive
                    )

                    #expect(SensitiveContent.shouldEncryptAtRest(tamperedTextItem))
                    #expect(SensitiveContent.shouldEncryptAtRest(tamperedTitleItem))
                    #expect(SensitiveContent.shouldEncryptAtRest(plainAssetPathItem))
                    #expect(SensitiveContent.shouldEncryptAtRest(downgradedPNGPathItem))

                    try seedStore.upsert(tamperedTextItem)
                    try seedStore.upsert(tamperedTitleItem)
                    _ = try seedStore.saveAndReconcileItem(plainAssetPathItem, convertingExternalAssets: true)
                    _ = try seedStore.saveAndReconcileItem(downgradedPNGPathItem, convertingExternalAssets: true)
                }

                // Apply 4 distinct tamper / downgrade attacks directly in SQLite:
                // 1) Plaintext UTF-8 bytes in clip_contents.text on an isEncrypted == 1 row
                // 2) Plaintext UTF-8 bytes in clips.title on an isEncrypted == 1 row
                // 3) Plaintext UTF-8 bytes in clips.assetPath on an isEncrypted == 1 row
                // 4) Validly AES-GCM-sealed downgraded ".png" path in clips.assetPath on an isEncrypted == 1 row
                let sealedDowngradedPNGPath = try HistoryCrypto.sealColumn(
                    Data(imagesDir.appendingPathComponent("\(downgradedPNGPathID.uuidString).png").path.utf8),
                    table: "clips",
                    column: "assetPath",
                    clipID: downgradedPNGPathID,
                    keys: derivedKeys
                )
                try Self.executeSQL(at: dbURL, """
                    UPDATE clip_contents SET text = \(Self.sqlHex(Data("injected plaintext body".utf8)))
                    WHERE clipId = '\(tamperedTextID.uuidString)';
                    UPDATE clips SET title = \(Self.sqlHex(Data("injected plaintext title".utf8)))
                    WHERE id = '\(tamperedTitleID.uuidString)';
                    UPDATE clips SET assetPath = \(Self.sqlHex(Data(imagesDir.appendingPathComponent("\(plainAssetPathID.uuidString).enc").path.utf8)))
                    WHERE id = '\(plainAssetPathID.uuidString)';
                    UPDATE clips SET assetPath = \(Self.sqlHex(sealedDowngradedPNGPath))
                    WHERE id = '\(downgradedPNGPathID.uuidString)';
                    """)

                // Verify batch isolation + strict authenticationFailed throws across loadingContent, fetchStoredFilePaths, and setSensitivity.
                do {
                    let store = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { store.close() }

                    let allItems = try store.fetchAll()
                    #expect(allItems.count == 5)
                    let byID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })

                    let healthy = try #require(byID[healthyID])
                    #expect(!healthy.isContentLoaded)
                    #expect(healthy.previewText == "Healthy surviving item")
                    #expect(try store.loadingContent(of: healthy, scope: .body).text == "Healthy surviving item")

                    // tamperedTextID only tampered clip_contents.text (which unloaded fetchAll() skips);
                    // hydrating its body or changing sensitivity strictly throws authenticationFailed.
                    let tamperedTextHeader = try #require(byID[tamperedTextID])
                    #expect(!tamperedTextHeader.isContentLoaded)
                    #expect(tamperedTextHeader.title == "Valid Title")
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        _ = try store.loadingContent(of: tamperedTextHeader, scope: .body)
                    }
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        _ = try store.setSensitivity(.notSensitive, for: tamperedTextID)
                    }

                    for corruptID in [tamperedTitleID, plainAssetPathID, downgradedPNGPathID] {
                        let placeholder = try #require(byID[corruptID])
                        #expect(placeholder.sensitivity == .sensitive)
                        #expect(placeholder.assetPath == nil)
                        #expect(placeholder.title == nil)
                        #expect(placeholder.textPreview == nil)
                        #expect(placeholder.searchText.isEmpty)
                        #expect(!placeholder.isContentLoaded)

                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.loadingContent(of: placeholder, scope: .body)
                        }
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.setSensitivity(.notSensitive, for: corruptID)
                        }
                    }

                    // fetchStoredFilePaths strictly throws authenticationFailed on tampered/downgraded assetPath!
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        _ = try store.fetchStoredFilePaths()
                    }

                    // Isolate downgradedPNGPathID alone as the only assetPath row to prove the sealed .png downgrade
                    // independently triggers authenticationFailed in fetchStoredFilePaths.
                    try store.delete(plainAssetPathID)
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        _ = try store.fetchStoredFilePaths()
                    }
                }
            }
        }

        @Test
        func upsertAndSaveAndReconcileRejectCorruptEncryptedPlaceholdersWithoutOverwriting() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                let masterKey = SymmetricKey(size: .bits256)
                let keyProvider = InMemoryDatabaseKeyProvider(key: masterKey)

                let healthyID = UUID()
                let corruptTextID = UUID()
                let corruptImageID = UUID()
                let sourcePNG = imagesDir.appendingPathComponent("\(corruptImageID.uuidString).png")
                try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemTeal).write(to: sourcePNG)
                var encAssetURL: URL!

                do {
                    let seedStore = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { seedStore.close() }

                    try seedStore.upsert(
                        ClipboardItem.fixture(
                            id: healthyID,
                            kind: .text,
                            text: "Healthy control clip",
                            copiedAt: Date(timeIntervalSince1970: 1_700_200_300)
                        )
                    )

                    let secretTextItem = ClipboardItem.fixture(
                        id: corruptTextID,
                        kind: .text,
                        title: "Protected Secret Title",
                        text: ["Authorization", ": Bearer ", "PLACEHOLDER_GUARD_", "4455667788990011"].joined(),
                        copiedAt: Date(timeIntervalSince1970: 1_700_200_200)
                    )
                    #expect(SensitiveContent.shouldEncryptAtRest(secretTextItem))
                    try seedStore.upsert(secretTextItem)

                    let secretImageItem = ClipboardItem.fixture(
                        id: corruptImageID,
                        kind: .image,
                        title: "Protected Image Title",
                        text: ["Authorization", ": Bearer ", "IMAGE_PLACEHOLDER_", "9988776655443322"].joined(),
                        assetPath: sourcePNG.path,
                        copiedAt: Date(timeIntervalSince1970: 1_700_200_100),
                        sensitivity: .sensitive
                    )
                    let savedImage = try seedStore.saveAndReconcileItem(secretImageItem, convertingExternalAssets: true)
                    encAssetURL = URL(fileURLWithPath: try #require(savedImage.assetPath))
                }

                // Tamper encrypted header columns on both secret rows while keeping clip_contents.text and the .enc asset intact.
                try Self.executeSQL(at: dbURL, """
                    UPDATE clips SET title = \(Self.sqlHex(Data("corrupted-header-title".utf8)))
                    WHERE id = '\(corruptTextID.uuidString)';
                    UPDATE clips SET assetPath = \(Self.sqlHex(Data("corrupted-header-asset-path".utf8)))
                    WHERE id = '\(corruptImageID.uuidString)';
                    """)

                func snapshotRowState(for id: UUID) throws -> String {
                    try #require(
                        try Self.queryText(
                            at: dbURL,
                            """
                            SELECT c.isEncrypted || '|' || c.isFavorite || '|' || coalesce(hex(c.title), 'NULL')
                                || '|' || coalesce(hex(c.textPreview), 'NULL') || '|' || coalesce(hex(c.assetPath), 'NULL')
                                || '|' || coalesce(hex(cc.text), 'NULL')
                            FROM clips c
                            LEFT JOIN clip_contents cc ON cc.clipId = c.id
                            WHERE c.id = '\(id.uuidString)';
                            """
                        )
                    )
                }

                let baselineTextRow = try snapshotRowState(for: corruptTextID)
                let baselineImageRow = try snapshotRowState(for: corruptImageID)
                let baselineEncBytes = try Data(contentsOf: encAssetURL)

                do {
                    let store = GRDBHistoryStore(directory: directory, keyProvider: keyProvider)
                    defer { store.close() }

                    let byID = Dictionary(uniqueKeysWithValues: try store.fetchAll().map { ($0.id, $0) })
                    let healthy = try #require(byID[healthyID])
                    #expect(!healthy.isCorruptPlaceholder)

                    for corruptID in [corruptTextID, corruptImageID] {
                        let placeholder = try #require(byID[corruptID])
                        #expect(placeholder.isCorruptPlaceholder)
                        #expect(placeholder.unloadingContent().isCorruptPlaceholder)
                        #expect(placeholder.withLoadedContent(text: "forged-body", qrCodeText: nil).isCorruptPlaceholder)

                        var mutatedUnloaded = placeholder
                        mutatedUnloaded.isFavorite = true
                        mutatedUnloaded.title = "Attempted Overwrite Title"
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            try store.upsert(mutatedUnloaded)
                        }
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.saveAndReconcileItem(mutatedUnloaded, convertingExternalAssets: false)
                        }
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.saveAndReconcileItem(mutatedUnloaded, convertingExternalAssets: true)
                        }

                        let mutatedLoaded = mutatedUnloaded.withLoadedContent(
                            text: "Attempted Overwrite Plaintext Body",
                            qrCodeText: nil
                        )
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            try store.upsert(mutatedLoaded)
                        }
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.saveAndReconcileItem(mutatedLoaded, convertingExternalAssets: true)
                        }

                        // Even a caller passing a non-placeholder unloaded header for the tampered ID is blocked by header authentication.
                        let synthesizedUnloaded = ClipboardItem.fromStoredHeader(
                            id: corruptID,
                            kind: placeholder.kind,
                            title: "Bypassed Flag Attempt",
                            textPreview: nil,
                            characterCount: 0,
                            containsPreviewSecret: true,
                            containsRestSecret: true,
                            hasRecognizedText: false,
                            hasQRCodeText: false,
                            isSVGText: false,
                            hasFormatting: false,
                            htmlDigest: nil,
                            imageDigest: nil,
                            imageWidth: nil,
                            imageHeight: nil,
                            assetPath: nil,
                            filePaths: [],
                            sourceAppName: placeholder.sourceAppName,
                            sourceBundleIdentifier: placeholder.sourceBundleIdentifier,
                            copiedAt: placeholder.copiedAt,
                            firstCopiedAt: placeholder.firstCopiedAt,
                            byteSize: placeholder.byteSize,
                            isFavorite: true,
                            tags: [],
                            tagOrders: [:],
                            copyCount: placeholder.copyCount,
                            linkPreviewDetails: nil,
                            copySequenceID: nil,
                            copySequenceOrder: nil,
                            favoriteOrder: nil,
                            sensitivity: .sensitive,
                            expiresAt: nil,
                            deletedAt: nil,
                            storedContentKey: nil,
                            isCorruptPlaceholder: false
                        )
                        #expect(!synthesizedUnloaded.isCorruptPlaceholder)
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            try store.upsert(synthesizedUnloaded)
                        }
                        #expect(throws: HistoryStoreError.authenticationFailed) {
                            _ = try store.saveAndReconcileItem(synthesizedUnloaded, convertingExternalAssets: true)
                        }
                    }

                    store.flushPendingFreePageRelease()
                }

                #expect(try snapshotRowState(for: corruptTextID) == baselineTextRow)
                #expect(try snapshotRowState(for: corruptImageID) == baselineImageRow)
                #expect(try Data(contentsOf: encAssetURL) == baselineEncBytes)
            }
        }

        @Test
        func storeLockStateFailClosedAndRetryUnlockRecovery() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileManager = FileManager.default
                let dbURL = directory.appendingPathComponent("History.sqlite")
                let walURL = directory.appendingPathComponent("History.sqlite-wal")
                let shmURL = directory.appendingPathComponent("History.sqlite-shm")
                let imagesDir = directory.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                let originalKey = SymmetricKey(size: .bits256)
                let seedProvider = InMemoryDatabaseKeyProvider(key: originalKey)

                let textClipID = UUID()
                let encImageID = UUID()
                let srcPNG = imagesDir.appendingPathComponent("\(encImageID.uuidString).png")
                try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20).write(to: srcPNG)
                var encAssetURL: URL!

                do {
                    let seedStore = GRDBHistoryStore(directory: directory, keyProvider: seedProvider)
                    defer { seedStore.close() }

                    let secretTextItem = ClipboardItem.fixture(
                        id: textClipID,
                        kind: .text,
                        text: ["Authorization", ": Bearer ", "LOCK_STATE_", "SECRET_555566667777"].joined(),
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_100)
                    )
                    #expect(SensitiveContent.shouldEncryptAtRest(secretTextItem))
                    try seedStore.upsert(secretTextItem)
                    let savedImg = try seedStore.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: encImageID,
                            kind: .image,
                            assetPath: srcPNG.path,
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                            sensitivity: .sensitive
                        ),
                        convertingExternalAssets: true
                    )
                    encAssetURL = URL(fileURLWithPath: try #require(savedImg.assetPath))
                }

                // Backdate History.sqlite mtime so any accidental write/open mutation visibly changes st_mtimespec.
                let fixedMtime = Date(timeIntervalSince1970: 1_700_000_000)
                try fileManager.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: dbURL.path)
                let dbBytesBaseline = try Data(contentsOf: dbURL)
                let encBytesBaseline = try Data(contentsOf: encAssetURL)
                var statBaseline = stat()
                #expect(Darwin.lstat(dbURL.path, &statBaseline) == 0)

                // 1. errSecItemNotFound -> .locked(.notFound) on existing v5 DB (leaves DB bytes/mtime & .enc untouched).
                let keychainState = OSAllocatedUnfairLock<Data?>(initialState: nil)
                let addCallCount = OSAllocatedUnfairLock(initialState: 0)
                let mockClient = SecItemClient(
                    copyMatching: { _, result in
                        guard let stored = keychainState.withLock({ $0 }) else {
                            return errSecItemNotFound
                        }
                        result?.pointee = stored as CFData
                        return errSecSuccess
                    },
                    add: { _, _ in
                        addCallCount.withLock { $0 += 1 }
                        return errSecSuccess
                    }
                )
                let keychainProvider = SystemKeychainKeyProvider(client: mockClient, allowsTestClient: true)

                do {
                    let lockedStore = GRDBHistoryStore(directory: directory, keyProvider: keychainProvider)
                    defer { lockedStore.close() }

                    #expect(lockedStore.lockState == .locked(.notFound))
                    #expect(addCallCount.withLock { $0 } == 0)

                    var statAfterLockedInit = stat()
                    #expect(Darwin.lstat(dbURL.path, &statAfterLockedInit) == 0)
                    #expect(statAfterLockedInit.st_mtimespec.tv_sec == statBaseline.st_mtimespec.tv_sec)
                    #expect(statAfterLockedInit.st_mtimespec.tv_nsec == statBaseline.st_mtimespec.tv_nsec)
                    #expect(try Data(contentsOf: dbURL) == dbBytesBaseline)
                    #expect(!fileManager.fileExists(atPath: walURL.path))
                    #expect(!fileManager.fileExists(atPath: shmURL.path))
                    #expect(try Data(contentsOf: encAssetURL) == encBytesBaseline)

                    #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                        _ = try lockedStore.fetchAll()
                    }
                    #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                        _ = try lockedStore.fetchStoredFilePaths()
                    }
                    #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                        _ = try lockedStore.capture(
                            ClipboardItem.fixture(kind: .text, text: "Blocked while locked"),
                            updatesCopySequence: false
                        )
                    }

                    // Restore key into Keychain and recover via retryUnlock().
                    keychainState.withLock { $0 = MasterKeyHexCodec.encode(originalKey) }
                    try lockedStore.retryUnlock()
                    #expect(lockedStore.lockState == .unlocked)
                    #expect(Set(try lockedStore.fetchAll().map(\.id)) == [textClipID, encImageID])
                }

                // 2. Wrong master key -> .keyMismatch on existing v5 DB (leaves DB bytes/mtime & .enc untouched).
                try fileManager.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: dbURL.path)
                let dbBytesBeforeMismatch = try Data(contentsOf: dbURL)
                var statBeforeMismatch = stat()
                #expect(Darwin.lstat(dbURL.path, &statBeforeMismatch) == 0)

                let mutableKeyProvider = InMemoryDatabaseKeyProvider(key: SymmetricKey(size: .bits256))
                do {
                    let mismatchStore = GRDBHistoryStore(directory: directory, keyProvider: mutableKeyProvider)
                    defer { mismatchStore.close() }

                    #expect(mismatchStore.lockState == .keyMismatch)

                    var statAfterMismatch = stat()
                    #expect(Darwin.lstat(dbURL.path, &statAfterMismatch) == 0)
                    #expect(statAfterMismatch.st_mtimespec.tv_sec == statBeforeMismatch.st_mtimespec.tv_sec)
                    #expect(statAfterMismatch.st_mtimespec.tv_nsec == statBeforeMismatch.st_mtimespec.tv_nsec)
                    #expect(try Data(contentsOf: dbURL) == dbBytesBeforeMismatch)
                    #expect(!fileManager.fileExists(atPath: walURL.path))
                    #expect(!fileManager.fileExists(atPath: shmURL.path))
                    #expect(try Data(contentsOf: encAssetURL) == encBytesBaseline)

                    #expect(throws: HistoryStoreError.encryptionKeyMismatch) {
                        _ = try mismatchStore.fetchAll()
                    }
                    #expect(throws: HistoryStoreError.encryptionKeyMismatch) {
                        _ = try mismatchStore.fetchStoredFilePaths()
                    }

                    // Install matching key and recover via retryUnlock().
                    mutableKeyProvider.setKey(originalKey)
                    try mismatchStore.retryUnlock()
                    #expect(mismatchStore.lockState == .unlocked)
                    #expect(Set(try mismatchStore.fetchAll().map(\.id)) == [textClipID, encImageID])
                    #expect(try Data(contentsOf: encAssetURL) == encBytesBaseline)
                }
            }
        }

        @Test
        func startupMigrationCutoverAndPostCommitDualAssetCrashRecovery() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default

                func makeLegacyV4MainAndWALSnapshots(
                    mainID: UUID,
                    mainText: String,
                    walID: UUID,
                    walText: String
                ) throws -> (dbBytes: Data, walBytes: Data) {
                    let scratchDir = rootDir.appendingPathComponent("Scratch-\(UUID().uuidString)", isDirectory: true)
                    try fileManager.createDirectory(at: scratchDir, withIntermediateDirectories: true)
                    defer { try? fileManager.removeItem(at: scratchDir) }

                    let scratchDB = scratchDir.appendingPathComponent("History.sqlite")
                    let scratchWAL = scratchDir.appendingPathComponent("History.sqlite-wal")
                    var dbSnapshot = Data()
                    var walSnapshot = Data()

                    try Self.withDatabase(at: scratchDB) { db in
                        func exec(_ sql: String) throws {
                            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                                throw TestSQLiteFixtureError.stepFailed(String(cString: sqlite3_errmsg(db)))
                            }
                        }

                        func insertV4TextClip(id: UUID, text: String, copiedAt: Double) throws {
                            let payloadObj: [String: Any] = [
                                "id": id.uuidString,
                                "kind": ClipboardKind.text.rawValue,
                                "text": text,
                                "filePaths": [String](),
                                "sourceAppName": "LegacyApp",
                                "copiedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: copiedAt)),
                                "byteSize": text.utf8.count,
                                "isFavorite": false,
                                "tags": [Int](),
                                "searchText": text,
                                "copyCount": 1,
                            ]
                            let payloadData = try JSONSerialization.data(withJSONObject: payloadObj, options: [.sortedKeys])
                            try exec("""
                                INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, contentKey, payload, html, rtf, deletedAt, expiresAt)
                                VALUES ('\(id.uuidString)', 'text', \(copiedAt), 0, 'LegacyApp', '\(text)', '', \(Self.sqlHex(payloadData)), NULL, NULL, NULL, NULL);
                                """)
                        }

                        try exec("""
                            PRAGMA auto_vacuum = NONE;
                            PRAGMA secure_delete = OFF;
                            PRAGMA journal_mode = WAL;
                            PRAGMA synchronous = NORMAL;
                            PRAGMA wal_autocheckpoint = 0;
                            CREATE TABLE tags (
                                id INTEGER PRIMARY KEY AUTOINCREMENT,
                                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                                color TEXT NOT NULL
                            );
                            CREATE TABLE clips (
                                id TEXT PRIMARY KEY,
                                kind TEXT NOT NULL,
                                copiedAt REAL NOT NULL,
                                favorite INTEGER NOT NULL,
                                sourceApp TEXT,
                                searchText TEXT NOT NULL,
                                contentKey TEXT NOT NULL DEFAULT '',
                                payload BLOB NOT NULL,
                                html TEXT,
                                rtf BLOB,
                                deletedAt REAL,
                                expiresAt REAL
                            );
                            PRAGMA user_version = 4;
                            """)

                        try insertV4TextClip(id: mainID, text: mainText, copiedAt: 1_700_000_100)
                        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
                        try insertV4TextClip(id: walID, text: walText, copiedAt: 1_700_000_200)

                        dbSnapshot = try Data(contentsOf: scratchDB)
                        walSnapshot = try Data(contentsOf: scratchWAL)
                    }

                    #expect(dbSnapshot.range(of: Data(walText.utf8)) == nil)
                    #expect(walSnapshot.range(of: Data(walText.utf8)) != nil)
                    return (dbSnapshot, walSnapshot)
                }

                // Case A: Incomplete History.v5.migrating.sqlite (user_version = 0) + History.sqlite.scrubbing + History.sqlite-wal.scrubbing with History.sqlite absent.
                let dirA = rootDir.appendingPathComponent("CaseA", isDirectory: true)
                try fileManager.createDirectory(at: dirA, withIntermediateDirectories: true)
                let dbURLA = dirA.appendingPathComponent("History.sqlite")
                let migratingURLA = dirA.appendingPathComponent("History.v5.migrating.sqlite")
                let scrubbingDBA = dirA.appendingPathComponent("History.sqlite.scrubbing")
                let scrubbingWALA = dirA.appendingPathComponent("History.sqlite-wal.scrubbing")

                let mainIDA = UUID()
                let walIDA = UUID()
                let snapshotsA = try makeLegacyV4MainAndWALSnapshots(
                    mainID: mainIDA,
                    mainText: "RecoveredLegacyMainRowA",
                    walID: walIDA,
                    walText: "RecoveredLegacyWALRowA"
                )
                try snapshotsA.dbBytes.write(to: scrubbingDBA, options: .atomic)
                try snapshotsA.walBytes.write(to: scrubbingWALA, options: .atomic)
                try Self.executeSQL(
                    at: migratingURLA,
                    """
                    CREATE TABLE store_metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
                    PRAGMA user_version = 0;
                    """
                )
                #expect(!fileManager.fileExists(atPath: dbURLA.path))
                #expect(try Self.queryInt(at: migratingURLA, "PRAGMA user_version;") == 0)

                do {
                    let storeA = GRDBHistoryStore(directory: dirA, keyProvider: InMemoryDatabaseKeyProvider())
                    defer { storeA.close() }
                    #expect(storeA.lockState == .unlocked)
                    let itemsA = try storeA.fetchAll()
                    #expect(Set(itemsA.map(\.id)) == [mainIDA, walIDA])
                    let hydratedTextsA = Set(try itemsA.compactMap { try storeA.loadingContent(of: $0, scope: .body).text })
                    #expect(hydratedTextsA == ["RecoveredLegacyMainRowA", "RecoveredLegacyWALRowA"])
                    #expect(try Self.inspectDatabaseState(at: dbURLA).schemaVersion == 5)

                    for fileURL in try Self.allRegularFilesRecursively(in: dirA) {
                        let name = fileURL.lastPathComponent
                        #expect(!name.contains(".migrating"))
                        #expect(!name.hasSuffix(".scrubbing"))
                    }
                }

                // Case B: Completed v5 History.v5.migrating.sqlite (matching key_verifier_v1) + History.sqlite.scrubbing with secret canary and History.sqlite absent.
                let seedDirB = rootDir.appendingPathComponent("SeedB", isDirectory: true)
                let dirB = rootDir.appendingPathComponent("CaseB", isDirectory: true)
                try fileManager.createDirectory(at: seedDirB, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: dirB, withIntermediateDirectories: true)

                let masterKeyB = SymmetricKey(size: .bits256)
                let keyProviderB = InMemoryDatabaseKeyProvider(key: masterKeyB)
                let promotedClipID = UUID()
                do {
                    let seedStoreB = GRDBHistoryStore(directory: seedDirB, keyProvider: keyProviderB)
                    try seedStoreB.upsert(
                        ClipboardItem.fixture(
                            id: promotedClipID,
                            kind: .text,
                            text: "PromotedCompletedV5Clip",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_300)
                        )
                    )
                    seedStoreB.close()
                }

                let seedDBURLB = seedDirB.appendingPathComponent("History.sqlite")
                try Self.executeSQL(at: seedDBURLB, "PRAGMA journal_mode = DELETE;")

                let dbURLB = dirB.appendingPathComponent("History.sqlite")
                let migratingURLB = dirB.appendingPathComponent("History.v5.migrating.sqlite")
                let scrubbingDBB = dirB.appendingPathComponent("History.sqlite.scrubbing")
                try fileManager.copyItem(
                    at: seedDBURLB,
                    to: migratingURLB
                )
                #expect(!fileManager.fileExists(atPath: dbURLB.path))
                #expect(try Self.queryInt(at: migratingURLB, "PRAGMA user_version;") == 5)

                let secretCanaryB = ["sk", "-proj-", "CANARY_CUTOVER_B_", "8473625190abcdef"].joined()
                let scrubbingPayloadB = Data(repeating: 0x42, count: 128) + Data(secretCanaryB.utf8) + Data(repeating: 0x24, count: 128)
                try scrubbingPayloadB.write(to: scrubbingDBB, options: .atomic)
                let scrubbingFDB = Darwin.open(scrubbingDBB.path, O_RDONLY)
                #expect(scrubbingFDB >= 0)
                defer {
                    if scrubbingFDB >= 0 { Darwin.close(scrubbingFDB) }
                }

                do {
                    let storeB = GRDBHistoryStore(directory: dirB, keyProvider: keyProviderB)
                    defer { storeB.close() }
                    #expect(storeB.lockState == .unlocked)
                    #expect(fileManager.fileExists(atPath: dbURLB.path))
                    #expect(!fileManager.fileExists(atPath: migratingURLB.path))
                    #expect(!fileManager.fileExists(atPath: scrubbingDBB.path))

                    let itemsB = try storeB.fetchAll()
                    #expect(itemsB.map(\.id) == [promotedClipID])
                    #expect(try storeB.loadingContent(of: try #require(itemsB.first), scope: .body).text == "PromotedCompletedV5Clip")

                    var zeroedBytesB = [UInt8](repeating: 0xFF, count: scrubbingPayloadB.count)
                    let readScrubbedB = Darwin.pread(scrubbingFDB, &zeroedBytesB, zeroedBytesB.count, 0)
                    #expect(readScrubbedB == zeroedBytesB.count)
                    #expect(zeroedBytesB.allSatisfy { $0 == 0 })

                    for fileURL in try Self.allRegularFilesRecursively(in: dirB) {
                        let name = fileURL.lastPathComponent
                        #expect(!name.contains(".migrating"))
                        #expect(!name.hasSuffix(".scrubbing"))
                        let rawBytes = try Data(contentsOf: fileURL)
                        for (encodingLabel, needle) in Self.canaryBytePatterns(for: secretCanaryB) {
                            #expect(
                                rawBytes.range(of: needle) == nil,
                                "Found canary (\(encodingLabel)) in \(fileURL.path)"
                            )
                        }
                    }
                }

                // Case C: Hardlinked History.sqlite == History.sqlite.scrubbing (same inode) + History.sqlite-wal.scrubbing.
                let dirC = rootDir.appendingPathComponent("CaseC", isDirectory: true)
                try fileManager.createDirectory(at: dirC, withIntermediateDirectories: true)
                let dbURLC = dirC.appendingPathComponent("History.sqlite")
                let walURLC = dirC.appendingPathComponent("History.sqlite-wal")
                let scrubbingDBC = dirC.appendingPathComponent("History.sqlite.scrubbing")
                let scrubbingWALC = dirC.appendingPathComponent("History.sqlite-wal.scrubbing")

                let mainIDC = UUID()
                let walIDC = UUID()
                let snapshotsC = try makeLegacyV4MainAndWALSnapshots(
                    mainID: mainIDC,
                    mainText: "HardlinkedMainRowC",
                    walID: walIDC,
                    walText: "HardlinkedWALRowC"
                )
                try snapshotsC.dbBytes.write(to: dbURLC, options: .atomic)
                #expect(Darwin.link(dbURLC.path, scrubbingDBC.path) == 0)
                try snapshotsC.walBytes.write(to: scrubbingWALC, options: .atomic)

                var dbStatC = stat()
                var scrubStatC = stat()
                #expect(Darwin.lstat(dbURLC.path, &dbStatC) == 0)
                #expect(Darwin.lstat(scrubbingDBC.path, &scrubStatC) == 0)
                #expect(dbStatC.st_ino == scrubStatC.st_ino)
                #expect(!fileManager.fileExists(atPath: walURLC.path))

                do {
                    let storeC = GRDBHistoryStore(directory: dirC, keyProvider: InMemoryDatabaseKeyProvider())
                    defer { storeC.close() }
                    #expect(storeC.lockState == .unlocked)
                    let itemsC = try storeC.fetchAll()
                    #expect(Set(itemsC.map(\.id)) == [mainIDC, walIDC])
                    let hydratedTextsC = Set(try itemsC.compactMap { try storeC.loadingContent(of: $0, scope: .body).text })
                    #expect(hydratedTextsC == ["HardlinkedMainRowC", "HardlinkedWALRowC"])
                    #expect(try Self.inspectDatabaseState(at: dbURLC).schemaVersion == 5)
                    #expect(!fileManager.fileExists(atPath: scrubbingDBC.path))
                    #expect(!fileManager.fileExists(atPath: scrubbingWALC.path))
                }

                // Case D: Coexisting .png + .enc in Images/ and LinkPreviews/ for encrypted (isEncrypted == 1) and plain (isEncrypted == 0) clips.
                let dirD = rootDir.appendingPathComponent("CaseD", isDirectory: true)
                try fileManager.createDirectory(at: dirD, withIntermediateDirectories: true)
                let dbURLD = dirD.appendingPathComponent("History.sqlite")
                let imagesDirD = dirD.appendingPathComponent("Images", isDirectory: true)
                let linkPreviewsDirD = dirD.appendingPathComponent("LinkPreviews", isDirectory: true)

                let masterKeyD = SymmetricKey(size: .bits256)
                let keyProviderD = InMemoryDatabaseKeyProvider(key: masterKeyD)
                let encImgID = UUID()
                let encLinkID = UUID()
                let plainImgID = UUID()
                let plainLinkID = UUID()

                let encImgPNG = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemRed)
                let encPreviewPNG = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 20, color: .systemPink)
                let plainImgPNG = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20, color: .systemGreen)
                let plainPreviewPNG = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 18, color: .systemBlue)

                do {
                    let seedStoreD = GRDBHistoryStore(directory: dirD, keyProvider: keyProviderD)
                    let encImgURL = try seedStoreD.writeManagedAsset(pngData: encImgPNG, role: .image, clipID: encImgID, encrypted: true)
                    let encPreviewURL = try seedStoreD.writeManagedAsset(pngData: encPreviewPNG, role: .linkPreview, clipID: encLinkID, encrypted: true)
                    let plainImgURL = try seedStoreD.writeManagedAsset(pngData: plainImgPNG, role: .image, clipID: plainImgID, encrypted: false)
                    let plainPreviewURL = try seedStoreD.writeManagedAsset(pngData: plainPreviewPNG, role: .linkPreview, clipID: plainLinkID, encrypted: false)

                    _ = try seedStoreD.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: encImgID,
                            kind: .image,
                            assetPath: encImgURL.path,
                            imageDigest: "enc-img-d",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_400),
                            sensitivity: .sensitive
                        ),
                        convertingExternalAssets: true
                    )
                    _ = try seedStoreD.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: encLinkID,
                            kind: .link,
                            text: "https://internal.example.com/secret",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_410),
                            linkPreviewDetails: LinkPreviewDetails(
                                url: "https://internal.example.com/secret",
                                title: "Internal Card",
                                description: nil,
                                imagePath: encPreviewURL.path,
                                faviconPath: nil,
                                fetchedAt: Date(timeIntervalSince1970: 1_700_000_410)
                            ),
                            sensitivity: .sensitive
                        ),
                        convertingExternalAssets: true
                    )
                    _ = try seedStoreD.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: plainImgID,
                            kind: .image,
                            assetPath: plainImgURL.path,
                            imageDigest: "plain-img-d",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_420),
                            sensitivity: nil
                        ),
                        convertingExternalAssets: true
                    )
                    _ = try seedStoreD.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: plainLinkID,
                            kind: .link,
                            text: "https://public.example.com/post",
                            copiedAt: Date(timeIntervalSince1970: 1_700_000_430),
                            linkPreviewDetails: LinkPreviewDetails(
                                url: "https://public.example.com/post",
                                title: "Public Post",
                                description: nil,
                                imagePath: plainPreviewURL.path,
                                faviconPath: nil,
                                fetchedAt: Date(timeIntervalSince1970: 1_700_000_430)
                            ),
                            sensitivity: nil
                        ),
                        convertingExternalAssets: true
                    )

                    _ = try seedStoreD.writeManagedAsset(pngData: plainImgPNG, role: .image, clipID: plainImgID, encrypted: true)
                    _ = try seedStoreD.writeManagedAsset(pngData: plainPreviewPNG, role: .linkPreview, clipID: plainLinkID, encrypted: true)
                    seedStoreD.close()
                }

                #expect(try Self.queryInt(at: dbURLD, "SELECT isEncrypted FROM clips WHERE id = '\(encImgID.uuidString)';") == 1)
                #expect(try Self.queryInt(at: dbURLD, "SELECT isEncrypted FROM clips WHERE id = '\(encLinkID.uuidString)';") == 1)
                #expect(try Self.queryInt(at: dbURLD, "SELECT isEncrypted FROM clips WHERE id = '\(plainImgID.uuidString)';") == 0)
                #expect(try Self.queryInt(at: dbURLD, "SELECT isEncrypted FROM clips WHERE id = '\(plainLinkID.uuidString)';") == 0)

                let keptEncImgURL = imagesDirD.appendingPathComponent("\(encImgID.uuidString).enc")
                let orphanPlainForEncImgURL = imagesDirD.appendingPathComponent("\(encImgID.uuidString).png")
                let keptEncPreviewURL = linkPreviewsDirD.appendingPathComponent("\(encLinkID.uuidString)-preview.enc")
                let orphanPlainForEncPreviewURL = linkPreviewsDirD.appendingPathComponent("\(encLinkID.uuidString)-preview.png")

                let keptPlainImgURL = imagesDirD.appendingPathComponent("\(plainImgID.uuidString).png")
                let orphanEncForPlainImgURL = imagesDirD.appendingPathComponent("\(plainImgID.uuidString).enc")
                let keptPlainPreviewURL = linkPreviewsDirD.appendingPathComponent("\(plainLinkID.uuidString)-preview.png")
                let orphanEncForPlainPreviewURL = linkPreviewsDirD.appendingPathComponent("\(plainLinkID.uuidString)-preview.enc")

                try encImgPNG.write(to: orphanPlainForEncImgURL, options: .atomic)
                try encPreviewPNG.write(to: orphanPlainForEncPreviewURL, options: .atomic)

                for url in [
                    keptEncImgURL, orphanPlainForEncImgURL,
                    keptEncPreviewURL, orphanPlainForEncPreviewURL,
                    keptPlainImgURL, orphanEncForPlainImgURL,
                    keptPlainPreviewURL, orphanEncForPlainPreviewURL,
                ] {
                    #expect(fileManager.fileExists(atPath: url.path))
                }

                let orphanFDs = [
                    orphanPlainForEncImgURL,
                    orphanPlainForEncPreviewURL,
                    orphanEncForPlainImgURL,
                    orphanEncForPlainPreviewURL,
                ].map { Darwin.open($0.path, O_RDONLY) }
                #expect(orphanFDs.allSatisfy { $0 >= 0 })
                defer {
                    for fd in orphanFDs where fd >= 0 { Darwin.close(fd) }
                }

                do {
                    let reopenedStoreD = GRDBHistoryStore(directory: dirD, keyProvider: keyProviderD)
                    defer { reopenedStoreD.close() }
                    #expect(reopenedStoreD.lockState == .unlocked)
                    _ = try reopenedStoreD.fetchAll()

                    #expect(fileManager.fileExists(atPath: keptEncImgURL.path))
                    #expect(fileManager.fileExists(atPath: keptEncPreviewURL.path))
                    #expect(fileManager.fileExists(atPath: keptPlainImgURL.path))
                    #expect(fileManager.fileExists(atPath: keptPlainPreviewURL.path))
                    #expect(try Data(contentsOf: keptPlainImgURL) == plainImgPNG)
                    #expect(try Data(contentsOf: keptPlainPreviewURL) == plainPreviewPNG)
                    #expect(
                        try ImageAssetStore.readAssetData(
                            at: keptEncImgURL,
                            role: .image,
                            ownerClipID: encImgID,
                            requiresEncryption: true
                        ) == encImgPNG
                    )
                    #expect(
                        try ImageAssetStore.readAssetData(
                            at: keptEncPreviewURL,
                            role: .linkPreview,
                            ownerClipID: encLinkID,
                            requiresEncryption: true
                        ) == encPreviewPNG
                    )

                    #expect(!fileManager.fileExists(atPath: orphanPlainForEncImgURL.path))
                    #expect(!fileManager.fileExists(atPath: orphanPlainForEncPreviewURL.path))
                    #expect(!fileManager.fileExists(atPath: orphanEncForPlainImgURL.path))
                    #expect(!fileManager.fileExists(atPath: orphanEncForPlainPreviewURL.path))

                    for fd in orphanFDs {
                        var header = [UInt8](repeating: 0xFF, count: 16)
                        let readCount = Darwin.pread(fd, &header, header.count, 0)
                        #expect(readCount == header.count)
                        #expect(header.allSatisfy { $0 == 0 })
                    }
                }
            }
        }

        @Test
        func saveAndReconcileItemScrubsClearedOrReplacedManagedAssetsOnCommitAndPreservesThemOnRollback() throws {
            struct IntentionalAssetRollbackError: Error {}

            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let supportDir = rootDir.appendingPathComponent("Support", isDirectory: true)
                let externalDir = rootDir.appendingPathComponent("External", isDirectory: true)
                try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: externalDir, withIntermediateDirectories: true)

                let store = GRDBHistoryStore(directory: supportDir, keyProvider: InMemoryDatabaseKeyProvider())
                defer { store.close() }

                let imgID = UUID()
                let linkID = UUID()
                let jpegHeaderBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])
                let icoBytes = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

                let initialImgURL = try store.writeManagedAsset(
                    pngData: jpegHeaderBytes,
                    role: .image,
                    clipID: imgID,
                    encrypted: false,
                    preferredPlainExtension: "jpg"
                )
                let initialPreviewURL = try store.writeManagedAsset(
                    pngData: jpegHeaderBytes,
                    role: .linkPreview,
                    clipID: linkID,
                    encrypted: false,
                    preferredPlainExtension: "jpg"
                )
                let initialFaviconURL = try store.writeManagedAsset(
                    pngData: icoBytes,
                    role: .linkFavicon,
                    clipID: linkID,
                    encrypted: false,
                    preferredPlainExtension: "ico"
                )
                #expect(initialImgURL.pathExtension == "jpg")
                #expect(initialPreviewURL.pathExtension == "jpg")
                #expect(initialFaviconURL.pathExtension == "ico")

                let fetchedAt = Date(timeIntervalSince1970: 1_700_000_500)
                var savedImg = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: imgID,
                        kind: .image,
                        assetPath: initialImgURL.path,
                        imageDigest: "img-jpg-digest",
                        copiedAt: fetchedAt
                    ),
                    convertingExternalAssets: true
                )
                var savedLink = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: linkID,
                        kind: .link,
                        text: "https://example.com/resource",
                        copiedAt: fetchedAt.addingTimeInterval(10),
                        linkPreviewDetails: LinkPreviewDetails(
                            url: "https://example.com/resource",
                            title: "Initial Resource",
                            description: "Initial preview",
                            imagePath: initialPreviewURL.path,
                            faviconPath: initialFaviconURL.path,
                            fetchedAt: fetchedAt
                        )
                    ),
                    convertingExternalAssets: true
                )

                let extImgPNGBytes = try TestSupport.makePNGData(pixelWidth: 26, pixelHeight: 20, color: .systemBlue)
                let extPreviewPNGBytes = try TestSupport.makePNGData(pixelWidth: 36, pixelHeight: 22, color: .systemCyan)
                let extFaviconPNGBytes = try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16, color: .systemMint)
                let extImgURL = externalDir.appendingPathComponent("next-image.png")
                let extPreviewURL = externalDir.appendingPathComponent("next-preview.png")
                let extFaviconURL = externalDir.appendingPathComponent("next-favicon.png")
                try extImgPNGBytes.write(to: extImgURL)
                try extPreviewPNGBytes.write(to: extPreviewURL)
                try extFaviconPNGBytes.write(to: extFaviconURL)

                let managedImgPNGURL = supportDir.appendingPathComponent("Images/\(imgID.uuidString).png")
                let managedPreviewPNGURL = supportDir.appendingPathComponent("LinkPreviews/\(linkID.uuidString)-preview.png")
                let managedFaviconPNGURL = supportDir.appendingPathComponent("LinkPreviews/\(linkID.uuidString)-favicon.png")

                #expect(throws: IntentionalAssetRollbackError.self) {
                    try store.performInTransaction {
                        var nextImg = savedImg
                        nextImg.assetPath = extImgURL.path
                        _ = try store.saveAndReconcileItem(nextImg, convertingExternalAssets: true)

                        var nextLink = savedLink
                        nextLink.linkPreviewDetails = LinkPreviewDetails(
                            url: "https://example.com/resource",
                            title: "Updated Resource",
                            description: "Updated preview",
                            imagePath: extPreviewURL.path,
                            faviconPath: extFaviconURL.path,
                            fetchedAt: fetchedAt
                        )
                        _ = try store.saveAndReconcileItem(nextLink, convertingExternalAssets: true)

                        #expect(fileManager.fileExists(atPath: managedImgPNGURL.path))
                        #expect(fileManager.fileExists(atPath: initialImgURL.path))
                        throw IntentionalAssetRollbackError()
                    }
                }
                #expect(!fileManager.fileExists(atPath: managedImgPNGURL.path))
                #expect(!fileManager.fileExists(atPath: managedPreviewPNGURL.path))
                #expect(!fileManager.fileExists(atPath: managedFaviconPNGURL.path))
                #expect(try Data(contentsOf: initialImgURL) == jpegHeaderBytes)
                #expect(try Data(contentsOf: initialPreviewURL) == jpegHeaderBytes)
                #expect(try Data(contentsOf: initialFaviconURL) == icoBytes)
                #expect(try Self.fetchItem(imgID, from: store).assetPath == initialImgURL.path)
                #expect(try Self.fetchItem(linkID, from: store).linkPreviewDetails?.imagePath == initialPreviewURL.path)
                #expect(try Self.fetchItem(linkID, from: store).linkPreviewDetails?.faviconPath == initialFaviconURL.path)

                #expect(throws: IntentionalAssetRollbackError.self) {
                    try store.performInTransaction {
                        var clearingImg = savedImg
                        clearingImg.assetPath = nil
                        _ = try store.saveAndReconcileItem(clearingImg, convertingExternalAssets: true)

                        var clearingLink = savedLink
                        clearingLink.linkPreviewDetails = nil
                        _ = try store.saveAndReconcileItem(clearingLink, convertingExternalAssets: true)

                        throw IntentionalAssetRollbackError()
                    }
                }
                #expect(try Data(contentsOf: initialImgURL) == jpegHeaderBytes)
                #expect(try Data(contentsOf: initialPreviewURL) == jpegHeaderBytes)
                #expect(try Data(contentsOf: initialFaviconURL) == icoBytes)
                #expect(try Self.fetchItem(imgID, from: store).assetPath == initialImgURL.path)
                #expect(try Self.fetchItem(linkID, from: store).linkPreviewDetails?.imagePath == initialPreviewURL.path)
                #expect(try Self.fetchItem(linkID, from: store).linkPreviewDetails?.faviconPath == initialFaviconURL.path)

                let initialFDs = [initialImgURL, initialPreviewURL, initialFaviconURL].map { Darwin.open($0.path, O_RDONLY) }
                #expect(initialFDs.allSatisfy { $0 >= 0 })
                defer {
                    for fd in initialFDs where fd >= 0 { Darwin.close(fd) }
                }

                savedImg.assetPath = extImgURL.path
                savedImg = try store.saveAndReconcileItem(savedImg, convertingExternalAssets: true)

                savedLink.linkPreviewDetails = LinkPreviewDetails(
                    url: "https://example.com/resource",
                    title: "Updated Resource",
                    description: "Updated preview",
                    imagePath: extPreviewURL.path,
                    faviconPath: extFaviconURL.path,
                    fetchedAt: fetchedAt
                )
                savedLink = try store.saveAndReconcileItem(savedLink, convertingExternalAssets: true)

                #expect(!fileManager.fileExists(atPath: initialImgURL.path))
                #expect(!fileManager.fileExists(atPath: initialPreviewURL.path))
                #expect(!fileManager.fileExists(atPath: initialFaviconURL.path))
                #expect(try Data(contentsOf: managedImgPNGURL) == extImgPNGBytes)
                #expect(try Data(contentsOf: managedPreviewPNGURL) == extPreviewPNGBytes)
                #expect(try Data(contentsOf: managedFaviconPNGURL) == extFaviconPNGBytes)

                for fd in initialFDs {
                    var scrubbed = [UInt8](repeating: 0xFF, count: 16)
                    let readCount = Darwin.pread(fd, &scrubbed, scrubbed.count, 0)
                    #expect(readCount == scrubbed.count)
                    #expect(scrubbed.allSatisfy { $0 == 0 })
                }

                let activePNGFDs = [managedImgPNGURL, managedPreviewPNGURL, managedFaviconPNGURL].map {
                    Darwin.open($0.path, O_RDONLY)
                }
                #expect(activePNGFDs.allSatisfy { $0 >= 0 })
                defer {
                    for fd in activePNGFDs where fd >= 0 { Darwin.close(fd) }
                }

                var clearedImg = try store.loadingContent(of: savedImg, scope: .body)
                clearedImg.assetPath = nil
                _ = try store.saveAndReconcileItem(clearedImg, convertingExternalAssets: true)

                var clearedLink = try store.loadingContent(of: savedLink, scope: .body)
                clearedLink.linkPreviewDetails = nil
                _ = try store.saveAndReconcileItem(clearedLink, convertingExternalAssets: true)

                #expect(!fileManager.fileExists(atPath: managedImgPNGURL.path))
                #expect(!fileManager.fileExists(atPath: managedPreviewPNGURL.path))
                #expect(!fileManager.fileExists(atPath: managedFaviconPNGURL.path))
                #expect(try Self.fetchItem(imgID, from: store).assetPath == nil)
                #expect(try Self.fetchItem(linkID, from: store).linkPreviewDetails == nil)

                for fd in activePNGFDs {
                    var scrubbed = [UInt8](repeating: 0xFF, count: 16)
                    let readCount = Darwin.pread(fd, &scrubbed, scrubbed.count, 0)
                    #expect(readCount == scrubbed.count)
                    #expect(scrubbed.allSatisfy { $0 == 0 })
                }
            }
        }

        @Test
        @MainActor
        func fetchItemsWhereHydratesLongPlainAndEncryptedBodyAndQRCodeTextWhileCoordinatorSweepsHeaders() throws {
            try TestSupport.withTemporaryHistoryStore { store, _ in
                let plainTag = try store.createTag(name: "PlainHydratedTag", color: "#1E88E5")
                let encryptedTag = try store.createTag(name: "EncryptedHydratedTag", color: "#E53935")

                let plainTailMarker = [" FetchPlainBodyMarker", "9911"].joined()
                let encryptedTailMarker = [" FetchEncryptedBodyMarker", "8822"].joined()
                let plainQRTailMarker = [" FetchPlainQRMarker", "7733"].joined()
                let encryptedQRTailMarker = [" FetchEncryptedQRMarker", "6644"].joined()

                let plainLongText = String(repeating: "p", count: 12_500) + plainTailMarker
                let encryptedLongText = String(repeating: "e", count: 12_500) + encryptedTailMarker
                let plainLongOCR = String(repeating: "o", count: 10_200) + "_OCR_PLAIN"
                let encryptedLongOCR = String(repeating: "s", count: 10_200) + "_OCR_ENC"
                let plainLongQR = String(repeating: "q", count: 9_200) + plainQRTailMarker
                let encryptedLongQR = String(repeating: "r", count: 9_200) + encryptedQRTailMarker

                let plainTextItem = ClipboardItem.fixture(
                    kind: .text,
                    text: plainLongText,
                    sourceAppName: "Notes",
                    sourceBundleIdentifier: "com.apple.Notes",
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_010),
                    isFavorite: true,
                    tags: [plainTag.id]
                )
                let encryptedTextItem = ClipboardItem.fixture(
                    kind: .text,
                    text: encryptedLongText,
                    sourceAppName: "Terminal",
                    sourceBundleIdentifier: "com.apple.Terminal",
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_020),
                    isFavorite: true,
                    tags: [encryptedTag.id],
                    sensitivity: .sensitive
                )

                let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemBlue)
                let plainImgID = UUID()
                let plainImgURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: plainImgID, encrypted: false)
                let plainImgItem = ClipboardItem.fixture(
                    id: plainImgID,
                    kind: .image,
                    text: plainLongOCR,
                    qrCodeText: plainLongQR,
                    assetPath: plainImgURL.path,
                    imageDigest: store.computeImageDigest(forPNGData: pngData),
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_030),
                    isFavorite: true
                )

                let encImgID = UUID()
                let encImgURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: encImgID, encrypted: true)
                let encImgItem = ClipboardItem.fixture(
                    id: encImgID,
                    kind: .image,
                    text: encryptedLongOCR,
                    qrCodeText: encryptedLongQR,
                    assetPath: encImgURL.path,
                    imageDigest: store.computeImageDigest(forPNGData: pngData),
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_040),
                    isFavorite: true,
                    sensitivity: .sensitive
                )

                let nonMatchingItem = ClipboardItem.fixture(
                    kind: .text,
                    text: String(repeating: "x", count: 10_000),
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_050),
                    isFavorite: true
                )
                let trashedMatchingItem = ClipboardItem.fixture(
                    kind: .text,
                    text: String(repeating: "t", count: 12_000) + plainTailMarker,
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_060)
                )

                for item in [plainTextItem, encryptedTextItem, plainImgItem, encImgItem, nonMatchingItem, trashedMatchingItem] {
                    _ = try store.saveAndReconcileItem(item, convertingExternalAssets: true)
                }
                try store.moveToTrash(ids: [trashedMatchingItem.id], at: Date(timeIntervalSince1970: 1_700_001_070))

                // Compact headers from fetchAll() leave >8 KB bodies and qrCodeText unloaded.
                let allHeaders = try store.fetchAll()
                #expect(allHeaders.count == 5)
                for header in allHeaders {
                    #expect(!header.isContentLoaded)
                    #expect(header.qrCodeText == nil)
                }

                // fetchItems(where:) hydrates full >8,096-char text and qrCodeText before evaluating isIncluded across plain & encrypted rows.
                let matched = try store.fetchItems { item in
                    item.text?.contains(plainTailMarker) == true
                        || item.text?.contains(encryptedTailMarker) == true
                        || item.qrCodeText?.contains(plainQRTailMarker) == true
                        || item.qrCodeText?.contains(encryptedQRTailMarker) == true
                }
                #expect(matched.map(\.id) == [encImgItem.id, plainImgItem.id, encryptedTextItem.id, plainTextItem.id])
                for item in matched {
                    #expect(item.isContentLoaded)
                }

                let byID = Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })
                #expect(byID[plainTextItem.id]?.text == plainLongText)
                #expect(byID[plainTextItem.id]?.searchText.contains("PlainHydratedTag") == true)
                #expect(byID[plainTextItem.id]?.searchText.contains(plainTailMarker) == true)

                #expect(byID[encryptedTextItem.id]?.text == encryptedLongText)
                #expect(byID[encryptedTextItem.id]?.searchText.contains("EncryptedHydratedTag") == true)
                #expect(byID[encryptedTextItem.id]?.searchText.contains(encryptedTailMarker) == true)

                #expect(byID[plainImgItem.id]?.text == plainLongOCR)
                #expect(byID[plainImgItem.id]?.qrCodeText == plainLongQR)
                #expect(byID[plainImgItem.id]?.searchText.contains(plainQRTailMarker) == true)

                #expect(byID[encImgItem.id]?.text == encryptedLongOCR)
                #expect(byID[encImgItem.id]?.qrCodeText == encryptedLongQR)
                #expect(byID[encImgItem.id]?.searchText.contains(encryptedQRTailMarker) == true)

                // Verify AppCoordinator settings sweeps scan compact headers via fetchAll() without invoking fetchItems(where:) or loadingContent.
                let (harness, spyStore, _) = try TestSupport.makeSpiedTestCoordinator()
                defer { harness.cleanup() }
                try harness.seedHistory([plainTextItem, encryptedTextItem])
                harness.model.preferences.keepFavoritesOnClearHistory = true
                spyStore.resetRecordedCalls()

                harness.coordinator.addIgnoredApplications(atPaths: ["/Applications/NonexistentIgnoredAppForHeaderSweep.app"])
                harness.coordinator.setSensitiveContentLifetime(ContentLifetime.dontSave)

                #expect(spyStore.fetchItemsWhereCalls == 0)
                #expect(spyStore.loadingContentCalls.isEmpty)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func recapturingContentMatchingCorruptEncryptedRowSkipsPlaceholderAndPreservesExistingEncAsset() async throws {
            try await TestSupport.withTemporaryDirectory { supportDir in
                let keyProvider = InMemoryDatabaseKeyProvider()
                let pngBytes = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20, color: .systemPurple)
                let corruptTextID = UUID()
                let corruptImageID = UUID()
                let sharedSecretText = ["CorruptRecapturePayload_", "Alpha9911"].joined()
                let corruptImageURL: URL
                let originalEncBytes: Data

                do {
                    let seedStore = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                    defer { seedStore.close() }

                    let seededText = ClipboardItem.fixture(
                        id: corruptTextID,
                        kind: .text,
                        title: "Encrypted Title",
                        text: sharedSecretText,
                        copiedAt: Date(timeIntervalSince1970: 1_700_010_010),
                        sensitivity: .sensitive
                    )
                    _ = try seedStore.saveAndReconcileItem(seededText)

                    corruptImageURL = try seedStore.writeManagedAsset(
                        pngData: pngBytes,
                        role: .image,
                        clipID: corruptImageID,
                        encrypted: true
                    )
                    originalEncBytes = try Data(contentsOf: corruptImageURL)
                    let seededImage = ClipboardItem.fixture(
                        id: corruptImageID,
                        kind: .image,
                        title: "Encrypted Screenshot Title",
                        text: "OCR text",
                        assetPath: corruptImageURL.path,
                        imageDigest: seedStore.computeImageDigest(forPNGData: pngBytes),
                        copiedAt: Date(timeIntervalSince1970: 1_700_010_020),
                        sensitivity: .sensitive
                    )
                    _ = try seedStore.saveAndReconcileItem(seededImage)
                    seedStore.flushPendingFreePageRelease()
                }

                // Corrupt only the sealed `clips.title` column on both rows so `contentKey` still matches!
                let dbURL = supportDir.appendingPathComponent("History.sqlite")
                var rawDB: OpaquePointer?
                #expect(sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
                defer { if let rawDB { sqlite3_close(rawDB) } }
                for targetID in [corruptTextID, corruptImageID] {
                    let corruptSQL = "UPDATE clips SET title = X'01FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' WHERE id = '\(targetID.uuidString)';"
                    #expect(sqlite3_exec(rawDB, corruptSQL, nil, nil, nil) == SQLITE_OK)
                }
                sqlite3_close(rawDB)
                rawDB = nil

                let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                defer { store.close() }

                // 1. Re-capturing identical text skips the corrupt placeholder and inserts a new healthy row.
                let recapturedText = try store.capture(
                    ClipboardItem.fixture(
                        kind: .text,
                        text: sharedSecretText,
                        copiedAt: Date(timeIntervalSince1970: 1_700_010_030),
                        sensitivity: .sensitive
                    ),
                    updatesCopySequence: false
                )
                #expect(recapturedText.id != corruptTextID)
                #expect(!recapturedText.isCorruptPlaceholder)
                #expect(try store.loadingContent(of: recapturedText, scope: .body).text == sharedSecretText)

                // 2. Re-capturing identical PNG via PasteboardMonitor leaves `Images/<corruptImageID>.enc` intact and captures a new healthy image row.
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let monitor = PasteboardMonitor(
                    historyStore: store,
                    fileManager: .default,
                    pasteboard: pasteboard,
                    recognizeImageData: { _ in .empty }
                )
                defer { monitor.stop() }
                var prefs = AppPreferences()
                prefs.confidentialContentLifetime = ContentLifetime.keep
                monitor.start(preferences: prefs)

                pasteboard.clearContents()
                #expect(pasteboard.setData(pngBytes, forType: .png))
                pasteboard.setData(Data(), forType: PasteboardReader.concealedType)
                #expect(await TestSupport.waitUntil {
                    (try? store.fetchAll().contains { $0.kind == .image && $0.id != corruptImageID }) == true
                })

                let allHeaders = try store.fetchAll()
                let corruptPlaceholder = try #require(allHeaders.first { $0.id == corruptImageID })
                #expect(corruptPlaceholder.isCorruptPlaceholder)
                let healthyImageHeader = try #require(allHeaders.first { $0.kind == .image && $0.id != corruptImageID })
                #expect(!healthyImageHeader.isCorruptPlaceholder)
                #expect(healthyImageHeader.assetPath != corruptImageURL.path)
                #expect(FileManager.default.fileExists(atPath: corruptImageURL.path))
                #expect(try Data(contentsOf: corruptImageURL) == originalEncBytes)
            }
        }

        @Test
        func customHistoryStoreCacheHooksFireOnlyAfterCommitAndPairAcrossOpenAndClose() throws {
            nonisolated struct HookLog: Sendable {
                var registeredOwners: [UUID] = []
                var unregisteredOwners: [UUID] = []
                var removedSVGIDs: [UUID] = []
                var purgedOwnerSVGs: [UUID] = []
                var removedThumbnailPaths: [String] = []
                var removedThumbnailDirs: [URL] = []
                var removedDragDirs: [URL] = []
                var sensitiveCacheClears: Int = 0
            }

            try TestSupport.withTemporaryDirectory { supportDir in
                let logLock = OSAllocatedUnfairLock<HookLog>(initialState: HookLog())
                let hooks = HistoryStoreCacheHooks(
                    registerSVGTextLoader: { _, _, ownerID in
                        logLock.withLock { $0.registeredOwners.append(ownerID) }
                    },
                    unregisterSVGTextLoader: { ownerID in
                        logLock.withLock { $0.unregisteredOwners.append(ownerID) }
                    },
                    removeSVGRendering: { clipID in
                        logLock.withLock { $0.removedSVGIDs.append(clipID) }
                    },
                    removeOwnerSVGRenderings: { ownerID in
                        logLock.withLock { $0.purgedOwnerSVGs.append(ownerID) }
                    },
                    removeThumbnailsForPath: { path in
                        logLock.withLock { $0.removedThumbnailPaths.append(path) }
                    },
                    removeThumbnailsInDirectory: { dir in
                        logLock.withLock { $0.removedThumbnailDirs.append(dir) }
                    },
                    removeDragCopiesInDirectory: { dir in
                        logLock.withLock { $0.removedDragDirs.append(dir) }
                    },
                    removeAllSensitiveContentCaches: {
                        logLock.withLock { $0.sensitiveCacheClears += 1 }
                    }
                )

                let store = GRDBHistoryStore(
                    directory: supportDir,
                    keyProvider: InMemoryDatabaseKeyProvider(),
                    cacheHooks: hooks
                )

                let afterOpen = logLock.withLock { $0 }
                #expect(afterOpen.registeredOwners.count == 1)
                let ownerID = try #require(afterOpen.registeredOwners.first)

                let svgMarkup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\"/></svg>"
                let svgItem = try store.saveAndReconcileItem(ClipboardItem.fixture(kind: .text, text: svgMarkup))
                let pngBytes = try TestSupport.makePNGData(pixelWidth: 12, pixelHeight: 12, color: .systemTeal)
                let imgID = UUID()
                let imgURL = try store.writeManagedAsset(pngData: pngBytes, role: .image, clipID: imgID, encrypted: false)
                let imgItem = try store.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        id: imgID,
                        kind: .image,
                        assetPath: imgURL.path,
                        imageDigest: store.computeImageDigest(forPNGData: pngBytes)
                    )
                )

                // Rolled-back transaction must NOT invoke post-commit cache evictions!
                struct RollbackSentinel: Error {}
                let preRollbackSnapshot = logLock.withLock { $0 }
                #expect(throws: RollbackSentinel.self) {
                    try store.performInTransaction {
                        _ = try store.setSensitivity(.sensitive, for: svgItem.id)
                        _ = try store.setSensitivity(.sensitive, for: imgItem.id)
                        try store.clear()
                        throw RollbackSentinel()
                    }
                }
                let postRollbackSnapshot = logLock.withLock { $0 }
                #expect(postRollbackSnapshot.removedSVGIDs == preRollbackSnapshot.removedSVGIDs)
                #expect(postRollbackSnapshot.purgedOwnerSVGs == preRollbackSnapshot.purgedOwnerSVGs)
                #expect(postRollbackSnapshot.removedThumbnailPaths == preRollbackSnapshot.removedThumbnailPaths)

                // Committed encryption upgrades & clear() fire post-commit hooks cleanly.
                _ = try store.setSensitivity(.sensitive, for: svgItem.id)
                _ = try store.setSensitivity(.sensitive, for: imgItem.id)
                try store.clear()

                let afterCommit = logLock.withLock { $0 }
                #expect(afterCommit.removedSVGIDs.contains(svgItem.id))
                #expect(afterCommit.removedThumbnailPaths.contains(imgURL.path))
                #expect(afterCommit.purgedOwnerSVGs == [ownerID])

                store.close()
                let afterClose = logLock.withLock { $0 }
                #expect(afterClose.unregisteredOwners == [ownerID])
                #expect(afterClose.removedThumbnailDirs == [supportDir])
                #expect(afterClose.removedDragDirs == [supportDir])
                #expect(afterClose.sensitiveCacheClears >= 1)
            }
        }

        @Test
        func existingV5OpenBackfillsSVGPartialIndexAndBatchSyncHelpersHandleEdgeCases() throws {
            try TestSupport.withTemporaryDirectory { supportDir in
                let keyProvider = InMemoryDatabaseKeyProvider()
                let svgMarkup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\"><circle cx=\"6\" cy=\"6\" r=\"5\"/></svg>"

                do {
                    let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                    defer { store.close() }
                    _ = try store.saveAndReconcileItem(ClipboardItem.fixture(kind: .text, text: svgMarkup))
                }

                let dbURL = supportDir.appendingPathComponent("History.sqlite")
                #expect(try Self.queryInt(at: dbURL, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_clips_svg';") == 1)

                var rawDB: OpaquePointer?
                #expect(sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
                defer { if let rawDB { sqlite3_close(rawDB) } }
                #expect(sqlite3_exec(rawDB, "DROP INDEX idx_clips_svg;", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(rawDB)
                rawDB = nil
                #expect(try Self.queryInt(at: dbURL, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_clips_svg';") == 0)

                // Reopening the existing v5 store backfills idx_clips_svg automatically.
                let reopened = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                defer { reopened.close() }
                let fetched = try reopened.fetchAll()
                #expect(fetched.count == 1)
                #expect(fetched.first?.isSVGText == true)
                reopened.close()
                #expect(try Self.queryInt(at: dbURL, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_clips_svg';") == 1)

                // Exercise ImageAssetStore.fullFsyncBatch & secureUnlinkBatch on empty, missing+valid, and hard-linked files.
                ImageAssetStore.fullFsyncBatch([] as [URL])
                ImageAssetStore.secureUnlinkBatch([] as [URL])

                let missingURL = supportDir.appendingPathComponent("missing-batch-file.bin")
                let validA = supportDir.appendingPathComponent("batch-a.bin")
                let validB = supportDir.appendingPathComponent("batch-b.bin")
                let pinA = supportDir.appendingPathComponent("batch-a.pin")
                let pinB = supportDir.appendingPathComponent("batch-b.pin")
                try Data(repeating: 0x5A, count: 4096).write(to: validA)
                try Data(repeating: 0x3C, count: 2048).write(to: validB)
                #expect(Darwin.link(validA.path, pinA.path) == 0)
                #expect(Darwin.link(validB.path, pinB.path) == 0)

                ImageAssetStore.fullFsyncBatch([missingURL, validA, validB])
                #expect(FileManager.default.fileExists(atPath: validA.path))
                #expect(FileManager.default.fileExists(atPath: validB.path))

                ImageAssetStore.secureUnlinkBatch([missingURL, validA, validB])
                #expect(!FileManager.default.fileExists(atPath: validA.path))
                #expect(!FileManager.default.fileExists(atPath: validB.path))
                let zeroedBytesA = try Data(contentsOf: pinA)
                #expect(zeroedBytesA.count == 4096)
                #expect(zeroedBytesA.allSatisfy { $0 == 0 })
                let zeroedBytesB = try Data(contentsOf: pinB)
                #expect(zeroedBytesB.count == 2048)
                #expect(zeroedBytesB.allSatisfy { $0 == 0 })
            }
        }

        // MARK: - Legacy Fixture Synthesis & Raw-Disk Scan Helpers

        private static func createSynthesizedLegacyDatabase(
            at dbURL: URL,
            walURL: URL,
            legacyVersion: Int,
            canaryFreelist: String,
            canaryWAL: String,
            secretTextID: UUID,
            secretPlainText: String,
            subSecondCopiedAt: Double,
            sequenceID: Date,
            secretRichID: UUID,
            secretHTML: String,
            secretRTFData: Data,
            sensitiveImageID: UUID,
            sensitiveImagePath: String,
            secretQRText: String,
            sensitiveLinkID: UUID,
            secretOGTitle: String,
            ogPreviewPath: String,
            ogFaviconPath: String,
            linkFetchedAt: Date,
            linkExpiresAt: Date,
            sensitiveFileID: UUID,
            secretFilePath: String,
            plainImageID: UUID,
            plainImagePath: String,
            orphanTagTrashedID: UUID,
            trashedDeletedAt: Date,
            v2UnmigratedStringTagID: UUID
        ) throws {
            var dbSnapshot = Data()
            var walSnapshot = Data()

            try withDatabase(at: dbURL) { db in
                func exec(_ sql: String) throws {
                    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                        throw TestSQLiteFixtureError.stepFailed(String(cString: sqlite3_errmsg(db)))
                    }
                }

                try exec("""
                    PRAGMA auto_vacuum = NONE;
                    PRAGMA secure_delete = OFF;
                    PRAGMA journal_mode = WAL;
                    PRAGMA synchronous = NORMAL;
                    PRAGMA wal_autocheckpoint = 0;
                    """)

                switch legacyVersion {
                case 0:
                    try exec("""
                        CREATE TABLE clips (
                            id TEXT PRIMARY KEY,
                            kind TEXT NOT NULL,
                            copiedAt REAL NOT NULL,
                            favorite INTEGER NOT NULL,
                            sourceApp TEXT,
                            searchText TEXT NOT NULL,
                            payload BLOB NOT NULL
                        );
                        CREATE TABLE clips_fts (content TEXT);
                        PRAGMA user_version = 0;
                        """)
                case 2:
                    try exec("""
                        CREATE TABLE tags (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                            color TEXT NOT NULL
                        );
                        CREATE TABLE clips (
                            id TEXT PRIMARY KEY,
                            kind TEXT NOT NULL,
                            copiedAt REAL NOT NULL,
                            favorite INTEGER NOT NULL,
                            sourceApp TEXT,
                            searchText TEXT NOT NULL,
                            contentKey TEXT NOT NULL DEFAULT '',
                            payload BLOB NOT NULL
                        );
                        PRAGMA user_version = 2;
                        """)
                case 3:
                    try exec("""
                        CREATE TABLE tags (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                            color TEXT NOT NULL
                        );
                        CREATE TABLE clips (
                            id TEXT PRIMARY KEY,
                            kind TEXT NOT NULL,
                            copiedAt REAL NOT NULL,
                            favorite INTEGER NOT NULL,
                            sourceApp TEXT,
                            searchText TEXT NOT NULL,
                            contentKey TEXT NOT NULL DEFAULT '',
                            payload BLOB NOT NULL,
                            html TEXT,
                            rtf BLOB
                        );
                        PRAGMA user_version = 3;
                        """)
                default:
                    try exec("""
                        CREATE TABLE tags (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                            color TEXT NOT NULL
                        );
                        CREATE TABLE clips (
                            id TEXT PRIMARY KEY,
                            kind TEXT NOT NULL,
                            copiedAt REAL NOT NULL,
                            favorite INTEGER NOT NULL,
                            sourceApp TEXT,
                            searchText TEXT NOT NULL,
                            contentKey TEXT NOT NULL DEFAULT '',
                            payload BLOB NOT NULL,
                            html TEXT,
                            rtf BLOB,
                            deletedAt REAL,
                            expiresAt REAL
                        );
                        PRAGMA user_version = 4;
                        """)
                }

                if legacyVersion >= 2 {
                    try exec("""
                        INSERT INTO tags (id, name, color) VALUES (1, 'LegacyTag', '#3B85ED');
                        INSERT INTO tags (id, name, color) VALUES (2, 'OpsTag', '#FF8800');
                        """)
                }

                func insertLegacyRow(
                    id: UUID,
                    kind: ClipboardKind,
                    copiedAt: Double,
                    favorite: Bool = false,
                    sourceApp: String = "LegacyApp",
                    searchText: String,
                    payloadDict: [String: Any],
                    columnHTML: String? = nil,
                    columnRTF: Data? = nil,
                    deletedAt: Double? = nil,
                    expiresAt: Double? = nil
                ) throws {
                    var merged: [String: Any] = [
                        "id": id.uuidString,
                        "kind": kind.rawValue,
                        "filePaths": [String](),
                        "sourceAppName": sourceApp,
                        "copiedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: copiedAt)),
                        "byteSize": 64,
                        "isFavorite": favorite,
                        "tags": [Int](),
                        "searchText": searchText,
                        "copyCount": 1,
                    ]
                    merged.merge(payloadDict) { _, new in new }
                    let payloadData = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])

                    switch legacyVersion {
                    case 0:
                        try exec("""
                            INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, payload)
                            VALUES ('\(id.uuidString)', '\(kind.rawValue)', \(copiedAt), \(favorite ? 1 : 0), '\(sourceApp)', '\(searchText)', \(sqlHex(payloadData)));
                            """)
                    case 2:
                        try exec("""
                            INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, contentKey, payload)
                            VALUES ('\(id.uuidString)', '\(kind.rawValue)', \(copiedAt), \(favorite ? 1 : 0), '\(sourceApp)', '\(searchText)', '', \(sqlHex(payloadData)));
                            """)
                    case 3:
                        let htmlLiteral = columnHTML.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
                        let rtfLiteral = columnRTF.map(sqlHex) ?? "NULL"
                        try exec("""
                            INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, contentKey, payload, html, rtf)
                            VALUES ('\(id.uuidString)', '\(kind.rawValue)', \(copiedAt), \(favorite ? 1 : 0), '\(sourceApp)', '\(searchText)', '', \(sqlHex(payloadData)), \(htmlLiteral), \(rtfLiteral));
                            """)
                    default:
                        let htmlLiteral = columnHTML.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
                        let rtfLiteral = columnRTF.map(sqlHex) ?? "NULL"
                        let deletedLiteral = deletedAt.map { String($0) } ?? "NULL"
                        let expiresLiteral = expiresAt.map { String($0) } ?? "NULL"
                        try exec("""
                            INSERT INTO clips (id, kind, copiedAt, favorite, sourceApp, searchText, contentKey, payload, html, rtf, deletedAt, expiresAt)
                            VALUES ('\(id.uuidString)', '\(kind.rawValue)', \(copiedAt), \(favorite ? 1 : 0), '\(sourceApp)', '\(searchText)', '', \(sqlHex(payloadData)), \(htmlLiteral), \(rtfLiteral), \(deletedLiteral), \(expiresLiteral));
                            """)
                    }
                }

                // 1. Seed dirty freelist pages inside History.sqlite (checkpointed, then deleted without VACUUM).
                let freelistID = UUID()
                let freelistFiller = String(repeating: "\(canaryFreelist)-", count: 240)
                try insertLegacyRow(
                    id: freelistID,
                    kind: .text,
                    copiedAt: 1_700_000_010,
                    searchText: freelistFiller,
                    payloadDict: ["text": freelistFiller]
                )
                try exec("PRAGMA wal_checkpoint(TRUNCATE);")
                try exec("DELETE FROM clips WHERE id = '\(freelistID.uuidString)';")
                try exec("PRAGMA wal_checkpoint(TRUNCATE);")

                // 2. Seed uncheckpointed WAL frames (wal_autocheckpoint = 0) + all live rows.
                let walCanaryID = UUID()
                let walFiller = String(repeating: "\(canaryWAL)-", count: 120)
                try insertLegacyRow(
                    id: walCanaryID,
                    kind: .text,
                    copiedAt: 1_700_000_020,
                    searchText: walFiller,
                    payloadDict: ["text": walFiller]
                )
                try exec("DELETE FROM clips WHERE id = '\(walCanaryID.uuidString)';")

                let isoFormatter = ISO8601DateFormatter()

                // Plain text secret with sub-second copiedAt, favoriteOrder, copySequenceID, and tags.
                var secretTextPayload: [String: Any] = [
                    "text": secretPlainText,
                    "copyCount": 2,
                    "favoriteOrder": 3,
                    "copySequenceID": isoFormatter.string(from: sequenceID),
                    "copySequenceOrder": 1,
                ]
                if legacyVersion == 0 {
                    secretTextPayload["tags"] = ["LegacyTag", "OpsTag"]
                } else {
                    secretTextPayload["tags"] = [1, 2]
                    secretTextPayload["tagOrders"] = ["1": 5, "2": 2]
                }
                try insertLegacyRow(
                    id: secretTextID,
                    kind: .text,
                    copiedAt: subSecondCopiedAt,
                    favorite: true,
                    searchText: secretPlainText,
                    payloadDict: secretTextPayload
                )

                // Rich text with secrets in HTML and RTF while plain text is benign.
                var secretRichPayload: [String: Any] = [
                    "text": "Benign Rich Heading",
                    "hasFormatting": true,
                ]
                if legacyVersion < 3 {
                    secretRichPayload["html"] = secretHTML
                    secretRichPayload["rtfData"] = secretRTFData.base64EncodedString()
                }
                try insertLegacyRow(
                    id: secretRichID,
                    kind: .richText,
                    copiedAt: 1_700_000_200.250,
                    searchText: "Benign Rich Heading \(secretHTML)",
                    payloadDict: secretRichPayload,
                    columnHTML: legacyVersion >= 3 ? secretHTML : nil,
                    columnRTF: legacyVersion >= 3 ? secretRTFData : nil
                )

                // Image with QR secret and managed sensitive PNG on disk.
                try insertLegacyRow(
                    id: sensitiveImageID,
                    kind: .image,
                    copiedAt: 1_700_000_300.500,
                    searchText: "Scan Badge \(secretQRText)",
                    payloadDict: [
                        "text": "Scan Badge",
                        "qrCodeText": secretQRText,
                        "assetPath": sensitiveImagePath,
                    ]
                )

                // Link with secret OpenGraph preview + preview/favicon images + expiresAt.
                try insertLegacyRow(
                    id: sensitiveLinkID,
                    kind: .link,
                    copiedAt: 1_700_000_400.000,
                    searchText: "https://portal.example.com/overview \(secretOGTitle)",
                    payloadDict: [
                        "text": "https://portal.example.com/overview",
                        "expiresAt": isoFormatter.string(from: linkExpiresAt),
                        "linkPreviewDetails": [
                            "url": "https://portal.example.com/overview",
                            "title": secretOGTitle,
                            "description": "Private portal",
                            "imagePath": ogPreviewPath,
                            "faviconPath": ogFaviconPath,
                            "fetchedAt": isoFormatter.string(from: linkFetchedAt),
                        ],
                    ],
                    expiresAt: legacyVersion >= 4 ? linkExpiresAt.timeIntervalSince1970 : nil
                )

                // File item with secret filePath.
                try insertLegacyRow(
                    id: sensitiveFileID,
                    kind: .file,
                    copiedAt: 1_700_000_500.000,
                    searchText: secretFilePath,
                    payloadDict: [
                        "filePaths": [secretFilePath],
                    ]
                )

                // Non-sensitive PNG image that must stay plain .png on disk.
                try insertLegacyRow(
                    id: plainImageID,
                    kind: .image,
                    copiedAt: 1_700_000_600.000,
                    searchText: "Public Diagram Non-sensitive OCR",
                    payloadDict: [
                        "title": "Public Diagram",
                        "text": "Non-sensitive OCR",
                        "assetPath": plainImagePath,
                    ]
                )

                // Item with orphaned tagId 9999 (and trashed on v4).
                try insertLegacyRow(
                    id: orphanTagTrashedID,
                    kind: .text,
                    copiedAt: 1_700_000_700.000,
                    searchText: "Orphan tag item",
                    payloadDict: [
                        "text": "Orphan tag item",
                        "tags": [9999],
                    ],
                    deletedAt: legacyVersion >= 4 ? trashedDeletedAt.timeIntervalSince1970 : nil
                )

                // On v2+, verify legacy string tags do not re-trigger v0 tag creation.
                if legacyVersion >= 2 {
                    try insertLegacyRow(
                        id: v2UnmigratedStringTagID,
                        kind: .text,
                        copiedAt: 1_700_000_800.000,
                        searchText: "Legacy string tag on v2+",
                        payloadDict: [
                            "text": "Legacy string tag on v2+",
                            "tags": ["UnmigratedV2StringTag"],
                        ]
                    )
                }

                // Capture exact pre-close DB + uncheckpointed WAL bytes while the WAL handle is live.
                dbSnapshot = try Data(contentsOf: dbURL)
                walSnapshot = try Data(contentsOf: walURL)
            }

            // Restore exact DB + uncheckpointed WAL state after sqlite3_close's auto-checkpoint.
            try dbSnapshot.write(to: dbURL, options: .atomic)
            try walSnapshot.write(to: walURL, options: .atomic)
        }

        private static func allRegularFilesRecursively(in rootURL: URL) throws -> [URL] {
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: []
                )
            )
            var urls: [URL] = []
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    urls.append(fileURL)
                }
            }
            return urls
        }

        private static func canaryBytePatterns(for canary: String) -> [(label: String, bytes: Data)] {
            var patterns: [(String, Data)] = [
                ("utf8", Data(canary.utf8)),
            ]
            if let utf16LE = canary.data(using: .utf16LittleEndian) {
                patterns.append(("utf16LE", utf16LE))
            }
            if let utf16BE = canary.data(using: .utf16BigEndian) {
                patterns.append(("utf16BE", utf16BE))
            }
            // Check all 3 Base64 byte-triplet alignments so Base64-encoded JSON/RTF blobs cannot hide canaries.
            let rawUTF8 = Data(canary.utf8)
            for padLen in 0..<3 {
                let padded = Data(repeating: 0x41, count: padLen) + rawUTF8
                let b64 = padded.base64EncodedString()
                let dropLeadingChars = padLen == 0 ? 0 : 4
                let usableChars = ((padded.count) / 3) * 4 - dropLeadingChars
                if usableChars >= 8 {
                    let start = b64.index(b64.startIndex, offsetBy: dropLeadingChars)
                    let end = b64.index(start, offsetBy: usableChars)
                    patterns.append(("base64-align\(padLen)", Data(b64[start..<end].utf8)))
                }
            }
            return patterns
        }

        nonisolated private static func hexString(_ data: Data) -> String {
            data.map { String(format: "%02X", $0) }.joined()
        }

        nonisolated private static func sqlHex(_ data: Data) -> String {
            "X'\(hexString(data))'"
        }

        private static func withDatabase<T>(at dbURL: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                throw HistoryStoreError.openFailed
            }
            defer { sqlite3_close(db) }
            return try body(db)
        }

        private static func executeSQL(at dbURL: URL, _ sql: String) throws {
            try withDatabase(at: dbURL) { db in
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw TestSQLiteFixtureError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
        }

        private static func queryText(at dbURL: URL, _ sql: String) throws -> String? {
            try withDatabase(at: dbURL) { db in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw TestSQLiteFixtureError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    return nil
                }
                return String(cString: text)
            }
        }

        private static func queryInt(at dbURL: URL, _ sql: String) throws -> Int? {
            try queryText(at: dbURL, sql).flatMap { Int($0) }
        }

        private static func inspectDatabaseState(
            at dbURL: URL
        ) throws -> (schemaVersion: Int32, hasFTSTable: Bool, hasPayloadColumn: Bool) {
            let version = try queryText(at: dbURL, "PRAGMA user_version;").flatMap { Int32($0) } ?? -1
            let ftsTableCount = try queryInt(
                at: dbURL,
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'clips_fts';"
            ) ?? 0
            let payloadColCount = try queryInt(
                at: dbURL,
                "SELECT count(*) FROM pragma_table_info('clips') WHERE name = 'payload';"
            ) ?? 0
            return (version, ftsTableCount > 0, payloadColCount > 0)
        }

        private static func fetchItem(_ id: ClipboardItem.ID, from store: GRDBHistoryStore) throws -> ClipboardItem {
            try #require(try store.fetchAll().first { $0.id == id })
        }
    }

    @Suite
    struct ClipBookArchiveServiceTests {
        @Test
        func fullExportAndImportRoundTrip() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let sourceSupportDir = rootDir.appendingPathComponent("SourceSupport", isDirectory: true)
                let targetSupportDir = rootDir.appendingPathComponent("TargetSupport", isDirectory: true)
                let archiveURL = rootDir.appendingPathComponent("Backup.clipbookarchive", isDirectory: true)
                try fileManager.createDirectory(at: sourceSupportDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: targetSupportDir, withIntermediateDirectories: true)

                let sourceStore = GRDBHistoryStore(
                    directory: sourceSupportDir,
                    keyProvider: InMemoryDatabaseKeyProvider()
                )
                defer { sourceStore.close() }
                let designTag = try sourceStore.createTag(name: "Design", color: "#E91E63")
                let docsTag = try sourceStore.createTag(name: "Docs", color: "#2196F3")

                let sourceImagesDir = sourceSupportDir.appendingPathComponent("Images", isDirectory: true)
                let sourcePreviewsDir = sourceSupportDir.appendingPathComponent("LinkPreviews", isDirectory: true)
                try fileManager.createDirectory(at: sourceImagesDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: sourcePreviewsDir, withIntermediateDirectories: true)

                let sourceImageURL = sourceImagesDir.appendingPathComponent("diagram.png")
                let sourcePreviewImageURL = sourcePreviewsDir.appendingPathComponent("og-image.png")
                let sourceFaviconURL = sourcePreviewsDir.appendingPathComponent("favicon.ico")
                let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x10, 0x20, 0x30])
                let previewImageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x40, 0x50, 0x60])
                let faviconBytes = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
                try imageBytes.write(to: sourceImageURL)
                try previewImageBytes.write(to: sourcePreviewImageURL)
                try faviconBytes.write(to: sourceFaviconURL)

                let richItem = ClipboardItem.fixture(
                    kind: .richText,
                    title: "Formatted Spec",
                    text: "Bold & Italic Spec",
                    rtfData: Data(#"{\rtf1\ansi\b Bold & Italic Spec\b0}"#.utf8),
                    html: "<b>Bold &amp; Italic Spec</b>",
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_000),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_500),
                    isFavorite: true,
                    tags: [designTag.id, docsTag.id],
                    copyCount: 4,
                    favoriteOrder: 1,
                    sensitivity: .notSensitive
                )

                let imageItem = ClipboardItem.fixture(
                    kind: .image,
                    title: "Architecture Mockup",
                    text: "OCR Diagram Text",
                    qrCodeText: "https://example.com/mockup",
                    assetPath: sourceImageURL.path,
                    imageDigest: ContentDigest.sha256(imageBytes),
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_010),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_510),
                    tags: [designTag.id]
                )

                let linkItem = ClipboardItem.fixture(
                    kind: .link,
                    text: "https://example.com/docs#section-2",
                    copiedAt: Date(timeIntervalSince1970: 1_700_001_020),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_520),
                    tags: [docsTag.id],
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://example.com/docs#section-2",
                        title: "Section 2 — API Reference",
                        description: "Detailed documentation",
                        imagePath: sourcePreviewImageURL.path,
                        faviconPath: sourceFaviconURL.path,
                        fetchedAt: Date(timeIntervalSince1970: 1_700_001_000)
                    )
                )

                try sourceStore.upsert(richItem)
                try sourceStore.upsert(imageItem)
                try sourceStore.upsert(linkItem)

                let itemsForExport = try sourceStore.fetchAll().map { try sourceStore.loadingContent(of: $0, scope: .full) }
                let tagsForExport = try sourceStore.fetchTags()
                let sourceArchiveService = ClipBookArchiveService(
                    supportDirectory: sourceSupportDir
                )

                var exportProgressSteps: [ClipBookArchiveProgress] = []
                try sourceArchiveService.export(
                    items: itemsForExport,
                    tags: tagsForExport,
                    to: archiveURL,
                    progress: { exportProgressSteps.append($0) }
                )
                #expect(exportProgressSteps.first?.completedItemCount == 0)
                #expect(exportProgressSteps.last?.completedItemCount == 3)
                #expect(exportProgressSteps.last?.totalItemCount == 3)

                let targetStore = GRDBHistoryStore(
                    directory: targetSupportDir,
                    keyProvider: InMemoryDatabaseKeyProvider()
                )
                defer { targetStore.close() }
                let targetArchiveService = ClipBookArchiveService(
                    supportDirectory: targetSupportDir
                )

                var importProgressSteps: [ClipBookArchiveProgress] = []
                let importResult = try targetArchiveService.import(
                    from: archiveURL,
                    into: targetStore,
                    progress: { importProgressSteps.append($0) }
                )
                #expect(importResult.itemCount == 3)
                #expect(importResult.tagCount == 2)
                #expect(importProgressSteps.last?.completedItemCount == 3)

                let importedTags = try targetStore.fetchTags()
                #expect(Set(importedTags.map(\.name)) == Set(["Design", "Docs"]))

                let importedItems = try targetStore.fetchAll()
                #expect(importedItems.map(\.id) == [linkItem.id, imageItem.id, richItem.id])

                let importedByID = Dictionary(uniqueKeysWithValues: importedItems.map { ($0.id, $0) })

                let importedRich = try #require(importedByID[richItem.id])
                #expect(!importedRich.isContentLoaded)
                #expect(importedRich.isFavorite)
                #expect(importedRich.favoriteOrder == 1)
                #expect(importedRich.sensitivity == .notSensitive)
                let loadedRich = try targetStore.loadingContent(of: importedRich, scope: .full)
                #expect(loadedRich.text == "Bold & Italic Spec")
                #expect(loadedRich.html == "<b>Bold &amp; Italic Spec</b>")
                #expect(loadedRich.rtfData == Data(#"{\rtf1\ansi\b Bold & Italic Spec\b0}"#.utf8))

                let importedImage = try #require(importedByID[imageItem.id])
                #expect(!importedImage.isContentLoaded)
                #expect(importedImage.title == "Architecture Mockup")
                let loadedImage = try targetStore.loadingContent(of: importedImage, scope: .body)
                #expect(loadedImage.text == "OCR Diagram Text")
                #expect(loadedImage.qrCodeText == "https://example.com/mockup")
                #expect(importedImage.imageDigest == targetStore.computeImageDigest(forPNGData: imageBytes))
                let importedImagePath = try #require(importedImage.assetPath)
                #expect(try Data(contentsOf: URL(fileURLWithPath: importedImagePath)) == imageBytes)

                let importedLink = try #require(importedByID[linkItem.id])
                let preview = try #require(importedLink.linkPreviewDetails)
                #expect(preview.title == "Section 2 — API Reference")
                let previewImagePath = try #require(preview.imagePath)
                let faviconPath = try #require(preview.faviconPath)
                #expect(try Data(contentsOf: URL(fileURLWithPath: previewImagePath)) == previewImageBytes)
                #expect(try Data(contentsOf: URL(fileURLWithPath: faviconPath)) == faviconBytes)
            }
        }

        @Test
        func archivePathSecurityChecks() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let (_, store, service) = try Self.makeImportTarget(in: rootDir)
                defer { store.close() }

                let secretOutsideFile = rootDir.appendingPathComponent("outside-secret.png")
                try Data("secret".utf8).write(to: secretOutsideFile)

                let invalidCases: [(name: String, assetPath: String, setup: (URL) throws -> Void)] = [
                    (
                        name: "dot-dot path traversal",
                        assetPath: "assets/images/../../../outside-secret.png",
                        setup: { _ in }
                    ),
                    (
                        name: "absolute path",
                        assetPath: secretOutsideFile.path,
                        setup: { _ in }
                    ),
                    (
                        name: "symlinked asset file",
                        assetPath: "assets/images/symlinked.png",
                        setup: { archiveDir in
                            let linkURL = archiveDir.appendingPathComponent("assets/images/symlinked.png")
                            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: secretOutsideFile)
                        }
                    ),
                    (
                        name: "symlinked parent directory",
                        assetPath: "assets/linked-dir/outside-secret.png",
                        setup: { archiveDir in
                            let linkedDirURL = archiveDir.appendingPathComponent("assets/linked-dir")
                            try fileManager.createSymbolicLink(at: linkedDirURL, withDestinationURL: rootDir)
                        }
                    ),
                    (
                        name: "directory instead of file",
                        assetPath: "assets/images/folder.png",
                        setup: { archiveDir in
                            let folderURL = archiveDir.appendingPathComponent("assets/images/folder.png")
                            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                            try Data("inner".utf8).write(to: folderURL.appendingPathComponent("inner.txt"))
                        }
                    ),
                    (
                        name: "dot-dot component inside the archive",
                        assetPath: "assets/images/../images/inner.png",
                        setup: { archiveDir in
                            try Data("inner".utf8).write(to: archiveDir.appendingPathComponent("assets/images/inner.png"))
                        }
                    )
                ]

                for (index, testCase) in invalidCases.enumerated() {
                    let badArchiveURL = rootDir.appendingPathComponent("Bad-\(index).clipbookarchive", isDirectory: true)
                    try Self.writeCustomArchive(
                        at: badArchiveURL,
                        items: [
                            (id: UUID(), kind: "image", text: nil, assetPath: testCase.assetPath)
                        ],
                        setupFiles: testCase.setup
                    )

                    let thrownError = #expect(throws: ClipBookArchiveError.self, Comment(rawValue: testCase.name)) {
                        _ = try service.import(from: badArchiveURL, into: store)
                    }
                    var isInvalidAssetPath = false
                    if case .invalidAssetPath? = thrownError {
                        isInvalidAssetPath = true
                    }
                    #expect(isInvalidAssetPath, Comment(rawValue: testCase.name))
                }
            }
        }

        @Test
        func archiveImportAcceptsDoubleDotInsideFileName() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let (_, store, service) = try Self.makeImportTarget(in: rootDir)
                defer { store.close() }

                let itemID = UUID()
                let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
                let archiveURL = rootDir.appendingPathComponent("Dots.clipbookarchive", isDirectory: true)
                try Self.writeCustomArchive(
                    at: archiveURL,
                    items: [(id: itemID, kind: "image", text: nil, assetPath: "assets/images/photo..png")],
                    setupFiles: { archiveDir in
                        try imageBytes.write(to: archiveDir.appendingPathComponent("assets/images/photo..png"))
                    }
                )

                let result = try service.import(from: archiveURL, into: store)
                #expect(result.itemIDs == [itemID])
                let imported = try #require(try store.fetchAll().first)
                let importedPath = try #require(imported.assetPath)
                #expect(try Data(contentsOf: URL(fileURLWithPath: importedPath)) == imageBytes)
            }
        }

        @Test
        func failedImportRemovesAssetFilesAlreadyCopied() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let (supportDir, store, service) = try Self.makeImportTarget(in: rootDir)
                defer { store.close() }

                // The first item copies its image, the second one is invalid
                // (its asset is a directory), so the whole import rolls back.
                let archiveURL = rootDir.appendingPathComponent("Rollback.clipbookarchive", isDirectory: true)
                try Self.writeCustomArchive(
                    at: archiveURL,
                    items: [
                        (id: UUID(), kind: "image", text: nil, assetPath: "assets/images/first.png"),
                        (id: UUID(), kind: "image", text: nil, assetPath: "assets/images/folder.png")
                    ],
                    setupFiles: { archiveDir in
                        try Data([0x01, 0x02, 0x03]).write(to: archiveDir.appendingPathComponent("assets/images/first.png"))
                        try fileManager.createDirectory(
                            at: archiveDir.appendingPathComponent("assets/images/folder.png"),
                            withIntermediateDirectories: true
                        )
                    }
                )

                #expect(throws: ClipBookArchiveError.self) {
                    _ = try service.import(from: archiveURL, into: store)
                }

                #expect(try store.fetchAll().isEmpty)
                let imagesDirectory = supportDir.appendingPathComponent("Images", isDirectory: true)
                let leftovers = (try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
                #expect(leftovers.isEmpty)
            }
        }

        @Test(arguments: [
            (imagePath: "assets/link-previews/good.png", faviconPath: "assets/link-previews/../../../outside.png"),
            (imagePath: "assets/link-previews/../../../outside.png", faviconPath: "assets/link-previews/good.png"),
            (imagePath: "assets/link-previews/good.png", faviconPath: "assets/link-previews/folder.png")
        ])
        func linkPreviewPicturesAreCheckedLikeAssetsAndRolledBack(imagePath: String, faviconPath: String) throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let (supportDir, store, service) = try Self.makeImportTarget(in: rootDir)
                defer { store.close() }
                let itemID = UUID()
                let archiveURL = rootDir.appendingPathComponent("Previews.clipbookarchive", isDirectory: true)
                try Self.writeCustomArchive(
                    at: archiveURL,
                    items: [(id: itemID, kind: "link", text: "https://example.com/page", assetPath: nil)],
                    linkPreviews: [itemID: (imagePath: imagePath, faviconPath: faviconPath)],
                    setupFiles: { archiveDir in
                        try Data([0x01, 0x02, 0x03]).write(to: archiveDir.appendingPathComponent("assets/link-previews/good.png"))
                        try Data("secret".utf8).write(to: rootDir.appendingPathComponent("outside.png"))
                        try fileManager.createDirectory(
                            at: archiveDir.appendingPathComponent("assets/link-previews/folder.png"),
                            withIntermediateDirectories: true
                        )
                    }
                )

                let thrownError = #expect(throws: ClipBookArchiveError.self) {
                    _ = try service.import(from: archiveURL, into: store)
                }
                var isInvalidAssetPath = false
                if case .invalidAssetPath? = thrownError {
                    isInvalidAssetPath = true
                }
                #expect(isInvalidAssetPath)

                #expect(try store.fetchAll().isEmpty)
                let previewsDirectory = supportDir.appendingPathComponent("LinkPreviews", isDirectory: true)
                #expect(((try? fileManager.contentsOfDirectory(atPath: previewsDirectory.path)) ?? []).isEmpty)
            }
        }

        @Test
        func encryptedV2ArchiveRoundTripAndZeroCleartextScan() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let sourceSupportDir = rootDir.appendingPathComponent("SourceSupport", isDirectory: true)
                let targetSupportDir = rootDir.appendingPathComponent("TargetSupport", isDirectory: true)
                let archiveURL = rootDir.appendingPathComponent("Backup.clipbookarchive", isDirectory: true)
                let sourceImagesDir = sourceSupportDir.appendingPathComponent("Images", isDirectory: true)
                let sourcePreviewsDir = sourceSupportDir.appendingPathComponent("LinkPreviews", isDirectory: true)
                try fileManager.createDirectory(at: sourceImagesDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: sourcePreviewsDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: targetSupportDir, withIntermediateDirectories: true)

                let sourceKeyProvider = InMemoryDatabaseKeyProvider()
                let targetKeyProvider = InMemoryDatabaseKeyProvider()
                let sourceStore = GRDBHistoryStore(directory: sourceSupportDir, keyProvider: sourceKeyProvider)
                defer { sourceStore.close() }

                let vaultTagAlpha = try sourceStore.createTag(name: "VaultTagAlpha", color: "#E91E63")
                let vaultTagBeta = try sourceStore.createTag(name: "VaultTagBeta", color: "#00BCD4")

                let plainImageBytes = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 20, color: .systemGreen)
                let sensitiveImageBytes = try TestSupport.makePNGData(pixelWidth: 36, pixelHeight: 24, color: .systemOrange)
                let plainPreviewBytes = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 16, color: .systemTeal)
                let sensitivePreviewBytes = try TestSupport.makePNGData(pixelWidth: 22, pixelHeight: 18, color: .systemPurple)
                let plainFaviconBytes = Data([
                    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10,
                    0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0xAA, 0xBB
                ])
                let sensitiveFaviconBytes = Data([
                    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10,
                    0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0xCC, 0xDD
                ])

                let plainImageID = UUID()
                let plainImageURL = try sourceStore.writeManagedAsset(
                    pngData: plainImageBytes,
                    role: .image,
                    clipID: plainImageID,
                    encrypted: false
                )

                let plainLinkID = UUID()
                let plainPreviewURL = try sourceStore.writeManagedAsset(
                    pngData: plainPreviewBytes,
                    role: .linkPreview,
                    clipID: plainLinkID,
                    encrypted: false
                )
                let plainFaviconURL = try sourceStore.writeManagedAsset(
                    pngData: plainFaviconBytes,
                    role: .linkFavicon,
                    clipID: plainLinkID,
                    encrypted: false,
                    preferredPlainExtension: "ico"
                )
                #expect(plainFaviconURL.pathExtension == "ico")

                let sensitiveImageID = UUID()
                let stagedPlainBeforeEncrypt = sourceImagesDir.appendingPathComponent("\(sensitiveImageID.uuidString).png")
                try sensitiveImageBytes.write(to: stagedPlainBeforeEncrypt)

                let sensitiveLinkID = UUID()
                let sensitivePreviewURL = try sourceStore.writeManagedAsset(
                    pngData: sensitivePreviewBytes,
                    role: .linkPreview,
                    clipID: sensitiveLinkID,
                    encrypted: true
                )
                let sensitiveFaviconURL = try sourceStore.writeManagedAsset(
                    pngData: sensitiveFaviconBytes,
                    role: .linkFavicon,
                    clipID: sensitiveLinkID,
                    encrypted: true
                )

                let secretOCRToken = ["gh", "p_", "V2ArchiveSensitiveOCRToken8877665544332211"].joined()
                let secretTextToken = ["sk", "-proj-", "V2ArchiveSecretBodyToken9988776655443322"].joined()
                let richBodyText = "FormattedArchiveBodyCanary2026"
                let richHTML = "<article><strong>FormattedArchiveBodyCanary2026</strong></article>"
                let richRTF = try TestSupport.makeRTFData(text: richBodyText)

                var richItem = ClipboardItem.fixture(
                    kind: .richText,
                    title: "RichSpecCanaryTitle",
                    text: richBodyText,
                    rtfData: richRTF,
                    html: richHTML,
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_100),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_000),
                    isFavorite: true,
                    tags: [vaultTagAlpha.id, vaultTagBeta.id],
                    copyCount: 3,
                    favoriteOrder: 4,
                    sensitivity: .notSensitive
                )
                richItem.tagOrders = [vaultTagAlpha.id: 2, vaultTagBeta.id: 7]

                let plainImageItem = ClipboardItem.fixture(
                    id: plainImageID,
                    kind: .image,
                    title: "PlainDiagramCanaryTitle",
                    text: "PlainDiagramOCRCanaryText",
                    qrCodeText: "https://plain-qr.example/diagram-canary",
                    assetPath: plainImageURL.path,
                    imageDigest: sourceStore.computeImageDigest(forPNGData: plainImageBytes),
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_200),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_010),
                    tags: [vaultTagAlpha.id]
                )

                let plainLinkItem = ClipboardItem.fixture(
                    id: plainLinkID,
                    kind: .link,
                    text: "https://public-docs.example/reference-canary",
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_300),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_020),
                    tags: [vaultTagBeta.id],
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://public-docs.example/reference-canary",
                        title: "PublicReferencePreviewCanary",
                        description: "PublicPreviewDescriptionCanary",
                        imagePath: plainPreviewURL.path,
                        faviconPath: plainFaviconURL.path,
                        fetchedAt: Date(timeIntervalSince1970: 1_710_200_290)
                    )
                )

                var sensitiveImageItem = ClipboardItem.fixture(
                    id: sensitiveImageID,
                    kind: .image,
                    title: "SensitiveReceiptCanaryTitle",
                    text: "OCR Prefix \(secretOCRToken)",
                    qrCodeText: "otpauth://totp/VaultExample:alice?secret=JBSWY3DPEHPK3PXP",
                    assetPath: stagedPlainBeforeEncrypt.path,
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_400),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_030),
                    tags: [vaultTagAlpha.id]
                )
                sensitiveImageItem.tagOrders = [vaultTagAlpha.id: 1]

                let sensitiveLinkItem = ClipboardItem.fixture(
                    id: sensitiveLinkID,
                    kind: .link,
                    text: "https://internal-vault.example/admin-token-canary",
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_500),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_040),
                    linkPreviewDetails: LinkPreviewDetails(
                        url: "https://internal-vault.example/admin-token-canary",
                        title: "InternalAdminPreviewCanary",
                        description: "SensitiveLinkDescriptionCanary",
                        imagePath: sensitivePreviewURL.path,
                        faviconPath: sensitiveFaviconURL.path,
                        fetchedAt: Date(timeIntervalSince1970: 1_710_200_490)
                    ),
                    sensitivity: .sensitive
                )

                let secretTextItem = ClipboardItem.fixture(
                    kind: .text,
                    title: "ProdAPIKeyCanaryTitle",
                    text: "API credential \(secretTextToken)",
                    copiedAt: Date(timeIntervalSince1970: 1_710_200_600),
                    firstCopiedAt: Date(timeIntervalSince1970: 1_710_200_050),
                    isFavorite: true,
                    tags: [vaultTagBeta.id],
                    favoriteOrder: 1
                )

                #expect(SensitiveContent.shouldEncryptAtRest(sensitiveImageItem))
                #expect(SensitiveContent.shouldEncryptAtRest(sensitiveLinkItem))
                #expect(SensitiveContent.shouldEncryptAtRest(secretTextItem))

                _ = try sourceStore.saveAndReconcileItem(richItem, convertingExternalAssets: true)
                _ = try sourceStore.saveAndReconcileItem(plainImageItem, convertingExternalAssets: true)
                _ = try sourceStore.saveAndReconcileItem(plainLinkItem, convertingExternalAssets: true)
                let savedSensitiveImage = try sourceStore.saveAndReconcileItem(sensitiveImageItem, convertingExternalAssets: true)
                _ = try sourceStore.saveAndReconcileItem(sensitiveLinkItem, convertingExternalAssets: false)
                _ = try sourceStore.saveAndReconcileItem(secretTextItem, convertingExternalAssets: true)

                #expect(URL(fileURLWithPath: try #require(savedSensitiveImage.assetPath)).pathExtension == "enc")
                #expect(!fileManager.fileExists(atPath: stagedPlainBeforeEncrypt.path))

                let unloadedSourceItems = try sourceStore.fetchAll()
                #expect(unloadedSourceItems.count == 6)
                #expect(unloadedSourceItems.allSatisfy { !$0.isContentLoaded })

                // Production 600,000 PBKDF2 iterations with NFD passphrase -> NFC verification & import.
                let sourceArchiveService = ClipBookArchiveService(
                    supportDirectory: sourceSupportDir
                )
                #expect(sourceArchiveService.kdfIterations == 600_000)
                #expect(!sourceArchiveService.allowTestIterations)

                let nfdPassphrase = "caf\u{0065}\u{0301}-backup"
                let nfcPassphrase = "caf\u{00E9}-backup"
                #expect(Array(nfdPassphrase.utf8) != Array(nfcPassphrase.utf8))

                try sourceArchiveService.export(
                    items: unloadedSourceItems,
                    tags: try sourceStore.fetchTags(),
                    to: archiveURL,
                    passphrase: nfdPassphrase,
                    loadItem: { item in
                        try sourceStore.loadingContent(of: item, scope: .full)
                    }
                )

                let inspection = try sourceArchiveService.inspect(at: archiveURL)
                #expect(inspection == ClipBookArchiveInspection(formatVersion: 2, isEncrypted: true))

                // Enumerate every file in Backup.clipbookarchive normalizing symlinked /var -> /private/var paths.
                let canonicalArchiveRoot = archiveURL.resolvingSymlinksInPath().standardizedFileURL
                let rootPrefix = canonicalArchiveRoot.path.hasSuffix("/")
                    ? canonicalArchiveRoot.path
                    : (canonicalArchiveRoot.path + "/")
                let enumerator = try #require(
                    fileManager.enumerator(
                        at: canonicalArchiveRoot,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                        options: []
                    )
                )
                var relativeRegularFiles: [String: URL] = [:]
                for case let entryURL as URL in enumerator {
                    let resolvedEntry = entryURL.resolvingSymlinksInPath().standardizedFileURL
                    #expect(resolvedEntry.path.hasPrefix(rootPrefix))
                    let relPath = String(resolvedEntry.path.dropFirst(rootPrefix.count))
                    let values = try resolvedEntry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    if values.isRegularFile == true {
                        relativeRegularFiles[relPath] = resolvedEntry
                    }
                }

                let expectedEncryptedAssetPaths: Set<String> = [
                    "assets/images/\(plainImageID.uuidString).enc",
                    "assets/images/\(sensitiveImageID.uuidString).enc",
                    "assets/link-previews/\(plainLinkID.uuidString)-preview.enc",
                    "assets/link-previews/\(plainLinkID.uuidString)-favicon.enc",
                    "assets/link-previews/\(sensitiveLinkID.uuidString)-preview.enc",
                    "assets/link-previews/\(sensitiveLinkID.uuidString)-favicon.enc"
                ]
                let expectedAllFiles = Set(["manifest.json", "tags.json.enc", "history.json.enc"]).union(expectedEncryptedAssetPaths)
                #expect(Set(relativeRegularFiles.keys) == expectedAllFiles)

                let manifestBytes = try Data(contentsOf: try #require(relativeRegularFiles["manifest.json"]))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(ClipBookArchiveManifest.self, from: manifestBytes)
                #expect(manifest.formatVersion == 2)
                #expect(manifest.encryption?.kdf == "PBKDF2-HMAC-SHA256")
                #expect(manifest.encryption?.algorithm == "AES-256-GCM")
                #expect(manifest.encryption?.iterations == 600_000)

                // Zero-cleartext scan across UTF-8, UTF-16LE, UTF-16BE, Base64 alignments, and PNG/ICO magic headers!
                let cleartextStrings = [
                    "VaultTagAlpha",
                    "VaultTagBeta",
                    richBodyText,
                    "RichSpecCanaryTitle",
                    "PlainDiagramCanaryTitle",
                    "PlainDiagramOCRCanaryText",
                    "https://plain-qr.example/diagram-canary",
                    "https://public-docs.example/reference-canary",
                    "PublicReferencePreviewCanary",
                    "PublicPreviewDescriptionCanary",
                    "SensitiveReceiptCanaryTitle",
                    secretOCRToken,
                    "otpauth://totp/VaultExample:alice",
                    "https://internal-vault.example/admin-token-canary",
                    "InternalAdminPreviewCanary",
                    "SensitiveLinkDescriptionCanary",
                    "ProdAPIKeyCanaryTitle",
                    secretTextToken
                ]
                var allForbiddenPatterns: [(label: String, bytes: Data)] = []
                for needle in cleartextStrings {
                    for encoded in Self.encodedPatterns(for: needle) {
                        allForbiddenPatterns.append(("\(needle)[\(encoded.label)]", encoded.bytes))
                    }
                }
                let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                let icoMagic = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])

                for (relPath, fileURL) in relativeRegularFiles {
                    let rawData = try Data(contentsOf: fileURL)
                    for pattern in allForbiddenPatterns {
                        #expect(
                            rawData.range(of: pattern.bytes) == nil,
                            "Cleartext pattern \(pattern.label) leaked into \(relPath)"
                        )
                    }
                    if relPath != "manifest.json" {
                        #expect(relPath.hasSuffix(".enc"))
                        #expect(rawData.prefix(HistoryCrypto.archiveEntryMagic.count) == HistoryCrypto.archiveEntryMagic)
                        #expect(rawData.range(of: pngMagic) == nil, "PNG magic leaked into \(relPath)")
                        #expect(rawData.range(of: icoMagic) == nil, "ICO magic leaked into \(relPath)")
                    }
                }

                // Import into targetStore with a DISTINCT keyProvider using NFC passphrase!
                let targetStore = GRDBHistoryStore(directory: targetSupportDir, keyProvider: targetKeyProvider)
                defer { targetStore.close() }
                #expect(
                    sourceStore.computeImageDigest(forPNGData: plainImageBytes)
                        != targetStore.computeImageDigest(forPNGData: plainImageBytes)
                )

                let targetArchiveService = ClipBookArchiveService(
                    supportDirectory: targetSupportDir
                )
                try targetArchiveService.verifyPassphrase(nfcPassphrase, at: archiveURL)

                let importResult = try targetArchiveService.import(
                    from: archiveURL,
                    into: targetStore,
                    passphrase: nfcPassphrase
                )
                #expect(importResult.itemCount == 6)
                #expect(importResult.tagCount == 2)

                let importedTags = try targetStore.fetchTags()
                let tagIDByName = Dictionary(uniqueKeysWithValues: importedTags.map { ($0.name, $0.id) })
                let targetAlphaID = try #require(tagIDByName["VaultTagAlpha"])
                let targetBetaID = try #require(tagIDByName["VaultTagBeta"])

                let importedByID = Dictionary(uniqueKeysWithValues: try targetStore.fetchAll().map { ($0.id, $0) })
                let targetDBURL = targetSupportDir.appendingPathComponent("History.sqlite")

                // 1. Rich non-sensitive item: isEncrypted == 0, preserves tagOrders, favoriteOrder, HTML, and RTF.
                let importedRich = try targetStore.loadingContent(of: try #require(importedByID[richItem.id]), scope: .full)
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: richItem.id) == 0)
                #expect(importedRich.favoriteOrder == 4)
                #expect(importedRich.tagOrders == [targetAlphaID: 2, targetBetaID: 7])
                #expect(importedRich.html == richHTML)
                #expect(importedRich.rtfData == richRTF)

                // 2. Non-sensitive image & link-preview: sanitized .png / .ico extensions (NEVER .enc), isEncrypted == 0, keyed imageDigest.
                let importedPlainImage = try targetStore.loadingContent(of: try #require(importedByID[plainImageID]), scope: .body)
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: plainImageID) == 0)
                #expect(importedPlainImage.imageDigest == targetStore.computeImageDigest(forPNGData: plainImageBytes))
                #expect(importedPlainImage.imageDimensions?.width == 28)
                #expect(importedPlainImage.imageDimensions?.height == 20)
                let targetPlainImageURL = URL(fileURLWithPath: try #require(importedPlainImage.assetPath))
                #expect(targetPlainImageURL.pathExtension == "png")
                #expect(try Data(contentsOf: targetPlainImageURL) == plainImageBytes)

                let importedPlainLink = try #require(importedByID[plainLinkID])
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: plainLinkID) == 0)
                let targetPlainPreviewURL = URL(fileURLWithPath: try #require(importedPlainLink.linkPreviewDetails?.imagePath))
                let targetPlainFaviconURL = URL(fileURLWithPath: try #require(importedPlainLink.linkPreviewDetails?.faviconPath))
                #expect(targetPlainPreviewURL.pathExtension == "png")
                #expect(targetPlainFaviconURL.pathExtension == "ico")
                #expect(try Data(contentsOf: targetPlainPreviewURL) == plainPreviewBytes)
                #expect(try Data(contentsOf: targetPlainFaviconURL) == plainFaviconBytes)

                // 3. Sensitive image, sensitive link-preview, and secret text: .enc in TargetSupport, isEncrypted == 1, readable under targetStore's distinct key!
                let importedSensImage = try targetStore.loadingContent(of: try #require(importedByID[sensitiveImageID]), scope: .body)
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: sensitiveImageID) == 1)
                #expect(importedSensImage.tagOrders == [targetAlphaID: 1])
                #expect(importedSensImage.imageDigest == targetStore.computeImageDigest(forPNGData: sensitiveImageBytes))
                #expect(importedSensImage.text == "OCR Prefix \(secretOCRToken)")
                let targetSensImageURL = URL(fileURLWithPath: try #require(importedSensImage.assetPath))
                #expect(targetSensImageURL.pathExtension == "enc")
                #expect(try Data(contentsOf: targetSensImageURL).prefix(ImageAssetStore.encryptedMagic.count) == ImageAssetStore.encryptedMagic)
                #expect(
                    try ImageAssetStore.readAssetData(
                        at: targetSensImageURL,
                        role: .image,
                        ownerClipID: sensitiveImageID,
                        requiresEncryption: true
                    ) == sensitiveImageBytes
                )

                let importedSensLink = try #require(importedByID[sensitiveLinkID])
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: sensitiveLinkID) == 1)
                let targetSensPreviewURL = URL(fileURLWithPath: try #require(importedSensLink.linkPreviewDetails?.imagePath))
                let targetSensFaviconURL = URL(fileURLWithPath: try #require(importedSensLink.linkPreviewDetails?.faviconPath))
                #expect(targetSensPreviewURL.pathExtension == "enc")
                #expect(targetSensFaviconURL.pathExtension == "enc")
                #expect(
                    try ImageAssetStore.readAssetData(
                        at: targetSensPreviewURL,
                        role: .linkPreview,
                        ownerClipID: sensitiveLinkID,
                        requiresEncryption: true
                    ) == sensitivePreviewBytes
                )
                #expect(
                    try ImageAssetStore.readAssetData(
                        at: targetSensFaviconURL,
                        role: .linkFavicon,
                        ownerClipID: sensitiveLinkID,
                        requiresEncryption: true
                    ) == sensitiveFaviconBytes
                )

                let importedSecretText = try targetStore.loadingContent(of: try #require(importedByID[secretTextItem.id]), scope: .body)
                #expect(try Self.queryIsEncrypted(at: targetDBURL, clipID: secretTextItem.id) == 1)
                #expect(importedSecretText.favoriteOrder == 1)
                #expect(importedSecretText.text == "API credential \(secretTextToken)")
            }
        }

        @Test
        func encryptedV2TamperKDFBoundsSymlinkContainmentAndMidTransactionRollbackChecks() throws {
            try TestSupport.withTemporaryDirectory { rootDir in
                let fileManager = FileManager.default
                let passphrase = "test-v2-archive-passphrase"

                let sourceSupportDir = rootDir.appendingPathComponent("Source", isDirectory: true)
                try fileManager.createDirectory(at: sourceSupportDir, withIntermediateDirectories: true)
                let sourceStore = GRDBHistoryStore(directory: sourceSupportDir, keyProvider: InMemoryDatabaseKeyProvider())
                defer { sourceStore.close() }

                let tag = try sourceStore.createTag(name: "SecTag", color: "#FF5722")
                let samplePNG = try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16, color: .systemRed)
                let clipID = UUID()
                let stagedImageURL = try sourceStore.writeManagedAsset(
                    pngData: samplePNG,
                    role: .image,
                    clipID: clipID,
                    encrypted: true
                )
                let seededItem = ClipboardItem.fixture(
                    id: clipID,
                    kind: .image,
                    title: "Protected Clip",
                    text: ["Authorization", ": Bearer ", "NEG_ARCHIVE_TOKEN_", "1122334455667788"].joined(),
                    assetPath: stagedImageURL.path,
                    copiedAt: Date(timeIntervalSince1970: 1_710_300_100),
                    tags: [tag.id],
                    sensitivity: .sensitive
                )
                _ = try sourceStore.saveAndReconcileItem(seededItem, convertingExternalAssets: false)

                let fastExportService = ClipBookArchiveService(
                    supportDirectory: sourceSupportDir,
                    kdfIterations: 1_000,
                    allowTestIterations: true
                )
                let baseArchiveURL = rootDir.appendingPathComponent("BaseV2.clipbookarchive", isDirectory: true)
                try fastExportService.export(
                    items: try sourceStore.fetchAll(),
                    tags: try sourceStore.fetchTags(),
                    to: baseArchiveURL,
                    passphrase: passphrase,
                    loadItem: { try sourceStore.loadingContent(of: $0, scope: .full) }
                )

                // 1. KDF iteration bounds: allowTestIterations == false rejects 1,000 and 50,000,000 with .invalidKeyParameters!
                do {
                    let strictExportLow = ClipBookArchiveService(
                        supportDirectory: sourceSupportDir,
                        kdfIterations: 1_000,
                        allowTestIterations: false
                    )
                    #expect(throws: ClipBookArchiveError.invalidKeyParameters) {
                        try strictExportLow.export(
                            items: [],
                            tags: [],
                            to: rootDir.appendingPathComponent("StrictLow.clipbookarchive", isDirectory: true),
                            passphrase: passphrase
                        )
                    }

                    let (strictDir, strictStore, _) = try Self.makeImportTarget(in: rootDir.appendingPathComponent("StrictTarget", isDirectory: true))
                    defer { strictStore.close() }
                    let strictImportService = ClipBookArchiveService(
                        supportDirectory: strictDir,
                        allowTestIterations: false
                    )
                    #expect(throws: ClipBookArchiveError.invalidKeyParameters) {
                        try strictImportService.verifyPassphrase(passphrase, at: baseArchiveURL)
                    }
                    #expect(throws: ClipBookArchiveError.invalidKeyParameters) {
                        _ = try strictImportService.import(from: baseArchiveURL, into: strictStore, passphrase: passphrase)
                    }

                    let hugeIterURL = rootDir.appendingPathComponent("HugeIter.clipbookarchive", isDirectory: true)
                    try fileManager.copyItem(at: baseArchiveURL, to: hugeIterURL)
                    let manifestFile = hugeIterURL.appendingPathComponent("manifest.json")
                    var manifestObj = try #require(
                        try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any]
                    )
                    var encObj = try #require(manifestObj["encryption"] as? [String: Any])
                    encObj["iterations"] = 50_000_000
                    manifestObj["encryption"] = encObj
                    try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
                        .write(to: manifestFile)

                    #expect(throws: ClipBookArchiveError.invalidKeyParameters) {
                        try strictImportService.verifyPassphrase(passphrase, at: hugeIterURL)
                    }
                    #expect(throws: ClipBookArchiveError.invalidKeyParameters) {
                        _ = try strictImportService.import(from: hugeIterURL, into: strictStore, passphrase: passphrase)
                    }
                }

                // 2. Passphrase & missing manifest negative checks (0 rows & 0 files written on failure).
                do {
                    let (checkDir, checkStore, _) = try Self.makeImportTarget(in: rootDir.appendingPathComponent("PassphraseChecks", isDirectory: true))
                    defer { checkStore.close() }
                    let fastTargetService = ClipBookArchiveService(
                        supportDirectory: checkDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )

                    #expect(throws: ClipBookArchiveError.emptyPassphrase) {
                        try fastExportService.export(
                            items: [],
                            tags: [],
                            to: rootDir.appendingPathComponent("EmptyPass.clipbookarchive", isDirectory: true),
                            passphrase: ""
                        )
                    }
                    #expect(throws: ClipBookArchiveError.emptyPassphrase) {
                        try fastTargetService.verifyPassphrase("", at: baseArchiveURL)
                    }
                    #expect(throws: ClipBookArchiveError.emptyPassphrase) {
                        _ = try fastTargetService.import(from: baseArchiveURL, into: checkStore, passphrase: "")
                    }
                    #expect(throws: ClipBookArchiveError.passphraseRequired) {
                        _ = try fastTargetService.import(from: baseArchiveURL, into: checkStore, passphrase: nil)
                    }
                    #expect(throws: ClipBookArchiveError.incorrectPassphrase) {
                        try fastTargetService.verifyPassphrase("wrong-passphrase", at: baseArchiveURL)
                    }
                    #expect(throws: ClipBookArchiveError.incorrectPassphrase) {
                        _ = try fastTargetService.import(from: baseArchiveURL, into: checkStore, passphrase: "wrong-passphrase")
                    }
                    #expect(try checkStore.fetchAll().isEmpty)
                    #expect(try checkStore.fetchTags().isEmpty)
                    #expect(((try? fileManager.contentsOfDirectory(atPath: checkDir.appendingPathComponent("Images").path)) ?? []).isEmpty)

                    let emptyFolderURL = rootDir.appendingPathComponent("EmptyFolder.clipbookarchive", isDirectory: true)
                    try fileManager.createDirectory(at: emptyFolderURL, withIntermediateDirectories: true)
                    #expect(throws: ClipBookArchiveError.missingFile("manifest.json")) {
                        _ = try fastTargetService.inspect(at: emptyFolderURL)
                    }
                    #expect(throws: ClipBookArchiveError.missingFile("manifest.json")) {
                        _ = try fastTargetService.import(from: emptyFolderURL, into: checkStore)
                    }
                }

                // 3. Manifest AAD tampering (exportedAt / appVersion), entry swapping, bit-flips & expectedAssets SHA-256 checks.
                do {
                    let (tamperDir, tamperStore, _) = try Self.makeImportTarget(in: rootDir.appendingPathComponent("TamperChecks", isDirectory: true))
                    defer { tamperStore.close() }
                    let tamperService = ClipBookArchiveService(
                        supportDirectory: tamperDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )

                    let tamperMutations: [(label: String, mutate: (URL) throws -> Void)] = [
                        (
                            label: "edit exportedAt in manifest.json",
                            mutate: { copyURL in
                                let manifestFile = copyURL.appendingPathComponent("manifest.json")
                                var obj = try #require(
                                    try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any]
                                )
                                obj["exportedAt"] = "2020-01-01T00:00:00Z"
                                try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                                    .write(to: manifestFile)
                            }
                        ),
                        (
                            label: "edit appVersion in manifest.json",
                            mutate: { copyURL in
                                let manifestFile = copyURL.appendingPathComponent("manifest.json")
                                var obj = try #require(
                                    try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any]
                                )
                                obj["appVersion"] = "99.99.99-tampered"
                                try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                                    .write(to: manifestFile)
                            }
                        ),
                        (
                            label: "swap tags.json.enc and history.json.enc",
                            mutate: { copyURL in
                                let tagsEnc = copyURL.appendingPathComponent("tags.json.enc")
                                let histEnc = copyURL.appendingPathComponent("history.json.enc")
                                let tagsBytes = try Data(contentsOf: tagsEnc)
                                let histBytes = try Data(contentsOf: histEnc)
                                try histBytes.write(to: tagsEnc)
                                try tagsBytes.write(to: histEnc)
                            }
                        ),
                        (
                            label: "flip 1 bit in history.json.enc",
                            mutate: { copyURL in
                                let histEnc = copyURL.appendingPathComponent("history.json.enc")
                                var bytes = try Data(contentsOf: histEnc)
                                let idx = bytes.count - 1
                                bytes[idx] ^= 0x01
                                try bytes.write(to: histEnc)
                            }
                        ),
                        (
                            label: "delete assets/images/<id>.enc",
                            mutate: { copyURL in
                                try fileManager.removeItem(
                                    at: copyURL.appendingPathComponent("assets/images/\(clipID.uuidString).enc")
                                )
                            }
                        ),
                        (
                            label: "modify 1 byte of assets/images/<id>.enc",
                            mutate: { copyURL in
                                let assetFile = copyURL.appendingPathComponent("assets/images/\(clipID.uuidString).enc")
                                var bytes = try Data(contentsOf: assetFile)
                                bytes[bytes.count - 1] ^= 0x80
                                try bytes.write(to: assetFile)
                            }
                        )
                    ]

                    for (index, mutation) in tamperMutations.enumerated() {
                        let copyURL = rootDir.appendingPathComponent("Tamper-\(index).clipbookarchive", isDirectory: true)
                        try fileManager.copyItem(at: baseArchiveURL, to: copyURL)
                        try mutation.mutate(copyURL)

                        let err = #expect(throws: ClipBookArchiveError.self, Comment(rawValue: mutation.label)) {
                            _ = try tamperService.import(from: copyURL, into: tamperStore, passphrase: passphrase)
                        }
                        var isCorrupted = false
                        if case .corruptedEncryptedArchive? = err {
                            isCorrupted = true
                        }
                        #expect(isCorrupted, Comment(rawValue: mutation.label))
                        #expect(try tamperStore.fetchAll().isEmpty)
                    }
                }

                // 4. Mid-transaction pre-existing <id_1>.enc backup-and-restore rollback test (v2 GCM tag tamper + v1 ../escape.png)!
                do {
                    let rollbackTargetDir = rootDir.appendingPathComponent("RollbackLiveTarget", isDirectory: true)
                    try fileManager.createDirectory(at: rollbackTargetDir, withIntermediateDirectories: true)
                    let rollbackStore = GRDBHistoryStore(directory: rollbackTargetDir, keyProvider: InMemoryDatabaseKeyProvider())
                    defer { rollbackStore.close() }
                    let rollbackService = ClipBookArchiveService(
                        supportDirectory: rollbackTargetDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )

                    let id1 = UUID()
                    let id2 = UUID()
                    let originalID1PNG = try TestSupport.makePNGData(pixelWidth: 18, pixelHeight: 18, color: .systemBlue)
                    let originalSecret = ["gh", "p_", "LIVE_ORIGINAL_TARGET_ASSET_998877665544"].joined()
                    let initialStageURL = try rollbackStore.writeManagedAsset(
                        pngData: originalID1PNG,
                        role: .image,
                        clipID: id1,
                        encrypted: true
                    )
                    let liveSeeded = try rollbackStore.saveAndReconcileItem(
                        ClipboardItem.fixture(
                            id: id1,
                            kind: .image,
                            title: "Live Original Title",
                            text: originalSecret,
                            assetPath: initialStageURL.path,
                            copiedAt: Date(timeIntervalSince1970: 1_710_310_000),
                            sensitivity: .sensitive
                        ),
                        convertingExternalAssets: false
                    )
                    let liveEncURL = URL(fileURLWithPath: try #require(liveSeeded.assetPath))
                    let originalEncOnDiskBytes = try Data(contentsOf: liveEncURL)

                    // Build a 2-item v2 archive where item 1 overwrites id1 inside performInTransaction and item 2 fails openArchiveEntry!
                    let stagingSourceDir = rootDir.appendingPathComponent("RollbackSource", isDirectory: true)
                    try fileManager.createDirectory(at: stagingSourceDir, withIntermediateDirectories: true)
                    let stagingSourceStore = GRDBHistoryStore(directory: stagingSourceDir, keyProvider: InMemoryDatabaseKeyProvider())
                    defer { stagingSourceStore.close() }

                    let replacementPNG1 = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemYellow)
                    let item2PNG = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 20, color: .systemPink)
                    let srcURL1 = try stagingSourceStore.writeManagedAsset(pngData: replacementPNG1, role: .image, clipID: id1, encrypted: true)
                    let srcURL2 = try stagingSourceStore.writeManagedAsset(pngData: item2PNG, role: .image, clipID: id2, encrypted: false)

                    let overwriteItem1 = ClipboardItem.fixture(
                        id: id1,
                        kind: .image,
                        title: "Overwritten Title Should Roll Back",
                        text: ["sk", "-proj-", "OVERWRITTEN_SECRET_SHOULD_ROLL_BACK_123456"].joined(),
                        assetPath: srcURL1.path,
                        copiedAt: Date(timeIntervalSince1970: 1_710_310_500),
                        sensitivity: .sensitive
                    )
                    let secondItem2 = ClipboardItem.fixture(
                        id: id2,
                        kind: .image,
                        title: "Second Item",
                        text: "Benign second image",
                        assetPath: srcURL2.path,
                        copiedAt: Date(timeIntervalSince1970: 1_710_310_400)
                    )

                    let midFailV2URL = rootDir.appendingPathComponent("MidFailV2.clipbookarchive", isDirectory: true)
                    let stagingExportService = ClipBookArchiveService(
                        supportDirectory: stagingSourceDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )
                    try stagingExportService.export(
                        items: [overwriteItem1, secondItem2],
                        tags: [],
                        to: midFailV2URL,
                        passphrase: passphrase
                    )

                    // Corrupt item 2's CBARC02\0 GCM tag and plant its new SHA-256 in history.json.enc expectedAssets
                    // so pre-transaction inventory checks pass and failure happens AFTER item 1 overwrites id1!
                    let rawManifestBytes = try Data(contentsOf: midFailV2URL.appendingPathComponent("manifest.json"))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

                    let v2Manifest = try decoder.decode(ClipBookArchiveManifest.self, from: rawManifestBytes)
                    let encMeta = try #require(v2Manifest.encryption)
                    let salt = try #require(Data(base64Encoded: encMeta.saltBase64))
                    let archiveKeys = try HistoryCrypto.deriveArchiveKeys(
                        passphrase: passphrase,
                        salt: salt,
                        iterations: encMeta.iterations,
                        archiveID: encMeta.archiveID,
                        allowTestIterations: true
                    )
                    let manifestDigest = Data(SHA256.hash(data: rawManifestBytes))

                    let item2RelPath = "assets/images/\(id2.uuidString).enc"
                    let item2EncFile = midFailV2URL.appendingPathComponent(item2RelPath)
                    var corruptedItem2Bytes = try Data(contentsOf: item2EncFile)
                    corruptedItem2Bytes[corruptedItem2Bytes.count - 1] ^= 0xFF
                    try corruptedItem2Bytes.write(to: item2EncFile)

                    let historyEncFile = midFailV2URL.appendingPathComponent("history.json.enc")
                    let openedHistoryBytes = try HistoryCrypto.openArchiveEntry(
                        Data(contentsOf: historyEncFile),
                        key: archiveKeys.aeadKey,
                        archiveID: encMeta.archiveID,
                        manifestDigest: manifestDigest,
                        relativePath: "history.json.enc"
                    )
                    var historyPayload = try decoder.decode(ClipBookEncryptedHistoryPayload.self, from: openedHistoryBytes)
                    #expect(historyPayload.items.map(\.id) == [id1, id2])
                    historyPayload.expectedAssets[item2RelPath] = ContentDigest.sha256(corruptedItem2Bytes)
                    let resealedHistory = try HistoryCrypto.sealArchiveEntry(
                        try encoder.encode(historyPayload),
                        key: archiveKeys.aeadKey,
                        archiveID: encMeta.archiveID,
                        manifestDigest: manifestDigest,
                        relativePath: "history.json.enc"
                    )
                    try resealedHistory.write(to: historyEncFile)

                    let v2Err = #expect(throws: ClipBookArchiveError.self) {
                        _ = try rollbackService.import(from: midFailV2URL, into: rollbackStore, passphrase: passphrase)
                    }
                    if case .corruptedEncryptedArchive? = v2Err {} else {
                        Issue.record("Expected .corruptedEncryptedArchive on mid-transaction v2 GCM failure, got \(String(describing: v2Err))")
                    }

                    // Verify live Images/<id1>.enc bytes AND SQLite row restored byte-for-byte!
                    #expect(try Data(contentsOf: liveEncURL) == originalEncOnDiskBytes)
                    #expect(!fileManager.fileExists(atPath: rollbackTargetDir.appendingPathComponent("Images/\(id2.uuidString).png").path))
                    #expect(!fileManager.fileExists(atPath: rollbackTargetDir.appendingPathComponent("Images/\(id2.uuidString).enc").path))
                    let supportEntriesAfterV2 = try fileManager.contentsOfDirectory(atPath: rollbackTargetDir.path)
                    #expect(!supportEntriesAfterV2.contains { $0.hasPrefix(".import-rollback-") })

                    let survivingAfterV2 = try rollbackStore.fetchAll()
                    #expect(survivingAfterV2.map(\.id) == [id1])
                    let hydratedAfterV2 = try rollbackStore.loadingContent(of: survivingAfterV2[0], scope: .body)
                    #expect(hydratedAfterV2.title == "Live Original Title")
                    #expect(hydratedAfterV2.text == originalSecret)
                    #expect(
                        try ImageAssetStore.readAssetData(
                            at: liveEncURL,
                            role: .image,
                            ownerClipID: id1,
                            requiresEncryption: true
                        ) == originalID1PNG
                    )

                    // Also test v1 mid-transaction rollback where item 1 overwrites id1 and item 2 has "../escape.png"!
                    let midFailV1URL = rootDir.appendingPathComponent("MidFailV1.clipbookarchive", isDirectory: true)
                    try Self.writeCustomArchive(
                        at: midFailV1URL,
                        items: [
                            (id: id1, kind: "image", text: overwriteItem1.text, assetPath: "assets/images/replacement.png"),
                            (id: id2, kind: "image", text: nil, assetPath: "../escape.png")
                        ],
                        setupFiles: { archiveDir in
                            try replacementPNG1.write(to: archiveDir.appendingPathComponent("assets/images/replacement.png"))
                        }
                    )
                    let v1Err = #expect(throws: ClipBookArchiveError.self) {
                        _ = try rollbackService.import(from: midFailV1URL, into: rollbackStore)
                    }
                    if case .invalidAssetPath? = v1Err {} else {
                        Issue.record("Expected .invalidAssetPath on v1 ../escape.png, got \(String(describing: v1Err))")
                    }

                    #expect(try Data(contentsOf: liveEncURL) == originalEncOnDiskBytes)
                    let survivingAfterV1 = try rollbackStore.fetchAll()
                    #expect(survivingAfterV1.map(\.id) == [id1])
                    #expect(try rollbackStore.loadingContent(of: survivingAfterV1[0], scope: .body).text == originalSecret)
                }

                // 5. Archive metadata/intermediate symlink rejection, export containment, cross-clip .enc AAD anti-transplant & atomic export!
                do {
                    let (symTargetDir, symTargetStore, symTargetService) = try Self.makeImportTarget(
                        in: rootDir.appendingPathComponent("SymTarget", isDirectory: true)
                    )
                    defer { symTargetStore.close() }
                    _ = symTargetDir

                    let outsideManifest = rootDir.appendingPathComponent("outside-manifest.json")
                    try Data(contentsOf: baseArchiveURL.appendingPathComponent("manifest.json")).write(to: outsideManifest)

                    // Symlinked manifest.json -> .invalidAssetPath
                    let symManifestArchive = rootDir.appendingPathComponent("SymManifest.clipbookarchive", isDirectory: true)
                    try fileManager.copyItem(at: baseArchiveURL, to: symManifestArchive)
                    try fileManager.removeItem(at: symManifestArchive.appendingPathComponent("manifest.json"))
                    try fileManager.createSymbolicLink(
                        at: symManifestArchive.appendingPathComponent("manifest.json"),
                        withDestinationURL: outsideManifest
                    )
                    #expect(throws: ClipBookArchiveError.invalidAssetPath("manifest.json")) {
                        _ = try symTargetService.inspect(at: symManifestArchive)
                    }
                    #expect(throws: ClipBookArchiveError.invalidAssetPath("manifest.json")) {
                        _ = try symTargetService.import(from: symManifestArchive, into: symTargetStore, passphrase: passphrase)
                    }

                    // Dangling symlink on tags.json -> .invalidAssetPath (checked before fileExists!)
                    let danglingTagsArchive = rootDir.appendingPathComponent("DanglingTags.clipbookarchive", isDirectory: true)
                    try Self.writeCustomArchive(at: danglingTagsArchive, items: [], setupFiles: { _ in })
                    try fileManager.removeItem(at: danglingTagsArchive.appendingPathComponent("tags.json"))
                    try fileManager.createSymbolicLink(
                        at: danglingTagsArchive.appendingPathComponent("tags.json"),
                        withDestinationURL: rootDir.appendingPathComponent("nonexistent-dangling-target.json")
                    )
                    #expect(throws: ClipBookArchiveError.invalidAssetPath("tags.json")) {
                        _ = try symTargetService.import(from: danglingTagsArchive, into: symTargetStore)
                    }

                    // Symlinked intermediate assets/images directory -> .invalidAssetPath
                    let symImagesDirArchive = rootDir.appendingPathComponent("SymImagesDir.clipbookarchive", isDirectory: true)
                    try fileManager.copyItem(at: baseArchiveURL, to: symImagesDirArchive)
                    let realOutsideImages = rootDir.appendingPathComponent("RealOutsideImages", isDirectory: true)
                    try fileManager.moveItem(
                        at: symImagesDirArchive.appendingPathComponent("assets/images"),
                        to: realOutsideImages
                    )
                    try fileManager.createSymbolicLink(
                        at: symImagesDirArchive.appendingPathComponent("assets/images"),
                        withDestinationURL: realOutsideImages
                    )
                    let fastSymTargetService = ClipBookArchiveService(
                        supportDirectory: symTargetDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )
                    let symImagesErr = #expect(throws: ClipBookArchiveError.self) {
                        _ = try fastSymTargetService.import(from: symImagesDirArchive, into: symTargetStore, passphrase: passphrase)
                    }
                    if case .invalidAssetPath? = symImagesErr {} else {
                        Issue.record("Expected .invalidAssetPath on symlinked assets/images, got \(String(describing: symImagesErr))")
                    }

                    // Export source containment & cross-clip .enc AAD anti-transplant checks!
                    let exportGuardDir = rootDir.appendingPathComponent("ExportGuardSupport", isDirectory: true)
                    let exportGuardImages = exportGuardDir.appendingPathComponent("Images", isDirectory: true)
                    let exportGuardPreviews = exportGuardDir.appendingPathComponent("LinkPreviews", isDirectory: true)
                    try fileManager.createDirectory(at: exportGuardImages, withIntermediateDirectories: true)
                    try fileManager.createDirectory(at: exportGuardPreviews, withIntermediateDirectories: true)

                    let devKeyProvider = FileDatabaseKeyProvider(supportDirectory: exportGuardDir)
                    let exportGuardStore = GRDBHistoryStore(directory: exportGuardDir, keyProvider: devKeyProvider)
                    defer { exportGuardStore.close() }
                    let victimID = UUID()
                    let victimEncURL = try exportGuardStore.writeManagedAsset(
                        pngData: samplePNG,
                        role: .image,
                        clipID: victimID,
                        encrypted: true
                    )
                    let devKeyURL = exportGuardDir.appendingPathComponent(".devkey")
                    #expect(fileManager.fileExists(atPath: devKeyURL.path))

                    let outsidePNG = rootDir.appendingPathComponent("outside-user-photo.png")
                    try samplePNG.write(to: outsidePNG)
                    let symlinkInsideImages = exportGuardImages.appendingPathComponent("symlink-inside.png")
                    try fileManager.createSymbolicLink(at: symlinkInsideImages, withDestinationURL: outsidePNG)
                    let wrongSubdirPreview = exportGuardImages.appendingPathComponent("wrong-subdir.png")
                    try samplePNG.write(to: wrongSubdirPreview)

                    let exportGuardService = ClipBookArchiveService(
                        supportDirectory: exportGuardDir,
                        kdfIterations: 1_000,
                        allowTestIterations: true
                    )

                    let badExportItems: [(label: String, item: ClipboardItem)] = [
                        (
                            label: "assetPath outside supportDirectory/Images",
                            item: .fixture(kind: .image, assetPath: outsidePNG.path)
                        ),
                        (
                            label: "assetPath pointing to supportDirectory/.devkey",
                            item: .fixture(kind: .image, assetPath: devKeyURL.path)
                        ),
                        (
                            label: "assetPath pointing through symlink inside Images/",
                            item: .fixture(kind: .image, assetPath: symlinkInsideImages.path)
                        ),
                        (
                            label: "linkPreviewDetails.imagePath outside LinkPreviews/",
                            item: .fixture(
                                kind: .link,
                                text: "https://example.com",
                                linkPreviewDetails: LinkPreviewDetails(
                                    url: "https://example.com",
                                    title: "Bad Preview",
                                    description: nil,
                                    imagePath: wrongSubdirPreview.path,
                                    faviconPath: nil,
                                    fetchedAt: Date(timeIntervalSince1970: 1_710_300_000)
                                )
                            )
                        )
                    ]

                    for (idx, badCase) in badExportItems.enumerated() {
                        let outURL = rootDir.appendingPathComponent("BlockedExport-\(idx).clipbookarchive", isDirectory: true)
                        let err = #expect(throws: ClipBookArchiveError.self, Comment(rawValue: badCase.label)) {
                            try exportGuardService.export(items: [badCase.item], tags: [], to: outURL)
                        }
                        if case .invalidAssetPath? = err {} else {
                            Issue.record("Expected .invalidAssetPath for \(badCase.label), got \(String(describing: err))")
                        }
                        #expect(!fileManager.fileExists(atPath: outURL.path))
                    }

                    // Non-sensitive (isEncrypted == 0) item pointing at another clip's Images/<victimID>.enc fails assetAAD!
                    let attackerItem = ClipboardItem.fixture(
                        id: UUID(),
                        kind: .image,
                        text: "Benign attacker clip",
                        assetPath: victimEncURL.path,
                        sensitivity: .notSensitive
                    )
                    #expect(!SensitiveContent.shouldEncryptAtRest(attackerItem))
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        try exportGuardService.export(
                            items: [attackerItem],
                            tags: [],
                            to: rootDir.appendingPathComponent("TransplantPlain.clipbookarchive", isDirectory: true),
                            passphrase: nil
                        )
                    }
                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        try exportGuardService.export(
                            items: [attackerItem],
                            tags: [],
                            to: rootDir.appendingPathComponent("TransplantV2.clipbookarchive", isDirectory: true),
                            passphrase: passphrase
                        )
                    }

                    // Failing export mid-flight (loadItem throwing) leaves an existing destination .clipbookarchive untouched!
                    let existingDestURL = rootDir.appendingPathComponent("ExistingIntact.clipbookarchive", isDirectory: true)
                    try fileManager.copyItem(at: baseArchiveURL, to: existingDestURL)
                    let preManifestBytes = try Data(contentsOf: existingDestURL.appendingPathComponent("manifest.json"))
                    let preHistoryEncBytes = try Data(contentsOf: existingDestURL.appendingPathComponent("history.json.enc"))

                    let unloadedFirst = ClipboardItem.fixture(kind: .text, text: "First Loaded Item")
                    var unloadedSecond = ClipboardItem.fixture(kind: .text, text: "Second Failing Item").unloadingContent()
                    unloadedSecond.title = "Unloaded Trigger"
                    #expect(!unloadedSecond.isContentLoaded)

                    #expect(throws: HistoryStoreError.authenticationFailed) {
                        try exportGuardService.export(
                            items: [unloadedFirst, unloadedSecond],
                            tags: [],
                            to: existingDestURL,
                            passphrase: passphrase,
                            loadItem: { _ in
                                throw HistoryStoreError.authenticationFailed
                            }
                        )
                    }
                    #expect(try Data(contentsOf: existingDestURL.appendingPathComponent("manifest.json")) == preManifestBytes)
                    #expect(try Data(contentsOf: existingDestURL.appendingPathComponent("history.json.enc")) == preHistoryEncBytes)
                }
            }
        }

        private static func encodedPatterns(for needle: String) -> [(label: String, bytes: Data)] {
            var patterns: [(String, Data)] = [
                ("utf8", Data(needle.utf8))
            ]
            if let utf16LE = needle.data(using: .utf16LittleEndian) {
                patterns.append(("utf16LE", utf16LE))
            }
            if let utf16BE = needle.data(using: .utf16BigEndian) {
                patterns.append(("utf16BE", utf16BE))
            }
            let rawUTF8 = Data(needle.utf8)
            for padLen in 0..<3 {
                let padded = Data(repeating: 0x41, count: padLen) + rawUTF8
                let b64 = padded.base64EncodedString()
                let dropLeadingChars = padLen == 0 ? 0 : 4
                let usableChars = ((padded.count) / 3) * 4 - dropLeadingChars
                if usableChars >= 8 {
                    let start = b64.index(b64.startIndex, offsetBy: dropLeadingChars)
                    let end = b64.index(start, offsetBy: usableChars)
                    patterns.append(("base64-align\(padLen)", Data(b64[start..<end].utf8)))
                }
            }
            return patterns
        }

        private static func queryIsEncrypted(at dbURL: URL, clipID: UUID) throws -> Int? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                throw HistoryStoreError.openFailed
            }
            defer { sqlite3_close(db) }
            let sql = "SELECT isEncrypted FROM clips WHERE id = '\(clipID.uuidString)' LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw TestSQLiteFixtureError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int(stmt, 0))
        }

        /// An empty support directory under `rootDir` with a store and an archive service on it.
        private static func makeImportTarget(
            in rootDir: URL
        ) throws -> (supportDir: URL, store: GRDBHistoryStore, service: ClipBookArchiveService) {
            let supportDir = rootDir.appendingPathComponent("Support", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            return (
                supportDir,
                GRDBHistoryStore(directory: supportDir, keyProvider: InMemoryDatabaseKeyProvider()),
                ClipBookArchiveService(supportDirectory: supportDir)
            )
        }

        private static func writeCustomArchive(
            at archiveURL: URL,
            items: [(id: UUID, kind: String, text: String?, assetPath: String?)],
            linkPreviews: [UUID: (imagePath: String?, faviconPath: String?)] = [:],
            setupFiles: (URL) throws -> Void
        ) throws {
            let fileManager = FileManager.default
            let imagesDir = archiveURL.appendingPathComponent("assets/images", isDirectory: true)
            let linkPreviewsDir = archiveURL.appendingPathComponent("assets/link-previews", isDirectory: true)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: linkPreviewsDir, withIntermediateDirectories: true)

            let manifest: [String: Any] = [
                "formatVersion": 1,
                "appName": "ClipBook",
                "exportedAt": "2026-10-30T12:00:00Z"
            ]
            let history: [[String: Any]] = items.map { entry in
                var dict: [String: Any] = [
                    "id": entry.id.uuidString,
                    "kind": entry.kind,
                    "filePaths": [String](),
                    "copiedAt": "2026-10-30T12:00:00Z",
                    "firstCopiedAt": "2026-10-30T12:00:00Z",
                    "byteSize": 16,
                    "isFavorite": false,
                    "tagIDs": [String](),
                    "tagNames": [String](),
                    "copyCount": 1
                ]
                if let text = entry.text {
                    dict["text"] = text
                }
                if let assetPath = entry.assetPath {
                    dict["assetPath"] = assetPath
                }
                if let preview = linkPreviews[entry.id] {
                    var details: [String: Any] = ["url": "https://example.com/page", "fetchedAt": "2026-10-30T12:00:00Z"]
                    details["imagePath"] = preview.imagePath
                    details["faviconPath"] = preview.faviconPath
                    dict["linkPreviewDetails"] = details
                }
                return dict
            }

            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
                .write(to: archiveURL.appendingPathComponent("manifest.json"))
            try Data("[]".utf8)
                .write(to: archiveURL.appendingPathComponent("tags.json"))
            try JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted])
                .write(to: archiveURL.appendingPathComponent("history.json"))

            try setupFiles(archiveURL)
        }
    }
}
