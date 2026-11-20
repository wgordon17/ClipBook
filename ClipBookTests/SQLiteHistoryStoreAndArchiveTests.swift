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
                    keyProvider: keyProvider,
                    loadsBodiesOnFetchAll: false
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
                    },
                    delete: { _ in errSecSuccess }
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
                        throw HistoryStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
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
                    throw HistoryStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
        }

        private static func queryText(at dbURL: URL, _ sql: String) throws -> String? {
            try withDatabase(at: dbURL) { db in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw HistoryStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
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

                let sourceImageURL = sourceSupportDir.appendingPathComponent("diagram.png")
                let sourcePreviewImageURL = sourceSupportDir.appendingPathComponent("og-image.png")
                let sourceFaviconURL = sourceSupportDir.appendingPathComponent("favicon.ico")
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
                    fileManager: fileManager,
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
                    fileManager: fileManager,
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
                #expect(importedImage.imageDigest == ContentDigest.sha256(imageBytes))
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

        /// An empty support directory under `rootDir` with a store and an archive service on it.
        private static func makeImportTarget(
            in rootDir: URL
        ) throws -> (supportDir: URL, store: GRDBHistoryStore, service: ClipBookArchiveService) {
            let supportDir = rootDir.appendingPathComponent("Support", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            return (
                supportDir,
                GRDBHistoryStore(directory: supportDir, keyProvider: InMemoryDatabaseKeyProvider()),
                ClipBookArchiveService(fileManager: .default, supportDirectory: supportDir)
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
