@testable import ClipBook
import AppKit
import Foundation
import Testing

@Suite
enum DomainAndSensitiveContentTests {
    @Suite
    struct ClipboardItemClassificationTests {
        @Test
        func htmlDigestDifferentiationAndCodingRoundTrip() throws {
            let itemOne = ClipboardItem.fixture(
                kind: .richText,
                text: "Hello",
                html: "<b>Bold Hello</b>"
            )
            let itemTwo = ClipboardItem.fixture(
                kind: .richText,
                text: "Hello",
                html: "<i>Italic Hello</i>"
            )

            #expect(itemOne.htmlDigest != nil)
            #expect(itemTwo.htmlDigest != nil)
            #expect(itemOne.htmlDigest != itemTwo.htmlDigest)
            #expect(itemOne.contentKey != itemTwo.contentKey)
            #expect(!itemOne.hasSameContent(as: itemTwo))

            let unloadedOne = itemOne.unloadingContent()
            let unloadedTwo = itemTwo.unloadingContent()
            #expect(!unloadedOne.isContentLoaded)
            #expect(!unloadedOne.isFormattingLoaded)
            #expect(unloadedOne.hasFormatting)
            #expect(unloadedOne.htmlDigest == itemOne.htmlDigest)
            #expect(!unloadedOne.hasSameContent(as: unloadedTwo))

            let encoded = try JSONEncoder().encode(itemOne)
            let decoded = try JSONDecoder().decode(ClipboardItem.self, from: encoded)
            #expect(decoded.htmlDigest == itemOne.htmlDigest)
            #expect(decoded.contentKey == itemOne.contentKey)

            var stripped = itemOne
            stripped.removeFormatting()
            #expect(!stripped.hasFormatting)
            #expect(stripped.htmlDigest == nil)
        }

        @Test
        func normalizedLinkContentKeyIgnoresFragmentAndCase() throws {
            let introURL = try #require(URL(string: "HTTPS://Example.COM/docs#intro"))
            let apiURL = try #require(URL(string: "https://example.com/docs#api"))

            #expect(ClipboardItem.normalizedLinkContentKey(for: introURL) == "https://example.com/docs")
            #expect(ClipboardItem.normalizedLinkContentKey(for: apiURL) == "https://example.com/docs")

            let introItem = ClipboardItem.fixture(kind: .link, text: "https://example.com/docs#intro")
            let apiItem = ClipboardItem.fixture(kind: .link, text: "https://example.com/docs#api")
            #expect(introItem.hasSameContent(as: apiItem))
        }

        @Test(
            arguments: [
                ("https://example.com/path?x=1#sec", true),
                ("http://localhost:8080/health", true),
                ("http://127.0.0.1:3000", true),
                ("http://[::1]:8080/test", true),
                ("https://example.com/with space", false),
                ("   ", false),
            ]
        )
        func linkURLValidation(input: String, isValid: Bool) {
            if isValid {
                #expect(ClipboardItem.linkURL(from: input) != nil)
            } else {
                #expect(ClipboardItem.linkURL(from: input) == nil)
            }
        }

        @Test
        func filePreviewTextAndMissingSingleFileCheck() throws {
            try TestSupport.withTemporaryDirectory { tempDir in
                let existingFileURL = tempDir.appendingPathComponent("diagram.png")
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: existingFileURL)
                let missingFileURL = tempDir.appendingPathComponent("deleted.png")

                let fileItemWithOCR = ClipboardItem.fixture(
                    kind: .file,
                    text: "Recognized OCR text inside image file",
                    filePaths: [existingFileURL.path]
                )
                #expect(fileItemWithOCR.previewText == existingFileURL.path)
                #expect(!fileItemWithOCR.isMissingSingleFileItem)

                let missingFileItem = ClipboardItem.fixture(
                    kind: .file,
                    text: nil,
                    filePaths: [missingFileURL.path]
                )
                #expect(missingFileItem.isMissingSingleFileItem)
            }
        }

        @Test(
            arguments: [
                ("@scope/pkg@1.0.0", false, ClipboardKind.text),
                ("user@localhost", false, ClipboardKind.text),
                ("user@example.com", false, ClipboardKind.email),
                ("first.last+tag@mail.example.co.uk", false, ClipboardKind.email),
                ("müller@example.de", false, ClipboardKind.email),
                ("mu\u{308}ller@example.de", false, ClipboardKind.email),
                ("info@münchen.de", false, ClipboardKind.email),
                ("user@例え.jp", false, ClipboardKind.email),
                ("https://clipbook.app/docs", false, ClipboardKind.link),
                ("#ff8800", false, ClipboardKind.color),
                ("ff8800", false, ClipboardKind.text),
                ("ff8800", true, ClipboardKind.color),
                ("rgb(12, 34, 56)", false, ClipboardKind.color),
            ]
        )
        func classifyText(
            input: String,
            treatDigitNumbersAsColor: Bool,
            expected: ClipboardKind
        ) {
            #expect(
                ClipboardKind.classifyText(input, treatDigitNumbersAsColor: treatDigitNumbersAsColor) == expected
            )
        }

        @Test
        func unloadedHeadersSearchRevisionAndContentKeyInvalidation() {
            let copiedAt = Date(timeIntervalSince1970: 1_700_000_100)
            var loaded = ClipboardItem(
                kind: .text,
                title: "Notes",
                text: "Initial body",
                qrCodeText: nil,
                filePaths: [],
                sourceAppName: "Editor",
                sourceBundleIdentifier: "com.example.editor",
                copiedAt: copiedAt,
                byteSize: 12,
                tags: [1, 2],
                tagOrders: [1: 0, 2: 4, 99: 7]
            )
            #expect(loaded.searchRevision > 0)
            #expect(loaded.tagOrders == [1: 0, 2: 4])
            loaded.storedContentKey = Data(repeating: 0xAA, count: 32)

            let initialRevision = loaded.searchRevision
            let unloaded = loaded.unloadingContent()
            #expect(!unloaded.isContentLoaded)
            #expect(unloaded.text == nil)
            #expect(unloaded.qrCodeText == nil)
            #expect(unloaded.html == nil)
            #expect(unloaded.rtfData == nil)
            #expect(unloaded.searchText == "")
            #expect(unloaded.searchRevision == initialRevision)
            #expect(unloaded.storedContentKey == Data(repeating: 0xAA, count: 32))
            #expect(unloaded.tagOrders == [1: 0, 2: 4])

            let rebuiltUnloaded = unloaded.rebuildingSearchText(tagNames: ["Work", "Infra"])
            #expect(!rebuiltUnloaded.isContentLoaded)
            #expect(rebuiltUnloaded.searchText == "")
            #expect(rebuiltUnloaded.searchRevision > unloaded.searchRevision)

            let headerOne = ClipboardItem.fromStoredHeader(
                id: loaded.id,
                kind: .text,
                title: "Notes",
                textPreview: "Initial body",
                characterCount: 12,
                containsPreviewSecret: false,
                containsRestSecret: false,
                hasRecognizedText: true,
                hasQRCodeText: false,
                isSVGText: false,
                hasFormatting: false,
                htmlDigest: nil,
                imageDigest: nil,
                imageWidth: nil,
                imageHeight: nil,
                assetPath: nil,
                filePaths: [],
                sourceAppName: "Editor",
                sourceBundleIdentifier: "com.example.editor",
                copiedAt: copiedAt,
                firstCopiedAt: copiedAt,
                byteSize: 12,
                isFavorite: false,
                tags: [1, 2],
                tagOrders: [1: 3, 999: 1],
                copyCount: 1,
                linkPreviewDetails: nil,
                copySequenceID: nil,
                copySequenceOrder: nil,
                favoriteOrder: nil,
                sensitivity: nil,
                expiresAt: nil,
                deletedAt: nil,
                storedContentKey: Data(repeating: 0xBB, count: 32)
            )
            let headerTwo = ClipboardItem.fromStoredHeader(
                id: loaded.id,
                kind: .text,
                title: "Notes",
                textPreview: "Initial body",
                characterCount: 12,
                containsPreviewSecret: false,
                containsRestSecret: false,
                hasRecognizedText: true,
                hasQRCodeText: false,
                isSVGText: false,
                hasFormatting: false,
                htmlDigest: nil,
                imageDigest: nil,
                imageWidth: nil,
                imageHeight: nil,
                assetPath: nil,
                filePaths: [],
                sourceAppName: "Editor",
                sourceBundleIdentifier: "com.example.editor",
                copiedAt: copiedAt,
                firstCopiedAt: copiedAt,
                byteSize: 12,
                isFavorite: false,
                tags: [1, 2],
                tagOrders: [1: 3],
                copyCount: 1,
                linkPreviewDetails: nil,
                copySequenceID: nil,
                copySequenceOrder: nil,
                favoriteOrder: nil,
                sensitivity: nil,
                expiresAt: nil,
                deletedAt: nil,
                storedContentKey: Data(repeating: 0xBB, count: 32)
            )
            #expect(!headerOne.isContentLoaded)
            #expect(headerOne.searchText == "")
            #expect(headerOne.tagOrders == [1: 3])
            #expect(headerOne.searchRevision > rebuiltUnloaded.searchRevision)
            #expect(headerTwo.searchRevision > headerOne.searchRevision)
            #expect(headerOne == headerTwo)
            #expect(headerOne.hashValue == headerTwo.hashValue)

            // Mutating any content-key input clears storedContentKey to nil.
            var textMutated = loaded
            textMutated.text = "Updated body"
            #expect(textMutated.storedContentKey == nil)
            #expect(textMutated.searchRevision > headerTwo.searchRevision)

            var kindMutated = loaded
            kindMutated.kind = .richText
            #expect(kindMutated.storedContentKey == nil)

            var filePathsMutated = loaded
            filePathsMutated.filePaths = ["/Users/alice/Documents/file.txt"]
            #expect(filePathsMutated.storedContentKey == nil)

            var formattingMutated = loaded
            formattingMutated.setFormatting(html: "<b>Initial body</b>", rtfData: nil)
            #expect(formattingMutated.storedContentKey == nil)

            var imageDigestMutated = loaded
            imageDigestMutated.imageDigest = "digest-2"
            #expect(imageDigestMutated.storedContentKey == nil)

            var assetPathMutated = loaded
            assetPathMutated.assetPath = "/Users/alice/Pictures/frame.png"
            #expect(assetPathMutated.storedContentKey == nil)

            // searchRevision increments on search-field mutations and rebuilds without breaking ==.
            let baseItem = ClipboardItem(
                kind: .text,
                title: "Same",
                text: "Unchanged content",
                copiedAt: copiedAt,
                byteSize: 17,
                tags: [1, 2],
                tagOrders: [1: 0, 2: 1],
                expiresAt: copiedAt.addingTimeInterval(60)
            )
            let rebuiltSame = baseItem.rebuildingSearchText(tagNames: [])
            #expect(rebuiltSame.searchRevision > baseItem.searchRevision)
            #expect(rebuiltSame == baseItem)
            #expect(rebuiltSame.hashValue == baseItem.hashValue)

            var tagMutated = baseItem
            let beforeTagRevision = tagMutated.searchRevision
            tagMutated.tags = [2]
            #expect(tagMutated.searchRevision > beforeTagRevision)
            #expect(tagMutated.tagOrders == [2: 1])
            #expect(tagMutated.expiresAt == nil)
        }

        @Test
        func withLoadedContentScopesPreserveFormattingFlagsAndKeyedHTMLDigest() throws {
            let htmlSecret = ["<a href=\"https://u", ":", "pass12345", "@example.com\">Hello</a>"].joined()
            let rtfData = try TestSupport.makeRTFData(text: "Hello")
            let richItem = ClipboardItem.fixture(
                kind: .richText,
                text: "Hello",
                rtfData: rtfData,
                html: htmlSecret
            )
            let originalHTMLDigest = try #require(richItem.htmlDigest)
            #expect(richItem.hasFormatting)
            #expect(richItem.isFormattingLoaded)
            #expect(richItem.isPreviewFormattingLoaded)
            #expect(richItem.containsRestSecret)

            let unloaded = richItem.unloadingContent()
            #expect(!unloaded.isContentLoaded)
            #expect(unloaded.hasFormatting)
            #expect(!unloaded.isFormattingLoaded)
            #expect(!unloaded.isPreviewFormattingLoaded)
            #expect(unloaded.htmlDigest == originalHTMLDigest)
            #expect(unloaded.containsRestSecret)

            let bodyScope = unloaded.withLoadedContent(
                text: "Hello",
                qrCodeText: nil,
                scope: .body
            )
            #expect(bodyScope.isContentLoaded)
            #expect(bodyScope.hasFormatting)
            #expect(bodyScope.htmlDigest == originalHTMLDigest)
            #expect(bodyScope.containsRestSecret)
            #expect(!bodyScope.isPreviewFormattingLoaded)
            #expect(!bodyScope.isFormattingLoaded)
            #expect(bodyScope.rtfData == nil)
            #expect(bodyScope.html == nil)

            let previewScope = unloaded.withLoadedContent(
                text: "Hello",
                qrCodeText: nil,
                rtfData: rtfData,
                scope: .preview
            )
            #expect(previewScope.isContentLoaded)
            #expect(previewScope.hasFormatting)
            #expect(previewScope.htmlDigest == originalHTMLDigest)
            #expect(previewScope.containsRestSecret)
            #expect(previewScope.isPreviewFormattingLoaded)
            #expect(!previewScope.isFormattingLoaded)
            #expect(previewScope.rtfData == rtfData)
            #expect(previewScope.html == nil)

            let fullScope = unloaded.withLoadedContent(
                text: "Hello",
                qrCodeText: nil,
                html: htmlSecret,
                rtfData: rtfData,
                scope: .full
            )
            #expect(fullScope.isContentLoaded)
            #expect(fullScope.hasFormatting)
            #expect(fullScope.htmlDigest == originalHTMLDigest)
            #expect(fullScope.containsRestSecret)
            #expect(fullScope.isPreviewFormattingLoaded)
            #expect(fullScope.isFormattingLoaded)
            #expect(fullScope.html == htmlSecret)
            #expect(fullScope.rtfData == rtfData)

            // Custom keyed htmlDigest on a stored header must not be overwritten on .full load.
            let customKeyedDigest = "keyed-hmac-html-digest-0123456789abcdef0123456789abcdef01234567"
            let customHeader = ClipboardItem.fromStoredHeader(
                id: UUID(),
                kind: .richText,
                title: nil,
                textPreview: "Hello",
                characterCount: 5,
                containsPreviewSecret: false,
                containsRestSecret: false,
                hasRecognizedText: true,
                hasQRCodeText: false,
                isSVGText: false,
                hasFormatting: true,
                htmlDigest: customKeyedDigest,
                imageDigest: nil,
                imageWidth: nil,
                imageHeight: nil,
                assetPath: nil,
                filePaths: [],
                sourceAppName: nil,
                sourceBundleIdentifier: nil,
                copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                firstCopiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                byteSize: 5,
                isFavorite: false,
                tags: [1],
                copyCount: 1,
                linkPreviewDetails: nil,
                copySequenceID: nil,
                copySequenceOrder: nil,
                favoriteOrder: nil,
                sensitivity: nil,
                expiresAt: nil,
                deletedAt: nil,
                storedContentKey: Data(repeating: 0x33, count: 32)
            )
            let hydratedCustom = customHeader.withLoadedContent(
                text: "Hello",
                qrCodeText: nil,
                html: "<b>Hello</b>",
                rtfData: rtfData,
                scope: .full,
                tagNames: ["Design"]
            )
            #expect(hydratedCustom.isFormattingLoaded)
            #expect(hydratedCustom.htmlDigest == customKeyedDigest)
            #expect(hydratedCustom.searchText.contains("Design"))
        }

        @Test
        func formattingLoadStateDistinguishesHydrationScopesInEquatableAndHashable() throws {
            // (a) RTF-only .richText (rtfData != nil, html == nil): .preview vs .full differ only in formattingLoadState.
            let rtfData = try TestSupport.makeRTFData(text: "RTF only content")
            let rtfOnlyHeader = ClipboardItem.fixture(
                kind: .richText,
                text: "RTF only content",
                rtfData: rtfData,
                html: nil
            ).unloadingContent()

            let previewHydratedRTF = rtfOnlyHeader.withLoadedContent(
                text: "RTF only content",
                qrCodeText: nil,
                html: nil,
                rtfData: rtfData,
                scope: .preview
            )
            let fullHydratedRTF = rtfOnlyHeader.withLoadedContent(
                text: "RTF only content",
                qrCodeText: nil,
                html: nil,
                rtfData: rtfData,
                scope: .full
            )
            #expect(!previewHydratedRTF.isFormattingLoaded)
            #expect(previewHydratedRTF.isPreviewFormattingLoaded)
            #expect(fullHydratedRTF.isFormattingLoaded)
            #expect(previewHydratedRTF != fullHydratedRTF)
            #expect(Set([previewHydratedRTF, fullHydratedRTF]).count == 2)

            // (b) HTML-only .richText (rtfData == nil, html != nil): .body vs .preview with nil formatting payloads.
            let htmlOnlyHeader = ClipboardItem.fixture(
                kind: .richText,
                text: "HTML only content",
                rtfData: nil,
                html: "<b>HTML only content</b>"
            ).unloadingContent()

            let bodyHydratedHTML = htmlOnlyHeader.withLoadedContent(
                text: "HTML only content",
                qrCodeText: nil,
                html: nil,
                rtfData: nil,
                scope: .body
            )
            let previewHydratedHTML = htmlOnlyHeader.withLoadedContent(
                text: "HTML only content",
                qrCodeText: nil,
                html: nil,
                rtfData: nil,
                scope: .preview
            )
            #expect(!bodyHydratedHTML.isPreviewFormattingLoaded)
            #expect(previewHydratedHTML.isPreviewFormattingLoaded)
            #expect(bodyHydratedHTML != previewHydratedHTML)
            #expect(Set([bodyHydratedHTML, previewHydratedHTML]).count == 2)

            // (c) Unformatted .text (hasFormatting == false) round-trips through unloadingContent + .body hydration identically.
            let original = ClipboardItem.fixture(kind: .text, text: "Unformatted plain note")
            #expect(!original.hasFormatting)
            let roundTripped = original
                .unloadingContent()
                .withLoadedContent(text: original.text, qrCodeText: nil, scope: .body, tagNames: [])
            #expect(roundTripped == original)
            #expect(roundTripped.hashValue == original.hashValue)
        }

        @Test
        func unloadedAccessorsGraphemeCapsAndHasSameContentCollisionResistance() throws {
            // Unloaded previewText, contentTitle, and hasCompleteTextPreview
            let headingBody = ClipboardItem.fixture(kind: .text, text: "Heading\nBody")
            let unloadedHeadingBody = headingBody.unloadingContent()
            #expect(unloadedHeadingBody.previewText == "Heading\nBody")
            #expect(unloadedHeadingBody.contentTitle == "Heading")
            #expect(unloadedHeadingBody.hasCompleteTextPreview)
            #expect(unloadedHeadingBody.hasTextContent)

            let colorItem = ClipboardItem.fixture(kind: .color, text: "#FF5733")
            let unloadedColor = colorItem.unloadingContent()
            #expect(unloadedColor.previewText == "#FF5733")
            #expect(unloadedColor.contentTitle == "#FF5733")
            #expect(unloadedColor.hasCompleteTextPreview)

            let leadingNewline = ClipboardItem.fixture(kind: .text, text: "\nHeading")
            let unloadedLeadingNewline = leadingNewline.unloadingContent()
            #expect(unloadedLeadingNewline.previewText == "\nHeading")
            #expect(unloadedLeadingNewline.contentTitle == leadingNewline.contentTitle)
            #expect(!unloadedLeadingNewline.hasCompleteTextPreview)

            // Variation-selector grapheme cluster bomb: 1 Character, >40k UTF-16 code units
            let cluster20k = "a" + String(repeating: "\u{E0100}", count: 20_000)
            let cluster25k = "a" + String(repeating: "\u{E0100}", count: 25_000)
            let unloadedCluster20k = ClipboardItem.fixture(kind: .text, text: cluster20k).unloadingContent()
            let unloadedCluster25k = ClipboardItem.fixture(kind: .text, text: cluster25k).unloadingContent()
            #expect(unloadedCluster20k.characterCount == 1)
            #expect(unloadedCluster25k.characterCount == 1)
            let boundedPreview = try #require(unloadedCluster20k.textPreview)
            #expect(boundedPreview.utf16.count <= ClipboardItem.textPreviewMaxUTF16Length)
            #expect(!unloadedCluster20k.hasCompleteTextPreview)
            #expect(unloadedCluster20k.storedContentKey == nil)
            #expect(!unloadedCluster20k.hasSameContent(as: unloadedCluster25k))
            #expect(unloadedCluster20k.hasSameContent(as: unloadedCluster20k))

            // browserURL on unloaded .link
            let shortLink = ClipboardItem.fixture(kind: .link, text: "https://clipbook.app/docs?page=2")
            let unloadedShortLink = shortLink.unloadingContent()
            #expect(unloadedShortLink.hasCompleteTextPreview)
            #expect(unloadedShortLink.browserURL == URL(string: "https://clipbook.app/docs?page=2"))

            let longLinkPrefix = "https://clipbook.app/" + String(repeating: "p", count: 8_200)
            let unloadedLongLinkOne = ClipboardItem.fixture(
                kind: .link,
                text: longLinkPrefix + "/one"
            ).unloadingContent()
            let unloadedLongLinkTwo = ClipboardItem.fixture(
                kind: .link,
                text: longLinkPrefix + "/two"
            ).unloadingContent()
            #expect(!unloadedLongLinkOne.hasCompleteTextPreview)
            #expect(unloadedLongLinkOne.browserURL == nil)
            #expect(!unloadedLongLinkOne.hasSameContent(as: unloadedLongLinkTwo))
            #expect(unloadedLongLinkOne.hasSameContent(as: unloadedLongLinkOne))

            // canCopyTextFromImage & canCopyTextFromQRCode on unloaded items
            #expect(!unloadedHeadingBody.canCopyTextFromImage)
            #expect(!unloadedHeadingBody.canCopyTextFromQRCode)

            let imageWithOCRAndQR = ClipboardItem.fixture(
                kind: .image,
                text: "Detected screenshot text",
                qrCodeText: "https://clipbook.app",
                assetPath: "/Users/alice/Pictures/shot.png"
            ).unloadingContent()
            #expect(imageWithOCRAndQR.canCopyTextFromImage)
            #expect(imageWithOCRAndQR.canCopyTextFromQRCode)

            let imageWithoutOCR = ClipboardItem.fixture(
                kind: .image,
                text: "   \n  ",
                qrCodeText: nil,
                assetPath: "/Users/alice/Pictures/blank.png"
            ).unloadingContent()
            #expect(!imageWithoutOCR.canCopyTextFromImage)
            #expect(!imageWithoutOCR.canCopyTextFromQRCode)

            // characterCount == 50_000 on unloaded .text
            let text50k = String(repeating: "m", count: 50_000)
            let unloaded50k = ClipboardItem.fixture(kind: .text, text: text50k).unloadingContent()
            #expect(unloaded50k.characterCount == 50_000)
            #expect(unloaded50k.textPreview?.count == ClipboardItem.textPreviewBodyLimit)
            #expect(!unloaded50k.hasCompleteTextPreview)
            #expect(unloaded50k.hasTextContent)

            // isSVGText == true on 12,000-char <svg>...</svg>
            let svgOpen = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><desc>"
            let svgClose = "</desc></svg>"
            let svg12k = svgOpen + String(repeating: "s", count: 12_000 - svgOpen.count - svgClose.count) + svgClose
            #expect(svg12k.count == 12_000)
            let unloadedSVG = ClipboardItem.fixture(kind: .text, text: svg12k).unloadingContent()
            #expect(unloadedSVG.isSVGText)

            // imageDimensions == (1440, 900) without touching disk
            let sizedImage = ClipboardItem(
                kind: .image,
                assetPath: "/nonexistent/encrypted-image.enc",
                imageWidth: 1440,
                imageHeight: 900
            )
            #expect(sizedImage.imageDimensions?.width == 1440)
            #expect(sizedImage.imageDimensions?.height == 900)
            let unloadedSizedImage = sizedImage.unloadingContent()
            #expect(unloadedSizedImage.imageDimensions?.width == 1440)
            #expect(unloadedSizedImage.imageDimensions?.height == 900)

            // Non-colliding hasSameContent(as:) on two unloaded 20 KB .text items sharing 8,097-char prefix
            let sharedPrefix = String(repeating: "k", count: 8_097)
            var unloaded20kOne = ClipboardItem.fixture(
                kind: .text,
                text: sharedPrefix + String(repeating: "a", count: 12_383)
            ).unloadingContent()
            var unloaded20kTwo = ClipboardItem.fixture(
                kind: .text,
                text: sharedPrefix + String(repeating: "b", count: 12_383)
            ).unloadingContent()
            #expect(unloaded20kOne.characterCount == 20_480)
            #expect(unloaded20kTwo.characterCount == 20_480)
            #expect(unloaded20kOne.textPreview == unloaded20kTwo.textPreview)
            #expect(!unloaded20kOne.hasSameContent(as: unloaded20kTwo))

            unloaded20kOne.storedContentKey = Data(repeating: 0x55, count: 32)
            unloaded20kTwo.storedContentKey = Data(repeating: 0x66, count: 32)
            #expect(!unloaded20kOne.hasSameContent(as: unloaded20kTwo))
            unloaded20kTwo.storedContentKey = Data(repeating: 0x55, count: 32)
            #expect(unloaded20kOne.hasSameContent(as: unloaded20kTwo))

            // Leading-whitespace compression non-collision when unloaded
            let wsOne = ClipboardItem.fixture(kind: .text, text: " \nhello").unloadingContent()
            let wsTwo = ClipboardItem.fixture(kind: .text, text: "\n\nhello").unloadingContent()
            #expect(wsOne.characterCount == wsTwo.characterCount)
            #expect(wsOne.textPreview == wsTwo.textPreview)
            #expect(!wsOne.hasSameContent(as: wsTwo))
        }

        nonisolated private static func runNonisolatedDomainAndDetectionCheck() -> Bool {
            let trimmed = "  #ff5733  ".trimmingCharacters(in: .whitespaces).nilIfEmpty
            guard let trimmed,
                  ColorText(trimmed, allowsBareHex: false) != nil,
                  ClipboardKind.classifyText(trimmed, treatDigitNumbersAsColor: false) == .color else {
                return false
            }

            let secretToken = ["sk", "-proj-", "1234567890", "abcdefghijklmnop"].joined()
            let item = ClipboardItem(
                kind: .text,
                title: "Deploy " + secretToken,
                text: "Payload " + secretToken,
                qrCodeText: nil
            )
            let unloaded = item.unloadingContent()
            let reloaded = unloaded.withLoadedContent(text: "Payload " + secretToken, qrCodeText: nil)
            let parts = reloaded.contentKeyComponents
            let maskedBody = SensitiveContent.maskedText("Payload " + secretToken, for: unloaded, detectsAutomatically: true)
            let maskedHeaderTitle = SensitiveContent.maskedTitle("Deploy " + secretToken, for: unloaded, detectsAutomatically: true)
            let directSecrets = SensitiveContentDetector.secrets(in: secretToken, detectsPasswordLikeText: true)

            return !parts.canonicalContent.isEmpty
                && SensitiveContent.shouldEncryptAtRest(item)
                && SensitiveContent.shouldEncryptAtRest(unloaded)
                && SensitiveContent.containsSensitiveContent(unloaded)
                && SensitiveContent.isMasked(unloaded, detectsAutomatically: true)
                && !maskedBody.contains(secretToken)
                && !maskedHeaderTitle.contains(secretToken)
                && !directSecrets.isEmpty
        }

        @Test
        func nonisolatedDomainAndSensitiveContentExecuteInDetachedTask() async {
            let passed = await Task.detached {
                Self.runNonisolatedDomainAndDetectionCheck()
            }.value
            #expect(passed)
        }
    }

    @Suite
    struct PreferencesIgnoredAppAndRetentionTests {
        @Test
        func isApplicationIgnoredMatching() throws {
            let entries = [
                "/Applications/Safari.app",
                "1Password",
                "Keychain Access",
            ]

            #expect(
                AppPreferences.isApplicationIgnored(
                    bundlePath: "/Applications/Safari.app",
                    localizedName: "Safari",
                    entries: entries
                )
            )
            #expect(
                AppPreferences.isApplicationIgnored(
                    bundlePath: "/Applications/1Password.app",
                    localizedName: "1Password",
                    entries: entries
                )
            )
            #expect(
                !AppPreferences.isApplicationIgnored(
                    bundlePath: "/Applications/Notes.app",
                    localizedName: "Notes",
                    entries: entries
                )
            )

            var preferences = AppPreferences()
            preferences.ignoredAppsText = "/Applications/Safari.app\n1Password\n"
            #expect(preferences.ignoredApps == Set(["1Password"]))
        }

        @Test
        func ignoredApplicationMatching() throws {
            try TestSupport.withTemporaryDirectory { tempDir in
                let appURL = tempDir.appendingPathComponent("CustomVault.app", isDirectory: true)
                let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

                let infoPlist: [String: Any] = [
                    "CFBundleIdentifier": "com.example.customvault",
                    "CFBundleName": "CustomVaultName",
                ]
                let plistData = try PropertyListSerialization.data(
                    fromPropertyList: infoPlist,
                    format: .xml,
                    options: 0
                )
                try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

                let ignoredApp = IgnoredApplication(path: appURL.path)
                #expect(ignoredApp.path == appURL.path)
                #expect(ignoredApp.name == "CustomVaultName")

                let matchingByBundleID = ClipboardItem.fixture(
                    kind: .text,
                    text: "secret",
                    sourceAppName: "OtherName",
                    sourceBundleIdentifier: "com.example.customvault"
                )
                #expect(ignoredApp.matches(matchingByBundleID))

                let matchingByName = ClipboardItem.fixture(
                    kind: .text,
                    text: "secret",
                    sourceAppName: "customvaultname",
                    sourceBundleIdentifier: nil
                )
                #expect(ignoredApp.matches(matchingByName))

                let otherApp = ClipboardItem.fixture(
                    kind: .text,
                    text: "secret",
                    sourceAppName: "OtherName",
                    sourceBundleIdentifier: "com.example.other"
                )
                #expect(!ignoredApp.matches(otherApp))
            }
        }

        private static let retentionNow = Date(timeIntervalSince1970: 1_750_000_000)

        private static func retentionPolicy() -> HistoryRetentionPolicy {
            var preferences = AppPreferences()
            preferences.textRetentionDays = AppPreferences.neverKeepRetentionDays
            preferences.richTextRetentionDays = AppPreferences.unlimitedRetentionDays
            preferences.linkRetentionDays = 7
            preferences.keepFavoritesOnClearHistory = true
            return HistoryRetentionPolicy(preferences: preferences, now: retentionNow)
        }

        @Test
        func retentionCutoffsFollowThePreferences() {
            let policy = Self.retentionPolicy()
            #expect(policy.cutoffsByKind[.text] == Self.retentionNow)
            #expect(policy.cutoffsByKind[.richText] == nil)
            #expect(policy.cutoffsByKind[.link] != nil)
        }

        @Test(arguments: [
            (kind: ClipboardKind.text, ageDays: 30.0, isFavorite: false, tags: [Int](), isExpired: true),
            (kind: ClipboardKind.link, ageDays: 10.0, isFavorite: false, tags: [Int](), isExpired: true),
            (kind: ClipboardKind.link, ageDays: 2.0, isFavorite: false, tags: [Int](), isExpired: false),
            (kind: ClipboardKind.link, ageDays: 10.0, isFavorite: true, tags: [Int](), isExpired: false),
            (kind: ClipboardKind.link, ageDays: 10.0, isFavorite: false, tags: [1], isExpired: false),
            (kind: ClipboardKind.richText, ageDays: 3_650.0, isFavorite: false, tags: [Int](), isExpired: false)
        ])
        func retentionExpiresItemsOlderThanTheirKindsCutoffUnlessKept(
            kind: ClipboardKind,
            ageDays: Double,
            isFavorite: Bool,
            tags: [Int],
            isExpired: Bool
        ) {
            let item = ClipboardItem.fixture(
                kind: kind,
                text: "retained text",
                copiedAt: Self.retentionNow.addingTimeInterval(-ageDays * 86_400),
                isFavorite: isFavorite,
                tags: tags
            )
            #expect(Self.retentionPolicy().isExpired(item) == isExpired)
        }

        @Test
        func retentionPeriodStepRoundTrips() {
            #expect(RetentionPeriod.stepCount == 23)
            for index in 0..<RetentionPeriod.stepCount {
                let days = RetentionPeriod.days(forStepIndex: index)
                let roundTrippedIndex = RetentionPeriod.stepIndex(forDays: days)
                #expect(roundTrippedIndex == index)

                let position = RetentionPeriod.visualPosition(forStepIndex: index)
                let indexFromPosition = RetentionPeriod.stepIndex(forVisualPosition: position)
                #expect(indexFromPosition == index)

                let fraction = RetentionPeriod.trackFraction(forVisualPosition: position)
                #expect((0.0...1.0).contains(fraction))
                #expect(!RetentionPeriod.label(forStepIndex: index).isEmpty)
            }
        }
    }

    @Suite
    struct SensitiveContentTests {
        nonisolated private static let openAITokenSample = ["sk", "-proj-", "1234567890", "abcdefghijklmnop"].joined()
        nonisolated private static let githubClassicTokenSample = ["ghp", "_", "1234567890abcdefghijklmnopqrstuvwxyz", "ABCD"].joined()
        nonisolated private static let githubFineGrainedTokenSample = ["github", "_pat_", "11ABCDEF0123456789abcdef", "_0123456789abcdef"].joined()
        nonisolated private static let gitlabTokenSample = ["glpat", "-", "1234567890", "abcdefghijkl"].joined()
        nonisolated private static let awsAccessKeySample = ["AK", "IA", "1234567890", "ABCDEF"].joined()
        nonisolated private static let slackBotTokenSample = ["xox", "b-", "1234567890-1234567890-", "abcdefghijklmnop"].joined()
        nonisolated private static let googleAPIKeySample = ["AI", "zaSyA", "1234567890", "abcdefghijklmnopqrstuvwx"].joined()
        nonisolated private static let stripeLiveKeySample = ["sk", "_live_", "1234567890", "abcdefghijklmn"].joined()
        nonisolated private static let jwtTokenSample = [
            "eyJ", "hbGciOiJIUzI1NiJ9.",
            "eyJ", "zdWIiOiIxMjM0NTY3ODkwIn0.",
            "signature12345",
        ].joined()
        nonisolated private static let rsaPrivateKeySample = [
            "-----BEGIN ", "RSA PRIVATE KEY-----\n",
            "MIIEpAIBAA", "KCAQEA1234567890\n",
            "-----END ", "RSA PRIVATE KEY-----",
        ].joined()
        nonisolated private static let basicAuthURLSample = [
            "https://admin", ":", "superSecretPass123", "@example.com/login",
        ].joined()
        nonisolated private static let bearerHeaderSample = [
            "Authori", "zation: ", "Bea", "rer ",
            String(repeating: "ab12", count: 5),
        ].joined()
        nonisolated private static let otpAuthAlphaSecretSample = [
            "otp", "auth://totp/GitHub:alice?secret=", "JBSWYSDPEHPKSPXP",
        ].joined()
        nonisolated private static let wifiEscapedPasswordSample = [
            "WIFI:S:CorpNet;T:WPA;P:", #"my home wifi\;2026"#, ";H:true;;",
        ].joined()
        nonisolated private static let wifiEscapedSSIDSample = [
            #"WIFI:S:My\;SSID;P:"#, "pass1234", ";;",
        ].joined()
        nonisolated private static let wifiEscapedBackslashMaxFieldsSample = [
            #"WIFI:S:My\\SSID\;Name;T:WPA2;H:false;I:user;A:anon;E:PEAP;PH2:MSCHAPV2;CA:cert;DOM:corp;ID:1;P:"#,
            #"ab\\cd\;ef"#,
            ";;",
        ].joined()
        nonisolated private static let htmlEmbeddedCredentialLinkSample = [
            "<a href=\"https://u", ":", "pass12345", "@example.com\">link</a>",
        ].joined()

        /// Whether the item counts as sensitive, and the text its row shows.
        private static func shown(
            _ text: String,
            kind: ClipboardKind = .text,
            characterLimit: Int? = nil
        ) -> (isMasked: Bool, text: String) {
            let item = ClipboardItem.fixture(kind: kind, text: text)
            let masked = characterLimit.map {
                SensitiveContent.maskedText(text, for: item, detectsAutomatically: true, characterLimit: $0)
            } ?? SensitiveContent.maskedText(text, for: item, detectsAutomatically: true)
            return (SensitiveContent.isMasked(item, detectsAutomatically: true), masked)
        }

        @Test(
            arguments: [
                Self.openAITokenSample,
                Self.githubClassicTokenSample,
                Self.githubFineGrainedTokenSample,
                Self.gitlabTokenSample,
                Self.awsAccessKeySample,
                Self.slackBotTokenSample,
                Self.googleAPIKeySample,
                Self.stripeLiveKeySample,
                Self.jwtTokenSample,
                Self.rsaPrivateKeySample,
                Self.basicAuthURLSample,
                Self.bearerHeaderSample,
            ]
        )
        func detectsKnownSecretFormats(sample: String) {
            let result = Self.shown(sample)
            #expect(result.isMasked)
            #expect(result.text != sample)
            #expect(result.text.contains(SensitiveContent.inlineMask))
        }

        /// The last group is what the valid card number's mask leaves visible.
        @Test(arguments: [
            (lastGroup: " 0366", isValid: true),
            (lastGroup: " 0367", isValid: false)
        ])
        func creditCardNumbersAreMaskedOnlyWhenTheyPassTheLuhnCheck(lastGroup: String, isValid: Bool) {
            let card = ["Card: 4532", " 0151", " 1283", lastGroup].joined()
            let result = Self.shown(card)
            #expect(result.isMasked == isValid)
            if isValid {
                #expect(result.text.hasSuffix(lastGroup))
                #expect(!result.text.contains("4532"))
            } else {
                #expect(result.text == card)
            }
        }

        @Test
        func secretsBeyond4000CharactersAreMaskedInThePreview() {
            let text = String(repeating: "a", count: 4_100) + " " + Self.openAITokenSample
            let result = Self.shown(text, characterLimit: SensitiveContent.previewCharacterLimit)
            #expect(result.isMasked)
            #expect(!result.text.contains(Self.openAITokenSample))
            #expect(result.text.contains(SensitiveContent.inlineMask))
        }

        @Test
        func tokensStraddlingTheRowLimitAreMaskedCompletely() {
            let text = String(repeating: "b", count: 3_990) + " " + Self.githubClassicTokenSample + " trailing text"
            let result = Self.shown(text)
            #expect(result.isMasked)
            #expect(!result.text.contains(["ghp", "_1234"].joined()))
            #expect(!result.text.contains("uvwxyzABCD"))
        }

        @Test
        func privateKeysStraddlingTheRowLimitAreMaskedCompletely() {
            let pemBlock = [
                "-----BEGIN ", "PRIVATE KEY-----\n",
                "MIIEvQIBADAN", "BgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC1234567890\n",
                "-----END ", "PRIVATE KEY-----",
            ].joined()
            let result = Self.shown(String(repeating: "b", count: 3_990) + " " + pemBlock)
            #expect(result.isMasked)
            #expect(!result.text.contains(["BEGIN ", "PRIVATE KEY"].joined()))
            #expect(!result.text.contains("MIIEvQIBADAN"))
        }

        @Test
        func queryParametersInALinkAreMaskedButItsFragmentIsNot() {
            let url = [
                "https://api.example.com/callback?token=", "abc12345",
                "&api_key=", "xyz98765", "#section(1)",
            ].joined()
            let result = Self.shown(url, kind: .link)
            #expect(result.isMasked)
            #expect(!result.text.contains("abc12345"))
            #expect(!result.text.contains("xyz98765"))
            #expect(result.text.contains("#section(1)"))
        }

        @Test
        func tokensInAnOAuthFragmentAreMasked() {
            let url = [
                "https://app.example.com/auth#access_token=", "abc12345",
                "&refresh_token=", "xyz98765",
            ].joined()
            let result = Self.shown(url, kind: .link)
            #expect(result.isMasked)
            #expect(!result.text.contains("abc12345"))
            #expect(!result.text.contains("xyz98765"))
        }

        @Test
        func anAssignmentRightAfterAnEmojiIsMasked() {
            let result = Self.shown(["🔑api_key=", "secret12345"].joined())
            #expect(result.isMasked)
            #expect(result.text.hasPrefix("🔑api_key="))
            #expect(!result.text.contains("secret12345"))
        }

        @Test(
            arguments: [
                ["password: ", "ab#cdefgh"],
                ["password=", "P&ss1234xyz"],
                ["pwd=", "hunter#2024"],
                ["DB_PASSWORD=", "hunter2#Secret99"],
            ]
        )
        func masksWholePasswordsWithAmpersandOrHash(parts: [String]) {
            let result = Self.shown(parts.joined())
            #expect(result.isMasked)
            #expect(result.text == parts[0] + SensitiveContent.inlineMask)
        }

        @Test(arguments: [
            (body: "password=hunter22&remember=1", masked: "password=MASK&remember=1"),
            (body: "token=abc12345&grant_type=refresh", masked: "token=MASK&grant_type=refresh"),
            (body: "user=ann&password=hunter22&remember=1", masked: "user=ann&password=MASK&remember=1")
        ])
        func aFormBodyKeepsTheFieldsAroundTheSecret(body: String, masked: String) {
            let expected = masked.replacingOccurrences(of: "MASK", with: SensitiveContent.inlineMask)
            #expect(Self.shown(body).text == expected)
        }

        @Test
        func masksEveryQueryParameterAndStopsAtItsSeparator() {
            let url = [
                "https://x.example.com/p?a=1&password=", "hunter2x",
                "&b=2&token=", "abc12345", "#frag",
            ].joined()
            let mask = SensitiveContent.inlineMask
            let maskedURL = "https://x.example.com/p?a=1&password=\(mask)&b=2&token=\(mask)#frag"
            #expect(Self.shown(url, kind: .link).text == maskedURL)

            // A URL followed by a password that has a "#" in it: each keeps its own rule.
            let mixed = [url, " ", "password: ", "ab#cdefgh"].joined()
            #expect(Self.shown(mixed).text == "\(maskedURL) password: \(mask)")
        }

        @Test
        func whitespaceARowDoesNotShowDoesNotCountAgainstItsReach() {
            let token = Self.openAITokenSample
            #expect(!Self.shown(String(repeating: " ", count: 6_000) + token).text.contains(token))
        }

        @Test
        func aSecretFarIntoALongItemMasksTheItem() {
            let token = Self.openAITokenSample
            let farText = String(repeating: "a", count: 50_000) + " " + token
            let far = Self.shown(farText)
            #expect(far.isMasked)
            // A row shows only the beginning, so its text is searched no further than that.
            #expect(far.text == farText)
            #expect(!Self.shown(farText, characterLimit: SensitiveContent.previewCharacterLimit).text.contains(token))
        }

        private static func maskedRichText(_ text: String) -> NSAttributedString {
            let item = ClipboardItem.fixture(kind: .richText, text: text)
            let attributed = NSAttributedString(string: text, attributes: [.toolTip: "kept"])
            return SensitiveContent.maskedAttributedText(attributed, for: item, detectsAutomatically: true)
        }

        @Test
        func maskedAttributedTextMasksLateAndStraddlingSecrets() {
            let whitespaceLead = String(repeating: " ", count: 6_000) + String(repeating: "a", count: 198_000) + " "
            let lateToken = Self.openAITokenSample
            let late = Self.maskedRichText(whitespaceLead + lateToken + " tail")
            #expect(!late.string.contains(lateToken))
            #expect(late.string == whitespaceLead + SensitiveContent.inlineMask + " tail")
            // The dots keep the formatting of the text they replace.
            #expect(late.attribute(.toolTip, at: whitespaceLead.utf16.count, effectiveRange: nil) as? String == "kept")

            let straddlingLead = String(repeating: "b", count: SensitiveContent.previewCharacterLimit - 10) + " "
            let straddlingToken = Self.githubClassicTokenSample
            let straddling = Self.maskedRichText(straddlingLead + straddlingToken + " trailing text")
            #expect(!straddling.string.contains(["ghp", "_1234"].joined()))
            #expect(!straddling.string.contains("uvwxyzABCD"))
            #expect(straddling.string == straddlingLead + SensitiveContent.inlineMask + " trailing text")
        }

        @Test
        func maskedAttributedTextLeavesTextWithoutSecretsAlone() {
            let text = "Nothing to hide here"
            #expect(Self.maskedRichText(text).string == text)

            let item = ClipboardItem.fixture(kind: .richText, text: Self.openAITokenSample, sensitivity: .notSensitive)
            let shown = SensitiveContent.maskedAttributedText(
                NSAttributedString(string: Self.openAITokenSample),
                for: item,
                detectsAutomatically: true
            )
            #expect(shown.string == Self.openAITokenSample)
        }

        @Test
        func itemMaskCacheReflectsSameIDAndSameByteLengthEdits() {
            let sharedID = UUID()
            let initialSecret = ["token=", "abc12345"].joined()
            let editedPlain = ["notes=", "ordinary"].joined()
            let editedSecret = ["pwd=", "P&ss1234xy"].joined()
            #expect(initialSecret.utf8.count == editedPlain.utf8.count)
            #expect(initialSecret.utf8.count == editedSecret.utf8.count)

            let secretItem = ClipboardItem.fixture(id: sharedID, kind: .text, text: initialSecret)
            #expect(SensitiveContent.isMasked(secretItem, detectsAutomatically: true))
            #expect(SensitiveContent.isMasked(secretItem, detectsAutomatically: true))

            let plainItem = ClipboardItem.fixture(id: sharedID, kind: .text, text: editedPlain)
            #expect(!SensitiveContent.isMasked(plainItem, detectsAutomatically: true))
            #expect(!SensitiveContent.isMasked(plainItem, detectsAutomatically: true))

            let reeditedSecretItem = ClipboardItem.fixture(id: sharedID, kind: .text, text: editedSecret)
            #expect(SensitiveContent.isMasked(reeditedSecretItem, detectsAutomatically: true))

            let kindSwitchID = UUID()
            let passwordLike = ["https://P@ss", "w0rd123!"].joined().replacingOccurrences(of: "https://", with: "")
            let asText = ClipboardItem.fixture(id: kindSwitchID, kind: .text, text: passwordLike)
            let asLink = ClipboardItem.fixture(id: kindSwitchID, kind: .link, text: passwordLike)
            #expect(SensitiveContent.isMasked(asText, detectsAutomatically: true))
            #expect(!SensitiveContent.isMasked(asLink, detectsAutomatically: true))
        }

        @Test
        func shouldEncryptAtRestDetectsQRHTMLRTFImageFileAndHeaderSecrets() throws {
            // Purely alphabetic Base32 otpauth:// secret (zero digits)
            let otpItem = ClipboardItem.fixture(kind: .text, text: Self.otpAuthAlphaSecretSample)
            #expect(SensitiveContent.shouldEncryptAtRest(otpItem))
            #expect(SensitiveContent.containsSensitiveContent(otpItem))
            #expect(SensitiveContent.isMasked(otpItem, detectsAutomatically: true))

            // WIFI: QR secrets with spaces, escaped semicolons, escaped backslashes, and 4..128-char passwords
            for wifiSample in [
                Self.wifiEscapedPasswordSample,
                Self.wifiEscapedSSIDSample,
                Self.wifiEscapedBackslashMaxFieldsSample,
                ["WIFI:S:Guest;T:WEP;P:", "abcd", ";;"].joined(),
                ["WIFI:S:MaxLen;T:WPA2;P:", String(repeating: "w", count: 128), ";;"].joined(),
            ] {
                let wifiItem = ClipboardItem.fixture(kind: .text, text: wifiSample)
                #expect(SensitiveContent.shouldEncryptAtRest(wifiItem))
                #expect(SensitiveContent.isMasked(wifiItem, detectsAutomatically: true))
            }

            // <4-char WIFI: passwords are rejected
            for shortWifi in [
                "WIFI:S:Net;T:WPA;P:abc;;",
                "WIFI:S:Net;T:nopass;P:;;",
            ] {
                let nonSecretWifi = ClipboardItem.fixture(kind: .text, text: shortWifi)
                #expect(!SensitiveContent.shouldEncryptAtRest(nonSecretWifi))
                #expect(!SensitiveContent.isMasked(nonSecretWifi, detectsAutomatically: true))
            }

            // Secret at offset 250,000 (beyond 200,000 previewCharacterLimit)
            let farSecret = String(repeating: "a", count: 250_000) + " " + Self.openAITokenSample
            let farItem = ClipboardItem.fixture(kind: .text, text: farSecret)
            #expect(SensitiveContent.shouldEncryptAtRest(farItem))
            #expect(SensitiveContent.containsSensitiveContent(farItem))
            #expect(!SensitiveContent.isMasked(farItem, detectsAutomatically: true))

            // Secret inside html or rtfData when plain text is "link"
            let htmlItem = ClipboardItem.fixture(
                kind: .richText,
                text: "link",
                html: Self.htmlEmbeddedCredentialLinkSample
            )
            #expect(SensitiveContent.shouldEncryptAtRest(htmlItem))
            #expect(!SensitiveContent.isMasked(htmlItem, detectsAutomatically: true))

            let rtfSecretData = try TestSupport.makeRTFData(text: "embedded " + Self.openAITokenSample)
            let rtfItem = ClipboardItem.fixture(
                kind: .richText,
                text: "link",
                rtfData: rtfSecretData,
                html: nil
            )
            #expect(SensitiveContent.shouldEncryptAtRest(rtfItem))
            #expect(!SensitiveContent.isMasked(rtfItem, detectsAutomatically: true))

            // .image and .file items carrying secrets in text, qrCodeText, or filePaths
            let imageOCRSecret = ClipboardItem.fixture(
                kind: .image,
                text: "Scanned " + Self.openAITokenSample,
                assetPath: "/Users/alice/Pictures/ocr.png"
            )
            #expect(SensitiveContent.shouldEncryptAtRest(imageOCRSecret))
            #expect(SensitiveContent.isMasked(imageOCRSecret, detectsAutomatically: true))

            let imageQRSecret = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                qrCodeText: Self.otpAuthAlphaSecretSample,
                assetPath: "/Users/alice/Pictures/qr.png"
            )
            #expect(SensitiveContent.shouldEncryptAtRest(imageQRSecret))
            #expect(SensitiveContent.isMasked(imageQRSecret, detectsAutomatically: true))

            let imagePathSecret = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                assetPath: "/Users/alice/Pictures/plain.png",
                filePaths: ["/Users/alice/Pictures/key-" + Self.awsAccessKeySample + ".png"]
            )
            #expect(SensitiveContent.shouldEncryptAtRest(imagePathSecret))

            let fileOCRSecret = ClipboardItem.fixture(
                kind: .file,
                text: "Invoice " + Self.githubClassicTokenSample,
                filePaths: ["/Users/alice/Documents/invoice.png"]
            )
            #expect(SensitiveContent.shouldEncryptAtRest(fileOCRSecret))
            #expect(SensitiveContent.isMasked(fileOCRSecret, detectsAutomatically: true))

            let fileQRSecret = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                qrCodeText: Self.wifiEscapedSSIDSample,
                filePaths: ["/Users/alice/Documents/wifi-qr.png"]
            )
            #expect(SensitiveContent.shouldEncryptAtRest(fileQRSecret))
            #expect(SensitiveContent.isMasked(fileQRSecret, detectsAutomatically: true))

            let secretFilePath = "/Users/alice/Exports/dump-" + Self.openAITokenSample + ".txt"
            let filePathSecretItem = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [secretFilePath]
            )
            #expect(SensitiveContent.shouldEncryptAtRest(filePathSecretItem))
            #expect(SensitiveContent.isMasked(filePathSecretItem, detectsAutomatically: true))
            let maskedFilePath = SensitiveContent.maskedText(
                secretFilePath,
                for: filePathSecretItem,
                detectsAutomatically: true
            )
            #expect(maskedFilePath == "/Users/alice/Exports/dump-" + SensitiveContent.inlineMask + ".txt")
            #expect(
                SensitiveContent.maskedText(
                    secretFilePath,
                    for: filePathSecretItem,
                    detectsAutomatically: false
                ) == secretFilePath
            )

            // .sensitive .image and .file items encrypt at rest and return wholeMask in maskedText
            let sensitiveImage = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                assetPath: "/Users/alice/Pictures/shot.png",
                sensitivity: .sensitive
            )
            #expect(SensitiveContent.shouldEncryptAtRest(sensitiveImage))
            #expect(SensitiveContent.isMasked(sensitiveImage, detectsAutomatically: false))
            #expect(
                SensitiveContent.maskedText(
                    "Image (800x600)",
                    for: sensitiveImage,
                    detectsAutomatically: false
                ) == SensitiveContent.wholeMask
            )

            let sensitiveFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: ["/Users/alice/Documents/roadmap.pdf"],
                sensitivity: .sensitive
            )
            #expect(SensitiveContent.shouldEncryptAtRest(sensitiveFile))
            #expect(SensitiveContent.isMasked(sensitiveFile, detectsAutomatically: false))
            #expect(
                SensitiveContent.maskedText(
                    "/Users/alice/Documents/roadmap.pdf",
                    for: sensitiveFile,
                    detectsAutomatically: false
                ) == SensitiveContent.wholeMask
            )

            // Unloaded item mutated on title or linkPreviewDetails
            var unloadedPlain = ClipboardItem.fixture(kind: .text, text: "ordinary text").unloadingContent()
            #expect(!SensitiveContent.shouldEncryptAtRest(unloadedPlain))
            #expect(!SensitiveContent.isMasked(unloadedPlain, detectsAutomatically: true))
            unloadedPlain.title = "Prod key " + Self.openAITokenSample
            #expect(SensitiveContent.shouldEncryptAtRest(unloadedPlain))
            #expect(SensitiveContent.isMasked(unloadedPlain, detectsAutomatically: true))

            let previewFetchedAt = Date(timeIntervalSince1970: 1_700_000_500)
            var unloadedLinkWithTitleSecret = ClipboardItem.fixture(
                kind: .link,
                text: "https://example.com/Callback"
            ).unloadingContent()
            #expect(!SensitiveContent.shouldEncryptAtRest(unloadedLinkWithTitleSecret))
            unloadedLinkWithTitleSecret.linkPreviewDetails = LinkPreviewDetails(
                url: "https://example.com/Callback",
                title: "Auth " + Self.githubClassicTokenSample,
                description: "Benign description",
                imagePath: nil,
                faviconPath: nil,
                fetchedAt: previewFetchedAt
            )
            #expect(SensitiveContent.shouldEncryptAtRest(unloadedLinkWithTitleSecret))
            #expect(SensitiveContent.isMasked(unloadedLinkWithTitleSecret, detectsAutomatically: true))

            var unloadedLinkWithDescSecret = ClipboardItem.fixture(
                kind: .link,
                text: "https://example.com/Docs"
            ).unloadingContent()
            unloadedLinkWithDescSecret.linkPreviewDetails = LinkPreviewDetails(
                url: "https://example.com/Docs",
                title: "Docs",
                description: "Token " + Self.openAITokenSample,
                imagePath: nil,
                faviconPath: nil,
                fetchedAt: previewFetchedAt
            )
            #expect(SensitiveContent.shouldEncryptAtRest(unloadedLinkWithDescSecret))
            #expect(SensitiveContent.isMasked(unloadedLinkWithDescSecret, detectsAutomatically: true))

            var unloadedLinkWithURLSecret = ClipboardItem.fixture(
                kind: .link,
                text: "https://example.com/Redirect"
            ).unloadingContent()
            unloadedLinkWithURLSecret.linkPreviewDetails = LinkPreviewDetails(
                url: Self.basicAuthURLSample,
                title: "Redirect",
                description: nil,
                imagePath: nil,
                faviconPath: nil,
                fetchedAt: previewFetchedAt
            )
            #expect(SensitiveContent.shouldEncryptAtRest(unloadedLinkWithURLSecret))

            // sensitivity == .notSensitive overrides all secret sources
            let explicitlyPublic = ClipboardItem.fixture(
                kind: .richText,
                title: "Title " + Self.openAITokenSample,
                text: Self.githubClassicTokenSample,
                qrCodeText: Self.otpAuthAlphaSecretSample,
                rtfData: rtfSecretData,
                html: Self.htmlEmbeddedCredentialLinkSample,
                filePaths: [secretFilePath],
                sensitivity: .notSensitive
            )
            #expect(!SensitiveContent.shouldEncryptAtRest(explicitlyPublic))
            #expect(!SensitiveContent.containsSensitiveContent(explicitlyPublic))
            #expect(!SensitiveContent.isMasked(explicitlyPublic, detectsAutomatically: true))
        }

        @Test
        func maskedTitleMasksInlineSecretsAcrossAllKindsWhilePreservingHumanLabels() {
            let inlineSecretTitle = "Webhook " + Self.openAITokenSample + " primary"
            let expectedMaskedTitle = "Webhook " + SensitiveContent.inlineMask + " primary"

            for kind in ClipboardKind.allCases {
                let autoItem = ClipboardItem.fixture(
                    kind: kind,
                    title: inlineSecretTitle,
                    text: kind == .color ? "#FF5733" : "benign",
                    filePaths: kind == .file ? ["/Users/alice/file.txt"] : []
                )
                #expect(SensitiveContent.isMasked(autoItem, detectsAutomatically: true))
                #expect(
                    SensitiveContent.maskedTitle(
                        inlineSecretTitle,
                        for: autoItem,
                        detectsAutomatically: true
                    ) == expectedMaskedTitle
                )
                #expect(
                    SensitiveContent.maskedTitle(
                        inlineSecretTitle,
                        for: autoItem,
                        detectsAutomatically: false
                    ) == inlineSecretTitle
                )

                var sensitiveItem = autoItem
                sensitiveItem.sensitivity = .sensitive
                #expect(
                    SensitiveContent.maskedTitle(
                        "Production Webhook",
                        for: sensitiveItem,
                        detectsAutomatically: true
                    ) == "Production Webhook"
                )
                #expect(
                    SensitiveContent.maskedTitle(
                        inlineSecretTitle,
                        for: sensitiveItem,
                        detectsAutomatically: false
                    ) == expectedMaskedTitle
                )

                var notSensitiveItem = autoItem
                notSensitiveItem.sensitivity = .notSensitive
                #expect(
                    SensitiveContent.maskedTitle(
                        inlineSecretTitle,
                        for: notSensitiveItem,
                        detectsAutomatically: true
                    ) == inlineSecretTitle
                )
            }
        }

        @Test
        func wifiPatternRunsInLinearTimeWithoutBacktracking() {
            // Warm up regex compilation before measuring execution windows.
            _ = SensitiveContentDetector.secrets(
                in: Self.wifiEscapedSSIDSample,
                detectsPasswordLikeText: true
            )

            let backslashPayload = "WIFI:P:" + String(repeating: "\\", count: 500)
            let backslashStart = ContinuousClock.now
            let backslashSecrets = SensitiveContentDetector.secrets(
                in: backslashPayload,
                detectsPasswordLikeText: true
            )
            let backslashElapsed = ContinuousClock.now - backslashStart
            #expect(backslashSecrets.isEmpty)
            #expect(backslashElapsed < .milliseconds(50))

            let repeatedFieldsPayload = String(repeating: "WIFI:a;", count: 5_000)
            let fieldsStart = ContinuousClock.now
            let fieldsSecrets = SensitiveContentDetector.secrets(
                in: repeatedFieldsPayload,
                detectsPasswordLikeText: true
            )
            let fieldsElapsed = ContinuousClock.now - fieldsStart
            #expect(fieldsSecrets.isEmpty)
            #expect(fieldsElapsed < .milliseconds(100))

            let repeatedUnterminatedPasswordPayload = String(repeating: "WIFI:P:aaaa ", count: 5_000)
            let passwordStart = ContinuousClock.now
            let passwordSecrets = SensitiveContentDetector.secrets(
                in: repeatedUnterminatedPasswordPayload,
                detectsPasswordLikeText: true
            )
            let passwordElapsed = ContinuousClock.now - passwordStart
            #expect(passwordSecrets.isEmpty)
            #expect(passwordElapsed < .milliseconds(100))
        }

        @Test
        func isMaskedAndShouldEncryptAtRestMaintainExactParityAcrossUnloadAndReload() {
            func expectParity(
                _ states: [ClipboardItem],
                shouldEncrypt: Bool,
                maskedAutomatically: Bool,
                maskedManuallyOnly: Bool = false
            ) {
                for state in states {
                    #expect(SensitiveContent.shouldEncryptAtRest(state) == shouldEncrypt)
                    #expect(SensitiveContent.isMasked(state, detectsAutomatically: true) == maskedAutomatically)
                    #expect(SensitiveContent.isMasked(state, detectsAutomatically: false) == maskedManuallyOnly)
                }
            }

            // 1. 260,000-char item with secret at offset 250,000: encrypted at rest, unmasked in preview
            let tail260k = 260_000 - 250_000 - 1 - Self.openAITokenSample.count
            let text260k = String(repeating: "a", count: 250_000)
                + " "
                + Self.openAITokenSample
                + String(repeating: "b", count: tail260k)
            #expect(text260k.count == 260_000)
            let loaded260k = ClipboardItem.fixture(kind: .text, text: text260k)
            let unloaded260k = loaded260k.unloadingContent()
            let reloaded260k = unloaded260k.withLoadedContent(text: text260k, qrCodeText: nil)
            expectParity([loaded260k, unloaded260k, reloaded260k], shouldEncrypt: true, maskedAutomatically: false)

            // 2. Secret only in html (plain text "link"): encrypted at rest, unmasked in preview
            let loadedHTMLOnly = ClipboardItem.fixture(
                kind: .richText,
                text: "link",
                html: Self.htmlEmbeddedCredentialLinkSample
            )
            let unloadedHTMLOnly = loadedHTMLOnly.unloadingContent()
            let reloadedHTMLBody = unloadedHTMLOnly.withLoadedContent(text: "link", qrCodeText: nil, scope: .body)
            let reloadedHTMLFull = unloadedHTMLOnly.withLoadedContent(
                text: "link",
                qrCodeText: nil,
                html: Self.htmlEmbeddedCredentialLinkSample,
                rtfData: nil,
                scope: .full
            )
            expectParity(
                [loadedHTMLOnly, unloadedHTMLOnly, reloadedHTMLBody, reloadedHTMLFull],
                shouldEncrypt: true,
                maskedAutomatically: false
            )

            // 3. 60,000-char item with secret at offset 50,000 (past 8,096 textPreview, inside 200,000 reach)
            let tail60k = 60_000 - 50_000 - 1 - Self.openAITokenSample.count
            let text60k = String(repeating: "a", count: 50_000)
                + " "
                + Self.openAITokenSample
                + String(repeating: "b", count: tail60k)
            #expect(text60k.count == 60_000)
            let loaded60k = ClipboardItem.fixture(kind: .text, text: text60k)
            let unloaded60k = loaded60k.unloadingContent()
            let reloaded60k = unloaded60k.withLoadedContent(text: text60k, qrCodeText: nil)
            expectParity([loaded60k, unloaded60k, reloaded60k], shouldEncrypt: true, maskedAutomatically: true)

            // 4. Secret in title with benign body
            let loadedTitleSecret = ClipboardItem.fixture(
                kind: .text,
                title: "Key " + Self.githubClassicTokenSample,
                text: "benign body"
            )
            let unloadedTitleSecret = loadedTitleSecret.unloadingContent()
            let reloadedTitleSecret = unloadedTitleSecret.withLoadedContent(text: "benign body", qrCodeText: nil)
            expectParity(
                [loadedTitleSecret, unloadedTitleSecret, reloadedTitleSecret],
                shouldEncrypt: true,
                maskedAutomatically: true
            )

            // 5. Auto-detected .image (OCR or QR secret) and .file (OCR, QR, or filePaths secret)
            let imageOCRText = "OCR " + Self.openAITokenSample
            let loadedImageOCR = ClipboardItem.fixture(
                kind: .image,
                text: imageOCRText,
                assetPath: "/Users/alice/Pictures/ocr.png"
            )
            let unloadedImageOCR = loadedImageOCR.unloadingContent()
            let reloadedImageOCR = unloadedImageOCR.withLoadedContent(text: imageOCRText, qrCodeText: nil)
            expectParity([loadedImageOCR, unloadedImageOCR, reloadedImageOCR], shouldEncrypt: true, maskedAutomatically: true)

            let loadedImageQR = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                qrCodeText: Self.wifiEscapedPasswordSample,
                assetPath: "/Users/alice/Pictures/qr.png"
            )
            let unloadedImageQR = loadedImageQR.unloadingContent()
            let reloadedImageQR = unloadedImageQR.withLoadedContent(
                text: nil,
                qrCodeText: Self.wifiEscapedPasswordSample
            )
            expectParity([loadedImageQR, unloadedImageQR, reloadedImageQR], shouldEncrypt: true, maskedAutomatically: true)

            let fileOCRText = "Scan " + Self.awsAccessKeySample
            let loadedFileOCR = ClipboardItem.fixture(
                kind: .file,
                text: fileOCRText,
                filePaths: ["/Users/alice/Documents/scan.png"]
            )
            let unloadedFileOCR = loadedFileOCR.unloadingContent()
            let reloadedFileOCR = unloadedFileOCR.withLoadedContent(text: fileOCRText, qrCodeText: nil)
            expectParity([loadedFileOCR, unloadedFileOCR, reloadedFileOCR], shouldEncrypt: true, maskedAutomatically: true)

            let loadedFileQR = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                qrCodeText: Self.otpAuthAlphaSecretSample,
                filePaths: ["/Users/alice/Documents/totp.png"]
            )
            let unloadedFileQR = loadedFileQR.unloadingContent()
            let reloadedFileQR = unloadedFileQR.withLoadedContent(
                text: nil,
                qrCodeText: Self.otpAuthAlphaSecretSample
            )
            expectParity([loadedFileQR, unloadedFileQR, reloadedFileQR], shouldEncrypt: true, maskedAutomatically: true)

            let secretPath = "/Users/alice/Secrets/env-" + Self.openAITokenSample + ".txt"
            let loadedFilePath = ClipboardItem.fixture(kind: .file, text: nil, filePaths: [secretPath])
            let unloadedFilePath = loadedFilePath.unloadingContent()
            let reloadedFilePath = unloadedFilePath.withLoadedContent(text: nil, qrCodeText: nil)
            expectParity([loadedFilePath, unloadedFilePath, reloadedFilePath], shouldEncrypt: true, maskedAutomatically: true)

            // 6. 6,000 leading spaces + secret stays masked after unloadingContent()
            let paddedSecret = String(repeating: " ", count: 6_000) + Self.openAITokenSample
            let loadedPadded = ClipboardItem.fixture(kind: .text, text: paddedSecret)
            let unloadedPadded = loadedPadded.unloadingContent()
            #expect(SensitiveContent.isMasked(unloadedPadded, detectsAutomatically: true))
            let maskedUnloadedPreview = SensitiveContent.maskedText(
                unloadedPadded.previewText,
                for: unloadedPadded,
                detectsAutomatically: true
            )
            #expect(!maskedUnloadedPreview.contains(Self.openAITokenSample))
            #expect(maskedUnloadedPreview.contains(SensitiveContent.inlineMask))

            // 7. ClipboardItem.init and isMasked use zero-plaintext SHA-256 restVerdictCache without inserting plaintext into SensitiveContent.cache (so dontSave-rejected secrets leave zero plaintext in SensitiveContent.cache).
            let dontSaveUniqueSecret = ["sk-", "proj-", UUID().uuidString.replacingOccurrences(of: "-", with: ""), "DontSaveProbe99"].joined()
            let transientSecretItem = ClipboardItem.fixture(kind: .text, text: dontSaveUniqueSecret)
            #expect(SensitiveContent.shouldEncryptAtRest(transientSecretItem))
            #expect(SensitiveContent.isMasked(transientSecretItem, detectsAutomatically: true))
            #expect(!SensitiveContent.hasCachedMaskSecretsForTesting(in: dontSaveUniqueSecret, detectsPasswordLikeText: true))
        }
    }
}
