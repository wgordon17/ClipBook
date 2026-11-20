@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing

@Suite
enum PasteboardAndServicesTests {
    private static func makeRuntimeSecretToken(tag: String = "alpha") -> String {
        let raw = ["sk", "-proj-", tag, "-", String(repeating: "x9K2mP7q", count: 4)].joined()
        return raw
    }

    /// Reads `pasteboard` the way the monitor does on a poll.
    private static func readOutcome(
        from pasteboard: NSPasteboard,
        lastChangeCount: Int = -1,
        retriesUnchangedPasteboard: Bool = false,
        ignoresTransientContent: Bool = true,
        ignoresConcealedContent: Bool = true,
        ignoredApplicationEntries: [String] = [],
        frontmostApplication: FrontmostApplication? = nil,
        computeImageDigest: @escaping @Sendable (Data) -> String = ContentDigest.sha256,
        findStoredImage: @escaping @Sendable (String) -> StoredImage? = { _ in nil }
    ) -> PasteboardReadResult.Outcome {
        let request = PasteboardReadRequest(
            lastChangeCount: lastChangeCount,
            retriesUnchangedPasteboard: retriesUnchangedPasteboard,
            ignoresTransientContent: ignoresTransientContent,
            ignoresConcealedContent: ignoresConcealedContent,
            ignoredApplicationEntries: ignoredApplicationEntries,
            computeImageDigest: computeImageDigest,
            findStoredImage: findStoredImage,
            frontmostApplication: { frontmostApplication }
        )
        return PasteboardReader.read(request, from: pasteboard).outcome
    }

    /// Reads a fresh pasteboard that `fill` has written to.
    private static func readOutcome(
        ignoresTransientContent: Bool = true,
        ignoresConcealedContent: Bool = true,
        filling fill: (NSPasteboard) throws -> Void
    ) throws -> PasteboardReadResult.Outcome {
        try TestSupport.withUniquePasteboard { pasteboard in
            pasteboard.clearContents()
            try fill(pasteboard)
            return readOutcome(
                from: pasteboard,
                ignoresTransientContent: ignoresTransientContent,
                ignoresConcealedContent: ignoresConcealedContent
            )
        }
    }

    @Suite
    struct PasteboardReaderTests {
        @Test
        func readsPlainText() throws {
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setString("Hello plain world", forType: .string)
            }
            #expect(outcome.payload?.text == "Hello plain world")
        }

        @Test
        func readsRichTextWithItsAlternateFormats() throws {
            let rtfData = try TestSupport.makeRTFData(text: "Formatted Greeting")
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setData(rtfData, forType: .rtf)
                pasteboard.setString("<b>Formatted Greeting</b>", forType: .html)
                pasteboard.setString("Formatted Greeting", forType: .string)
            }
            let richText = try #require(outcome.payload?.richText)
            #expect(richText.plainText == "Formatted Greeting")
            #expect(richText.rtf == rtfData)
            #expect(richText.html == "<b>Formatted Greeting</b>")
        }

        @Test
        func readsRTFOnlyContentAsRichText() throws {
            let rtfData = try TestSupport.makeRTFData(text: "RTF fallback body")
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setData(rtfData, forType: .rtf)
            }
            let richText = try #require(outcome.payload?.richText)
            #expect(richText.plainText == "RTF fallback body")
            #expect(richText.rtf == rtfData)
        }

        @Test
        func readsHTMLOnlyContentAsRichTextWithMarkupStripped() throws {
            let markup = "<meta charset='utf-8'><style>p { color: red }</style><p>Tom &amp; <b>Jerry</b></p>"
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setString(markup, forType: .html)
            }
            let richText = try #require(outcome.payload?.richText)
            #expect(richText.plainText == "Tom & Jerry")
            #expect(richText.rtf == nil)
            #expect(richText.html == markup)
        }

        @Test(arguments: [
            (html: "<p>Hi</p><script>alert(1)</script><style>p { color: red }</style>Bye", text: "Hi\nBye"),
            (html: "<SCRIPT type='x'>x</Script >y", text: "y"),
            (html: "<scripture>Genesis</scripture>", text: "Genesis"),
            (html: "a<script>never closed", text: "anever closed"),
            (html: "<b>1 &lt; 2</b>", text: "1 < 2"),
            (html: "<p>One</p><p>Two</p>", text: "One\nTwo"),
            (html: "<div>A<br>B<br/>C</div>", text: "A\nB\nC"),
            (html: "<head><title>Title</title></head><body>Body</body>", text: "Body"),
            (html: "<header>Top</header>", text: "Top"),
            (html: "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>", text: "a\nb"),
            (html: "<p>Tom   and\n   Jerry</p>", text: "Tom and Jerry"),
            (html: "<pre>line1\n    line2\n\nline4</pre>", text: "line1\nline2\n\nline4"),
            (html: "<table><tr><td>Name</td><td>Age</td></tr><tr><td>Ann</td><td>30</td></tr></table>", text: "Name\tAge\nAnn\t30"),
            (html: "<!-- a <b>hidden</b> <script>x</script> -->Shown", text: "Shown")
        ])
        func htmlOnlyContentKeepsItsParagraphsAndLosesScriptsStylesAndTags(html: String, text: String) throws {
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setString(html, forType: .html)
            }
            #expect(try #require(outcome.payload?.richText).plainText == text)
        }

        @Test(arguments: [
            String(repeating: "<", count: 200_000) + "text",
            String(repeating: "<script ", count: 50_000) + "text",
            String(repeating: "<style>", count: 50_000) + "text"
        ])
        func htmlThatNeverClosesItsTagsIsReadInLinearTime(html: String) throws {
            let clock = ContinuousClock()
            var outcome: PasteboardReadResult.Outcome?
            let elapsed = try clock.measure {
                outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                    pasteboard.setString(html, forType: .html)
                }
            }
            #expect(elapsed < .seconds(5), "Reading took \(elapsed)")
            #expect(outcome?.payload?.richText?.plainText?.hasSuffix("text") == true)
        }

        @Test
        func whitespaceOnlyHTMLIsEmpty() throws {
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setString("<div><span>   </span></div>", forType: .html)
            }
            #expect(outcome.isEmpty, "\(outcome)")
        }

        @Test
        func anUnchangedPasteboardIsReadOnlyWhenARetryIsAsked() throws {
            TestSupport.withUniquePasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Copied text", forType: .string)
                let changeCount = pasteboard.changeCount

                let unchanged = PasteboardAndServicesTests.readOutcome(
                    from: pasteboard,
                    lastChangeCount: changeCount
                )
                #expect(unchanged.isUnchanged, "\(unchanged)")

                let retried = PasteboardAndServicesTests.readOutcome(
                    from: pasteboard,
                    lastChangeCount: changeCount,
                    retriesUnchangedPasteboard: true
                )
                #expect(retried.payload?.text == "Copied text")
            }
        }

        @Test
        func richTextThatAccompaniesABitmapIsNotReadAsAnImage() throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 16)
            let rtfSample = Data("{\\rtf1\\ansi\\deff0 Keynote Selection}".utf8)
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setData(pngData, forType: .png)
                pasteboard.setData(rtfSample, forType: .rtf)
                pasteboard.setString("Keynote Selection", forType: .string)
            }
            let richText = try #require(outcome.payload?.richText)
            #expect(richText.plainText == "Keynote Selection")
            #expect(richText.rtf == rtfSample)
        }

        @Test
        func aStandaloneImageIsStoredAndThenReusedByDigest() throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 16)
            let derivedKeys = ClipBookDerivedKeys(masterKey: SymmetricKey(size: .bits256))
            try TestSupport.withTemporaryDirectory { directory in
                try TestSupport.withUniquePasteboard { pasteboard in
                    pasteboard.clearContents()
                    pasteboard.setData(pngData, forType: .png)

                    let first = PasteboardAndServicesTests.readOutcome(
                        from: pasteboard,
                        computeImageDigest: { HistoryCrypto.imageDigest(forPNGData: $0, keys: derivedKeys) }
                    )
                    let firstImage = try #require(first.payload?.image)
                    #expect(!firstImage.reusesStoredFile)
                    #expect(firstImage.pngData == pngData)
                    #expect(firstImage.existingAssetPath == nil)
                    #expect(firstImage.pixelWidth == 20)
                    #expect(firstImage.pixelHeight == 16)
                    #expect(firstImage.byteSize == pngData.count)
                    let directoryEntries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                    #expect(directoryEntries.isEmpty, "PasteboardReader must never write plaintext PNG files to disk")

                    let storedURL = directory.appendingPathComponent("stored.enc")
                    try Data("CBENC01\0".utf8).write(to: storedURL)

                    let second = PasteboardAndServicesTests.readOutcome(
                        from: pasteboard,
                        computeImageDigest: { HistoryCrypto.imageDigest(forPNGData: $0, keys: derivedKeys) },
                        findStoredImage: { digest in
                            guard digest == firstImage.digest else { return nil }
                            return StoredImage(
                                assetPath: storedURL.path,
                                recognizedContent: RecognizedImageContent(text: "OCR Text", qrCodeText: "https://qr.example")
                            )
                        }
                    )
                    let reused = try #require(second.payload?.image)
                    #expect(reused.reusesStoredFile)
                    #expect(reused.pngData == nil)
                    #expect(reused.existingAssetPath == storedURL.path)
                    #expect(reused.recognizedContent.text == "OCR Text")
                    #expect(reused.recognizedContent.qrCodeText == "https://qr.example")

                    try FileManager.default.removeItem(at: storedURL)
                    let missingFallback = PasteboardAndServicesTests.readOutcome(
                        from: pasteboard,
                        computeImageDigest: { HistoryCrypto.imageDigest(forPNGData: $0, keys: derivedKeys) },
                        findStoredImage: { digest in
                            guard digest == firstImage.digest else { return nil }
                            return StoredImage(
                                assetPath: storedURL.path,
                                recognizedContent: RecognizedImageContent(text: "OCR Text", qrCodeText: nil)
                            )
                        }
                    )
                    let restaged = try #require(missingFallback.payload?.image)
                    #expect(!restaged.reusesStoredFile)
                    #expect(restaged.pngData == pngData)
                    #expect(restaged.existingAssetPath == nil)
                }
            }
        }

        @Test
        func readsCopiedFiles() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("note.txt")
                let fileData = Data("File payload content".utf8)
                try fileData.write(to: fileURL)

                let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                    #expect(pasteboard.writeObjects([fileURL as NSURL]))
                }
                let files = try #require(outcome.payload?.files)
                #expect(files.paths == [fileURL.path])
                #expect(files.byteSize == fileData.count)
            }
        }

        @Test
        func skipsContentClipBookWroteItself() throws {
            let outcome = try PasteboardAndServicesTests.readOutcome { pasteboard in
                pasteboard.setString("Internal ClipBook write", forType: .string)
                pasteboard.setString("1", forType: PasteboardReader.ghostType)
            }
            #expect(outcome.isSkipped, "\(outcome)")
        }

        private static let safari = FrontmostApplication(
            bundlePath: "/Applications/Safari.app",
            localizedName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        private static func readText(
            from application: FrontmostApplication?,
            ignoring entries: [String] = []
        ) throws -> PasteboardReadResult.Outcome {
            TestSupport.withUniquePasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Copied text", forType: .string)
                return PasteboardAndServicesTests.readOutcome(
                    from: pasteboard,
                    ignoredApplicationEntries: entries,
                    frontmostApplication: application
                )
            }
        }

        @Test
        func recordsTheFrontmostApplicationAsTheSourceOfTheCopy() throws {
            let content = try #require(try Self.readText(from: Self.safari).content)
            #expect(content.sourceAppName == "Safari")
            #expect(content.sourceBundleIdentifier == "com.apple.Safari")

            let anonymous = try #require(try Self.readText(from: nil).content)
            #expect(anonymous.sourceAppName == nil)
            #expect(anonymous.sourceBundleIdentifier == nil)
        }

        @Test(arguments: [
            (entries: ["/Applications/Safari.app"], isIgnored: true),
            (entries: ["Safari"], isIgnored: true),
            (entries: ["1Password", "/Applications/Safari.app"], isIgnored: true),
            (entries: ["/Applications/Notes.app", "Keychain Access"], isIgnored: false),
            (entries: [String](), isIgnored: false)
        ])
        func copiesMadeInAnIgnoredApplicationAreSkipped(entries: [String], isIgnored: Bool) throws {
            let outcome = try Self.readText(from: Self.safari, ignoring: entries)
            if isIgnored {
                #expect(outcome.isSkipped, "\(outcome)")
            } else {
                #expect(outcome.payload?.text == "Copied text")
            }
        }

        private static let transientMarker = "org.nspasteboard.TransientType"
        private static let concealedMarker = "org.nspasteboard.ConcealedType"

        @Test(arguments: [
            (marker: transientMarker, ignoresTransient: true, ignoresConcealed: true, isCaptured: false),
            (marker: transientMarker, ignoresTransient: false, ignoresConcealed: true, isCaptured: true),
            // Allowing one kind of marked content does not allow the other.
            (marker: transientMarker, ignoresTransient: true, ignoresConcealed: false, isCaptured: false),
            (marker: concealedMarker, ignoresTransient: true, ignoresConcealed: true, isCaptured: false),
            (marker: concealedMarker, ignoresTransient: true, ignoresConcealed: false, isCaptured: true),
            (marker: concealedMarker, ignoresTransient: false, ignoresConcealed: true, isCaptured: false)
        ])
        func contentWithAMarkerIsCapturedOnlyWhenItsKindIsAllowed(
            marker: String,
            ignoresTransient: Bool,
            ignoresConcealed: Bool,
            isCaptured: Bool
        ) throws {
            let outcome = try PasteboardAndServicesTests.readOutcome(
                ignoresTransientContent: ignoresTransient,
                ignoresConcealedContent: ignoresConcealed
            ) { pasteboard in
                pasteboard.setString("Marked snippet", forType: .string)
                pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            }
            if isCaptured {
                #expect(outcome.payload?.text == "Marked snippet")
            } else {
                #expect(outcome.isSkipped, "\(outcome)")
            }
        }
    }

    @Suite
    struct PasteServiceTests {
        @Test
        func copyingAnImageWritesTheFileBytesAndATIFFAlternative() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let pngURL = directory.appendingPathComponent("clip.png")
                let pngData = try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16)
                try pngData.write(to: pngURL)

                try TestSupport.withUniquePasteboard { pasteboard in
                    let service = PasteService(pasteboard: pasteboard, loadFormatting: { $0 })
                    try service.copy(ClipboardItem.fixture(kind: .image, text: nil, assetPath: pngURL.path), variant: .standard)

                    let item = try #require(pasteboard.pasteboardItems?.first)
                    #expect(item.data(forType: .png) == pngData)
                    #expect(item.data(forType: .tiff) != nil)
                }
            }
        }

        @Test
        func copyingFilesWritesTheirURLs() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("report.pdf")
                try TestSupport.makePDFData().write(to: fileURL)

                try TestSupport.withUniquePasteboard { pasteboard in
                    let service = PasteService(pasteboard: pasteboard, loadFormatting: { $0 })
                    try service.copy(ClipboardItem.fixture(kind: .file, text: nil, filePaths: [fileURL.path]), variant: .standard)

                    let urls = pasteboard.readObjects(
                        forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]
                    ) as? [URL]
                    #expect(urls?.map(\.standardizedFileURL.path) == [fileURL.standardizedFileURL.path])
                }
            }
        }

        @Test
        func copyMarksTheOnlyPasteboardItemForEveryKindAndVariant() throws {
            try TestSupport.withTemporaryDirectory { directory in
                let pngURL = directory.appendingPathComponent("clip.png")
                try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16).write(to: pngURL)
                let pdfURL = directory.appendingPathComponent("report.pdf")
                try TestSupport.makePDFData().write(to: pdfURL)
                let rtfData = try TestSupport.makeRTFData(text: "Rich body")
                let richItem = ClipboardItem.fixture(
                    kind: .richText,
                    text: "Rich body",
                    rtfData: rtfData,
                    html: "<b>Rich body</b>"
                )
                let cases: [(label: String, item: ClipboardItem, variant: PasteVariant, contentType: NSPasteboard.PasteboardType)] = [
                    ("text standard", .fixture(kind: .text, text: "Plain body"), .standard, .string),
                    ("text plainText", .fixture(kind: .text, text: "Plain body"), .plainText, .string),
                    ("link standard", .fixture(kind: .link, text: "https://example.com"), .standard, .string),
                    ("rich standard", richItem, .standard, .rtf),
                    ("rich html", richItem, .standard, .html),
                    ("rich plainText", richItem, .plainText, .string),
                    ("file filePath", .fixture(kind: .file, text: nil, filePaths: ["/path/to/report.txt"]), .filePath, .string),
                    ("image standard", .fixture(kind: .image, text: nil, assetPath: pngURL.path), .standard, .png),
                    ("file standard", .fixture(kind: .file, text: nil, filePaths: [pdfURL.path]), .standard, .fileURL)
                ]

                try TestSupport.withUniquePasteboard { pasteboard in
                    let service = PasteService(pasteboard: pasteboard, loadFormatting: { $0 })
                    for testCase in cases {
                        try service.copy(testCase.item, variant: testCase.variant)

                        let pasteboardItems = try #require(pasteboard.pasteboardItems, "\(testCase.label)")
                        #expect(pasteboardItems.count == 1, "\(testCase.label)")
                        let first = try #require(pasteboardItems.first)
                        #expect(first.string(forType: PasteboardMonitor.ghostType) == "1", "\(testCase.label)")
                        #expect(first.types.contains(testCase.contentType), "\(testCase.label)")
                        #expect(!first.types.contains(PasteboardReader.concealedType), "\(testCase.label) should omit ConcealedType on benign item")

                        let outcome = PasteboardAndServicesTests.readOutcome(from: pasteboard)
                        #expect(outcome.isSkipped, "PasteboardReader should skip the \(testCase.label) write: \(outcome)")
                    }

                    // An item with nothing to write leaves no pasteboard item behind,
                    // so the marker goes on the pasteboard itself.
                    try service.copy(ClipboardItem.fixture(kind: .richText, text: nil), variant: .standard)
                    #expect(pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")
                    #expect(pasteboard.pasteboardItems?.count == 1)
                }
            }
        }

        @Test
        func copyingEncryptedImageDecryptsPNGAndLazyTIFFAndStampsConcealedTypeAcrossSensitiveVariants() throws {
            let secretToken = PasteboardAndServicesTests.makeRuntimeSecretToken(tag: "paste")
            #expect(SensitiveContent.shouldEncryptAtRest(.fixture(kind: .text, text: secretToken)))

            try TestSupport.withTemporaryHistoryStore { store, supportDir in
                let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 18)
                let imageID = UUID()
                let encURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: imageID, encrypted: true)
                let rawEnc = try Data(contentsOf: encURL)
                #expect(rawEnc.starts(with: ImageAssetStore.encryptedMagic))
                #expect(rawEnc.firstRange(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil)

                let pdfURL = supportDir.appendingPathComponent("secret-\(secretToken).pdf")
                try TestSupport.makePDFData().write(to: pdfURL)
                let rtfData = try TestSupport.makeRTFData(text: "Header")

                let sensitiveImage = ClipboardItem.fixture(
                    id: imageID,
                    kind: .image,
                    text: "Token \(secretToken)",
                    assetPath: encURL.path,
                    sensitivity: .sensitive
                )
                let sensitiveRich = ClipboardItem.fixture(
                    kind: .richText,
                    text: "Rich body",
                    rtfData: rtfData,
                    html: "<a href='https://example.com?token=\(secretToken)'>Rich body</a>"
                )
                let sensitiveFile = ClipboardItem.fixture(
                    kind: .file,
                    text: nil,
                    filePaths: [pdfURL.path],
                    sensitivity: .sensitive
                )
                let notSensitiveOverride = ClipboardItem.fixture(
                    kind: .text,
                    text: "Override \(secretToken)",
                    sensitivity: .notSensitive
                )
                #expect(SensitiveContent.shouldEncryptAtRest(sensitiveImage))
                #expect(SensitiveContent.shouldEncryptAtRest(sensitiveRich))
                #expect(SensitiveContent.shouldEncryptAtRest(sensitiveFile))
                #expect(!SensitiveContent.shouldEncryptAtRest(notSensitiveOverride))

                let sensitiveCases: [(label: String, item: ClipboardItem, variant: PasteVariant)] = [
                    ("image standard", sensitiveImage, .standard),
                    ("image plainText", sensitiveImage, .plainText),
                    ("text standard", .fixture(kind: .text, text: "Bearer \(secretToken)"), .standard),
                    ("text plainText", .fixture(kind: .text, text: "Bearer \(secretToken)"), .plainText),
                    ("rich standard", sensitiveRich, .standard),
                    ("rich rich", sensitiveRich, .rich),
                    ("file standard", sensitiveFile, .standard),
                    ("file filePath", sensitiveFile, .filePath)
                ]

                try TestSupport.withUniquePasteboard { pasteboard in
                    let service = PasteService(pasteboard: pasteboard, loadFormatting: { $0 })

                    for entry in sensitiveCases {
                        try service.copy(entry.item, variant: entry.variant)
                        let items = try #require(pasteboard.pasteboardItems, "\(entry.label)")
                        #expect(items.count == 1, "\(entry.label)")
                        let pbItem = try #require(items.first, "\(entry.label)")
                        #expect(pbItem.string(forType: PasteboardMonitor.ghostType) == "1", "\(entry.label)")
                        #expect(pbItem.types.contains(PasteboardReader.concealedType), "\(entry.label) must carry ConcealedType")
                        if entry.label == "image standard" {
                            #expect(pbItem.data(forType: .png) == pngData)
                            #expect(pbItem.data(forType: .tiff) != nil)
                        }
                    }

                    // Explicit .notSensitive override omits ConcealedType.
                    try service.copy(notSensitiveOverride, variant: .standard)
                    let nonSensitivePB = try #require(pasteboard.pasteboardItems?.first)
                    #expect(!nonSensitivePB.types.contains(PasteboardReader.concealedType))

                    // copyText sets ConcealedType only when markAsConcealed is true.
                    try service.copyText("Concealed OCR line", markAsGhost: false, markAsConcealed: true)
                    #expect((pasteboard.types ?? []).contains(PasteboardReader.concealedType))
                    #expect(pasteboard.string(forType: PasteboardMonitor.ghostType) == nil)

                    try service.copyText("Benign OCR line", markAsGhost: true, markAsConcealed: false)
                    #expect(!(pasteboard.types ?? []).contains(PasteboardReader.concealedType))
                    #expect(pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")

                    // Transplanted clipB pointing at clipA's .enc throws unsupportedItem.
                    let transplanted = ClipboardItem.fixture(
                        id: UUID(),
                        kind: .image,
                        text: nil,
                        assetPath: encURL.path
                    )
                    #expect(throws: PasteServiceError.unsupportedItem) {
                        try service.copy(transplanted, variant: .standard)
                    }

                    // Verify Images/<id>.enc on disk is still encrypted.
                    let afterDisk = try Data(contentsOf: encURL)
                    #expect(afterDisk == rawEnc)
                }
            }
        }
    }

    /// Applies a capture to a real `AppModel` the way `AppCoordinator` does.
    @MainActor
    private final class MockMonitorDelegate: PasteboardMonitorDelegate {
        let model = AppModel()
        var capturedHistory: [(item: ClipboardItem, updatedItems: [ClipboardItem])] = []
        var recognizedEvents: [(id: ClipboardItem.ID, content: RecognizedImageContent)] = []

        var items: [ClipboardItem] { model.items }

        func pasteboardMonitor(
            _ monitor: PasteboardMonitor,
            didCapture item: ClipboardItem,
            updatedItems: [ClipboardItem]
        ) {
            capturedHistory.append((item: item, updatedItems: updatedItems))
            updatedItems.forEach(model.replace)
            model.insert(item)
        }

        func pasteboardMonitor(
            _ monitor: PasteboardMonitor,
            didRecognize content: RecognizedImageContent,
            inItemWithID itemID: ClipboardItem.ID
        ) {
            recognizedEvents.append((id: itemID, content: content))
        }
    }

    private final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ initial: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.current = initial
        }
        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }
    }

    /// A monitor on its own store and pasteboard, a clock the test moves, and a delegate that records captures.
    @MainActor
    private final class MonitorFixture {
        let monitor: PasteboardMonitor
        let delegate = MockMonitorDelegate()
        let clock: MutableClock
        let store: GRDBHistoryStore
        let pasteboard: NSPasteboard
        let supportDirectory: URL

        init(
            monitor: PasteboardMonitor,
            clock: MutableClock,
            store: GRDBHistoryStore,
            pasteboard: NSPasteboard,
            supportDirectory: URL
        ) {
            self.monitor = monitor
            self.clock = clock
            self.store = store
            self.pasteboard = pasteboard
            self.supportDirectory = supportDirectory
            monitor.delegate = delegate
        }

        /// Hands the monitor what a poll would have read after `changeCount` changed, and waits
        /// until the delegate has heard about any capture it makes.
        func deliver(_ payload: PasteboardContent.Payload, changeCount: Int, isConcealed: Bool = false) async {
            monitor.processReadResultForTesting(
                PasteboardReadResult(
                    changeCount: changeCount,
                    outcome: .content(
                        PasteboardContent(
                            payload: payload,
                            sourceAppName: "Notes",
                            sourceBundleIdentifier: "com.apple.Notes",
                            isConcealed: isConcealed
                        )
                    )
                )
            )
            await PasteboardMonitor.deliveryOfCaptures()
        }

        func deliverUnchanged(changeCount: Int) async {
            monitor.processReadResultForTesting(PasteboardReadResult(changeCount: changeCount, outcome: .unchanged))
            await PasteboardMonitor.deliveryOfCaptures()
        }
    }

    @MainActor
    private static func withMonitor<T>(
        clockStart: TimeInterval = 1_700_000_000,
        preferences configurePreferences: ((inout AppPreferences) -> Void)? = nil,
        recognizeImageData: (@Sendable (Data) -> RecognizedImageContent)? = nil,
        recognizeImageFile: (@Sendable (URL) -> RecognizedImageContent)? = nil,
        _ body: (MonitorFixture) async throws -> T
    ) async throws -> T {
        try await TestSupport.withTemporaryDirectory { supportDirectory in
            let store = GRDBHistoryStore(
                directory: supportDirectory,
                keyProvider: InMemoryDatabaseKeyProvider()
            )
            defer { store.close() }
            return try await TestSupport.withUniquePasteboard { pasteboard in
                let clock = MutableClock(Date(timeIntervalSince1970: clockStart))
                let monitor = PasteboardMonitor(
                    historyStore: store,
                    fileManager: .default,
                    supportDirectory: supportDirectory,
                    pasteboard: pasteboard,
                    now: { clock.current },
                    recognizeImageData: recognizeImageData ?? ImageTextRecognizer.recognizeContent(ofPNGData:),
                    recognizeImageFile: recognizeImageFile ?? ImageTextRecognizer.recognizeContent(ofImageAt:)
                )
                defer { monitor.stop() }
                if let configurePreferences {
                    var preferences = AppPreferences()
                    configurePreferences(&preferences)
                    monitor.updatePreferences(preferences)
                }
                return try await body(
                    MonitorFixture(
                        monitor: monitor,
                        clock: clock,
                        store: store,
                        pasteboard: pasteboard,
                        supportDirectory: supportDirectory
                    )
                )
            }
        }
    }

    @Suite
    struct PasteboardMonitorTests {
        @Test
        @MainActor
        func contentCopiedWhilePausedIsNotCaptured() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                let (monitor, pasteboard, delegate) = (fixture.monitor, fixture.pasteboard, fixture.delegate)

                pasteboard.clearContents()
                pasteboard.setString("Before pause", forType: .string)
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.map(\.text) == ["Before pause"])

                monitor.isPaused = true
                pasteboard.clearContents()
                pasteboard.setString("Copied while paused", forType: .string)
                #expect(monitor.poll() == nil)

                monitor.isPaused = false
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.map(\.text) == ["Before pause"])

                pasteboard.clearContents()
                pasteboard.setString("After resume", forType: .string)
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.map(\.text) == ["After resume", "Before pause"])
            }
        }

        @Test
        @MainActor
        func pausingDropsDeferredRetryOfEarlierChange() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                let (monitor, pasteboard, delegate) = (fixture.monitor, fixture.pasteboard, fixture.delegate)

                // A change that yields nothing readable arms the deferred retry.
                pasteboard.clearContents()
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.isEmpty)

                monitor.isPaused = true
                pasteboard.setString("Copied while paused", forType: .string)
                monitor.isPaused = false

                // Without the reset the armed retry re-reads the pasteboard here.
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.isEmpty)
            }
        }

        @Test
        @MainActor
        func contentThatArrivesLateIsCapturedByTheDeferredRetry() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                let (monitor, pasteboard, delegate) = (fixture.monitor, fixture.pasteboard, fixture.delegate)

                // A change that yields nothing readable arms the deferred retry.
                pasteboard.clearContents()
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.isEmpty)

                pasteboard.setString("Arrived late", forType: .string)
                await monitor.pollAndWaitForDelivery()
                #expect(delegate.items.map(\.text) == ["Arrived late"])
            }
        }

        @Test
        @MainActor
        func aReadIsCapturedWhenNothingPausesTheMonitorMeanwhile() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setString("Copied", forType: .string)

                await fixture.monitor.pollAndWaitForDelivery()

                #expect(fixture.delegate.items.map(\.text) == ["Copied"])
            }
        }

        @Test
        @MainActor
        func pausingAbandonsAReadThatIsInFlight() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setString("Copied just before pausing", forType: .string)

                let read = fixture.monitor.poll()
                fixture.monitor.isPaused = true
                fixture.monitor.isPaused = false
                await read?.value
                await PasteboardMonitor.deliveryOfCaptures()

                #expect(fixture.delegate.items.isEmpty)
            }
        }

        @Test
        @MainActor
        func copyAndMergeStateMachine() async throws {
            try await PasteboardAndServicesTests.withMonitor(preferences: { preferences in
                preferences.copyAndMergeEnabled = true
                preferences.copyAndMergeSeparator = CopyAndMergeSeparatorPreference.space.rawValue
                preferences.copyToClipboardAfterMerge = true
            }) { fixture in
                fixture.clock.advance(by: 1)
                await fixture.deliver(.text("First"), changeCount: 1)
                #expect(fixture.delegate.capturedHistory.isEmpty)

                fixture.clock.advance(by: 0.6)
                await fixture.deliverUnchanged(changeCount: 1)
                #expect(fixture.delegate.capturedHistory.count == 1)
                #expect(fixture.delegate.items.first?.text == "First")

                // Double-copy within 0.5s merges into the previous item.
                fixture.clock.advance(by: 1)
                await fixture.deliver(.text("Second"), changeCount: 2)
                #expect(fixture.delegate.capturedHistory.count == 1)

                fixture.clock.advance(by: 0.1)
                await fixture.deliver(.text("Second"), changeCount: 3)
                #expect(fixture.delegate.capturedHistory.count == 2)
                #expect(fixture.delegate.items.first?.text == "First Second")
                #expect(fixture.pasteboard.string(forType: .string) == "First Second")
                #expect(fixture.pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")
            }
        }

        @Test
        @MainActor
        func copySequenceTracking() async throws {
            try await PasteboardAndServicesTests.withMonitor(
                clockStart: 1_700_000_000.75,
                preferences: { $0.copySequenceModeEnabled = true }
            ) { fixture in
                let delegate = fixture.delegate
                await fixture.deliver(.text("Seq A"), changeCount: 1)
                #expect(delegate.items.count == 1)
                #expect(delegate.items[0].copySequenceID == nil)
                #expect(delegate.items[0].copySequenceOrder == nil)

                fixture.clock.advance(by: 5)
                await fixture.deliver(.text("Seq B"), changeCount: 2)
                let expectedSequenceID = Date(timeIntervalSince1970: 1_700_000_000)
                #expect(delegate.items.count == 2)
                let itemB = try #require(delegate.items.first { $0.text == "Seq B" })
                let itemA = try #require(delegate.items.first { $0.text == "Seq A" })
                #expect(itemA.copySequenceID == expectedSequenceID)
                #expect(itemA.copySequenceOrder == 0)
                #expect(itemB.copySequenceID == expectedSequenceID)
                #expect(itemB.copySequenceOrder == 1)

                fixture.clock.advance(by: 1)
                fixture.monitor.markCopySequencePasteBoundary()
                fixture.clock.advance(by: 1)
                await fixture.deliver(.text("Seq C after paste"), changeCount: 3)
                let itemC = try #require(delegate.items.first { $0.text == "Seq C after paste" })
                #expect(itemC.copySequenceID == nil)
                #expect(itemC.copySequenceOrder == nil)

                fixture.clock.advance(by: 35)
                await fixture.deliver(.text("Seq D after 35s"), changeCount: 4)
                let itemD = try #require(delegate.items.first { $0.text == "Seq D after 35s" })
                #expect(itemD.copySequenceID == nil)
                #expect(itemD.copySequenceOrder == nil)
            }
        }

        @Test(arguments: [
            (text: "https://example.com/path", kind: ClipboardKind.link),
            (text: "user@example.com", kind: ClipboardKind.email),
            (text: "#FF5733", kind: ClipboardKind.color),
            (text: "General rich text paragraph", kind: ClipboardKind.richText)
        ])
        @MainActor
        func formattingIsKeptOnlyForRichText(text: String, kind: ClipboardKind) async throws {
            let rtf = try TestSupport.makeRTFData(text: "Rich")
            let html = "<a href=\"https://example.com\">https://example.com</a>"
            try await PasteboardAndServicesTests.withMonitor { fixture in
                await fixture.deliver(.richText(plainText: text, rtf: rtf, html: html), changeCount: 1)

                let captured = try #require(fixture.delegate.items.first)
                #expect(captured.kind == kind)
                if kind == .richText {
                    #expect(captured.hasFormatting)
                    #expect(captured.byteSize == rtf.count + html.utf8.count + text.utf8.count)
                } else {
                    #expect(captured.rtfData == nil)
                    #expect(captured.html == nil)
                    #expect(!captured.hasFormatting)
                    #expect(captured.byteSize == text.utf8.count)
                }
            }
        }

        @Test
        @MainActor
        func capturedItemsAreStampedWithTheMonitorsClock() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                fixture.clock.advance(by: 5)
                await fixture.deliver(.text("First"), changeCount: 1)
                #expect(fixture.delegate.items.first?.copiedAt == fixture.clock.current)

                let firstStamp = fixture.clock.current
                fixture.clock.advance(by: 90)
                await fixture.deliver(.text("Second"), changeCount: 2)
                let second = try #require(fixture.delegate.items.first)
                #expect(second.copiedAt == fixture.clock.current)
                #expect(second.copiedAt.timeIntervalSince(firstStamp) == 90)
            }
        }

        private static func fileContent(_ paths: [String]) -> PasteboardContent.Payload {
            .files(paths: paths, byteSize: 1, recognizedContent: .empty)
        }

        @Test
        @MainActor
        func textIsReadOnlyFromASingleCopiedImageFile() async throws {
            try await TestSupport.withTemporaryDirectory { directory in
                let imageURL = directory.appendingPathComponent("photo.png")
                try TestSupport.makePNGData().write(to: imageURL)

                try await PasteboardAndServicesTests.withMonitor { fixture in
                    // Neither a document nor several files is read for text.
                    await fixture.deliver(Self.fileContent([directory.appendingPathComponent("notes.txt").path]), changeCount: 1)
                    fixture.clock.advance(by: 1)
                    await fixture.deliver(Self.fileContent([imageURL.path, directory.appendingPathComponent("other.png").path]), changeCount: 2)
                    #expect(fixture.delegate.capturedHistory.count == 2)

                    // One image file is, and its result is delivered for that item. The reads
                    // run one after the other, so nothing is left over from the first two.
                    fixture.clock.advance(by: 1)
                    await fixture.deliver(Self.fileContent([imageURL.path]), changeCount: 3)
                    let imageItem = try #require(fixture.delegate.items.first)
                    #expect(imageItem.filePaths == [imageURL.path])

                    let arrived = await TestSupport.waitUntil { !fixture.delegate.recognizedEvents.isEmpty }
                    #expect(arrived)
                    #expect(fixture.delegate.recognizedEvents.map(\.id) == [imageItem.id])
                }
            }
        }

        @Test
        @MainActor
        func copyingAnImageFileAgainKeepsTheTextReadFromItBefore() async throws {
            try await TestSupport.withTemporaryDirectory { directory in
                let imageURL = directory.appendingPathComponent("scan.png")
                try TestSupport.makePNGData().write(to: imageURL)

                try await PasteboardAndServicesTests.withMonitor { fixture in
                    await fixture.deliver(Self.fileContent([imageURL.path]), changeCount: 1)
                    var stored = try #require(fixture.delegate.items.first)
                    _ = await TestSupport.waitUntil { !fixture.delegate.recognizedEvents.isEmpty }

                    // What the coordinator does with the recognized text.
                    stored.text = "Text read from the scan"
                    try fixture.store.upsert(stored)

                    fixture.clock.advance(by: 60)
                    await fixture.deliver(Self.fileContent([imageURL.path]), changeCount: 2)
                    let recopied = try #require(fixture.delegate.items.first)
                    #expect(recopied.id == stored.id)
                    #expect(recopied.text == "Text read from the scan")
                    #expect(recopied.copyCount == stored.copyCount + 1)
                }
            }
        }

        @Test
        @MainActor
        func captureNotifiesDelegateInOrder() async throws {
            try await PasteboardAndServicesTests.withMonitor { fixture in
                for (index, text) in ["First", "Second", "Third"].enumerated() {
                    fixture.clock.advance(by: 1)
                    await fixture.deliver(.text(text), changeCount: index + 1)
                    // The delegate has the item, and the store holds it, once the delivery has run.
                    #expect(fixture.delegate.capturedHistory.count == index + 1)
                    let stored = (try? fixture.store.fetchAll()) ?? []
                    #expect(stored.contains { $0.text == text })
                }
                #expect(fixture.delegate.capturedHistory.map(\.item.text) == ["First", "Second", "Third"])
            }
        }

        @Test
        @MainActor
        func imageCaptureSearchTextIncludesRecognizedContentAndSourceAppWithoutAssetPath() async throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 20, pixelHeight: 16)
            let id = UUID()
            try await PasteboardAndServicesTests.withMonitor(
                recognizeImageData: { _ in
                    RecognizedImageContent(text: "OCR Invoice", qrCodeText: "https://qr.example")
                }
            ) { fixture in
                await fixture.deliver(
                    .image(
                        id: id,
                        pngData: pngData,
                        existingAssetPath: nil,
                        pixelWidth: 20,
                        pixelHeight: 16,
                        byteSize: pngData.count,
                        recognizedContent: RecognizedImageContent(
                            text: "OCR Invoice",
                            qrCodeText: "https://qr.example"
                        ),
                        digest: fixture.store.computeImageDigest(forPNGData: pngData),
                        reusesStoredFile: false
                    ),
                    changeCount: 1
                )

                let captured = try #require(fixture.delegate.items.first)
                #expect(captured.id == id)
                #expect(captured.kind == .image)
                #expect(captured.searchText.contains("OCR Invoice"))
                #expect(captured.searchText.contains("https://qr.example"))
                #expect(captured.searchText.contains("Notes"))
                #expect(!captured.searchText.contains(id.uuidString))
                #expect(!captured.searchText.localizedCaseInsensitiveContains("png"))
                #expect(!captured.searchText.localizedCaseInsensitiveContains("enc"))
            }
        }

        @Test
        @MainActor
        func concealedImageWithDontSaveWritesZeroFilesToImagesDirectory() async throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 18)
            try await PasteboardAndServicesTests.withMonitor(
                preferences: { $0.confidentialContentLifetime = ContentLifetime.dontSave }
            ) { fixture in
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setData(pngData, forType: .png)
                fixture.pasteboard.setData(Data(), forType: PasteboardReader.concealedType)

                await fixture.monitor.pollAndWaitForDelivery()

                #expect(fixture.delegate.items.isEmpty)
                #expect((try? fixture.store.fetchAll())?.isEmpty == true)
                let imagesDir = fixture.supportDirectory.appendingPathComponent("Images", isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []
                #expect(files.isEmpty, "Concealed image with dontSave must write zero files to Images/")
            }
        }

        @Test
        @MainActor
        func recopyingImageWithMissingStoredFileRestagesUnderExistingIDWithoutAADMismatch() async throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 20)
            try await PasteboardAndServicesTests.withMonitor(
                recognizeImageData: { _ in RecognizedImageContent(text: "Receipt 42", qrCodeText: nil) }
            ) { fixture in
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setData(pngData, forType: .png)
                await fixture.monitor.pollAndWaitForDelivery()

                let original = try #require(fixture.delegate.items.first)
                let arrivedFirst = await TestSupport.waitUntil { !fixture.delegate.recognizedEvents.isEmpty }
                #expect(arrivedFirst)
                _ = try fixture.store.finalizeRecognizedImage(
                    id: original.id,
                    content: RecognizedImageContent(text: "Receipt 42", qrCodeText: nil),
                    sensitiveContentLifetime: ContentLifetime.keep
                )

                let storedAfterFirst = try #require(try fixture.store.fetchAll().first)
                let firstAssetPath = try #require(storedAfterFirst.assetPath)
                try FileManager.default.removeItem(atPath: firstAssetPath)
                #expect(!FileManager.default.fileExists(atPath: firstAssetPath))

                fixture.clock.advance(by: 10)
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setData(pngData, forType: .png)
                await fixture.monitor.pollAndWaitForDelivery()

                let recopied = try #require(fixture.delegate.items.first)
                #expect(recopied.id == original.id, "Re-copying missing-file image must re-stage under existing.id")
                let restagedPath = try #require(recopied.assetPath)
                #expect(restagedPath.hasSuffix("\(original.id.uuidString).enc"))
                #expect(FileManager.default.fileExists(atPath: restagedPath))

                let decrypted = try ImageAssetStore.readAssetData(
                    at: URL(fileURLWithPath: restagedPath),
                    role: .image,
                    ownerClipID: original.id,
                    requiresEncryption: true
                )
                #expect(decrypted == pngData)
            }
        }

        @Test
        @MainActor
        func doubleCopyingImageWhileCopyAndMergeEnabledPreservesPendingPNGDataThroughCaptureFallback() async throws {
            let pngData = try TestSupport.makePNGData(pixelWidth: 22, pixelHeight: 18)
            try await PasteboardAndServicesTests.withMonitor(
                preferences: {
                    $0.copyAndMergeEnabled = true
                    $0.copyToClipboardAfterMerge = true
                },
                recognizeImageData: { _ in RecognizedImageContent(text: "Double copy OCR", qrCodeText: nil) }
            ) { fixture in
                // Seed a text target so copyAndMergeTargetItem() is non-nil while copyAndMergedItem returns nil on .image.
                _ = try fixture.store.capture(.fixture(kind: .text, text: "Target text"), updatesCopySequence: false)

                fixture.clock.advance(by: 1)
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setData(pngData, forType: .png)
                await fixture.monitor.pollAndWaitForDelivery()
                #expect(fixture.delegate.capturedHistory.isEmpty, "First copy should be held for Copy & Merge window")

                // Double-copy the same image within the 0.5s hold window.
                fixture.clock.advance(by: 0.1)
                fixture.pasteboard.clearContents()
                fixture.pasteboard.setData(pngData, forType: .png)
                await fixture.monitor.pollAndWaitForDelivery()

                #expect(fixture.delegate.capturedHistory.count == 1)
                let captured = try #require(fixture.delegate.items.first)
                #expect(captured.kind == .image)
                let assetPath = try #require(captured.assetPath)
                #expect(assetPath.hasSuffix(".enc"))
                #expect(FileManager.default.fileExists(atPath: assetPath))

                let decrypted = try ImageAssetStore.readAssetData(
                    at: URL(fileURLWithPath: assetPath),
                    role: .image,
                    ownerClipID: captured.id,
                    requiresEncryption: true
                )
                #expect(decrypted == pngData)

                let ocrDone = await TestSupport.waitUntil { !fixture.delegate.recognizedEvents.isEmpty }
                #expect(ocrDone)
                #expect(fixture.delegate.recognizedEvents.first?.id == captured.id)
            }
        }

        @Test
        @MainActor
        func copyAndMergePropagatesConcealedTypeSensitivityMinimumExpiryAndStoredContentKey() async throws {
            let secretToken = PasteboardAndServicesTests.makeRuntimeSecretToken(tag: "merge")
            let longPrefix = String(repeating: "m", count: 9_000)
            try await PasteboardAndServicesTests.withMonitor(
                preferences: {
                    $0.copyAndMergeEnabled = true
                    $0.copyAndMergeSeparator = CopyAndMergeSeparatorPreference.space.rawValue
                    $0.copyToClipboardAfterMerge = true
                    $0.confidentialContentLifetime = 120
                    $0.sensitiveContentLifetime = 60
                }
            ) { fixture in
                fixture.clock.advance(by: 1)
                await fixture.deliver(.text(longPrefix), changeCount: 1, isConcealed: true)
                fixture.clock.advance(by: 0.6)
                await fixture.deliverUnchanged(changeCount: 1)

                let firstCaptured = try #require(fixture.delegate.capturedHistory.last?.item)
                #expect(firstCaptured.sensitivity == .sensitive)
                let firstExpiry = try #require(firstCaptured.expiresAt)

                // Double-copy a secret token within the hold window so it merges into the concealed item.
                fixture.clock.advance(by: 5)
                await fixture.deliver(.text(secretToken), changeCount: 2)
                fixture.clock.advance(by: 0.1)
                await fixture.deliver(.text(secretToken), changeCount: 3)

                let merged = try #require(fixture.delegate.capturedHistory.last?.item)
                #expect(merged.sensitivity == .sensitive)
                #expect(merged.storedContentKey != nil, ">8 KB Copy & Merge item must retain storedContentKey")
                let mergedExpiry = try #require(merged.expiresAt)
                #expect(mergedExpiry <= firstExpiry)
                #expect((fixture.pasteboard.types ?? []).contains(PasteboardReader.concealedType))
                #expect(fixture.pasteboard.string(forType: PasteboardMonitor.ghostType) == "1")
            }
        }
    }

    @Suite(.serialized)
    struct EncryptedAssetReadersAndDragTests {
        @Test
        @MainActor
        func encryptedAssetReadersRejectPlaintextDowngradeOverwriteAndCrossClipTransplant() async throws {
            TestSupport.ensureAppKitInitialized()
            try await TestSupport.withTemporaryDirectory { supportDir in
                let keyProvider = InMemoryDatabaseKeyProvider()
                let store = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                defer { store.close() }

                let pngData = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 24)
                let clipA = UUID()
                let clipB = UUID()
                let encURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: clipA, encrypted: true)
                let plainURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: clipB, encrypted: false)
                let linkClipID = UUID()
                let linkEncURL = try store.writeManagedAsset(pngData: pngData, role: .linkPreview, clipID: linkClipID, encrypted: true)
                let linkPlainClipID = UUID()
                let linkPlainURL = try store.writeManagedAsset(pngData: pngData, role: .linkPreview, clipID: linkPlainClipID, encrypted: false)

                @MainActor
                func makeOffscreenHostWindow(hosting card: LinkPreviewCardView) -> NSWindow {
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false
                    )
                    window.isReleasedWhenClosed = false
                    card.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
                    window.contentView = card
                    card.layoutSubtreeIfNeeded()
                    return window
                }

                @MainActor
                func revealedCardImages(in root: NSView) -> [NSImageView] {
                    let own = (root as? NSImageView).map { [$0] } ?? []
                    let children = root.subviews.flatMap { revealedCardImages(in: $0) }
                    return (own + children).filter { !$0.isHidden && $0.image != nil && $0.image?.isTemplate == false }
                }

                // 1. Valid owner-bound .enc reads succeed in ImageAssetStore, ImageAssetThumbnailLoader, and LinkPreviewCardView.
                let validData = try ImageAssetStore.readAssetData(
                    at: encURL,
                    role: .image,
                    ownerClipID: clipA,
                    requiresEncryption: true
                )
                #expect(validData == pngData)

                var decodedThumb: NSImage?
                var didFinishDecode = false
                let immediate = ImageAssetThumbnailLoader.shared.thumbnail(
                    for: encURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: clipA, requiresEncryption: true)
                ) { img in
                    decodedThumb = img
                    didFinishDecode = true
                }
                if let immediate {
                    decodedThumb = immediate
                    didFinishDecode = true
                }
                let thumbLoaded = await TestSupport.waitUntil { didFinishDecode }
                #expect(thumbLoaded)
                #expect(decodedThumb != nil)

                let validLinkPreview = LinkPreview(
                    url: try #require(URL(string: "https://example.com")),
                    title: "Encrypted Card",
                    description: "Preview",
                    image: nil,
                    favicon: nil,
                    imageURL: linkEncURL,
                    ownerClipID: linkClipID,
                    requiresEncryptedAssets: true
                )
                let validCard = LinkPreviewCardView(preview: validLinkPreview, layout: .vertical)
                let validHostWindow = makeOffscreenHostWindow(hosting: validCard)
                defer {
                    validHostWindow.contentView = nil
                    validHostWindow.close()
                }
                let cardLoaded = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    !revealedCardImages(in: validCard).isEmpty
                }
                #expect(cardLoaded)

                // 2. Pointing a sensitive item (requiresEncryption == true) at a plain .png fails closed.
                #expect(throws: HistoryStoreError.authenticationFailed) {
                    _ = try ImageAssetStore.readAssetData(
                        at: plainURL,
                        role: .image,
                        ownerClipID: clipB,
                        requiresEncryption: true
                    )
                }
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: plainURL.path)
                var downgradeThumb: NSImage? = NSImage(size: NSSize(width: 1, height: 1))
                var downgradeDone = false
                _ = ImageAssetThumbnailLoader.shared.thumbnail(
                    for: plainURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: clipB, requiresEncryption: true)
                ) { img in
                    downgradeThumb = img
                    downgradeDone = true
                }
                let waitedDowngrade = await TestSupport.waitUntil { downgradeDone }
                #expect(waitedDowngrade)
                #expect(downgradeThumb == nil)

                let downgradedLinkPreview = LinkPreview(
                    url: try #require(URL(string: "https://example.com")),
                    title: "Downgraded Card",
                    description: "Preview",
                    image: nil,
                    favicon: nil,
                    imageURL: linkPlainURL,
                    ownerClipID: linkPlainClipID,
                    requiresEncryptedAssets: true
                )
                let downgradedCard = LinkPreviewCardView(preview: downgradedLinkPreview, layout: .vertical)
                let downgradedHostWindow = makeOffscreenHostWindow(hosting: downgradedCard)
                defer {
                    downgradedHostWindow.contentView = nil
                    downgradedHostWindow.close()
                }
                try? await Task.sleep(for: .milliseconds(120))
                #expect(revealedCardImages(in: downgradedCard).isEmpty)

                // 3. Transplanting Images/<clipA>.enc onto clipB (even with requiresEncryption == false) fails AAD check.
                #expect(throws: HistoryStoreError.authenticationFailed) {
                    _ = try ImageAssetStore.readAssetData(
                        at: encURL,
                        role: .image,
                        ownerClipID: clipB,
                        requiresEncryption: false
                    )
                }
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: encURL.path)
                var transplantThumb: NSImage? = NSImage(size: NSSize(width: 1, height: 1))
                var transplantDone = false
                _ = ImageAssetThumbnailLoader.shared.thumbnail(
                    for: encURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: clipB, requiresEncryption: false)
                ) { img in
                    transplantThumb = img
                    transplantDone = true
                }
                let waitedTransplant = await TestSupport.waitUntil { transplantDone }
                #expect(waitedTransplant)
                #expect(transplantThumb == nil)

                let transplantedLinkPreview = LinkPreview(
                    url: try #require(URL(string: "https://example.com")),
                    title: "Transplanted Card",
                    description: "Preview",
                    image: nil,
                    favicon: nil,
                    imageURL: linkEncURL,
                    ownerClipID: clipB,
                    requiresEncryptedAssets: false
                )
                let transplantedCard = LinkPreviewCardView(preview: transplantedLinkPreview, layout: .vertical)
                let transplantedHostWindow = makeOffscreenHostWindow(hosting: transplantedCard)
                defer {
                    transplantedHostWindow.contentView = nil
                    transplantedHostWindow.close()
                }
                try? await Task.sleep(for: .milliseconds(120))
                #expect(revealedCardImages(in: transplantedCard).isEmpty)

                // 4. Overwriting Images/<clipA>.enc in place with raw .png bytes fails closed.
                try pngData.write(to: encURL, options: .atomic)
                #expect(throws: HistoryStoreError.authenticationFailed) {
                    _ = try ImageAssetStore.readAssetData(
                        at: encURL,
                        role: .image,
                        ownerClipID: clipA,
                        requiresEncryption: false
                    )
                }
            }
        }

        @Test
        @MainActor
        func thumbnailLoaderEvictsByEpochAndPreservesKeyRegistryAcrossOverlappingStoreReopen() async throws {
            try await TestSupport.withTemporaryDirectory { supportDir in
                let sharedKeyProvider = InMemoryDatabaseKeyProvider(key: SymmetricKey(size: .bits256))
                let store1 = GRDBHistoryStore(directory: supportDir, keyProvider: sharedKeyProvider)
                let pngData = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 32)
                let clipID = UUID()
                let encURL = try store1.writeManagedAsset(pngData: pngData, role: .image, clipID: clipID, encrypted: true)

                // Populate cache on store1.
                var loaded1: NSImage?
                var done1 = false
                if let cached = ImageAssetThumbnailLoader.shared.thumbnail(
                    for: encURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: clipID, requiresEncryption: true),
                    completion: { img in
                        loaded1 = img
                        done1 = true
                    }
                ) {
                    loaded1 = cached
                    done1 = true
                }
                #expect(await TestSupport.waitUntil { done1 })
                #expect(loaded1 != nil)
                #expect(
                    ImageAssetThumbnailLoader.shared.thumbnail(
                        for: encURL,
                        maximumPixelSize: 128,
                        assetContext: .init(role: .image, ownerClipID: clipID, requiresEncryption: true),
                        completion: { _ in }
                    ) != nil
                )

                // Epoch-safe eviction clears the cached thumbnail immediately.
                ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: encURL.path)
                let postEvictImmediate = ImageAssetThumbnailLoader.shared.thumbnail(
                    for: encURL,
                    maximumPixelSize: 128,
                    assetContext: .init(role: .image, ownerClipID: clipID, requiresEncryption: true),
                    completion: { _ in }
                )
                #expect(postEvictImmediate == nil)

                // Open store2 on the same supportDirectory BEFORE closing store1 (and let an extra ephemeral store deinit).
                let store2 = GRDBHistoryStore(directory: supportDir, keyProvider: sharedKeyProvider)
                defer { store2.close() }
                _ = try store2.fetchAll()

                do {
                    let transientStore = GRDBHistoryStore(directory: supportDir, keyProvider: sharedKeyProvider)
                    _ = try transientStore.fetchAll()
                    // Re-register store2 by writing/opening on store2, then close store1 and let transientStore deinit:
                    // wait — store2 opened before transientStore, so closing store1 must NOT unregister transientStore/store2!
                    store1.close()
                    transientStore.close()
                }

                // Re-open store3 after store1/transientStore closed and verify store2 closing cannot clobber store3!
                let store3 = GRDBHistoryStore(directory: supportDir, keyProvider: sharedKeyProvider)
                defer { store3.close() }
                _ = try store3.fetchAll()
                store2.close()

                let decryptedAfterStore2Close = try ImageAssetStore.readAssetData(
                    at: encURL,
                    role: .image,
                    ownerClipID: clipID,
                    requiresEncryption: true
                )
                #expect(decryptedAfterStore2Close == pngData, "Closing an older store instance must not unregister a newer store's keys")

                store3.close()
                #expect(throws: HistoryStoreError.encryptionKeyUnavailable(.notFound)) {
                    _ = try ImageAssetStore.readAssetData(
                        at: encURL,
                        role: .image,
                        ownerClipID: clipID,
                        requiresEncryption: true
                    )
                }
            }
        }

        @Test
        @MainActor
        func imageAssetDragItemAndImageDragFilesHardenDirectoryDecryptAuthorizedDragsRejectTamperAndScrubDotFiles() throws {
            defer { ImageDragFiles.removeAll() }

            try TestSupport.withTemporaryHistoryStore { store, _ in
                let pngData = try TestSupport.makePNGData(pixelWidth: 28, pixelHeight: 20)
                let clipA = UUID()
                let clipB = UUID()
                let encURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: clipA, encrypted: true)
                let plainURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: clipB, encrypted: false)
                let originalEncBytes = try Data(contentsOf: encURL)

                // 1. Authorized .enc drag provides decrypted PNG, TIFF, .fileURL, and ConcealedType while Images/<id>.enc stays encrypted.
                try TestSupport.withUniquePasteboard { pasteboard in
                    pasteboard.clearContents()
                    let dragItem = ImageAssetDragItem.make(
                        assetURL: encURL,
                        fileName: "SecretDiagram.png",
                        ownerClipID: clipA,
                        requiresEncryption: true
                    )
                    #expect(pasteboard.writeObjects([dragItem]))

                    let fileURLString = try #require(pasteboard.string(forType: .fileURL))
                    let draggedFileURL = try #require(URL(string: fileURLString))
                    let canonicalDragRoot = ImageDragFiles.directory.resolvingSymlinksInPath().standardizedFileURL
                    let canonicalDraggedFile = draggedFileURL.resolvingSymlinksInPath().standardizedFileURL
                    #expect(canonicalDraggedFile.path.hasPrefix(canonicalDragRoot.path + "/"))
                    #expect(try Data(contentsOf: draggedFileURL) == pngData)
                    #expect(pasteboard.data(forType: .png) == pngData)
                    #expect(pasteboard.data(forType: .tiff) != nil)
                    #expect((pasteboard.types ?? []).contains(PasteboardReader.concealedType))

                    // Verify 0o700 + isExcludedFromBackup on ImageDragFiles.directory, 0o700 on UUID subdir, and 0o600 on PNG file.
                    var rootStat = stat()
                    #expect(Darwin.lstat(ImageDragFiles.directory.path, &rootStat) == 0)
                    #expect((rootStat.st_mode & 0o777) == 0o700)
                    let rootValues = try ImageDragFiles.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    #expect(rootValues.isExcludedFromBackup == true)

                    var folderStat = stat()
                    #expect(Darwin.lstat(draggedFileURL.deletingLastPathComponent().path, &folderStat) == 0)
                    #expect((folderStat.st_mode & 0o777) == 0o700)

                    var fileStat = stat()
                    #expect(Darwin.lstat(draggedFileURL.path, &fileStat) == 0)
                    #expect((fileStat.st_mode & 0o777) == 0o600)

                    // Source .enc on disk remains untouched and encrypted.
                    #expect(try Data(contentsOf: encURL) == originalEncBytes)
                }

                // 2. Non-sensitive plain .png drag omits ConcealedType.
                try TestSupport.withUniquePasteboard { pasteboard in
                    pasteboard.clearContents()
                    let plainDrag = ImageAssetDragItem.make(
                        assetURL: plainURL,
                        fileName: "PublicPhoto.png",
                        ownerClipID: clipB,
                        requiresEncryption: false
                    )
                    #expect(pasteboard.writeObjects([plainDrag]))
                    #expect(pasteboard.string(forType: .fileURL) != nil)
                    #expect(pasteboard.data(forType: .png) == pngData)
                    #expect(!(pasteboard.types ?? []).contains(PasteboardReader.concealedType))
                }

                // 3. Transplanted / downgraded / tampered drag items attach NO .fileURL and yield nil PNG/TIFF data.
                try TestSupport.withUniquePasteboard { pasteboard in
                    pasteboard.clearContents()
                    let transplantedDrag = ImageAssetDragItem.make(
                        assetURL: encURL,
                        fileName: "Transplant.png",
                        ownerClipID: clipB,
                        requiresEncryption: false
                    )
                    #expect(transplantedDrag.string(forType: .fileURL) == nil)
                    #expect(pasteboard.writeObjects([transplantedDrag]))
                    #expect(pasteboard.string(forType: .fileURL) == nil)
                    #expect(pasteboard.data(forType: .png) == nil)
                    #expect(pasteboard.data(forType: .tiff) == nil)

                    pasteboard.clearContents()
                    let downgradedDrag = ImageAssetDragItem.make(
                        assetURL: plainURL,
                        fileName: "Downgrade.png",
                        ownerClipID: clipB,
                        requiresEncryption: true
                    )
                    #expect(downgradedDrag.string(forType: .fileURL) == nil)
                    #expect(pasteboard.writeObjects([downgradedDrag]))
                    #expect(pasteboard.data(forType: .png) == nil)
                }

                // 4. Dot-prefixed user title drag files (e.g. .env-keys.png) are enumerated with options: [] and zero-filled via secureUnlink on expiry AND removeAll.
                let expiredDotFileURL = try #require(
                    ImageDragFiles.makeCopy(
                        of: encURL,
                        named: ".env-keys.png",
                        ownerClipID: clipA,
                        requiresEncryption: true
                    )
                )
                #expect(expiredDotFileURL.lastPathComponent == ".env-keys.png")
                let expiredFD = Darwin.open(expiredDotFileURL.path, O_RDONLY)
                #expect(expiredFD >= 0)
                defer {
                    if expiredFD >= 0 { Darwin.close(expiredFD) }
                }

                let expiredFolder = expiredDotFileURL.deletingLastPathComponent()
                let twoHoursAgo = Date().addingTimeInterval(-7_200)
                try FileManager.default.setAttributes(
                    [.creationDate: twoHoursAgo, .modificationDate: twoHoursAgo],
                    ofItemAtPath: expiredFolder.path
                )
                ImageDragFiles.removeExpiredCopies(now: Date())
                #expect(!FileManager.default.fileExists(atPath: expiredDotFileURL.path))
                #expect(!FileManager.default.fileExists(atPath: expiredFolder.path))

                var scrubbedHeader = [UInt8](repeating: 0xFF, count: 16)
                let readExpiredBytes = Darwin.pread(expiredFD, &scrubbedHeader, scrubbedHeader.count, 0)
                #expect(readExpiredBytes == scrubbedHeader.count)
                #expect(scrubbedHeader.allSatisfy { $0 == 0 }, "Expired dot-prefixed drag file must be zero-filled via secureUnlink")

                let activeDotFileURL = try #require(
                    ImageDragFiles.makeCopy(
                        of: encURL,
                        named: ".env-keys.png",
                        ownerClipID: clipA,
                        requiresEncryption: true
                    )
                )
                let activeFD = Darwin.open(activeDotFileURL.path, O_RDONLY)
                #expect(activeFD >= 0)
                defer {
                    if activeFD >= 0 { Darwin.close(activeFD) }
                }

                ImageDragFiles.removeAll()
                #expect(!FileManager.default.fileExists(atPath: activeDotFileURL.path))
                #expect(!FileManager.default.fileExists(atPath: ImageDragFiles.directory.path))

                var scrubbedActiveHeader = [UInt8](repeating: 0xFF, count: 16)
                let readActiveBytes = Darwin.pread(activeFD, &scrubbedActiveHeader, scrubbedActiveHeader.count, 0)
                #expect(readActiveBytes == scrubbedActiveHeader.count)
                #expect(scrubbedActiveHeader.allSatisfy { $0 == 0 }, "removeAll must zero-fill dot-prefixed drag files via secureUnlink")
            }
        }

        @Test
        @MainActor
        func filePreviewCacheCancelsInFlightGenerationOnRemovePreviewsAndScrubsExistingFiles() async throws {
            try await TestSupport.withTemporaryDirectory { tempDir in
                let cacheDir = tempDir.appendingPathComponent("FilePreviews", isDirectory: true)
                let cache = FilePreviewCache(directory: cacheDir)

                let existingSource = tempDir.appendingPathComponent("existing.png")
                try TestSupport.makePNGData(pixelWidth: 64, pixelHeight: 64).write(to: existingSource)

                var generatedExisting = false
                _ = cache.image(
                    forFileAt: existingSource.path,
                    targetSize: CGSize(width: 32, height: 32)
                ) { _ in
                    generatedExisting = true
                }
                #expect(await TestSupport.waitUntil { generatedExisting })

                let cachedEntries = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
                let cachedPNG = try #require(cachedEntries.first { $0.pathExtension == "png" })
                let cachedFD = Darwin.open(cachedPNG.path, O_RDONLY)
                #expect(cachedFD >= 0)
                defer {
                    if cachedFD >= 0 { Darwin.close(cachedFD) }
                }

                cache.removePreviews(forFilePaths: [existingSource.path])
                let afterRemoveEntries = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
                #expect(afterRemoveEntries.isEmpty)

                var scrubbedPreviewBytes = [UInt8](repeating: 0xFF, count: 16)
                let readCount = Darwin.pread(cachedFD, &scrubbedPreviewBytes, scrubbedPreviewBytes.count, 0)
                #expect(readCount == scrubbedPreviewBytes.count)
                #expect(scrubbedPreviewBytes.allSatisfy { $0 == 0 }, "FilePreviewCache.removePreviews must zero-fill cached PNGs via secureUnlink")

                // Schedule an in-flight thumbnail generation for a large image and immediately cancel via removePreviews.
                let canceledSource = tempDir.appendingPathComponent("canceled-secret.png")
                try TestSupport.makePNGData(pixelWidth: 1_024, pixelHeight: 768).write(to: canceledSource)
                let barrierSource = tempDir.appendingPathComponent("barrier.png")
                try TestSupport.makePNGData(pixelWidth: 48, pixelHeight: 48).write(to: barrierSource)

                var canceledCompletionCalled = false
                _ = cache.image(
                    forFileAt: canceledSource.path,
                    targetSize: CGSize(width: 40, height: 40)
                ) { _ in
                    canceledCompletionCalled = true
                }
                cache.removePreviews(forFilePaths: [canceledSource.path])

                // Schedule a second image on the serial generationQueue so awaiting it drains the canceled work item.
                var barrierFinished = false
                _ = cache.image(
                    forFileAt: barrierSource.path,
                    targetSize: CGSize(width: 40, height: 40)
                ) { _ in
                    barrierFinished = true
                }
                #expect(await TestSupport.waitUntil { barrierFinished })
                #expect(!canceledCompletionCalled)

                let finalEntries = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
                // Only barrierSource's .png + .json (2 files) may exist; zero files for canceledSource!
                #expect(finalEntries.count == 2)
                for jsonURL in finalEntries where jsonURL.pathExtension == "json" {
                    let jsonText = String(decoding: (try? Data(contentsOf: jsonURL)) ?? Data(), as: UTF8.self)
                    #expect(!jsonText.contains("canceled-secret.png"))
                }
            }
        }
    }
}

extension PasteboardMonitor {
    /// Returns once the main-actor tasks the monitor has queued so far, which hand captures to
    /// its delegate, have run. The main actor runs its tasks in the order they were queued.
    @MainActor
    static func deliveryOfCaptures() async {
        await Task.yield()
    }

    /// Polls once and waits until the delegate has heard about what the read captured.
    @MainActor
    func pollAndWaitForDelivery() async {
        await poll()?.value
        await Self.deliveryOfCaptures()
    }
}

// Accessors that let a test state what it read in one `#expect` instead of a `guard case` per payload kind.
private extension PasteboardReadResult.Outcome {
    var content: PasteboardContent? {
        guard case .content(let content) = self else { return nil }
        return content
    }

    var payload: PasteboardContent.Payload? { content?.payload }

    var isUnchanged: Bool {
        if case .unchanged = self { true } else { false }
    }

    var isSkipped: Bool {
        if case .skipped = self { true } else { false }
    }

    var isEmpty: Bool {
        if case .empty = self { true } else { false }
    }
}

private extension PasteboardContent.Payload {
    var text: String? {
        if case .text(let text) = self { text } else { nil }
    }

    var richText: (plainText: String?, rtf: Data?, html: String?)? {
        if case .richText(let plainText, let rtf, let html) = self { (plainText, rtf, html) } else { nil }
    }

    var files: (paths: [String], byteSize: Int)? {
        if case .files(let paths, let byteSize, _) = self { (paths, byteSize) } else { nil }
    }

    var image: (
        id: UUID,
        pngData: Data?,
        existingAssetPath: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        byteSize: Int,
        digest: String,
        reusesStoredFile: Bool,
        recognizedContent: RecognizedImageContent
    )? {
        if case .image(
            let id,
            let pngData,
            let existingAssetPath,
            let pixelWidth,
            let pixelHeight,
            let byteSize,
            let recognizedContent,
            let digest,
            let reusesStoredFile
        ) = self {
            (
                id,
                pngData,
                existingAssetPath,
                pixelWidth,
                pixelHeight,
                byteSize,
                digest,
                reusesStoredFile,
                recognizedContent
            )
        } else {
            nil
        }
    }
}
