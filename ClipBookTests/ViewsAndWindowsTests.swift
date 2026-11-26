@testable import ClipBook
import AppKit
import CryptoKit
import Foundation
import ImageIO
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WebKit

// These suites touch process-global state (`L10n`, `NSApp` focus/appearance,
// `ImageAssetThumbnailLoader.shared`, `SVGImageRenderer.shared`, `ImageDragFiles`).
extension SharedProcessStateTests {
    @Suite(.serialized)
    struct RowBuilderAndFormattingTests {
        @Test
        func historyTableRowBuilderGroupingAndDST() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))

            let now = Date()
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayDate = try #require(calendar.date(byAdding: .day, value: -1, to: todayStart)).addingTimeInterval(3600)
            let olderDate = try #require(calendar.date(byAdding: .day, value: -10, to: todayStart)).addingTimeInterval(3600)

            // DST spring-forward in America/New_York on 2026-03-08.
            let dstComponents = DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)
            let dstBeforeJump = try #require(calendar.date(from: dstComponents))
            let dstAfterJump = dstBeforeJump.addingTimeInterval(3 * 3600)

            let pinnedFav = ClipboardItem.fixture(
                kind: .text,
                text: "Pinned Favorite",
                copiedAt: olderDate,
                isFavorite: true,
                favoriteOrder: 0
            )
            let todayItem = ClipboardItem.fixture(
                kind: .text,
                text: "Today Item",
                copiedAt: todayStart.addingTimeInterval(600)
            )
            let yesterdayItem = ClipboardItem.fixture(
                kind: .text,
                text: "Yesterday Item",
                copiedAt: yesterdayDate
            )
            let dstItem1 = ClipboardItem.fixture(
                kind: .text,
                text: "DST Early",
                copiedAt: dstAfterJump
            )
            let dstItem2 = ClipboardItem.fixture(
                kind: .text,
                text: "DST Late",
                copiedAt: dstBeforeJump
            )

            // 00:30 the day after the jump is inside 24 hours of the start of the 23-hour day before it.
            let nextDayComponents = DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30)
            let dstNextDay = ClipboardItem.fixture(
                kind: .text,
                text: "DST Next Day",
                copiedAt: try #require(calendar.date(from: nextDayComponents))
            )

            let rows = HistoryTableRowBuilder.build(
                from: [pinnedFav, todayItem, yesterdayItem, dstNextDay, dstItem1, dstItem2],
                groupPinnedFavorites: true,
                calendar: calendar
            )

            let favoritesHeader = L10n.string("Favorites")
            let todayHeader = L10n.string("Today")
            let yesterdayHeader = L10n.string("Yesterday")

            #expect(rows.count == 11)
            #expect(rows[0] == .sectionHeader(favoritesHeader))
            #expect(rows[1] == .item(pinnedFav, itemIndex: 0))
            #expect(rows[2] == .sectionHeader(todayHeader))
            #expect(rows[3] == .item(todayItem, itemIndex: 1))
            #expect(rows[4] == .sectionHeader(yesterdayHeader))
            #expect(rows[5] == .item(yesterdayItem, itemIndex: 2))

            guard case .sectionHeader(let nextDayTitle) = rows[6], case .sectionHeader(let jumpDayTitle) = rows[8] else {
                Issue.record("Expected a section header for each of the two days around the DST jump")
                return
            }
            #expect(!nextDayTitle.isEmpty)
            #expect(!jumpDayTitle.isEmpty)
            #expect(nextDayTitle != jumpDayTitle)
            #expect(![nextDayTitle, jumpDayTitle].contains(todayHeader))
            #expect(![nextDayTitle, jumpDayTitle].contains(yesterdayHeader))
            #expect(rows[7] == .item(dstNextDay, itemIndex: 3))
            #expect(rows[9] == .item(dstItem1, itemIndex: 4))
            #expect(rows[10] == .item(dstItem2, itemIndex: 5))
        }

        @Test
        func searchMatchHighlighterDiacritics() {
            let text = "Café résumé naïve CAFÉ"
            let font = NSFont.systemFont(ofSize: 13)
            let baseColor = NSColor.labelColor
            let attributed = HistorySearchMatchHighlighter.attributedString(
                text: text,
                font: font,
                textColor: baseColor,
                searchQuery: "cafe"
            )

            let nsText = text as NSString
            let firstCafeRange = nsText.range(of: "Café")
            let secondCafeRange = nsText.range(of: "CAFÉ")
            let resumeRange = nsText.range(of: "résumé")

            let firstColor = attributed.attribute(.foregroundColor, at: firstCafeRange.location, effectiveRange: nil) as? NSColor
            let secondColor = attributed.attribute(.foregroundColor, at: secondCafeRange.location, effectiveRange: nil) as? NSColor
            let resumeColor = attributed.attribute(.foregroundColor, at: resumeRange.location, effectiveRange: nil) as? NSColor

            #expect(firstColor == .systemBlue)
            #expect(secondColor == .systemBlue)
            #expect(resumeColor == baseColor)
        }

        @Test
        @MainActor
        func maskStyleRespectsHidesSensitiveContentFlag() throws {
            TestSupport.ensureAppKitInitialized()
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
            let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            let literalBullets = "Prefix ●●●●●●●● Suffix"
            let nsLiteral = literalBullets as NSString
            let bulletRange = nsLiteral.range(of: "●●●●●●●●")

            let unmaskedAttr = NSMutableAttributedString(
                string: literalBullets,
                attributes: [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
            HistoryPreviewSymbolAppearance.applyMaskStyle(
                to: unmaskedAttr,
                text: literalBullets,
                font: baseFont,
                in: view,
                hidesSensitiveContent: false
            )
            let unmaskedFont = try #require(unmaskedAttr.attribute(.font, at: bulletRange.location, effectiveRange: nil) as? NSFont)
            #expect(abs(unmaskedFont.pointSize - baseFont.pointSize) < 0.01)

            let maskedAttr = NSMutableAttributedString(
                string: literalBullets,
                attributes: [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
            HistoryPreviewSymbolAppearance.applyMaskStyle(
                to: maskedAttr,
                text: literalBullets,
                font: baseFont,
                in: view,
                hidesSensitiveContent: true
            )
            let maskedFont = try #require(maskedAttr.attribute(.font, at: bulletRange.location, effectiveRange: nil) as? NSFont)
            let expectedMaskSize = baseFont.pointSize * 0.42
            #expect(abs(maskedFont.pointSize - expectedMaskSize) < 0.01)
            let kern = maskedAttr.attribute(.kern, at: bulletRange.location, effectiveRange: nil) as? CGFloat
            #expect(kern != nil && (kern ?? 0) > 0)
        }

        @Test
        func anUnquotedAttributeValueEndsBeforeTheSlashOfASelfClosingTag() throws {
            let baseURL = try #require(URL(string: "https://example.com/articles/post"))
            let html = "<head><link rel=icon href=/favicon.png/><meta property=og:image content=/cover.png/></head>"

            let metadata = LinkPreviewHTMLParser.parse(html: html, baseURL: baseURL)

            #expect(metadata.faviconURLs.map(\.absoluteString).first == "https://example.com/favicon.png")
            #expect(metadata.imageURL?.absoluteString == "https://example.com/cover.png")
        }

        @Test
        func linkPreviewHTMLParserMetadataAndEntities() throws {
            let baseURL = try #require(URL(string: "https://example.com/articles/post"))
            let html = """
            <html>
            <head>
              <title>Fallback &amp; Title</title>
              <meta property="og:title" content="Tom &amp; Jerry&nbsp;&mdash;&nbsp;Official &rsquo;Site&rsquo; &copy; 2026 &amp; more">
              <meta name="twitter:description" content="A &quot;classic&quot; show &amp; tell with bare &amp; ampersand">
              <meta property="og:image" content="/assets/preview.png">
              <link rel="shortcut icon" href="/old.ico" type="image/x-icon">
              <link rel="icon" href="/favicon-custom.png">
              <link rel="apple-touch-icon" href="/apple-touch.png">
            </head>
            </html>
            """

            let metadata = LinkPreviewHTMLParser.parse(html: html, baseURL: baseURL)
            #expect(metadata.title == "Tom & Jerry \u{2014} Official \u{2019}Site\u{2019} \u{00A9} 2026 & more")
            #expect(metadata.description == "A \"classic\" show & tell with bare & ampersand")
            #expect(metadata.imageURL?.absoluteString == "https://example.com/assets/preview.png")

            let faviconStrings = metadata.faviconURLs.map(\.absoluteString)
            #expect(faviconStrings.count >= 4)
            #expect(faviconStrings[0] == "https://example.com/apple-touch.png")
            #expect(faviconStrings[1] == "https://example.com/favicon-custom.png")
            #expect(faviconStrings[2] == "https://example.com/old.ico")

            let fallbackHTML = """
            <html><head><title>Bare &amp; Simple &nbsp; Title</title></head></html>
            """
            let fallbackMeta = LinkPreviewHTMLParser.parse(html: fallbackHTML, baseURL: baseURL)
            #expect(fallbackMeta.title == "Bare & Simple Title")
        }
    }

    @Suite(.serialized)
    struct ViewsDialogsAndWindowsTests {
        private static let rowFrame = NSRect(x: 0, y: 0, width: 480, height: HistoryRow.height)

        @MainActor
        private static func labels(of row: NSView) -> [HistoryFixedTextColorLabel] {
            row.layoutSubtreeIfNeeded()
            return collectLabels(in: row)
        }

        @Test
        @MainActor
        func linkRowMasksASensitiveURLOnLineTwo() throws {
            TestSupport.ensureAppKitInitialized()
            let secretToken = ["sk", "-", String(repeating: "aB3dE5fG", count: 4)].joined()
            let secretURLString = "https://api.example.com/v1/auth?token=\(secretToken)"
            let item = ClipboardItem.fixture(
                kind: .link,
                title: "Production Webhook",
                text: secretURLString,
                sensitivity: .sensitive
            )
            let preview = LinkPreview(
                url: try #require(URL(string: secretURLString)),
                title: "Webhook Dashboard",
                description: "Internal portal",
                image: NSImage(size: NSSize(width: 80, height: 40)),
                favicon: NSImage(size: NSSize(width: 16, height: 16))
            )

            let row = HistoryItemRowLinkView(frame: Self.rowFrame)
            row.configureForTest(item: item, linkPreview: preview, showsLinkPreview: true)

            let labels = Self.labels(of: row)
            #expect(labels.contains { $0.text == "Production Webhook" })
            #expect(!labels.contains { $0.text.contains(secretToken) })
            #expect(labels.contains { $0.text.contains(SensitiveContent.inlineMask) })
        }

        @Test
        @MainActor
        func reusedLinkRowShowsLiteralBulletsAsTheyAre() throws {
            TestSupport.ensureAppKitInitialized()
            let sensitiveItem = ClipboardItem.fixture(
                kind: .link,
                title: "Production Webhook",
                text: "https://api.example.com/v1/auth?token=sk-secret-token-value",
                sensitivity: .sensitive
            )
            let bulletItem = ClipboardItem.fixture(
                kind: .link,
                title: "Bullet Doc",
                text: "https://example.com/●●●●●●●●",
                sensitivity: .notSensitive
            )

            let row = HistoryItemRowLinkView(frame: Self.rowFrame)
            row.configureForTest(item: sensitiveItem, showsLinkPreview: true)
            row.prepareForReuse()
            row.configureForTest(item: bulletItem, quickPasteIndex: 2, showsLinkPreview: true)

            let secondLineLabel = try #require(Self.labels(of: row).first { $0.text.contains("●●●●●●●●") })
            #expect(!secondLineLabel.hidesSensitiveContent)
        }

        @Test
        @MainActor
        func emailRowMasksASensitiveAddress() {
            TestSupport.ensureAppKitInitialized()
            let item = ClipboardItem.fixture(
                kind: .email,
                title: "Root Contact",
                text: "security-admin@example.com",
                sensitivity: .sensitive
            )

            let row = HistoryItemRowEmailView(frame: Self.rowFrame)
            row.configureForTest(item: item)

            let labels = Self.labels(of: row)
            #expect(labels.contains { $0.text == "Root Contact" })
            #expect(!labels.contains { $0.text.contains("security-admin@example.com") })
            #expect(labels.contains { $0.text.contains(SensitiveContent.inlineMask) })
        }

        /// A toolbar with its search item built, and a delegate that records what the toolbar reports.
        @MainActor
        private static func makeSearchToolbar() throws -> (toolbar: HistoryToolbar, delegate: ToolbarDelegateSpy, searchView: NSView) {
            let toolbar = HistoryToolbar()
            let delegate = ToolbarDelegateSpy()
            toolbar.delegate = delegate
            let searchItem = try #require(
                toolbar.toolbar(
                    toolbar.makeToolbar(),
                    itemForItemIdentifier: NSToolbarItem.Identifier("HistoryToolbarSearch"),
                    willBeInsertedIntoToolbar: true
                )
            )
            return (toolbar, delegate, try #require(searchItem.view))
        }

        @Test
        @MainActor
        func historyToolbarSuggestionSelectionAndRanking() throws {
            TestSupport.ensureAppKitInitialized()
            let tagPrefix = ClipBook.Tag(id: 1, name: "SwiftUI", color: "#3B84ED")
            let tagInfix = ClipBook.Tag(id: 2, name: "RxSwift", color: "#E03E3E")
            let sourceApp = HistorySourceApplication(name: "Swift Playgrounds", bundleIdentifier: "com.apple.Playgrounds")

            let suggestions = SearchSuggestionProvider.suggestions(
                for: "swift",
                tags: [tagInfix, tagPrefix],
                sourceApplications: [sourceApp],
                activeKinds: []
            )
            #expect(suggestions.count == 3)
            #expect(suggestions[0].token.kind == .sourceApplication(sourceApp.id))
            #expect(suggestions[1].token.kind == .tag(tagPrefix.id))
            #expect(suggestions[2].token.kind == .tag(tagInfix.id))

            let (toolbar, delegate, _) = try Self.makeSearchToolbar()
            let onSelect = try #require(toolbar.suggestionsPopup.onSelect)
            onSelect(suggestions[1])
            #expect(delegate.selectedTags.map(\.0) == [tagPrefix.id])
            #expect(delegate.selectedTags.map(\.1) == [true])
            #expect(toolbar.searchField.tokens.contains { $0.kind == .tag(tagPrefix.id) })
        }

        @Test
        @MainActor
        func searchTokenFieldChipNavigation() throws {
            TestSupport.ensureAppKitInitialized()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil) }

            let (toolbar, _, searchView) = try Self.makeSearchToolbar()
            searchView.frame = NSRect(x: 0, y: 0, width: 360, height: 52)
            window.contentView?.addSubview(searchView)

            let field = toolbar.searchField
            field.setTokens([
                SearchToken(kind: .contentType(.links), title: "Link", image: nil),
                SearchToken(kind: .contentType(.images), title: "Image", image: nil)
            ])
            field.text = ""
            field.layoutSubtreeIfNeeded()

            #expect(field.control(NSControl(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
            #expect(field.selectedChipIndex == 1)

            // Left arrow (keyCode 123) selects chip 0.
            field.keyDown(with: try TestSupport.keyDownEvent(keyCode: 123, windowNumber: window.windowNumber))
            #expect(field.selectedChipIndex == 0)

            // Right arrow (keyCode 124) moves from chip 0 to chip 1, then back to the text field.
            let rightArrow = try TestSupport.keyDownEvent(keyCode: 124, windowNumber: window.windowNumber)
            field.keyDown(with: rightArrow)
            #expect(field.selectedChipIndex == 1)

            field.keyDown(with: rightArrow)
            #expect(field.selectedChipIndex == nil)
        }

        @MainActor
        private static func allItems(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(allItems(in:)) ?? []) }
        }

        /// The preview's "More actions" menu for a stored rich text item, with the full context
        /// menu it is built from and a count of how often the preview was dismissed.
        @MainActor
        private final class PreviewMenuFixture {
            let harness: TestCoordinatorHarness
            let item = ClipboardItem.fixture(kind: .richText, text: "Bold Text", html: "<b>Bold Text</b>")
            let viewController: HistoryContentViewController
            let contextMenuBuilder: HistoryItemContextMenu
            private(set) var dismissCount = 0
            private(set) var previewMenuBuilder: ItemPreviewActionsMenu!
            /// Built once: building the menu again forgets the actions of the one before.
            private(set) var previewMenuItems: [NSMenuItem] = []

            init() throws {
                TestSupport.ensureAppKitInitialized()
                harness = try TestSupport.makeTestCoordinator()
                try harness.seedHistory([item])
                viewController = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
                contextMenuBuilder = HistoryItemContextMenu(
                    target: viewController,
                    availableTags: [],
                    preferences: harness.model.preferences
                )
                previewMenuBuilder = ItemPreviewActionsMenu(
                    makeItemMenu: { [contextMenuBuilder] in contextMenuBuilder.makeMenu(for: $0) },
                    dismissPreview: { [unowned self] in dismissCount += 1 }
                )
                previewMenuItems = ViewsDialogsAndWindowsTests.allItems(in: previewMenuBuilder.makeMenu(for: item))
            }

            /// Every item of the full context menu.
            var fullMenuItems: [NSMenuItem] {
                ViewsDialogsAndWindowsTests.allItems(in: contextMenuBuilder.makeMenu(for: item))
            }

            /// The item of the preview menu that shows the same title as the item of the full menu with `action`.
            func previewItem(forFullMenuAction action: Selector) throws -> NSMenuItem {
                let title = try #require(fullMenuItems.first { $0.action == action }).title
                return try #require(previewMenuItems.first { $0.title == title })
            }

            func cleanup() {
                TestSupport.drainDelayedPerforms([viewController] + viewController.children)
                harness.cleanup()
            }
        }

        @Test
        @MainActor
        func previewActionsMenuDropsPasteAndCopyActionsAndKeepsTheRest() throws {
            let fixture = try PreviewMenuFixture()
            defer { fixture.cleanup() }

            let droppedActions = [
                #selector(HistoryContentViewController.pasteMenuItem(_:)),
                #selector(HistoryContentViewController.pastePlainTextMenuItem(_:)),
                #selector(HistoryContentViewController.copyMenuItem(_:)),
                #selector(HistoryContentViewController.copyPlainTextMenuItem(_:))
            ]
            let droppedTitles = fixture.fullMenuItems.filter { $0.action.map(droppedActions.contains) == true }.map(\.title)
            #expect(!droppedTitles.isEmpty, "The full context menu should offer the actions the preview leaves out")

            let previewTitles = fixture.previewMenuItems.map(\.title)
            #expect(previewTitles.contains { !$0.isEmpty })
            for title in droppedTitles {
                #expect(!previewTitles.contains(title), "\(title) should not be in the preview menu")
            }
        }

        @Test
        @MainActor
        func previewActionsThatOpenASheetDismissThePreviewAndInPlaceActionsDoNot() throws {
            let fixture = try PreviewMenuFixture()
            defer { fixture.cleanup() }

            let sheetAction = try fixture.previewItem(forFullMenuAction: #selector(HistoryContentViewController.deleteMenuItem(_:)))
            let inPlaceAction = try fixture.previewItem(forFullMenuAction: #selector(HistoryContentViewController.sensitiveMenuItem(_:)))

            NSApp.sendAction(try #require(inPlaceAction.action), to: inPlaceAction.target, from: inPlaceAction)
            #expect(fixture.dismissCount == 0)

            NSApp.sendAction(try #require(sheetAction.action), to: sheetAction.target, from: sheetAction)
            #expect(fixture.dismissCount == 1)
        }

        /// The preview masks only an item found to hold a secret, so a secret far into a long item has
        /// to make the item count as holding one.
        @Test(arguments: [3_000, 50_000])
        @MainActor
        func previewMasksASecretWhereverItIs(offset: Int) {
            TestSupport.ensureAppKitInitialized()
            let token = ["ghp", "_", "1234567890abcdefghijklmnopqrstuvwxyzAB"].joined()
            let controller = ItemPreviewDialogController(
                item: ClipboardItem.fixture(kind: .text, text: String(repeating: "a", count: offset) + " " + token + " end"),
                maximumContentSize: NSSize(width: 800, height: 600),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                loadContent: { item, _ in item }
            )
            defer { TestSupport.drainDelayedPerforms([controller]) }
            _ = controller.view

            func textViews(in view: NSView) -> [NSTextView] {
                ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
            }
            let shown = textViews(in: controller.view).map(\.string).joined()
            #expect(!shown.isEmpty)
            #expect(!shown.contains(token))
        }

        @Test
        @MainActor
        func itemPreviewDialogSavesEditedText() throws {
            TestSupport.ensureAppKitInitialized()

            let item = ClipboardItem.fixture(kind: .richText, text: "Bold Text", html: "<b>Bold Text</b>")
            var saved: [(ClipboardItem, String)] = []
            let controller = ItemPreviewDialogController(
                item: item,
                maximumContentSize: NSSize(width: 800, height: 600),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                loadContent: { item, _ in item }
            )
            defer { TestSupport.drainDelayedPerforms([controller]) }
            controller.onSave = { saved.append(($0, $1)) }
            _ = controller.view

            // Saving without a change saves nothing and keeps the formatting.
            controller.beginEditing()
            #expect(controller.isEditing)
            controller.saveEditing()
            #expect(!controller.isEditing)
            #expect(saved.isEmpty)
            #expect(controller.item.html == "<b>Bold Text</b>")

            // Restoring the original text leaves nothing to save either.
            controller.beginEditing()
            let textView = try #require(findEditableTextView(in: controller.view))
            #expect(textView.string == "Bold Text")
            textView.string = "Changed"
            controller.restoreEditingText()
            #expect(textView.string == "Bold Text")
            controller.saveEditing()
            #expect(saved.isEmpty)

            // A real edit is saved exactly once, with the new text.
            controller.beginEditing()
            let editor = try #require(findEditableTextView(in: controller.view))
            editor.string = "Edited text"
            controller.saveEditing()
            #expect(!controller.isEditing)
            #expect(saved.count == 1)
            #expect(saved.first?.0.id == item.id)
            #expect(saved.first?.1 == "Edited text")
        }

        @Test
        @MainActor
        func itemPreviewDetailsViewReusesSameShapeSubviewsAndTruncatesDockedListPaths() throws {
            TestSupport.ensureAppKitInitialized()

            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            let longText = String(repeating: "x", count: 4_096)
            let textItemA = ClipboardItem.fixture(
                kind: .text,
                text: "Hello world",
                sourceAppName: "Notes",
                sourceBundleIdentifier: "com.apple.Notes",
                copiedAt: baseDate,
                firstCopiedAt: baseDate,
                byteSize: 11,
                copyCount: 1
            )
            let textItemB = ClipboardItem.fixture(
                kind: .text,
                text: longText,
                sourceAppName: "Notes",
                sourceBundleIdentifier: "com.apple.Notes",
                copiedAt: baseDate,
                firstCopiedAt: baseDate,
                byteSize: 4_096,
                copyCount: 2
            )

            let floatingDetails = ItemPreviewDetailsView(item: textItemA, style: .floating)
            floatingDetails.frame = NSRect(x: 0, y: 0, width: 640, height: 80)
            floatingDetails.layoutSubtreeIfNeeded()

            let initialViews = allViewDescendants(in: floatingDetails)
            let initialStacks = initialViews.compactMap { $0 as? NSStackView }.map(ObjectIdentifier.init)
            let initialTextFields = initialViews.compactMap { $0 as? NSTextField }
            let initialTextFieldIDs = initialTextFields.map(ObjectIdentifier.init)

            let sizeA = ByteCountFormatter.string(fromByteCount: 11, countStyle: .file)
            let sizeB = ByteCountFormatter.string(fromByteCount: 4_096, countStyle: .file)
            let numberFormatter = NumberFormatter()
            numberFormatter.locale = L10n.currentLocale
            numberFormatter.numberStyle = .decimal
            let charsB = try #require(numberFormatter.string(from: 4_096))

            #expect(initialTextFields.contains { $0.stringValue == "11" })
            #expect(initialTextFields.contains { $0.stringValue == sizeA })

            floatingDetails.update(item: textItemB)
            floatingDetails.layoutSubtreeIfNeeded()

            let updatedViews = allViewDescendants(in: floatingDetails)
            let updatedStacks = updatedViews.compactMap { $0 as? NSStackView }.map(ObjectIdentifier.init)
            let updatedTextFields = updatedViews.compactMap { $0 as? NSTextField }
            #expect(!initialStacks.isEmpty)
            #expect(updatedStacks == initialStacks)
            #expect(updatedTextFields.map(ObjectIdentifier.init) == initialTextFieldIDs)
            #expect(updatedTextFields.contains { $0.stringValue == charsB })
            #expect(updatedTextFields.contains { $0.stringValue == sizeB })
            #expect(!updatedTextFields.contains { $0.stringValue == "11" })

            let pathA = "/Users/alice/Documents/Projects/ClipBook/Archive/report-alpha.pdf"
            let pathB = "/Users/alice/Documents/Projects/ClipBook/Archive/report-beta.pdf"
            let expectedPathA = (pathA as NSString).abbreviatingWithTildeInPath
            let expectedPathB = (pathB as NSString).abbreviatingWithTildeInPath

            let singleFileA = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [pathA],
                copiedAt: baseDate,
                firstCopiedAt: baseDate,
                byteSize: 1_024,
                copyCount: 1
            )
            let singleFileB = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [pathB],
                copiedAt: baseDate,
                firstCopiedAt: baseDate,
                byteSize: 8_192,
                copyCount: 2
            )
            let multiFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [pathA, pathB],
                copiedAt: baseDate,
                firstCopiedAt: baseDate,
                byteSize: 9_216,
                copyCount: 2
            )

            let dockedDetails = ItemPreviewDetailsView(item: singleFileA, style: .docked)
            dockedDetails.arrangement = .list
            dockedDetails.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
            dockedDetails.layoutSubtreeIfNeeded()

            let pathTitle = L10n.string("Path")
            let dockedFieldsInitial = allViewDescendants(in: dockedDetails).compactMap { $0 as? NSTextField }
            let pathTitleField = try #require(dockedFieldsInitial.first { $0.stringValue == pathTitle })
            let pathRowView = try #require(pathTitleField.superview)
            let fieldsContainer = try #require(pathRowView.superview)
            let initialListRowIDs = fieldsContainer.subviews.map(ObjectIdentifier.init)
            let pathValueField = try #require(
                pathRowView.subviews.compactMap { $0 as? NSTextField }.first { $0 !== pathTitleField }
            )
            #expect(pathValueField.stringValue == expectedPathA)
            #expect(pathValueField.lineBreakMode == .byTruncatingMiddle)

            dockedDetails.update(item: singleFileB)
            dockedDetails.layoutSubtreeIfNeeded()

            #expect(fieldsContainer.subviews.map(ObjectIdentifier.init) == initialListRowIDs)
            #expect(pathValueField.superview === pathRowView)
            #expect(pathValueField.stringValue == expectedPathB)
            #expect(pathValueField.lineBreakMode == .byTruncatingMiddle)
            #expect(pathRowView.toolTip == expectedPathB)

            dockedDetails.update(item: multiFile)
            dockedDetails.layoutSubtreeIfNeeded()

            let multiFields = allViewDescendants(in: dockedDetails).compactMap { $0 as? NSTextField }
            #expect(fieldsContainer.subviews.count == initialListRowIDs.count - 1)
            #expect(!multiFields.contains { $0.stringValue == pathTitle })
            #expect(!multiFields.contains { $0.stringValue.contains("report-") })
            #expect(multiFields.contains { $0.stringValue == L10n.string("Files") })
        }

        private static func makeRuntimeSecret(tag: String) -> String {
            ["sk", "-proj-", tag, "-", String(repeating: "h7J3pQ5w", count: 4)].joined()
        }

        @Test
        @MainActor
        func rowViewsMaskInlineSecretItemTitlesPreserveHumanTitlesHideSensitiveFileDetailsAndSkipFilePreviewCacheWrites() async throws {
            TestSupport.ensureAppKitInitialized()
            let secretToken = Self.makeRuntimeSecret(tag: "row-title")
            #expect(SensitiveContent.shouldEncryptAtRest(.fixture(kind: .text, text: secretToken)))

            // 1. Human title "Production Webhook" stays visible on a .sensitive row while inline secret tokens in itemTitle are masked.
            let humanTitledRow = HistoryItemRowTextView(frame: Self.rowFrame)
            let humanItem = ClipboardItem.fixture(
                kind: .text,
                title: "Production Webhook",
                text: "Secret body \(secretToken)",
                sensitivity: .sensitive
            )
            humanTitledRow.configureForTest(item: humanItem)
            let humanLabels = Self.labels(of: humanTitledRow)
            let webhookLabel = try #require(humanLabels.first { $0.text == "Production Webhook" })
            #expect(!webhookLabel.hidesSensitiveContent)

            let inlineSecretTitleRow = HistoryItemRowTextView(frame: Self.rowFrame)
            let inlineSecretTitleItem = ClipboardItem.fixture(
                kind: .text,
                title: "Webhook \(secretToken)",
                text: "Benign body"
            )
            #expect(SensitiveContent.shouldEncryptAtRest(inlineSecretTitleItem))
            inlineSecretTitleRow.configureForTest(item: inlineSecretTitleItem)
            let maskedTitleLabels = Self.labels(of: inlineSecretTitleRow)
            #expect(!maskedTitleLabels.contains { $0.text.contains(secretToken) })
            let maskedHeaderLabel = try #require(maskedTitleLabels.first { $0.text.contains(SensitiveContent.inlineMask) })
            #expect(maskedHeaderLabel.hidesSensitiveContent)

            // 2. Sensitive single and multi-file rows hide folder/file names/tooltips/preview strip when hidden, and write zero FilePreviewCache files even when revealed!
            try await TestSupport.withTemporaryDirectory { tempDir in
                let cacheDir = tempDir.appendingPathComponent("FilePreviews", isDirectory: true)
                let previewCache = FilePreviewCache(directory: cacheDir)
                let secretFolder = tempDir.appendingPathComponent("VaultFolderAlpha", isDirectory: true)
                try FileManager.default.createDirectory(at: secretFolder, withIntermediateDirectories: true)
                let secretImage1 = secretFolder.appendingPathComponent("secret-card-one.png")
                let secretImage2 = secretFolder.appendingPathComponent("secret-card-two.png")
                let pngData = try TestSupport.makePNGData(pixelWidth: 40, pixelHeight: 40)
                try pngData.write(to: secretImage1)
                try pngData.write(to: secretImage2)
                defer {
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: secretImage1.path)
                    ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: secretImage2.path)
                }

                let singleSensitiveFile = ClipboardItem.fixture(
                    kind: .file,
                    text: nil,
                    filePaths: [secretImage1.path],
                    byteSize: pngData.count,
                    sensitivity: .sensitive
                )
                let fileRow = HistoryItemRowFileView(frame: Self.rowFrame)
                fileRow.filePreviewCache = previewCache
                fileRow.configure(
                    item: singleSensitiveFile,
                    quickPasteIndex: 1,
                    tableWidth: 480,
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: false
                )
                let hiddenFileLabels = Self.labels(of: fileRow)
                #expect(!hiddenFileLabels.contains { $0.text.contains("secret-card-one.png") })
                #expect(!hiddenFileLabels.contains { $0.text.contains("VaultFolderAlpha") })
                let hiddenFileTooltips = allViewDescendants(in: fileRow).compactMap(\.toolTip)
                #expect(!hiddenFileTooltips.contains { $0.contains("secret-card-one") || $0.contains("VaultFolderAlpha") })

                let multiSensitiveFiles = ClipboardItem.fixture(
                    kind: .file,
                    text: nil,
                    filePaths: [secretImage1.path, secretImage2.path],
                    byteSize: pngData.count * 2,
                    sensitivity: .sensitive
                )
                let filesRow = HistoryItemRowFilesView(frame: Self.rowFrame)
                filesRow.filePreviewCache = previewCache
                filesRow.configure(
                    item: multiSensitiveFiles,
                    quickPasteIndex: 1,
                    tableWidth: 480,
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: false
                )
                filesRow.layoutSubtreeIfNeeded()
                let hiddenMultiImageViews = allViewDescendants(in: filesRow)
                    .compactMap { $0 as? NSImageView }
                    .filter { !$0.isHidden && $0.superview != nil }
                let hiddenPreviewStripViews = hiddenMultiImageViews.filter { $0.wantsLayer && $0.layer?.cornerRadius == 4 }
                // Only the type icon box symbols (document symbol + lock badge) are visible; the trailing preview strip is omitted and has zero file-name tooltips.
                let hiddenMultiTooltips = allViewDescendants(in: filesRow).compactMap(\.toolTip)
                #expect(!hiddenMultiTooltips.contains { $0.contains("secret-card") })
                #expect(hiddenMultiImageViews.count <= 2)
                #expect(hiddenPreviewStripViews.isEmpty)

                filesRow.configure(
                    item: multiSensitiveFiles,
                    quickPasteIndex: 1,
                    tableWidth: 480,
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: true
                )
                filesRow.layoutSubtreeIfNeeded()
                let revealedMultiImageViews = allViewDescendants(in: filesRow)
                    .compactMap { $0 as? NSImageView }
                    .filter { !$0.isHidden && $0.superview != nil }
                let revealedPreviewStripViews = revealedMultiImageViews.filter { $0.wantsLayer && $0.layer?.cornerRadius == 4 }
                #expect(revealedPreviewStripViews.count == 2)
                #expect(revealedMultiImageViews.count == hiddenMultiImageViews.count + 2)

                // Revealing the sensitive .file row decodes via in-memory ImageAssetThumbnailLoader without writing anything to FilePreviews/!
                fileRow.configure(
                    item: singleSensitiveFile,
                    quickPasteIndex: 1,
                    tableWidth: 480,
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: true
                )
                fileRow.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(150))
                let cacheEntries = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
                #expect(cacheEntries.isEmpty, "Sensitive .file rows must never write thumbnails or metadata to FilePreviewCache on disk")
            }
        }

        @Test
        @MainActor
        func historyTileViewRendersPlaceholderWhenHiddenAndClearsScreenshotBackToPlaceholderWhenRehidden() async throws {
            TestSupport.ensureAppKitInitialized()
            let secretToken = Self.makeRuntimeSecret(tag: "tile")

            try await TestSupport.withTemporaryDirectory { supportDir in
                let store = GRDBHistoryStore(directory: supportDir, keyProvider: InMemoryDatabaseKeyProvider())
                defer { store.close() }

                let pngData = try TestSupport.makePNGData(pixelWidth: 64, pixelHeight: 48, color: .systemBlue)
                let imageID = UUID()
                let encURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: imageID, encrypted: true)
                var item = ClipboardItem.fixture(
                    id: imageID,
                    kind: .image,
                    title: "Key \(secretToken)",
                    text: "OCR \(secretToken)",
                    assetPath: encURL.path,
                    sensitivity: .sensitive
                )
                item.imageWidth = 64
                item.imageHeight = 48

                let tileView = HistoryTileView(frame: NSRect(x: 0, y: 0, width: 180, height: 150))
                tileView.configure(
                    item: item,
                    quickPasteIndex: 1,
                    detectsSensitiveContent: true,
                    hidesSensitiveContent: true
                )
                tileView.layoutSubtreeIfNeeded()

                @MainActor
                func tilePictureImageView() throws -> NSImageView {
                    let imageViews = allViewDescendants(in: tileView).compactMap { $0 as? NSImageView }
                    return try #require(imageViews.first { $0.image != nil })
                }

                let hiddenFields = allViewDescendants(in: tileView).compactMap { $0 as? NSTextField }
                #expect(!hiddenFields.contains { $0.stringValue.contains(secretToken) })
                #expect(hiddenFields.contains { $0.stringValue.contains(SensitiveContent.inlineMask) })
                #expect(tileView.toolTip == nil)
                #expect(try tilePictureImageView().image?.isTemplate == true)

                // Reveal the same item (isSameItem == true) and wait for the encrypted screenshot to decode.
                tileView.configure(
                    item: item,
                    quickPasteIndex: 1,
                    detectsSensitiveContent: true,
                    hidesSensitiveContent: false
                )
                tileView.layoutSubtreeIfNeeded()
                let decodedShown = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    allViewDescendants(in: tileView)
                        .compactMap { $0 as? NSImageView }
                        .contains { $0.image?.isTemplate == false && ($0.image?.size.width ?? 0) > 20 }
                }
                #expect(decodedShown)

                // Re-hide the same item (isSameItem == true): screenshot must immediately clear back to the template placeholder!
                tileView.configure(
                    item: item,
                    quickPasteIndex: 1,
                    detectsSensitiveContent: true,
                    hidesSensitiveContent: true
                )
                tileView.layoutSubtreeIfNeeded()
                let nonTemplatePicturesAfterRehide = allViewDescendants(in: tileView)
                    .compactMap { $0 as? NSImageView }
                    .filter { $0.image?.isTemplate == false && ($0.image?.size.width ?? 0) > 20 }
                #expect(nonTemplatePicturesAfterRehide.isEmpty, "Re-hiding a tile must clear the decoded screenshot back to placeholder")
                #expect(try tilePictureImageView().image?.isTemplate == true)
                #expect(tileView.toolTip == nil)
            }
        }

        @Test
        @MainActor
        func contextMenuAndPreviewToolbarExposeSensitivityActionsAndOmitOpenActionsOnEncryptedImagesWithoutDuplication() throws {
            TestSupport.ensureAppKitInitialized()
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let secretToken = Self.makeRuntimeSecret(tag: "menus")
            let pngData = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 24)

            let plainImgID = UUID()
            let plainImgURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: plainImgID, encrypted: false)
            let plainImg = ClipboardItem.fixture(id: plainImgID, kind: .image, text: nil, assetPath: plainImgURL.path)

            let encImgID = UUID()
            let encImgURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: encImgID, encrypted: true)
            let encImg = ClipboardItem.fixture(id: encImgID, kind: .image, text: "Token \(secretToken)", assetPath: encImgURL.path)
            #expect(encImg.hasEncryptedImageAsset)
            #expect(encImg.quickLookURL == nil)
            #expect(!plainImg.hasEncryptedImageAsset)

            let tempFileA = harness.supportDirectory.appendingPathComponent("doc-a.txt")
            let tempFileB = harness.supportDirectory.appendingPathComponent("doc-b.txt")
            try Data("a".utf8).write(to: tempFileA)
            try Data("b".utf8).write(to: tempFileB)
            let singleFile = ClipboardItem.fixture(kind: .file, text: nil, filePaths: [tempFileA.path])
            let multiFile = ClipboardItem.fixture(kind: .file, text: nil, filePaths: [tempFileA.path, tempFileB.path], sensitivity: .sensitive)

            try harness.seedHistory([plainImg, encImg, singleFile, multiFile])
            let vc = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([vc]) }
            let menuBuilder = HistoryItemContextMenu(target: vc, availableTags: [], preferences: harness.model.preferences)

            // 1. Context menu checks on plain .png vs encrypted .enc image (including detectSensitiveContent == false!) and .file items.
            let plainImgMenuItems = Self.allItems(in: menuBuilder.makeMenu(for: plainImg))
            let plainImgMenuTitles = plainImgMenuItems.map(\.title)
            #expect(plainImgMenuTitles.contains(L10n.string("Mark as Sensitive")))
            #expect(plainImgMenuItems.contains { $0.action == #selector(HistoryContentViewController.openInAssociatedApplicationMenuItem(_:)) })

            let encImgMenu = menuBuilder.makeMenu(for: encImg)
            let encImgItems = Self.allItems(in: encImgMenu)
            let encImgTitles = encImgItems.map(\.title)
            #expect(encImgTitles.contains(L10n.string("Show Sensitive Content")))
            #expect(encImgTitles.contains(L10n.string("Mark as Not Sensitive")))
            #expect(!encImgItems.contains { $0.action == #selector(HistoryContentViewController.openInAssociatedApplicationMenuItem(_:)) })
            #expect(!encImgTitles.contains(L10n.string("Open With")))

            // Even when detectSensitiveContent == false, canMarkAsNotSensitive still offers single-click "Mark as Not Sensitive" on rest-secret items!
            harness.model.preferences.detectSensitiveContent = false
            let unmaskedAutoMenuBuilder = HistoryItemContextMenu(target: vc, availableTags: [], preferences: harness.model.preferences)
            let encUnmaskedTitles = Self.allItems(in: unmaskedAutoMenuBuilder.makeMenu(for: encImg)).map(\.title)
            #expect(encUnmaskedTitles.contains(L10n.string("Mark as Not Sensitive")))
            harness.model.preferences.detectSensitiveContent = true

            let singleFileTitles = Self.allItems(in: menuBuilder.makeMenu(for: singleFile)).map(\.title)
            #expect(singleFileTitles.contains(L10n.string("Mark as Sensitive")))
            let multiFileTitles = Self.allItems(in: menuBuilder.makeMenu(for: multiFile)).map(\.title)
            #expect(multiFileTitles.contains(L10n.string("Show Sensitive Content")))
            #expect(multiFileTitles.contains(L10n.string("Mark as Not Sensitive")))

            // 2. ItemPreviewToolbar identifiers & ItemPreviewActionsMenu deduplication ("Save as File...", "Show in Finder", "Open in ...").
            let moreID = NSToolbarItem.Identifier("ItemPreviewToolbarMoreActions")
            let openID = NSToolbarItem.Identifier("ItemPreviewToolbarOpenInApplication")
            let saveID = NSToolbarItem.Identifier("ItemPreviewToolbarSaveAsFile")
            let finderID = NSToolbarItem.Identifier("ItemPreviewToolbarShowInFinder")
            let eyeID = NSToolbarItem.Identifier("ItemPreviewToolbarSensitiveContent")

            func toolbarIdentifiers(for item: ClipboardItem) -> [NSToolbarItem.Identifier] {
                let controller = ItemPreviewDialogController(
                    item: item,
                    maximumContentSize: NSSize(width: 800, height: 600),
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: false,
                    loadContent: { item, _ in item }
                )
                defer { TestSupport.drainDelayedPerforms([controller]) }
                return withExtendedLifetime(controller) {
                    let toolbar = controller.makeToolbar()
                    return toolbar.delegate?.toolbarDefaultItemIdentifiers?(toolbar) ?? []
                }
            }

            let plainImgToolbar = toolbarIdentifiers(for: plainImg)
            #expect(plainImgToolbar.contains(saveID))
            #expect(plainImgToolbar.contains(moreID))
            #expect(plainImgToolbar.contains(openID))

            let encImgToolbar = toolbarIdentifiers(for: encImg)
            #expect(encImgToolbar.contains(eyeID))
            #expect(encImgToolbar.contains(saveID))
            #expect(encImgToolbar.contains(moreID))
            #expect(!encImgToolbar.contains(openID), "Encrypted .enc image must omit Open in Application toolbar item")

            let singleFileToolbar = toolbarIdentifiers(for: singleFile)
            #expect(singleFileToolbar.contains(finderID))
            #expect(singleFileToolbar.contains(moreID))
            #expect(singleFileToolbar.contains(openID))

            let multiFileToolbar = toolbarIdentifiers(for: multiFile)
            #expect(multiFileToolbar.contains(eyeID))
            #expect(multiFileToolbar.contains(moreID))

            var dismissCount = 0
            let actionsMenu = ItemPreviewActionsMenu(
                makeItemMenu: { menuBuilder.makeMenu(for: $0) },
                dismissPreview: { dismissCount += 1 }
            )
            let plainImgMoreTitles = Self.allItems(in: actionsMenu.makeMenu(for: plainImg)).map(\.title)
            #expect(plainImgMoreTitles.contains(L10n.string("Mark as Sensitive")))
            #expect(!plainImgMoreTitles.contains(L10n.string("Save as File...")))
            #expect(!plainImgMoreTitles.contains { $0.hasPrefix("Open in ") })

            let singleFileMoreMenu = actionsMenu.makeMenu(for: singleFile)
            let singleFileMoreItems = Self.allItems(in: singleFileMoreMenu)
            let singleFileMoreTitles = singleFileMoreItems.map(\.title)
            #expect(singleFileMoreTitles.contains(L10n.string("Mark as Sensitive")))
            #expect(!singleFileMoreTitles.contains(L10n.string("Show in Finder")))
            #expect(!singleFileMoreTitles.contains { $0.hasPrefix("Open in ") })

            // Clicking "Mark as Sensitive" inside More Actions mutates in place without dismissing the preview!
            let sensitiveMoreItem = try #require(singleFileMoreItems.first { $0.title == L10n.string("Mark as Sensitive") })
            NSApp.sendAction(try #require(sensitiveMoreItem.action), to: sensitiveMoreItem.target, from: sensitiveMoreItem)
            #expect(dismissCount == 0)
            #expect(harness.currentItem(singleFile.id)?.sensitivity == .sensitive)
        }

        @Test
        @MainActor
        func itemPreviewDialogToolbarAndDetailsHideVisualImageAndFileMetadataAndRevealOnUpdate() throws {
            TestSupport.ensureAppKitInitialized()
            let secretToken = Self.makeRuntimeSecret(tag: "preview-dialog")

            try TestSupport.withTemporaryHistoryStore { store, supportDir in
                let pngData = try TestSupport.makePNGData(pixelWidth: 80, pixelHeight: 60, color: .systemGreen)
                let encImgID = UUID()
                let encImgURL = try store.writeManagedAsset(pngData: pngData, role: .image, clipID: encImgID, encrypted: true)
                var encImageItem = ClipboardItem.fixture(
                    id: encImgID,
                    kind: .image,
                    text: "Secret \(secretToken)",
                    assetPath: encImgURL.path,
                    sensitivity: .sensitive
                )
                encImageItem.imageWidth = 80
                encImageItem.imageHeight = 60

                // 1. Encrypted .image in ItemPreviewDialogController hides screenshot while hidden and decodes .enc when revealed!
                let imageDialog = ItemPreviewDialogController(
                    item: encImageItem,
                    maximumContentSize: NSSize(width: 800, height: 600),
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: false,
                    loadContent: { item, _ in item }
                )
                defer { TestSupport.drainDelayedPerforms([imageDialog]) }
                _ = imageDialog.view
                imageDialog.view.layoutSubtreeIfNeeded()

                @MainActor
                func hasDecodedPreviewPicture(in root: NSView) -> Bool {
                    allViewDescendants(in: root)
                        .compactMap { $0 as? NSImageView }
                        .contains { !$0.isHidden && $0.image?.isTemplate == false && ($0.image?.size.width ?? 0) >= 60 }
                }
                #expect(!hasDecodedPreviewPicture(in: imageDialog.view), "Hidden .enc image preview must not show the screenshot")

                imageDialog.update(item: encImageItem, revealsSensitiveContent: true)
                imageDialog.view.layoutSubtreeIfNeeded()
                #expect(hasDecodedPreviewPicture(in: imageDialog.view), "Revealing .enc image preview must decode and display screenshot")

                // 2. Sensitive single image .file across ItemPreviewDialogController, ItemPreviewToolbar, and ItemPreviewDetailsView (.docked + .list).
                let secretFolder = supportDir.appendingPathComponent("PrivateVaultDir", isDirectory: true)
                try FileManager.default.createDirectory(at: secretFolder, withIntermediateDirectories: true)
                let secretFileURL = secretFolder.appendingPathComponent("passport-scan.png")
                try pngData.write(to: secretFileURL)

                let sensitiveFileItem = ClipboardItem.fixture(
                    kind: .file,
                    text: nil,
                    filePaths: [secretFileURL.path],
                    byteSize: pngData.count,
                    sensitivity: .sensitive
                )

                let fileDialog = ItemPreviewDialogController(
                    item: sensitiveFileItem,
                    maximumContentSize: NSSize(width: 800, height: 600),
                    detectsSensitiveContent: true,
                    revealsSensitiveContent: false,
                    loadContent: { item, _ in item }
                )
                let closeAccessory = fileDialog.makeCloseAccessory()
                defer { TestSupport.drainDelayedPerforms([fileDialog, closeAccessory]) }
                _ = fileDialog.view
                fileDialog.view.layoutSubtreeIfNeeded()
                closeAccessory.view.layoutSubtreeIfNeeded()

                #expect(!hasDecodedPreviewPicture(in: fileDialog.view), "Hidden sensitive image .file must not show visual image preview")
                let hiddenAccessoryFields = allViewDescendants(in: closeAccessory.view).compactMap { $0 as? NSTextField }
                #expect(hiddenAccessoryFields.contains { $0.stringValue == ItemPreviewDetailsView.typeName(for: sensitiveFileItem) })
                #expect(!hiddenAccessoryFields.contains { !$0.isHidden && ($0.stringValue.contains("passport-scan.png") || $0.stringValue.contains("PrivateVaultDir")) })
                let hiddenAccessoryTooltips = allViewDescendants(in: closeAccessory.view).compactMap(\.toolTip)
                #expect(!hiddenAccessoryTooltips.contains { $0.contains("passport-scan") || $0.contains("PrivateVaultDir") })

                let dockedDetails = ItemPreviewDetailsView(
                    item: sensitiveFileItem,
                    style: .docked,
                    hidesSensitiveContent: true
                )
                dockedDetails.arrangement = .list
                dockedDetails.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
                dockedDetails.layoutSubtreeIfNeeded()

                let hiddenDetailsFields = allViewDescendants(in: dockedDetails).compactMap { $0 as? NSTextField }
                #expect(hiddenDetailsFields.contains { $0.stringValue == SensitiveContent.wholeMask })
                #expect(!hiddenDetailsFields.contains { $0.stringValue.contains("passport-scan") || $0.stringValue.contains("PrivateVaultDir") })
                let hiddenDetailsTooltips = allViewDescendants(in: dockedDetails).compactMap(\.toolTip)
                #expect(!hiddenDetailsTooltips.contains { $0.contains("passport-scan") || $0.contains("PrivateVaultDir") })

                // Reveal sensitive .file (as Cmd+U does) and verify visual preview + filename + path + tooltip appear!
                fileDialog.update(item: sensitiveFileItem, revealsSensitiveContent: true)
                fileDialog.view.layoutSubtreeIfNeeded()
                closeAccessory.view.layoutSubtreeIfNeeded()
                #expect(hasDecodedPreviewPicture(in: fileDialog.view))
                let revealedAccessoryFields = allViewDescendants(in: closeAccessory.view).compactMap { $0 as? NSTextField }
                #expect(revealedAccessoryFields.contains { !$0.isHidden && $0.stringValue == "passport-scan.png" })
                #expect(revealedAccessoryFields.contains { !$0.isHidden && $0.stringValue.contains("PrivateVaultDir") })

                dockedDetails.update(item: sensitiveFileItem, hidesSensitiveContent: false)
                dockedDetails.layoutSubtreeIfNeeded()
                let expectedAbbrevPath = (secretFileURL.path as NSString).abbreviatingWithTildeInPath
                let revealedDetailsFields = allViewDescendants(in: dockedDetails).compactMap { $0 as? NSTextField }
                #expect(revealedDetailsFields.contains { $0.stringValue == expectedAbbrevPath })
                let revealedDetailsTooltips = allViewDescendants(in: dockedDetails).compactMap(\.toolTip)
                #expect(revealedDetailsTooltips.contains(expectedAbbrevPath))
            }
        }

        @MainActor
        private static func collectLabels(in root: NSView) -> [HistoryFixedTextColorLabel] {
            var results: [HistoryFixedTextColorLabel] = []
            if let label = root as? HistoryFixedTextColorLabel, !label.isHidden, label.superview != nil {
                results.append(label)
            }
            for subview in root.subviews where !subview.isHidden {
                results.append(contentsOf: collectLabels(in: subview))
            }
            return results
        }
    }
    /// A link row decodes the pictures of a stored preview in the background via
    /// `ImageAssetThumbnailLoader.shared`.
    @Suite(.serialized)
    struct LinkRowImageLoadingTests {
        private static let pageURL = URL(string: "https://site.example/page")!

        private enum Picture: CaseIterable, Sendable {
            case favicon
            case preview
        }

        private enum Change: CaseIterable, Sendable {
            case maskedWhileLoading
            case reusedForAnotherItemWhileLoading
            case previewsTurnedOffWhileLoading
        }

        private static var screenScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

        private static var faviconPixelSize: Int {
            let side = HistoryRow.typeIconSize
            return ImageAssetThumbnailLoader.maximumPixelSize(forDisplaySize: CGSize(width: side, height: side), scale: screenScale)
        }

        private static var previewPixelSize: Int {
            let size = CGSize(width: HistoryRow.linkPreviewImageWidth * 2, height: HistoryRow.linkPreviewImageHeight * 2)
            return ImageAssetThumbnailLoader.maximumPixelSize(forDisplaySize: size, scale: screenScale)
        }

        private static func writePNG(named name: String, width: Int, height: Int, in directory: URL) throws -> URL {
            let rep = try TestSupport.makeBitmap(pixelsWide: width, pixelsHigh: height)
            let url = directory.appendingPathComponent(name)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }

        /// Returns once the row's request for `url` has delivered its result. The loader calls
        /// the requests for one picture in the order they were made, so a request made after the
        /// row's is answered after it.
        @MainActor
        private static func waitForDecode(of url: URL, maximumPixelSize: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let cached = ImageAssetThumbnailLoader.shared.thumbnail(for: url, maximumPixelSize: maximumPixelSize) { _ in
                    continuation.resume()
                }
                if cached != nil {
                    // Decoded already: the row's callback is queued on the main queue ahead of this one.
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }

        @MainActor
        private static func toolTips(in view: NSView) -> [String] {
            ([view.toolTip].compactMap { $0 }) + view.subviews.flatMap { toolTips(in: $0) }
        }

        @MainActor
        private static func previewImageViews(in view: NSView) -> [NSImageView] {
            let own = (view as? NSImageView).map { String(describing: type(of: $0)).contains("AspectFill") ? [$0] : [] } ?? []
            return own + view.subviews.flatMap { previewImageViews(in: $0) }
        }

        @MainActor
        private static func makeRow() -> HistoryItemRowLinkView {
            HistoryItemRowLinkView(frame: NSRect(x: 0, y: 0, width: 480, height: HistoryRow.height))
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func faviconIsShownOnceDecoded() async throws {
            TestSupport.ensureAppKitInitialized()
            try await TestSupport.withTemporaryDirectory { directory in
                let faviconURL = try Self.writePNG(named: "favicon.png", width: 32, height: 32, in: directory)
                let preview = LinkPreview(url: Self.pageURL, title: "Site", description: nil, image: nil, favicon: nil, faviconURL: faviconURL)
                let row = Self.makeRow()

                row.configureForTest(item: .fixture(kind: .link, text: Self.pageURL.absoluteString), linkPreview: preview, showsLinkPreview: true)
                #expect(!Self.toolTips(in: row).contains("site.example"))

                await Self.waitForDecode(of: faviconURL, maximumPixelSize: Self.faviconPixelSize)
                #expect(Self.toolTips(in: row).contains("site.example"))
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func previewImageIsShownOnceDecoded() async throws {
            TestSupport.ensureAppKitInitialized()
            try await TestSupport.withTemporaryDirectory { directory in
                let imageURL = try Self.writePNG(named: "preview.png", width: 96, height: 48, in: directory)
                let preview = LinkPreview(url: Self.pageURL, title: "Site", description: nil, image: nil, favicon: nil, imageURL: imageURL)
                let row = Self.makeRow()

                row.configureForTest(item: .fixture(kind: .link, text: Self.pageURL.absoluteString), linkPreview: preview, showsLinkPreview: true)
                let imageView = try #require(Self.previewImageViews(in: row).first)
                #expect(imageView.image == nil)

                await Self.waitForDecode(of: imageURL, maximumPixelSize: Self.previewPixelSize)
                #expect(imageView.image != nil)
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: Picture.allCases, Change.allCases)
        @MainActor
        private func aPictureThatArrivesAfterTheRowChangedIsNotShown(picture: Picture, change: Change) async throws {
            TestSupport.ensureAppKitInitialized()
            try await TestSupport.withTemporaryDirectory { directory in
                let pictureURL = try Self.writePNG(named: "picture.png", width: 32, height: 32, in: directory)
                let preview: LinkPreview
                let pixelSize: Int
                switch picture {
                case .favicon:
                    preview = LinkPreview(url: Self.pageURL, title: "Site", description: nil, image: nil, favicon: nil, faviconURL: pictureURL)
                    pixelSize = Self.faviconPixelSize
                case .preview:
                    preview = LinkPreview(url: Self.pageURL, title: "Site", description: nil, image: nil, favicon: nil, imageURL: pictureURL)
                    pixelSize = Self.previewPixelSize
                }
                let itemID = UUID()
                let row = Self.makeRow()

                row.configureForTest(
                    item: .fixture(id: itemID, kind: .link, text: Self.pageURL.absoluteString),
                    linkPreview: preview,
                    showsLinkPreview: true
                )
                // The picture view stays with the row when it is no longer shown.
                let previewImageView = Self.previewImageViews(in: row).first

                // A row that stays as it is. The loader answers the requests for one picture in
                // the order they were made, so once the wait below is over, this row has been
                // answered too, which shows that the wait used the same request as the rows.
                let controlRow = Self.makeRow()
                controlRow.configureForTest(
                    item: .fixture(kind: .link, text: Self.pageURL.absoluteString),
                    linkPreview: preview,
                    showsLinkPreview: true
                )
                let controlImageView = Self.previewImageViews(in: controlRow).first

                switch change {
                case .maskedWhileLoading:
                    row.configureForTest(
                        item: .fixture(id: itemID, kind: .link, text: Self.pageURL.absoluteString, sensitivity: .sensitive),
                        linkPreview: preview,
                        showsLinkPreview: true
                    )
                case .reusedForAnotherItemWhileLoading:
                    row.prepareForReuse()
                    row.configureForTest(
                        item: .fixture(kind: .link, text: "https://other.example/page"),
                        showsLinkPreview: true
                    )
                case .previewsTurnedOffWhileLoading:
                    row.configureForTest(
                        item: .fixture(id: itemID, kind: .link, text: Self.pageURL.absoluteString),
                        linkPreview: preview,
                        showsLinkPreview: false
                    )
                }

                await Self.waitForDecode(of: pictureURL, maximumPixelSize: pixelSize)
                switch picture {
                case .favicon:
                    #expect(Self.toolTips(in: controlRow).contains("site.example"), "The loader had not answered the control row")
                    #expect(!Self.toolTips(in: row).contains("site.example"))
                case .preview:
                    #expect(try #require(controlImageView).image != nil, "The loader had not answered the control row")
                    #expect(try #require(previewImageView).image == nil)
                }
            }
        }
    }

    @Suite(.serialized)
    struct HistoryWindowBehaviorTests {
        @Test
        @MainActor
        func commandPaletteRunsCommandShortcuts() async throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.hideOnFocusLoss = false
            let item = ClipboardItem.fixture(kind: .text, text: "Editable clip")
            try harness.seedHistory([item])

            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            defer {
                TestSupport.tearDownHistoryWindow(historyWindow)
            }

            // ⌘K opens the command palette sheet.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 40, modifiers: [.command]))
            let paletteSheet = try #require(historyWindow.window.attachedSheet as? CommandPaletteSheetWindow)

            // Space is a plain key for typing in the search field, not a command shortcut.
            #expect(!paletteSheet.performKeyEquivalent(with: try TestSupport.keyDownEvent(keyCode: 49)))
            #expect(historyWindow.window.attachedSheet === paletteSheet)

            // ⌘S runs Add to Favorites and closes the command palette.
            #expect(paletteSheet.performKeyEquivalent(with: try TestSupport.keyDownEvent(keyCode: 1, modifiers: [.command])))
            #expect(harness.currentItem(item.id)?.isFavorite == true)
            #expect(historyWindow.window.attachedSheet == nil)

            // ⌘K then ⌘E closes the command palette and opens the preview editor sheet.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 40, modifiers: [.command]))
            let editPaletteSheet = try #require(historyWindow.window.attachedSheet as? CommandPaletteSheetWindow)
            #expect(editPaletteSheet.performKeyEquivalent(with: try TestSupport.keyDownEvent(keyCode: 14, modifiers: [.command])))
            let editorOpened = await TestSupport.waitUntil(timeout: .seconds(5)) {
                guard let sheet = historyWindow.window.attachedSheet,
                      !(sheet is CommandPaletteSheetWindow),
                      let contentView = sheet.contentView else {
                    return false
                }
                return findEditableTextView(in: contentView) != nil
            }
            #expect(editorOpened)
            if let editSheet = historyWindow.window.attachedSheet {
                if let vc = editSheet.contentViewController {
                    TestSupport.drainDelayedPerforms([vc])
                }
                historyWindow.window.endSheet(editSheet)
            }

            // ⌘K then ⌘R closes the command palette and opens the Rename sheet.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 40, modifiers: [.command]))
            let renamePaletteSheet = try #require(historyWindow.window.attachedSheet as? CommandPaletteSheetWindow)
            #expect(renamePaletteSheet.performKeyEquivalent(with: try TestSupport.keyDownEvent(keyCode: 15, modifiers: [.command])))
            let renameOpened = await TestSupport.waitUntil(timeout: .seconds(5)) {
                guard let sheet = historyWindow.window.attachedSheet,
                      !(sheet is CommandPaletteSheetWindow) else {
                    return false
                }
                return true
            }
            #expect(renameOpened)
        }

        @Test
        @MainActor
        func commandPaletteLeavesDeleteKeysToATypedQuery() throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.hideOnFocusLoss = false
            let item = ClipboardItem.fixture(kind: .text, text: "Deletable clip")
            try harness.seedHistory([item])

            var transientTargets: [AnyObject] = []
            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            defer {
                TestSupport.tearDownHistoryWindow(historyWindow, keepingAlive: transientTargets)
            }

            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 40, modifiers: [.command]))
            let paletteSheet = try #require(historyWindow.window.attachedSheet as? CommandPaletteSheetWindow)
            transientTargets.append(paletteSheet)
            if let vc = paletteSheet.contentViewController {
                transientTargets.append(vc)
            }
            let contentView = try #require(paletteSheet.contentView)
            let searchField = try #require(findEditableTextField(in: contentView))
            let commandDelete = try TestSupport.keyDownEvent(keyCode: 51, modifiers: [.command])

            // With a query typed, ⌘⌫ is left to the search field and the item stays.
            searchField.stringValue = "Del"
            #expect(!paletteSheet.performKeyEquivalent(with: commandDelete))
            #expect(harness.currentItem(item.id) != nil)
            #expect(historyWindow.window.attachedSheet === paletteSheet)

            // With nothing typed, ⌘⌫ runs Delete as the palette lists it.
            searchField.stringValue = ""
            #expect(paletteSheet.performKeyEquivalent(with: commandDelete))
            #expect(harness.currentItem(item.id) == nil)
        }

        @Test
        @MainActor
        func windowFrameIsSavedOnceTheWindowHasBeenShown() throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            defer { TestSupport.tearDownHistoryWindow(historyWindow) }

            historyWindow.show()
            historyWindow.saveWindowFrame()

            let frame = historyWindow.window.frame
            let preferences = harness.model.preferences
            #expect(preferences.historyWindowX == Double(frame.origin.x))
            #expect(preferences.historyWindowY == Double(frame.origin.y))
            #expect(preferences.historyWindowWidth == Double(frame.width))
            #expect(preferences.historyWindowHeight == Double(frame.height))
            #expect(harness.preferencesStore.load().historyWindowWidth == Double(frame.width))
        }

        @Test
        @MainActor
        func windowFrameIsNotSavedBeforeTheWindowHasBeenShown() throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            var initialPrefs = harness.model.preferences
            initialPrefs.openWindowStrategy = HistoryWindowOpenStrategy.lastLocation.rawValue
            initialPrefs.historyWindowX = 222
            initialPrefs.historyWindowY = 333
            initialPrefs.historyWindowWidth = 520
            initialPrefs.historyWindowHeight = 460
            harness.model.preferences = initialPrefs
            harness.preferencesStore.save(initialPrefs)

            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.tearDownHistoryWindow(historyWindow) }
            historyWindow.saveWindowFrame()
            #expect(harness.model.preferences.historyWindowX == 222)
            #expect(harness.model.preferences.historyWindowY == 333)
        }

        @Test
        @MainActor
        func commandPaletteAndCmdUShortcutHandleImageAndFileSensitivityAndEncryptedOpenGuards() throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.hideOnFocusLoss = false

            let secretToken = ["sk", "-proj-cmd-", String(repeating: "d4F6gH8j", count: 4)].joined()
            let pngData = try TestSupport.makePNGData(pixelWidth: 48, pixelHeight: 36)

            let plainImgID = UUID()
            let plainImgURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: plainImgID, encrypted: false)
            let plainImg = ClipboardItem.fixture(
                id: plainImgID,
                kind: .image,
                text: nil,
                assetPath: plainImgURL.path,
                copiedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )

            let encImgID = UUID()
            let encImgURL = try harness.historyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: encImgID, encrypted: true)
            let encImg = ClipboardItem.fixture(
                id: encImgID,
                kind: .image,
                text: "Secret \(secretToken)",
                assetPath: encImgURL.path,
                copiedAt: Date(timeIntervalSince1970: 1_700_000_400)
            )

            let realFileA = harness.supportDirectory.appendingPathComponent("alpha.txt")
            let realFileB = harness.supportDirectory.appendingPathComponent("beta.txt")
            try Data("alpha".utf8).write(to: realFileA)
            try Data("beta".utf8).write(to: realFileB)

            let singleFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [realFileA.path],
                copiedAt: Date(timeIntervalSince1970: 1_700_000_300)
            )
            let missingFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [harness.supportDirectory.appendingPathComponent("missing.txt").path],
                copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                sensitivity: .sensitive
            )
            let multiFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [realFileA.path, realFileB.path],
                copiedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )

            try harness.seedHistory([plainImg, encImg, singleFile, missingFile, multiFile])

            var transientTargets: [AnyObject] = []
            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            defer {
                TestSupport.tearDownHistoryWindow(historyWindow, keepingAlive: transientTargets)
            }

            func findTableView(in root: NSView) -> NSTableView? {
                if let tv = root as? NSTableView {
                    return tv
                }
                for sub in root.subviews {
                    if let found = findTableView(in: sub) {
                        return found
                    }
                }
                return nil
            }

            func allTextValues(in root: NSView) -> [String] {
                var strings: [String] = []
                if let tf = root as? NSTextField {
                    strings.append(tf.stringValue)
                }
                for sub in root.subviews {
                    strings.append(contentsOf: allTextValues(in: sub))
                }
                return strings
            }

            func paletteCommandTitles(selecting item: ClipboardItem) throws -> [String] {
                harness.model.selectedItemID = item.id
                harness.model.selectedItemIDs = [item.id]
                harness.model.selectedItemIDsInSelectionOrder = [item.id]

                historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 40, modifiers: [.command]))
                let sheet = try #require(historyWindow.window.attachedSheet as? CommandPaletteSheetWindow)
                let sheetVC = sheet.contentViewController
                transientTargets.append(sheet)
                if let sheetVC {
                    transientTargets.append(sheetVC)
                }
                defer {
                    let sheetTargets: [AnyObject] = [sheet] + (sheetVC.map { [$0] } ?? [])
                    TestSupport.drainDelayedPerforms(sheetTargets)
                    historyWindow.window.endSheet(sheet)
                    TestSupport.drainDelayedPerforms(sheetTargets)
                }

                let contentView = try #require(sheet.contentView)
                contentView.layoutSubtreeIfNeeded()
                let tableView = try #require(findTableView(in: contentView))
                let column = tableView.tableColumns.first
                var titles: [String] = []
                for row in 0..<tableView.numberOfRows {
                    if let cellView = tableView.delegate?.tableView?(tableView, viewFor: column, row: row) {
                        titles.append(contentsOf: allTextValues(in: cellView))
                    }
                }
                return titles
            }

            // 1. Plain .png image includes Mark as Sensitive AND Open With...
            let plainImgTitles = try paletteCommandTitles(selecting: plainImg)
            #expect(plainImgTitles.contains(L10n.string("Mark as Sensitive")))
            #expect(plainImgTitles.contains(L10n.string("Open With...")))

            // 2. Encrypted .enc image includes Show Sensitive Content + Mark as Not Sensitive and OMITS Open in ... / Open With...!
            let encImgTitles = try paletteCommandTitles(selecting: encImg)
            #expect(encImgTitles.contains(L10n.string("Show Sensitive Content")))
            #expect(encImgTitles.contains(L10n.string("Mark as Not Sensitive")))
            #expect(!encImgTitles.contains(L10n.string("Open With...")))
            #expect(!encImgTitles.contains { $0.hasPrefix("Open in ") })

            // 3. Cmd+U (keyCode 32, .command) toggles Show Sensitive Content -> Hide Sensitive Content on the selected .enc image!
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let revealedEncImgTitles = try paletteCommandTitles(selecting: encImg)
            #expect(revealedEncImgTitles.contains(L10n.string("Hide Sensitive Content")))

            // 4. Single .file, missing .file, and multiple .file Command Palette builders all expose sensitivity commands!
            let singleFileTitles = try paletteCommandTitles(selecting: singleFile)
            #expect(singleFileTitles.contains(L10n.string("Mark as Sensitive")))

            let missingFileTitles = try paletteCommandTitles(selecting: missingFile)
            #expect(missingFileTitles.contains(L10n.string("Show Sensitive Content")))
            #expect(missingFileTitles.contains(L10n.string("Mark as Not Sensitive")))

            let multiFileTitles = try paletteCommandTitles(selecting: multiFile)
            #expect(multiFileTitles.contains(L10n.string("Mark as Sensitive")))
        }
    }

    @Suite(.serialized)
    struct SettingsViewWiringTests {
        @MainActor
        private static func makeLockedCoordinatorHarness(
            supportDirectory: URL,
            keyProvider: any DatabaseKeyProvider
        ) throws -> TestCoordinatorHarness {
            try TestSupport.makeTestCoordinator(
                supportDirectory: supportDirectory,
                keyProvider: keyProvider,
                probeStoreBeforeInit: true
            )
        }

        @MainActor
        private static func safeAXAttribute(_ attr: NSAccessibility.Attribute, of object: AnyObject) -> Any? {
            guard let supported = object.accessibilityAttributeNames?(),
                  supported.contains(attr) else {
                return nil
            }
            return object.accessibilityAttributeValue?(attr)
        }

        @MainActor
        private static func collectAccessibilityObjects(in root: AnyObject) -> [AnyObject] {
            var visited = Set<ObjectIdentifier>()
            var result: [AnyObject] = []
            func walk(_ object: AnyObject) {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return }
                result.append(object)
                if let children = object.accessibilityChildren?() {
                    for child in children {
                        walk(child as AnyObject)
                    }
                }
                if let children = safeAXAttribute(.children, of: object) as? [AnyObject] {
                    for child in children {
                        walk(child)
                    }
                }
                if let view = object as? NSView {
                    for subview in view.subviews {
                        walk(subview)
                    }
                }
            }
            walk(root)
            return result
        }

        @MainActor
        private static func axStringAttributes(of object: AnyObject) -> [String] {
            var values: [String] = []
            if let label = object.accessibilityLabel?(), !label.isEmpty { values.append(label) }
            if let title = object.accessibilityTitle?(), !title.isEmpty { values.append(title) }
            let valueSel = NSSelectorFromString("accessibilityValue")
            if object.responds(to: valueSel),
               let val = object.perform(valueSel)?.takeUnretainedValue() as? String,
               !val.isEmpty {
                values.append(val)
            }
            for attr: NSAccessibility.Attribute in [.title, .description, .value] {
                if let str = safeAXAttribute(attr, of: object) as? String, !str.isEmpty {
                    values.append(str)
                }
            }
            return values
        }

        @MainActor
        private static func axRole(of object: AnyObject) -> NSAccessibility.Role? {
            if let role = object.accessibilityRole?() {
                return role
            }
            if let rawRole = safeAXAttribute(.role, of: object) as? String {
                return NSAccessibility.Role(rawValue: rawRole)
            }
            return nil
        }

        @MainActor
        private static func axSubrole(of object: AnyObject) -> NSAccessibility.Subrole? {
            if let subrole = object.accessibilitySubrole?() {
                return subrole
            }
            if let rawSubrole = safeAXAttribute(.subrole, of: object) as? String {
                return NSAccessibility.Subrole(rawValue: rawSubrole)
            }
            return nil
        }

        @MainActor
        private static func axIsEnabled(_ object: AnyObject) -> Bool {
            if let enabled = object.isAccessibilityEnabled?() {
                return enabled
            }
            if let number = safeAXAttribute(.enabled, of: object) as? NSNumber {
                return number.boolValue
            }
            return false
        }

        @MainActor
        private static func renderedStrings(in root: NSView) -> [String] {
            var strings: [String] = []
            for view in allViewDescendants(in: root, includeGlassContentView: false) {
                if let tf = view as? NSTextField, !tf.isHidden, !tf.stringValue.isEmpty {
                    strings.append(tf.stringValue)
                } else if let button = view as? NSButton, !button.isHidden, !button.title.isEmpty {
                    strings.append(button.title)
                }
            }
            for element in collectAccessibilityObjects(in: root) {
                strings.append(contentsOf: axStringAttributes(of: element))
            }
            return strings
        }

        @MainActor
        private static func findHostedButton(titled title: String, in root: NSView) -> (isEnabled: Bool, press: () -> Void)? {
            for view in allViewDescendants(in: root, includeGlassContentView: false) {
                if let button = view as? NSButton, !button.isHidden, button.title == title {
                    return (
                        isEnabled: button.isEnabled,
                        press: { button.performClick(nil) }
                    )
                }
            }
            for element in collectAccessibilityObjects(in: root) where axRole(of: element) == .button {
                if axStringAttributes(of: element).contains(title) {
                    return (
                        isEnabled: axIsEnabled(element),
                        press: {
                            if element.accessibilityPerformPress?() == true {
                                return
                            }
                            if let actions = element.accessibilityActionNames?(), actions.contains(.press) {
                                element.accessibilityPerformAction?(.press)
                            }
                        }
                    )
                }
            }
            return nil
        }

        @MainActor
        private static func findHostedSwitchEnabledState(labeled label: String, in root: NSView) -> Bool? {
            let switches = allViewDescendants(in: root, includeGlassContentView: false).compactMap { $0 as? NSSwitch }.filter { !$0.isHidden }
            if let matchingSwitch = switches.first(where: { axStringAttributes(of: $0).contains(label) }) {
                return matchingSwitch.isEnabled
            }
            if switches.count == 1 {
                return switches[0].isEnabled
            }
            for element in collectAccessibilityObjects(in: root) {
                let role = axRole(of: element)
                if role == .checkBox || axSubrole(of: element) == .switch {
                    if axStringAttributes(of: element).contains(label) {
                        return axIsEnabled(element)
                    }
                }
            }
            return nil
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func changingAPreferenceInTheSettingsWindowSavesIt() async throws {
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
            defer {
                TestSupport.drainDelayedPerforms([window, hostingView])
                window.orderOut(nil)
                window.contentView = nil
                TestSupport.drainDelayedPerforms([window, hostingView])
            }
            hostingView.layoutSubtreeIfNeeded()

            let original = harness.model.preferences.warnOnClearHistory
            #expect(harness.preferencesStore.load().warnOnClearHistory == original)

            harness.model.preferences.warnOnClearHistory.toggle()
            let saved = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.preferencesStore.load().warnOnClearHistory != original
            }
            #expect(saved, "The view did not save the changed preference")
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func importExportSettingsViewReflectsStoreLockStateDisablesArchiveControlsAndUnlocks() async throws {
            try await TestSupport.withTemporaryDirectory { supportDir in
                let masterKey = SymmetricKey(size: .bits256)
                let seededClip = ClipboardItem.fixture(
                    kind: .text,
                    text: "Seeded clip behind locked ImportExportSettingsView",
                    copiedAt: Date(timeIntervalSince1970: 1_715_800_100)
                )
                do {
                    let seedStore = GRDBHistoryStore(
                        directory: supportDir,
                        keyProvider: InMemoryDatabaseKeyProvider(key: masterKey)
                    )
                    defer { seedStore.close() }
                    _ = try seedStore.saveAndReconcileItem(seededClip, convertingExternalAssets: true)
                }

                let toggleProvider = InMemoryDatabaseKeyProvider(
                    key: nil,
                    error: .encryptionKeyUnavailable(.interactionNotAllowed)
                )
                let lockedHarness = try Self.makeLockedCoordinatorHarness(
                    supportDirectory: supportDir,
                    keyProvider: toggleProvider
                )
                defer { lockedHarness.cleanup() }

                #expect(lockedHarness.model.storeLockState == .locked(.interactionNotAllowed))

                let hostingView = NSHostingView(
                    rootView: ImportExportSettingsView(model: lockedHarness.model)
                        .environmentObject(lockedHarness.coordinator)
                )
                hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                window.contentView = hostingView
                window.orderBack(nil)
                defer {
                    TestSupport.drainDelayedPerforms([window, hostingView])
                    window.orderOut(nil)
                    window.contentView = nil
                    TestSupport.drainDelayedPerforms([window, hostingView])
                }
                hostingView.layoutSubtreeIfNeeded()
                hostingView.displayIfNeeded()

                let unlockTitle = L10n.string("Unlock History")
                let exportTitle = L10n.string("Export...")
                let importTitle = L10n.string("Import...")
                let passphraseToggleLabel = L10n.string("Encrypt archive with passphrase")
                let lockedState: StoreLockState = .locked(.interactionNotAllowed)
                let lockedStatusTitle = PersistenceErrorLocalization.statusTitle(for: lockedState)
                let lockedStatusMessage = PersistenceErrorLocalization.statusMessage(for: lockedState)

                let axEnhancedAttr = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
                let previousEnhancedAX = (NSApp.accessibilityAttributeValue(axEnhancedAttr) as? Bool) ?? false
                NSApp.accessibilitySetValue(true, forAttribute: axEnhancedAttr)
                defer {
                    NSApp.accessibilitySetValue(previousEnhancedAX, forAttribute: axEnhancedAttr)
                }

                // 1. While .locked(.interactionNotAllowed), warning banner + Unlock History button render and archive controls are disabled.
                let lockedRendered = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    hostingView.layoutSubtreeIfNeeded()
                    let fullText = Self.renderedStrings(in: hostingView).joined(separator: "\n")
                    return fullText.contains(lockedStatusTitle)
                        && fullText.contains(lockedStatusMessage)
                        && Self.findHostedButton(titled: unlockTitle, in: hostingView) != nil
                }
                #expect(lockedRendered)

                let unlockWhileLocked = try #require(Self.findHostedButton(titled: unlockTitle, in: hostingView))
                let exportWhileLocked = try #require(Self.findHostedButton(titled: exportTitle, in: hostingView))
                let importWhileLocked = try #require(Self.findHostedButton(titled: importTitle, in: hostingView))
                #expect(unlockWhileLocked.isEnabled)
                #expect(!exportWhileLocked.isEnabled)
                #expect(!importWhileLocked.isEnabled)
                #expect(Self.findHostedSwitchEnabledState(labeled: passphraseToggleLabel, in: hostingView) == false)

                // 2. Pressing Unlock History with a wrong key invokes retryUnlockHistoryStore() and updates banner to .keyMismatch.
                toggleProvider.setError(nil)
                toggleProvider.setKey(SymmetricKey(size: .bits256))
                unlockWhileLocked.press()
                #expect(lockedHarness.model.storeLockState == .keyMismatch)

                let mismatchStatusTitle = PersistenceErrorLocalization.statusTitle(for: .keyMismatch)
                let mismatchStatusMessage = PersistenceErrorLocalization.statusMessage(for: .keyMismatch)
                let mismatchRendered = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    hostingView.layoutSubtreeIfNeeded()
                    let fullText = Self.renderedStrings(in: hostingView).joined(separator: "\n")
                    return fullText.contains(mismatchStatusTitle) && fullText.contains(mismatchStatusMessage)
                }
                #expect(mismatchRendered)

                let unlockWhileMismatch = try #require(Self.findHostedButton(titled: unlockTitle, in: hostingView))
                let exportWhileMismatch = try #require(Self.findHostedButton(titled: exportTitle, in: hostingView))
                let importWhileMismatch = try #require(Self.findHostedButton(titled: importTitle, in: hostingView))
                #expect(unlockWhileMismatch.isEnabled)
                #expect(!exportWhileMismatch.isEnabled)
                #expect(!importWhileMismatch.isEnabled)
                #expect(Self.findHostedSwitchEnabledState(labeled: passphraseToggleLabel, in: hostingView) == false)

                // 3. Installing the matching key and pressing Unlock History unlocks the store, hides the banner, and enables controls.
                toggleProvider.setKey(masterKey)
                unlockWhileMismatch.press()
                #expect(lockedHarness.model.storeLockState == .unlocked)
                #expect(lockedHarness.model.items.map(\.id) == [seededClip.id])

                let unlockedRendered = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    hostingView.layoutSubtreeIfNeeded()
                    let fullText = Self.renderedStrings(in: hostingView).joined(separator: "\n")
                    return Self.findHostedButton(titled: unlockTitle, in: hostingView) == nil
                        && !fullText.contains(lockedStatusMessage)
                        && !fullText.contains(mismatchStatusMessage)
                        && !fullText.contains(mismatchStatusTitle)
                        && (Self.findHostedButton(titled: exportTitle, in: hostingView)?.isEnabled == true)
                }
                #expect(unlockedRendered)

                let exportWhenUnlocked = try #require(Self.findHostedButton(titled: exportTitle, in: hostingView))
                let importWhenUnlocked = try #require(Self.findHostedButton(titled: importTitle, in: hostingView))
                #expect(exportWhenUnlocked.isEnabled)
                #expect(importWhenUnlocked.isEnabled)
                #expect(Self.findHostedSwitchEnabledState(labeled: passphraseToggleLabel, in: hostingView) == true)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func lockedHistoryViewAndAppDelegateTestStateReflectStoreLockTransitionsAndUnlock() async throws {
            // Verify internal-accessible AppDelegate test-mode state without mutating production visibility or touching NSStatusBar.
            #expect(AppDelegate.isRunningTests)
            do {
                let delegate = AppDelegate()
                defer {
                    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                }
                #expect(delegate.model.storeLockState == .unlocked)
            }

            try await TestSupport.withTemporaryDirectory { supportDir in
                let masterKey = SymmetricKey(size: .bits256)
                let seededClip = ClipboardItem.fixture(
                    kind: .text,
                    text: "Clip revealed after LockedHistoryView unlock",
                    copiedAt: Date(timeIntervalSince1970: 1_715_800_200)
                )
                do {
                    let seedStore = GRDBHistoryStore(
                        directory: supportDir,
                        keyProvider: InMemoryDatabaseKeyProvider(key: masterKey)
                    )
                    defer { seedStore.close() }
                    _ = try seedStore.saveAndReconcileItem(seededClip, convertingExternalAssets: true)
                }

                let toggleProvider = InMemoryDatabaseKeyProvider(
                    key: nil,
                    error: .encryptionKeyUnavailable(.interactionNotAllowed)
                )
                let lockedHarness = try Self.makeLockedCoordinatorHarness(
                    supportDirectory: supportDir,
                    keyProvider: toggleProvider
                )
                defer { lockedHarness.cleanup() }

                let hostWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                hostWindow.isReleasedWhenClosed = false
                hostWindow.alphaValue = 0
                let contentVC = HistoryContentViewController(
                    model: lockedHarness.model,
                    coordinator: lockedHarness.coordinator
                )
                hostWindow.contentViewController = contentVC
                defer {
                    TestSupport.drainDelayedPerforms([hostWindow, contentVC] + contentVC.children)
                    hostWindow.orderOut(nil)
                    hostWindow.contentViewController = nil
                    TestSupport.drainDelayedPerforms([contentVC])
                }
                contentVC.view.layoutSubtreeIfNeeded()

                let unlockTitle = L10n.string("Unlock History")
                let emptyListTitle = L10n.string("No clipboard items")
                let emptyTrashTitle = L10n.string("Trash is empty")
                let emptySearchTitle = L10n.string("No results")

                func visibleTextFieldStrings(in root: NSView) -> [String] {
                    func walk(_ view: NSView) -> [String] {
                        guard !view.isHidden else { return [] }
                        var found: [String] = []
                        if let tf = view as? NSTextField, !tf.stringValue.isEmpty {
                            found.append(tf.stringValue)
                        }
                        for sub in view.subviews {
                            found.append(contentsOf: walk(sub))
                        }
                        return found
                    }
                    return walk(root)
                }

                func findVisibleNSButton(titled title: String, in root: NSView) -> NSButton? {
                    func walk(_ view: NSView) -> NSButton? {
                        guard !view.isHidden else { return nil }
                        if let button = view as? NSButton, button.title == title {
                            return button
                        }
                        for sub in view.subviews {
                            if let match = walk(sub) {
                                return match
                            }
                        }
                        return nil
                    }
                    return walk(root)
                }

                // 1. Initial .locked(.interactionNotAllowed) state shows LockedHistoryView and hides all EmptyHistory views.
                let lockedState: StoreLockState = .locked(.interactionNotAllowed)
                let initialTexts = visibleTextFieldStrings(in: contentVC.view)
                #expect(initialTexts.contains(PersistenceErrorLocalization.statusTitle(for: lockedState)))
                #expect(initialTexts.contains(PersistenceErrorLocalization.statusMessage(for: lockedState)))
                #expect(!initialTexts.contains(emptyListTitle))
                #expect(!initialTexts.contains(emptyTrashTitle))
                #expect(!initialTexts.contains(emptySearchTitle))

                // Trash filter and non-empty search query still keep LockedHistoryView visible while locked.
                lockedHarness.model.selectedHistoryFilterContentTypes = [.trash]
                lockedHarness.model.searchQuery = "unmatched"
                let trashSearchSettled = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    contentVC.view.layoutSubtreeIfNeeded()
                    let texts = visibleTextFieldStrings(in: contentVC.view)
                    return texts.contains(PersistenceErrorLocalization.statusTitle(for: lockedState))
                        && !texts.contains(emptyTrashTitle)
                        && !texts.contains(emptySearchTitle)
                }
                #expect(trashSearchSettled)
                lockedHarness.model.selectedHistoryFilterContentTypes = []
                lockedHarness.model.searchQuery = ""

                // 2. Clicking Unlock History with a wrong key transitions LockedHistoryView to .keyMismatch via Combine.
                let unlockButtonLocked = try #require(findVisibleNSButton(titled: unlockTitle, in: contentVC.view))
                #expect(unlockButtonLocked.isEnabled)
                toggleProvider.setError(nil)
                toggleProvider.setKey(SymmetricKey(size: .bits256))
                unlockButtonLocked.performClick(nil)
                #expect(lockedHarness.model.storeLockState == .keyMismatch)

                let mismatchUpdated = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    contentVC.view.layoutSubtreeIfNeeded()
                    let texts = visibleTextFieldStrings(in: contentVC.view)
                    return texts.contains(PersistenceErrorLocalization.statusTitle(for: .keyMismatch))
                        && texts.contains(PersistenceErrorLocalization.statusMessage(for: .keyMismatch))
                }
                #expect(mismatchUpdated)

                // 3. Installing matching masterKey and clicking Unlock History unlocks the store and hides LockedHistoryView.
                let unlockButtonMismatch = try #require(findVisibleNSButton(titled: unlockTitle, in: contentVC.view))
                toggleProvider.setKey(masterKey)
                unlockButtonMismatch.performClick(nil)
                #expect(lockedHarness.model.storeLockState == .unlocked)
                #expect(lockedHarness.model.items.map(\.id) == [seededClip.id])

                let unlockedUpdated = await TestSupport.waitUntil(timeout: .seconds(5)) {
                    contentVC.view.layoutSubtreeIfNeeded()
                    return findVisibleNSButton(titled: unlockTitle, in: contentVC.view) == nil
                        && !visibleTextFieldStrings(in: contentVC.view).contains(
                            PersistenceErrorLocalization.statusMessage(for: .keyMismatch)
                        )
                }
                #expect(unlockedUpdated)

                // 4. Direct History.reload(..., storeLockState:) with empty items restores EmptyHistory once .unlocked.
                let standaloneHistory = History(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
                defer { TestSupport.drainDelayedPerforms([standaloneHistory]) }
                standaloneHistory.reload(
                    items: [],
                    availableTags: [],
                    selectedItemID: nil,
                    selectedItemIDs: [],
                    searchQuery: "",
                    showCommandNumberShortcut: true,
                    showPreviewForLinks: false,
                    detectSensitiveContent: true,
                    showDividers: false,
                    preferPastingAsPlainText: true,
                    groupPinnedFavorites: false,
                    sectionDate: nil,
                    storeLockState: .locked(.notFound),
                    onSelectFirstItem: { _ in }
                )
                #expect(findVisibleNSButton(titled: unlockTitle, in: standaloneHistory) != nil)
                #expect(!visibleTextFieldStrings(in: standaloneHistory).contains(emptyListTitle))

                standaloneHistory.reload(
                    items: [],
                    availableTags: [],
                    selectedItemID: nil,
                    selectedItemIDs: [],
                    searchQuery: "",
                    showCommandNumberShortcut: true,
                    showPreviewForLinks: false,
                    detectSensitiveContent: true,
                    showDividers: false,
                    preferPastingAsPlainText: true,
                    groupPinnedFavorites: false,
                    sectionDate: nil,
                    storeLockState: .unlocked,
                    onSelectFirstItem: { _ in }
                )
                #expect(findVisibleNSButton(titled: unlockTitle, in: standaloneHistory) == nil)
                #expect(visibleTextFieldStrings(in: standaloneHistory).contains(emptyListTitle))
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func appDelegateStatusPresentationMenusAndRetryUnlockReflectStoreLockStates() async throws {
            try await TestSupport.withTemporaryDirectory { supportDir in
                let masterKey = SymmetricKey(size: .bits256)
                let seededClip = ClipboardItem.fixture(
                    kind: .text,
                    text: "Clip unlocked through AppDelegate",
                    copiedAt: Date(timeIntervalSince1970: 1_715_800_300)
                )
                do {
                    let seedStore = GRDBHistoryStore(
                        directory: supportDir,
                        keyProvider: InMemoryDatabaseKeyProvider(key: masterKey)
                    )
                    defer { seedStore.close() }
                    _ = try seedStore.saveAndReconcileItem(seededClip, convertingExternalAssets: true)
                }

                let toggleProvider = InMemoryDatabaseKeyProvider(
                    key: nil,
                    error: .encryptionKeyUnavailable(.interactionNotAllowed)
                )
                let suiteName = "com.ikryanov.clipbook.tests.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suiteName))
                defer { defaults.removePersistentDomain(forName: suiteName) }

                let delegate = AppDelegate(
                    supportDirectory: supportDir,
                    userDefaults: defaults,
                    keyProvider: toggleProvider
                )
                defer {
                    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                }

                // 1. Starts .locked(.interactionNotAllowed) on init: disables Pause/Resume and adds Unlock History...
                delegate.retryUnlockHistory()
                #expect(delegate.model.storeLockState == .locked(.interactionNotAllowed))
                let unlockTitle = L10n.string("Unlock History...")
                let lockedTitle = PersistenceErrorLocalization.statusTitle(for: .locked(.interactionNotAllowed))
                #expect(delegate.statusItemPresentation.label == "ClipBook — \(lockedTitle)")
                #expect(delegate.statusItemPresentation.isPausedIcon)

                let historyLocked = delegate.makeHistoryMenu()
                historyLocked.update()
                let historyLockStatus = try #require(historyLocked.item(withTitle: lockedTitle))
                #expect(!historyLockStatus.isEnabled)
                let historyUnlockLocked = try #require(historyLocked.item(withTitle: unlockTitle))
                #expect(historyUnlockLocked.isEnabled)
                #expect(historyUnlockLocked.target === delegate)
                #expect(historyUnlockLocked.action == #selector(AppDelegate.retryUnlockHistory))
                #expect(historyLocked.item(withTitle: L10n.string("Pause Clipboard Capture"))?.isEnabled == false)

                let statusLocked = delegate.makeStatusMenu()
                statusLocked.update()
                let statusLockStatus = try #require(statusLocked.item(withTitle: lockedTitle))
                #expect(!statusLockStatus.isEnabled)
                let statusUnlockLocked = try #require(statusLocked.item(withTitle: unlockTitle))
                #expect(statusUnlockLocked.isEnabled)
                #expect(statusUnlockLocked.target === delegate)
                #expect(statusUnlockLocked.action == #selector(AppDelegate.retryUnlockHistory))
                #expect(statusLocked.item(withTitle: L10n.string("Pause"))?.isEnabled == false)

                // 2. Dispatching the menu item action with a wrong key transitions to .keyMismatch.
                toggleProvider.setError(nil)
                toggleProvider.setKey(SymmetricKey(size: .bits256))
                delegate.perform(historyUnlockLocked.action, with: historyUnlockLocked)
                #expect(delegate.model.storeLockState == .keyMismatch)
                let mismatchTitle = PersistenceErrorLocalization.statusTitle(for: .keyMismatch)
                #expect(delegate.statusItemPresentation.label == "ClipBook — \(mismatchTitle)")
                #expect(delegate.statusItemPresentation.isPausedIcon)

                let historyMismatch = delegate.makeHistoryMenu()
                historyMismatch.update()
                #expect(historyMismatch.item(withTitle: mismatchTitle)?.isEnabled == false)
                let historyUnlockMismatch = try #require(historyMismatch.item(withTitle: unlockTitle))
                #expect(historyUnlockMismatch.isEnabled)
                #expect(historyMismatch.item(withTitle: L10n.string("Pause Clipboard Capture"))?.isEnabled == false)

                let statusMismatch = delegate.makeStatusMenu()
                statusMismatch.update()
                #expect(statusMismatch.item(withTitle: mismatchTitle)?.isEnabled == false)
                #expect(statusMismatch.item(withTitle: unlockTitle)?.isEnabled == true)
                #expect(statusMismatch.item(withTitle: L10n.string("Pause"))?.isEnabled == false)

                // 3. Installing the matching key and invoking retryUnlockHistory() restores .unlocked state and paused toggle.
                toggleProvider.setKey(masterKey)
                delegate.perform(historyUnlockMismatch.action, with: historyUnlockMismatch)
                #expect(delegate.model.storeLockState == .unlocked)
                #expect(delegate.model.items.map(\.id) == [seededClip.id])
                #expect(delegate.statusItemPresentation.label == "ClipBook")
                #expect(!delegate.statusItemPresentation.isPausedIcon)
                delegate.model.isPaused = true
                #expect(delegate.statusItemPresentation.label == "ClipBook")
                #expect(delegate.statusItemPresentation.isPausedIcon)
                delegate.model.isPaused = false
                #expect(delegate.makeHistoryMenu().item(withTitle: unlockTitle) == nil)
                #expect(delegate.makeHistoryMenu().item(withTitle: L10n.string("Pause Clipboard Capture"))?.isEnabled == true)
                #expect(delegate.makeStatusMenu().item(withTitle: unlockTitle) == nil)
                #expect(delegate.makeStatusMenu().item(withTitle: L10n.string("Pause"))?.isEnabled == true)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func archivePassphraseSheetModelValidatesCreateAndUnlockFlows() async throws {
            let createModel = ArchivePassphraseSheetModel(mode: .create)
            var confirmedPassphrases: [String] = []
            #expect(createModel.isConfirmDisabled)
            #expect(!createModel.showsMismatchWarning)

            createModel.submit(
                onConfirmExportPassphrase: { confirmedPassphrases.append($0) },
                verifyUnlockPassphrase: { _ in },
                onUnlockVerified: { _ in }
            )
            #expect(createModel.errorMessage == PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase))
            #expect(confirmedPassphrases.isEmpty)

            createModel.passphrase = "alpha"
            #expect(createModel.errorMessage == nil)
            createModel.confirmPassphrase = "beta"
            #expect(createModel.isConfirmDisabled)
            #expect(createModel.showsMismatchWarning)

            createModel.submit(
                onConfirmExportPassphrase: { confirmedPassphrases.append($0) },
                verifyUnlockPassphrase: { _ in },
                onUnlockVerified: { _ in }
            )
            #expect(createModel.errorMessage == L10n.string("Passphrases do not match."))
            #expect(confirmedPassphrases.isEmpty)

            // NFC-equivalent passphrases (composed U+00E9 vs decomposed e + U+0301) match and normalize to NFC.
            let nfc = "caf\u{00E9}-pass"
            let nfd = "cafe\u{0301}-pass"
            createModel.passphrase = nfc
            createModel.confirmPassphrase = nfd
            #expect(!createModel.isConfirmDisabled)
            #expect(!createModel.showsMismatchWarning)
            createModel.submit(
                onConfirmExportPassphrase: { confirmedPassphrases.append($0) },
                verifyUnlockPassphrase: { _ in },
                onUnlockVerified: { _ in }
            )
            #expect(confirmedPassphrases == [nfc])

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            try harness.seedHistory([
                ClipboardItem.fixture(kind: .text, text: "Encrypted archive clip", copiedAt: Date(timeIntervalSince1970: 1_715_800_400))
            ])
            let archiveURL = harness.supportDirectory.appendingPathComponent("passphrase-check.clipbookarchive", isDirectory: true)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let started = harness.coordinator.beginExportHistoryArchive(
                    mode: .encrypted(passphrase: nfc),
                    destinationURL: archiveURL,
                    progress: { _ in },
                    completion: { result in
                        switch result {
                        case .success:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                )
                if !started {
                    continuation.resume(throwing: ClipBookArchiveError.corruptedEncryptedArchive("Export did not start"))
                }
            }

            let unlockModel = ArchivePassphraseSheetModel(mode: .unlock(archiveURL))
            var verifiedPassphrases: [String] = []
            #expect(unlockModel.isConfirmDisabled)
            unlockModel.submit(
                onConfirmExportPassphrase: { _ in },
                verifyUnlockPassphrase: { _ in },
                onUnlockVerified: { verifiedPassphrases.append($0) }
            )
            #expect(unlockModel.errorMessage == PersistenceErrorLocalization.message(for: ClipBookArchiveError.emptyPassphrase))

            unlockModel.passphrase = "wrong-passphrase"
            #expect(!unlockModel.isConfirmDisabled)
            var failureCallbackCount = 0
            let wrongTask = unlockModel.submit(
                onConfirmExportPassphrase: { _ in },
                verifyUnlockPassphrase: { passphrase in
                    try await harness.coordinator.verifyArchivePassphrase(passphrase, for: archiveURL)
                },
                onUnlockVerified: { verifiedPassphrases.append($0) },
                onUnlockFailed: { failureCallbackCount += 1 }
            )
            await wrongTask?.value
            #expect(!unlockModel.isVerifying)
            #expect(unlockModel.errorMessage == PersistenceErrorLocalization.message(for: ClipBookArchiveError.incorrectPassphrase))
            #expect(verifiedPassphrases.isEmpty)
            #expect(failureCallbackCount == 1)

            unlockModel.passphrase = nfd
            #expect(unlockModel.errorMessage == nil)
            let validTask = unlockModel.submit(
                onConfirmExportPassphrase: { _ in },
                verifyUnlockPassphrase: { passphrase in
                    try await harness.coordinator.verifyArchivePassphrase(passphrase, for: archiveURL)
                },
                onUnlockVerified: { verifiedPassphrases.append($0) }
            )
            await validTask?.value
            #expect(!unlockModel.isVerifying)
            #expect(unlockModel.errorMessage == nil)
            #expect(verifiedPassphrases == [nfc])
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func importExportFlowStateBranchesSensitiveAlertsInspectsArchivesAndChainsDismissals() async throws {
            let sourceHarness = try TestSupport.makeTestCoordinator()
            defer { sourceHarness.cleanup() }
            let baseTime = Date(timeIntervalSince1970: 1_715_800_500)
            let regularClip = ClipboardItem.fixture(kind: .text, text: "Regular clip", copiedAt: baseTime)
            let sensitiveClip = ClipboardItem.fixture(
                kind: .text,
                text: "Sensitive secret",
                copiedAt: baseTime.addingTimeInterval(10),
                sensitivity: .sensitive
            )

            // 1. Without sensitive items, unencrypted export starts immediately without alert.
            try sourceHarness.seedHistory([regularClip])
            let flow = ImportExportArchiveFlowState()
            let plainURL = sourceHarness.supportDirectory.appendingPathComponent("plain.clipbookarchive", isDirectory: true)
            flow.exportArchive(
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count,
                destinationURL: plainURL
            )
            #expect(!flow.isSensitiveExportAlertPresented)
            #expect(flow.activeSheet == .progress)
            let plainDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(plainDone)
            if case .success = flow.operationProgress?.result {} else {
                Issue.record("Expected plain export to succeed")
            }
            flow.closeProgress()
            #expect(flow.activeSheet == nil)
            #expect(flow.operationProgress == nil)

            // 2. With sensitive items and encrypt toggle off, exportArchive presents sensitive-export alert.
            try sourceHarness.seedHistory([regularClip, sensitiveClip])
            flow.exportArchive(
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count
            )
            #expect(flow.isSensitiveExportAlertPresented)
            #expect(flow.activeSheet == nil)
            flow.isSensitiveExportAlertPresented = false

            // 2a. Choice: Encrypt Archive... -> opens .createPassphrase sheet and chains on dismissal.
            flow.handleSensitiveExportChoice(
                .encrypt,
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count
            )
            #expect(flow.activeSheet == .createPassphrase)

            let encryptedURL = sourceHarness.supportDirectory.appendingPathComponent("encrypted.clipbookarchive", isDirectory: true)
            flow.confirmExportPassphrase("export-secret")
            #expect(flow.activeSheet == nil)
            #expect(flow.pendingConfirmedExportPassphrase == "export-secret")
            flow.handleSheetDismissal(
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count,
                exportDestinationURL: encryptedURL
            )
            #expect(flow.pendingConfirmedExportPassphrase == nil)
            #expect(flow.activeSheet == .progress)
            let encryptedDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(encryptedDone)
            #expect(try sourceHarness.coordinator.inspectArchive(at: encryptedURL).isEncrypted)
            flow.closeProgress()

            // 2b. Choice: Skip Sensitive Items -> exports only non-sensitive items.
            let skippedURL = sourceHarness.supportDirectory.appendingPathComponent("skipped.clipbookarchive", isDirectory: true)
            flow.handleSensitiveExportChoice(
                .skipSensitive,
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count,
                destinationURL: skippedURL
            )
            #expect(flow.activeSheet == .progress)
            let skippedDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(skippedDone)
            flow.closeProgress()

            // 2c. Choice: Export Unencrypted Anyway -> exports all items including sensitive.
            let includedURL = sourceHarness.supportDirectory.appendingPathComponent("included.clipbookarchive", isDirectory: true)
            flow.handleSensitiveExportChoice(
                .includeSensitive,
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count,
                destinationURL: includedURL
            )
            #expect(flow.activeSheet == .progress)
            let includedDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(includedDone)
            if case .success = flow.operationProgress?.result {} else {
                Issue.record("Expected unencrypted-including-sensitive export to succeed")
            }
            #expect(try !sourceHarness.coordinator.inspectArchive(at: includedURL).isEncrypted)
            flow.closeProgress()

            let includedVerifyHarness = try TestSupport.makeTestCoordinator()
            defer { includedVerifyHarness.cleanup() }
            flow.importArchive(from: includedURL, coordinator: includedVerifyHarness.coordinator)
            #expect(flow.activeSheet == .progress)
            let includedVerifyDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(includedVerifyDone)
            #expect(Set(includedVerifyHarness.model.items.map(\.id)) == [regularClip.id, sensitiveClip.id])
            flow.closeProgress()

            // 3. Encrypt toggle ON opens .createPassphrase directly regardless of sensitive items.
            flow.encryptExportWithPassphrase = true
            flow.exportArchive(
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count
            )
            #expect(flow.activeSheet == .createPassphrase)
            flow.activeSheet = nil

            // 4. Import inspection: unencrypted imports immediately; encrypted opens .unlockPassphrase and chains on dismissal; invalid shows failure.
            let targetHarness = try TestSupport.makeTestCoordinator()
            defer { targetHarness.cleanup() }

            flow.importArchive(from: skippedURL, coordinator: targetHarness.coordinator)
            #expect(flow.activeSheet == .progress)
            let skippedImportDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(skippedImportDone)
            #expect(targetHarness.model.items.map(\.id) == [regularClip.id])
            flow.closeProgress()

            flow.importArchive(from: encryptedURL, coordinator: targetHarness.coordinator)
            #expect(flow.activeSheet == .unlockPassphrase(encryptedURL))
            flow.completeUnlockVerification(for: encryptedURL, passphrase: "export-secret")
            #expect(flow.activeSheet == nil)
            #expect(flow.pendingVerifiedImport?.url == encryptedURL)
            flow.handleSheetDismissal(
                coordinator: targetHarness.coordinator,
                itemCount: targetHarness.model.items.count
            )
            #expect(flow.pendingVerifiedImport == nil)
            #expect(flow.activeSheet == .progress)
            let encryptedImportDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(encryptedImportDone)
            #expect(Set(targetHarness.model.items.map(\.id)) == [regularClip.id, sensitiveClip.id])
            flow.closeProgress()

            let missingURL = sourceHarness.supportDirectory.appendingPathComponent("missing.clipbookarchive", isDirectory: true)
            flow.importArchive(from: missingURL, coordinator: targetHarness.coordinator)
            #expect(flow.activeSheet == .progress)
            if case .failure = flow.operationProgress?.result {} else {
                Issue.record("Expected missing archive inspection to surface failure progress")
            }
            flow.closeProgress()

            // 5. Async failure completion paths for both startImport (wrong passphrase) and startExport (blocked symlink destination).
            flow.startImport(from: encryptedURL, passphrase: "wrong-async-passphrase", coordinator: targetHarness.coordinator)
            #expect(flow.activeSheet == .progress)
            let failedImportDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(failedImportDone)
            #expect(
                flow.operationProgress?.result == .failure(
                    PersistenceErrorLocalization.message(for: ClipBookArchiveError.incorrectPassphrase)
                )
            )
            flow.closeProgress()

            let blockedExportSymlink = sourceHarness.supportDirectory.appendingPathComponent("blocked-export.clipbookarchive")
            try FileManager.default.createSymbolicLink(
                at: blockedExportSymlink,
                withDestinationURL: sourceHarness.supportDirectory
            )
            flow.startExport(
                mode: .unencryptedIncludingSensitive,
                coordinator: sourceHarness.coordinator,
                itemCount: sourceHarness.model.items.count,
                destinationURL: blockedExportSymlink
            )
            #expect(flow.activeSheet == .progress)
            let failedExportDone = await TestSupport.waitUntil(timeout: .seconds(5)) {
                flow.operationProgress?.isCompleted == true
            }
            #expect(failedExportDone)
            if case .failure = flow.operationProgress?.result {} else {
                Issue.record("Expected async export to symlink destination to surface failure progress")
            }
            flow.closeProgress()
        }
    }

    @Suite(.serialized)
    struct LazyPreviewDragAndSVGHydrationTests {
        private static let sentinel = "TAIL_SENTINEL_AT_40KB"

        private static func make40KBBody(prefix: String = "") -> String {
            let padCount = max(0, 40_020 - prefix.count - sentinel.count)
            return prefix + String(repeating: "a", count: padCount) + sentinel
        }

        @MainActor
        private static func allTextStrings(in root: NSView) -> String {
            var parts: [String] = []
            for view in allViewDescendants(in: root, includeGlassContentView: false) {
                if let tv = view as? NSTextView {
                    parts.append(tv.string)
                } else if let tf = view as? NSTextField, !tf.isHidden {
                    parts.append(tf.stringValue)
                }
            }
            return parts.joined(separator: "\n")
        }

        @Test
        @MainActor
        func rowDragPreviewDialogDetailsOnlyPaneAndLivePaneEditingHydrateMinimalScopes() async throws {
            TestSupport.ensureAppKitInitialized()

            let (harness, spyStore, _) = try TestSupport.makeSpiedTestCoordinator()
            defer { harness.cleanup() }

            let baseTime = Date(timeIntervalSince1970: 1_710_200_000)
            let text40KB = Self.make40KBBody()
            #expect(text40KB.count == 40_020)

            let richPlain40KB = Self.make40KBBody(prefix: "RichPlain ")
            let richRTF40KB = try TestSupport.makeRTFData(text: "RTFOnly_" + richPlain40KB)
            let richHTML40KB = "<section>HTMLOnly_\(richPlain40KB)</section>"

            let pngBytes = try TestSupport.makePNGData(pixelWidth: 64, pixelHeight: 48, color: .systemBlue)
            let imageID = UUID()
            let imageURL = try spyStore.writeManagedAsset(pngData: pngBytes, role: .image, clipID: imageID, encrypted: false)
            let sampleFileURL = harness.supportDirectory.appendingPathComponent("preview-doc.txt")
            try Data("preview-file".utf8).write(to: sampleFileURL)

            let seededText = ClipboardItem.fixture(kind: .text, text: text40KB, copiedAt: baseTime.addingTimeInterval(40))
            let seededRich = ClipboardItem.fixture(
                kind: .richText,
                text: richPlain40KB,
                rtfData: richRTF40KB,
                html: richHTML40KB,
                copiedAt: baseTime.addingTimeInterval(30)
            )
            var seededImage = ClipboardItem.fixture(
                id: imageID,
                kind: .image,
                text: "Image OCR",
                assetPath: imageURL.path,
                copiedAt: baseTime.addingTimeInterval(20)
            )
            seededImage.imageWidth = 64
            seededImage.imageHeight = 48
            let seededFile = ClipboardItem.fixture(
                kind: .file,
                text: nil,
                filePaths: [sampleFileURL.path],
                copiedAt: baseTime.addingTimeInterval(10)
            )

            try harness.seedHistory([seededText, seededRich, seededImage, seededFile])
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded && $0.searchText.isEmpty })

            let textHeader = try #require(harness.currentItem(seededText.id))
            let richHeader = try #require(harness.currentItem(seededRich.id))
            let imageHeader = try #require(harness.currentItem(seededImage.id))
            let fileHeader = try #require(harness.currentItem(seededFile.id))

            // 1. History row drag minimal scope verification (.body for plain-text drag, .full for rich drag, 0 for image/file).
            let historyView = History(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
            historyView.preferDraggingAsPlainText = true
            historyView.loadContent = { [weak coordinator = harness.coordinator] item, scope in
                try coordinator?.loadingContent(of: item, scope: scope) ?? item
            }
            historyView.reload(
                items: [textHeader, richHeader, imageHeader, fileHeader],
                availableTags: [],
                selectedItemID: textHeader.id,
                selectedItemIDs: [textHeader.id],
                searchQuery: "",
                showCommandNumberShortcut: true,
                showPreviewForLinks: false,
                detectSensitiveContent: true,
                showDividers: false,
                preferPastingAsPlainText: true,
                groupPinnedFavorites: false,
                sectionDate: nil,
                showsTiles: false,
                showsCompactRows: false,
                onSelectFirstItem: { _ in }
            )

            // Row 1 is richHeader: plain-text drag (no Option key) requests .body, skipping html/rtf!
            spyStore.resetRecordedCalls()
            let plainRichDragPayload = try #require(historyView.tableView.dragPayloadForRow?(1, []))
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .body)])
            TestSupport.withUniquePasteboard { pb in
                pb.clearContents()
                #expect(pb.writeObjects(plainRichDragPayload.entries.map(\.writer)))
                #expect(pb.string(forType: .string) == richPlain40KB)
                #expect(pb.data(forType: .rtf) == nil)
                #expect(pb.string(forType: .html) == nil)
            }

            // Option-drag on richHeader requests .full and writes RTF + HTML!
            spyStore.resetRecordedCalls()
            let fullRichDragPayload = try #require(historyView.tableView.dragPayloadForRow?(1, [.option]))
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .full)])
            TestSupport.withUniquePasteboard { pb in
                pb.clearContents()
                #expect(pb.writeObjects(fullRichDragPayload.entries.map(\.writer)))
                #expect(pb.string(forType: .string) == richPlain40KB)
                #expect(pb.data(forType: .rtf) == richRTF40KB)
                #expect(pb.string(forType: .html) == richHTML40KB)
            }

            // Image (row 2) and File (row 3) drags perform 0 loadContent calls!
            spyStore.resetRecordedCalls()
            _ = try #require(historyView.tableView.dragPayloadForRow?(2, []))
            _ = try #require(historyView.tableView.dragPayloadForRow?(3, []))
            #expect(spyStore.loadingContentCalls.isEmpty)

            // 2. ItemPreviewDialogController requests .preview on .richText (leaving html == nil) and 0 calls on .image/.file!
            var observedRichHydrated: ClipboardItem?
            spyStore.resetRecordedCalls()
            let richSheetPreview = ItemPreviewDialogController(
                item: richHeader,
                maximumContentSize: NSSize(width: 800, height: 600),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                presentation: .sheet,
                showsPreview: true,
                loadContent: { [weak coordinator = harness.coordinator] item, scope in
                    let loaded = try coordinator?.loadingContent(of: item, scope: scope) ?? item
                    observedRichHydrated = loaded
                    return loaded
                }
            )
            defer { TestSupport.drainDelayedPerforms([richSheetPreview]) }
            _ = richSheetPreview.view
            richSheetPreview.view.layoutSubtreeIfNeeded()
            #expect(spyStore.loadingContentCalls == [.init(id: richHeader.id, scope: .preview)])
            let capturedRichHydrated = try #require(observedRichHydrated)
            #expect(capturedRichHydrated.isContentLoaded)
            #expect(capturedRichHydrated.isPreviewFormattingLoaded)
            #expect(!capturedRichHydrated.isFormattingLoaded)
            #expect(capturedRichHydrated.rtfData == richRTF40KB)
            #expect(capturedRichHydrated.html == nil)
            let renderedRichString = Self.allTextStrings(in: richSheetPreview.view)
            #expect(renderedRichString.contains("RTFOnly_"))
            #expect(renderedRichString.contains(Self.sentinel))

            spyStore.resetRecordedCalls()
            let imagePreview = ItemPreviewDialogController(
                item: imageHeader,
                maximumContentSize: NSSize(width: 800, height: 600),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                loadContent: { [weak coordinator = harness.coordinator] item, scope in
                    try coordinator?.loadingContent(of: item, scope: scope) ?? item
                }
            )
            defer { TestSupport.drainDelayedPerforms([imagePreview]) }
            let filePreview = ItemPreviewDialogController(
                item: fileHeader,
                maximumContentSize: NSSize(width: 800, height: 600),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                loadContent: { [weak coordinator = harness.coordinator] item, scope in
                    try coordinator?.loadingContent(of: item, scope: scope) ?? item
                }
            )
            defer { TestSupport.drainDelayedPerforms([filePreview]) }
            _ = imagePreview.view
            _ = filePreview.view
            #expect(spyStore.loadingContentCalls.isEmpty)

            // 3. Details-only .pane (presentation == .pane && showsPreview == false && showsDetails == true):
            //    0 loadContent calls across init, loadView, and update, with exact 40,020 characterCount!
            spyStore.resetRecordedCalls()
            let detailsOnlyPane = ItemPreviewDialogController(
                item: textHeader,
                maximumContentSize: NSSize(width: 600, height: 480),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                presentation: .pane,
                showsPreview: false,
                loadContent: { [weak coordinator = harness.coordinator] item, scope in
                    try coordinator?.loadingContent(of: item, scope: scope) ?? item
                }
            )
            defer { TestSupport.drainDelayedPerforms([detailsOnlyPane]) }
            _ = detailsOnlyPane.view
            detailsOnlyPane.showsDetails = true
            detailsOnlyPane.view.layoutSubtreeIfNeeded()
            #expect(spyStore.loadingContentCalls.isEmpty, "init + loadView with showsPreview == false must perform 0 loadContent calls")

            let expectedCharCountText = NumberFormatter.localizedString(from: NSNumber(value: 40_020), number: .decimal)
            #expect(Self.allTextStrings(in: detailsOnlyPane.view).contains(expectedCharCountText))

            detailsOnlyPane.update(item: richHeader, revealsSensitiveContent: false)
            detailsOnlyPane.update(item: textHeader, revealsSensitiveContent: false)
            #expect(spyStore.loadingContentCalls.isEmpty, "Navigating items while showsPreview == false must perform 0 loadContent calls")

            // Toggling showsPreview false -> true hydrates once on demand (.body for .text), and CachedBody serves metadata updates!
            detailsOnlyPane.showsPreview = true
            detailsOnlyPane.view.layoutSubtreeIfNeeded()
            #expect(spyStore.loadingContentCalls == [.init(id: textHeader.id, scope: .body)])
            #expect(Self.allTextStrings(in: detailsOnlyPane.view).contains(Self.sentinel))

            spyStore.resetRecordedCalls()
            var favoritedTextHeader = textHeader
            favoritedTextHeader.isFavorite = true
            detailsOnlyPane.update(item: favoritedTextHeader, revealsSensitiveContent: false)
            #expect(spyStore.loadingContentCalls.isEmpty, "Metadata-only update must reuse CachedBody with 0 extra DB reads")

            // 4. Editing >8 KB text while the live HistoryContentViewController preview pane is open updates preview & characterCount immediately!
            var panePrefs = harness.model.preferences
            panePrefs.showPreviewPane = true
            panePrefs.showPreviewPaneDetails = true
            harness.model.preferences = panePrefs
            harness.model.selectedItemID = textHeader.id
            harness.model.selectedItemIDs = [textHeader.id]
            harness.model.selectedItemIDsInSelectionOrder = [textHeader.id]

            var livePaneRef: ItemPreviewDialogController?
            let hostWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            hostWindow.isReleasedWhenClosed = false
            hostWindow.alphaValue = 0
            let contentVC = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            hostWindow.contentViewController = contentVC
            defer {
                TestSupport.drainDelayedPerforms([hostWindow, contentVC] + contentVC.children + [livePaneRef].compactMap { $0 })
                hostWindow.orderOut(nil)
                hostWindow.contentViewController = nil
                TestSupport.drainDelayedPerforms([contentVC] + [livePaneRef].compactMap { $0 })
            }
            contentVC.view.layoutSubtreeIfNeeded()

            let mountedPaneLoaded = await TestSupport.waitUntil(timeout: .seconds(5)) {
                contentVC.children.contains { $0 is ItemPreviewDialogController }
            }
            #expect(mountedPaneLoaded)
            let livePane = try #require(contentVC.children.compactMap { $0 as? ItemPreviewDialogController }.first)
            livePaneRef = livePane
            livePane.view.layoutSubtreeIfNeeded()
            #expect(Self.allTextStrings(in: livePane.view).contains(Self.sentinel))

            livePane.beginEditing()
            #expect(livePane.isEditing)
            let editor = try #require(findEditableTextView(in: livePane.view))
            #expect(editor.string == text40KB)

            let edited42KB = String(repeating: "e", count: 42_000) + "LIVE_PANE_EDITED_SENTINEL"
            editor.string = edited42KB
            livePane.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            livePane.saveEditing()
            #expect(!livePane.isEditing)

            let updatedModelHeader = try #require(harness.currentItem(textHeader.id))
            #expect(!updatedModelHeader.isContentLoaded)
            #expect(updatedModelHeader.characterCount == edited42KB.count)
            let livePaneRendered = Self.allTextStrings(in: livePane.view)
            #expect(livePaneRendered.contains("LIVE_PANE_EDITED_SENTINEL"))
            let expectedEditedCountText = NumberFormatter.localizedString(from: NSNumber(value: edited42KB.count), number: .decimal)
            #expect(livePaneRendered.contains(expectedEditedCountText))
        }

        @Test
        @MainActor
        func concealedImageTileAndRowCmdUToggleAnd12KBUnloadedSVGSharedCacheHit() async throws {
            TestSupport.ensureAppKitInitialized()

            // 1. Unregistered SVG ID does NOT poison cache with nil; GRDBHistoryStore [weak self] loader shares cache between unloaded row & hydrated preview and unregisters on close().
            let transientUnregisteredSVGText = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><!-- "
                + String(repeating: "u", count: 12_000)
                + " --><circle cx=\"20\" cy=\"20\" r=\"18\" fill=\"#22AA66\"/></svg>"
            let unregisteredHeader = ClipboardItem.fixture(
                kind: .text,
                text: transientUnregisteredSVGText
            ).unloadingContent()
            #expect(!unregisteredHeader.isContentLoaded)
            #expect(unregisteredHeader.isSVGText)

            // With no store holding unregisteredHeader.id, sync & async rendering return nil without caching nil.
            #expect(SVGImageRenderer.shared.rendering(for: unregisteredHeader) == nil)
            var asyncMissCompleted = false
            var asyncMissResult: SVGImageRenderer.Rendering?
            _ = SVGImageRenderer.shared.rendering(for: unregisteredHeader) { result in
                asyncMissResult = result
                asyncMissCompleted = true
            }
            #expect(await TestSupport.waitUntil { asyncMissCompleted })
            #expect(asyncMissResult == nil)

            let manualLoaderOwner = UUID()
            let loaderCallCount = OSAllocatedUnfairLock(initialState: 0)
            SVGImageRenderer.registerTextLoader(
                { id in
                    guard id == unregisteredHeader.id else { return nil }
                    loaderCallCount.withLock { $0 += 1 }
                    return transientUnregisteredSVGText
                },
                ownerID: manualLoaderOwner
            )
            defer { SVGImageRenderer.unregisterTextLoader(ownerID: manualLoaderOwner) }

            let recoveredRendering = SVGImageRenderer.shared.rendering(for: unregisteredHeader)
            #expect(recoveredRendering != nil, "Previous unavailable-text nil must not have poisoned SVGImageRenderer cache")
            #expect(loaderCallCount.withLock { $0 } == 1)

            // Verify GRDBHistoryStore [weak self] registration does not leak store instances and shares 1 cache entry across unloaded row & hydrated preview.
            weak var weakStoreRef: GRDBHistoryStore?
            try await TestSupport.withTemporaryDirectory { svgSupportDir in
                let svg12KB = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"48\"><!-- "
                    + String(repeating: "v", count: 12_200)
                    + " --><rect width=\"64\" height=\"48\" fill=\"#CC3366\"/></svg>"
                let svgClipID = UUID()
                do {
                    let store = GRDBHistoryStore(directory: svgSupportDir, keyProvider: InMemoryDatabaseKeyProvider())
                    weakStoreRef = store
                    let spy = SpyHistoryStore(base: store)
                    _ = try spy.saveAndReconcileItem(
                        ClipboardItem.fixture(id: svgClipID, kind: .text, text: svg12KB),
                        convertingExternalAssets: true
                    )
                    let unloadedSVGHeader = try #require(try spy.fetchAll().first { $0.id == svgClipID })
                    #expect(!unloadedSVGHeader.isContentLoaded)
                    #expect(unloadedSVGHeader.isSVGText)
                    #expect(!(unloadedSVGHeader.textPreview?.hasSuffix("</svg>") ?? true))

                    spy.resetRecordedCalls()
                    var rowRendered: SVGImageRenderer.Rendering?
                    var rowDone = false
                    if let immediate = SVGImageRenderer.shared.rendering(for: unloadedSVGHeader, completion: { res in
                        rowRendered = res
                        rowDone = true
                    }) {
                        rowRendered = immediate
                        rowDone = true
                    }
                    #expect(await TestSupport.waitUntil { rowDone })
                    let firstRendering = try #require(rowRendered)
                    #expect(spy.loadingContentCalls.isEmpty, "SVGImageRenderer must project only clip_contents.text without full loadingContent")

                    // Hydrating the item preserves (id, searchRevision) and hits the exact same cached NSImage in preview!
                    let hydratedSVG = try spy.base.loadingContent(of: unloadedSVGHeader, scope: .body)
                    #expect(hydratedSVG.searchRevision == unloadedSVGHeader.searchRevision)
                    let previewRendering = try #require(SVGImageRenderer.shared.rendering(for: hydratedSVG))
                    #expect(previewRendering.image === firstRendering.image)

                    store.close()
                }
                #expect(weakStoreRef == nil, "SVGImageRenderer static registry must hold [weak self] so GRDBHistoryStore deallocates")
            }

            // 2. Concealed image row & HistoryTileView hide screenshot while hidden, reveal on Cmd+U, and re-hide on second Cmd+U!
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.hideOnFocusLoss = false
            harness.model.preferences.showImagesAsTiles = true
            harness.model.selectedHistoryFilterContentTypes = [.images]

            let pngData = try TestSupport.makePNGData(pixelWidth: 72, pixelHeight: 54, color: .systemPurple)
            let concealedImgID = UUID()
            let concealedImgURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: concealedImgID,
                encrypted: true
            )
            var concealedImg = ClipboardItem.fixture(
                id: concealedImgID,
                kind: .image,
                text: "Concealed badge text",
                assetPath: concealedImgURL.path,
                sensitivity: .sensitive
            )
            concealedImg.imageWidth = 72
            concealedImg.imageHeight = 54
            try harness.seedHistory([concealedImg])
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })

            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            defer { TestSupport.tearDownHistoryWindow(historyWindow) }

            func findTileView(in root: NSView) -> HistoryTileView? {
                allViewDescendants(in: root).compactMap { $0 as? HistoryTileView }.first { !$0.isHidden }
            }
            func hasDecodedTileScreenshot(in tile: HistoryTileView) -> Bool {
                allViewDescendants(in: tile)
                    .compactMap { $0 as? NSImageView }
                    .contains { !$0.isHidden && $0.image?.isTemplate == false && ($0.image?.size.width ?? 0) >= 40 }
            }

            let contentRoot = try #require(historyWindow.window.contentView)
            contentRoot.layoutSubtreeIfNeeded()
            let tile = try #require(findTileView(in: contentRoot))
            #expect(!hasDecodedTileScreenshot(in: tile), "Hidden concealed tile must show placeholder rather than screenshot")

            // Press Cmd+U -> reveals tile screenshot!
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let revealed = await TestSupport.waitUntil(timeout: .seconds(5)) {
                guard let currentTile = findTileView(in: contentRoot) else { return false }
                return hasDecodedTileScreenshot(in: currentTile)
            }
            #expect(revealed)

            // Press Cmd+U again -> re-hides tile back to placeholder while model.items stays unloaded!
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            contentRoot.layoutSubtreeIfNeeded()
            let rehiddenTile = try #require(findTileView(in: contentRoot))
            #expect(!hasDecodedTileScreenshot(in: rehiddenTile), "Re-hiding concealed tile via Cmd+U must clear screenshot back to placeholder")
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded })
        }

        @Test
        @MainActor
        func activeSearchRefreshUpdatesListPaneForLongTailAndQRCodeCapturesAndStoreUnlock() async throws {
            TestSupport.ensureAppKitInitialized()

            let (harness, spyStore, _) = try TestSupport.makeSpiedTestCoordinator()
            defer { harness.cleanup() }
            let store = spyStore.base
            harness.model.preferences.showPreviewPane = false

            let baseTime = Date(timeIntervalSince1970: 1_705_000_000)
            let initialItem = ClipboardItem.fixture(
                kind: .text,
                text: "Unrelated baseline clip",
                copiedAt: baseTime
            )
            try harness.seedHistory([initialItem])

            let hostWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            hostWindow.isReleasedWhenClosed = false
            hostWindow.alphaValue = 0
            let contentVC = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            hostWindow.contentViewController = contentVC
            let toolbar = HistoryToolbar()
            toolbar.delegate = contentVC
            contentVC.attachToolbar(toolbar)
            defer {
                TestSupport.drainDelayedPerforms([hostWindow, contentVC] + contentVC.children)
                hostWindow.orderOut(nil)
                hostWindow.contentViewController = nil
                TestSupport.drainDelayedPerforms([contentVC])
            }
            contentVC.view.layoutSubtreeIfNeeded()

            let listPane = try #require(
                allViewDescendants(in: contentVC.view).compactMap { $0 as? History }.first
            )
            #expect(listPane.items.map(\.id) == [initialItem.id])

            let query = "deep_refresh_needle_901"
            contentVC.historyToolbar(toolbar, didChangeSearchQuery: query)
            let initialSearchSettled = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.model.searchQuery == query
                    && harness.model.searchResult?.terms == HistorySearchTerms(query: query)
                    && listPane.items.isEmpty
            }
            #expect(initialSearchSettled)

            // 1. Insert unloaded >8,096-char text item whose matching token sits past textPreview.
            let longTextBody = String(repeating: "a", count: 12_400) + " " + query
            let savedLongText = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(
                    kind: .text,
                    text: longTextBody,
                    copiedAt: baseTime.addingTimeInterval(10)
                ),
                convertingExternalAssets: true
            )
            let unloadedLongText = savedLongText.unloadingContent()
            #expect(!unloadedLongText.isContentLoaded)
            #expect(!(unloadedLongText.textPreview?.contains(query) ?? false))
            harness.model.items.insert(unloadedLongText, at: 0)

            let longTailMatchedInList = await TestSupport.waitUntil(timeout: .seconds(5)) {
                listPane.items.map(\.id) == [savedLongText.id]
            }
            #expect(longTailMatchedInList, "listPaneView must reload once searchRefreshJob hydrates >8,096-char body")

            // 2. Insert unloaded image item whose matching token lives solely in qrCodeText.
            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemGreen)
            let qrImgID = UUID()
            let qrImgURL = try spyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: qrImgID, encrypted: false)
            let savedQRImg = try spyStore.saveAndReconcileItem(
                ClipboardItem.fixture(
                    id: qrImgID,
                    kind: .image,
                    text: "Benign screenshot caption",
                    qrCodeText: "https://qr.example/\(query)",
                    assetPath: qrImgURL.path,
                    imageDigest: spyStore.computeImageDigest(forPNGData: pngData),
                    copiedAt: baseTime.addingTimeInterval(20)
                ),
                convertingExternalAssets: true
            )
            let unloadedQRImg = savedQRImg.unloadingContent()
            #expect(!unloadedQRImg.isContentLoaded)
            #expect(unloadedQRImg.qrCodeText == nil)
            harness.model.items.insert(unloadedQRImg, at: 0)

            let qrMatchedInList = await TestSupport.waitUntil(timeout: .seconds(5)) {
                listPane.items.map(\.id) == [savedQRImg.id, savedLongText.id]
            }
            #expect(qrMatchedInList, "listPaneView must reload once searchRefreshJob hydrates qrCodeText")

            // 3. Simulate fetchSearchTexts failure (hasCompleteTexts == false): must NOT spin a refresh loop, and must recover on unlock!
            spyStore.shouldThrowOnFetchSearchTexts = true
            harness.model.storeLockState = .locked(.userCanceled)
            spyStore.resetRecordedCalls()

            let thirdLongBody = String(repeating: "b", count: 12_400) + " " + query
            let savedThirdLong = try store.saveAndReconcileItem(
                ClipboardItem.fixture(
                    kind: .text,
                    text: thirdLongBody,
                    copiedAt: baseTime.addingTimeInterval(30)
                ),
                convertingExternalAssets: true
            ).unloadingContent()
            harness.model.items.insert(savedThirdLong, at: 0)

            let degradedSettled = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
                    && harness.model.searchResult?.corpus.hasCompleteTexts == false
            }
            #expect(degradedSettled)
            let callsAfterLockedDegraded = spyStore.fetchSearchTextsCalls.count
            try await Task.sleep(for: .milliseconds(160))
            #expect(
                spyStore.fetchSearchTextsCalls.count == callsAfterLockedDegraded,
                "Locked store with hasCompleteTexts == false must not spin background refresh retries"
            )

            // Even if unlocked while DB still throws, one refresh attempt runs without spinning an infinite loop.
            harness.model.storeLockState = .unlocked
            try await Task.sleep(for: .milliseconds(220))
            let callsAfterUnlockedError = spyStore.fetchSearchTextsCalls.count
            #expect(callsAfterUnlockedError <= callsAfterLockedDegraded + 2)
            try await Task.sleep(for: .milliseconds(160))
            #expect(
                spyStore.fetchSearchTextsCalls.count == callsAfterUnlockedError,
                "Persistent DB error while unlocked must not spin an infinite refresh loop"
            )

            // Once the store recovers and unlocks cleanly, hasCompleteTexts == false re-arms and updates listPaneView!
            spyStore.shouldThrowOnFetchSearchTexts = false
            harness.model.storeLockState = .locked(.userCanceled)
            try await Task.sleep(for: .milliseconds(20))
            harness.model.storeLockState = .unlocked

            let recoveredAllThree = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.model.searchResult?.corpus.hasCompleteTexts == true
                    && listPane.items.map(\.id) == [savedThirdLong.id, savedQRImg.id, savedLongText.id]
            }
            #expect(recoveredAllThree, "Unlocking store must re-arm incomplete search corpus and reload listPaneView")
        }

        @Test
        @MainActor
        func hydratedSVGRenderingsEvictOnClearAndCloseAndRehidingSensitiveItemsEvictsMediaCaches() async throws {
            TestSupport.ensureAppKitInitialized()

            // (a) Hydrated SVG renderings (inlineText != nil) evict from SVGImageRenderer.shared on clear(), clear(keepingFavoritesAndTaggedItems: true), and close().
            try TestSupport.withTemporaryDirectory { svgDir in
                let makeSVG = { (fill: String, padChar: Character) in
                    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\"><!-- "
                        + String(repeating: String(padChar), count: 12_100)
                        + " --><rect width=\"48\" height=\"48\" fill=\"\(fill)\"/></svg>"
                }

                let clearAllID = UUID()
                let keptFavID = UUID()
                let clearedRegularID = UUID()

                do {
                    let store = GRDBHistoryStore(directory: svgDir, keyProvider: InMemoryDatabaseKeyProvider())
                    let savedClearAll = try store.saveAndReconcileItem(
                        ClipboardItem.fixture(id: clearAllID, kind: .text, text: makeSVG("#1155AA", "c")),
                        convertingExternalAssets: true
                    )
                    let unloadedClearAll = savedClearAll.unloadingContent()
                    let hydratedClearAll = try store.loadingContent(of: unloadedClearAll, scope: .body)
                    #expect(hydratedClearAll.isContentLoaded)

                    _ = try #require(SVGImageRenderer.shared.rendering(for: hydratedClearAll))
                    #expect(SVGImageRenderer.shared.hasCachedRendering(for: clearAllID))

                    try store.clear()
                    #expect(!SVGImageRenderer.shared.hasCachedRendering(for: clearAllID))
                    #expect(SVGImageRenderer.shared.rendering(for: unloadedClearAll) == nil)

                    let savedFav = try store.saveAndReconcileItem(
                        ClipboardItem.fixture(id: keptFavID, kind: .text, text: makeSVG("#22AA55", "f"), isFavorite: true),
                        convertingExternalAssets: true
                    )
                    let savedRegular = try store.saveAndReconcileItem(
                        ClipboardItem.fixture(id: clearedRegularID, kind: .text, text: makeSVG("#DD4422", "r"), isFavorite: false),
                        convertingExternalAssets: true
                    )
                    let unloadedFav = savedFav.unloadingContent()
                    let unloadedRegular = savedRegular.unloadingContent()
                    let hydratedFav = try store.loadingContent(of: unloadedFav, scope: .body)
                    let hydratedRegular = try store.loadingContent(of: unloadedRegular, scope: .body)

                    _ = try #require(SVGImageRenderer.shared.rendering(for: hydratedFav))
                    _ = try #require(SVGImageRenderer.shared.rendering(for: hydratedRegular))
                    #expect(SVGImageRenderer.shared.hasCachedRendering(for: keptFavID))
                    #expect(SVGImageRenderer.shared.hasCachedRendering(for: clearedRegularID))

                    try store.clear(keepingFavoritesAndTaggedItems: true)
                    #expect(!SVGImageRenderer.shared.hasCachedRendering(for: clearedRegularID))
                    #expect(SVGImageRenderer.shared.rendering(for: unloadedRegular) == nil)
                    #expect(SVGImageRenderer.shared.hasCachedRendering(for: keptFavID))

                    // A rolled-back performInTransaction must not remove deleted SVG IDs or retain inserted SVG IDs in knownSVGClipIDs.
                    struct RollbackError: Error {}
                    let rolledBackInsertID = UUID()
                    let rolledBackInsertItem = ClipboardItem.fixture(
                        id: rolledBackInsertID,
                        kind: .text,
                        text: makeSVG("#9933FF", "x")
                    )
                    #expect(throws: RollbackError.self) {
                        try store.performInTransaction {
                            try store.delete(keptFavID)
                            _ = try store.saveAndReconcileItem(rolledBackInsertItem, convertingExternalAssets: true)
                            throw RollbackError()
                        }
                    }
                    let unloadedRolledBack = rolledBackInsertItem.unloadingContent()
                    #expect(SVGImageRenderer.shared.rendering(for: unloadedRolledBack) == nil)
                    SVGImageRenderer.shared.removeRendering(for: keptFavID)
                    #expect(SVGImageRenderer.shared.rendering(for: unloadedFav) != nil)
                    #expect(SVGImageRenderer.shared.hasCachedOwnerAssociation(for: keptFavID))

                    // Deleting and re-upserting the same SVG UUID inside one committed performInTransaction preserves knownSVGClipIDs membership.
                    try store.performInTransaction {
                        try store.delete(keptFavID)
                        _ = try store.saveAndReconcileItem(
                            ClipboardItem.fixture(id: keptFavID, kind: .text, text: makeSVG("#22AA55", "f"), isFavorite: true),
                            convertingExternalAssets: true
                        )
                    }
                    #expect(!SVGImageRenderer.shared.hasCachedRendering(for: keptFavID))
                    _ = try #require(SVGImageRenderer.shared.rendering(for: hydratedFav))
                    #expect(SVGImageRenderer.shared.hasCachedRendering(for: keptFavID))
                    #expect(SVGImageRenderer.shared.hasCachedOwnerAssociation(for: keptFavID))

                    store.close()
                    #expect(!SVGImageRenderer.shared.hasCachedRendering(for: keptFavID))
                    #expect(SVGImageRenderer.shared.rendering(for: unloadedFav) == nil)
                }
            }

            // (b) Re-hiding temporarily revealed sensitive image & SVG items (both via Cmd+U and hideRevealedSensitiveContent()) evicts decrypted NSImage / Rendering caches.
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.hideOnFocusLoss = false
            harness.model.preferences.showImagesAsTiles = false

            let baseTime = Date(timeIntervalSince1970: 1_706_000_000)
            let pngData = try TestSupport.makePNGData(pixelWidth: 64, pixelHeight: 48, color: .systemOrange)
            let sensitiveImgID = UUID()
            let sensitiveImgURL = try harness.historyStore.writeManagedAsset(
                pngData: pngData,
                role: .image,
                clipID: sensitiveImgID,
                encrypted: true
            )
            var sensitiveImg = ClipboardItem.fixture(
                id: sensitiveImgID,
                kind: .image,
                text: "Sensitive badge screenshot",
                assetPath: sensitiveImgURL.path,
                copiedAt: baseTime.addingTimeInterval(20),
                sensitivity: .sensitive
            )
            sensitiveImg.imageWidth = 64
            sensitiveImg.imageHeight = 48

            let sensitiveSVGID = UUID()
            let sensitiveSVGMarkup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\"><!-- "
                + String(repeating: "s", count: 12_000)
                + " --><circle cx=\"24\" cy=\"24\" r=\"20\" fill=\"#AA2288\"/></svg>"
            let sensitiveSVG = ClipboardItem.fixture(
                id: sensitiveSVGID,
                kind: .text,
                text: sensitiveSVGMarkup,
                copiedAt: baseTime.addingTimeInterval(10),
                sensitivity: .sensitive
            )

            try harness.seedHistory([sensitiveSVG, sensitiveImg])
            ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: sensitiveImgURL.path)
            SVGImageRenderer.shared.removeRendering(for: sensitiveSVGID)

            let historyWindow = HistoryWindow(model: harness.model, coordinator: harness.coordinator)
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            defer { TestSupport.tearDownHistoryWindow(historyWindow) }
            historyWindow.window.contentView?.layoutSubtreeIfNeeded()

            #expect(harness.model.selectedItemID == sensitiveImgID)
            #expect(!ImageAssetThumbnailLoader.shared.hasCachedThumbnails(forPath: sensitiveImgURL.path))

            // Reveal sensitive image via Cmd+U -> populates ImageAssetThumbnailLoader.shared.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let imgCachedOnReveal = await TestSupport.waitUntil(timeout: .seconds(5)) {
                ImageAssetThumbnailLoader.shared.hasCachedThumbnails(forPath: sensitiveImgURL.path)
            }
            #expect(imgCachedOnReveal)

            // Second Cmd+U re-hides -> evicts ImageAssetThumbnailLoader.shared immediately.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            #expect(!ImageAssetThumbnailLoader.shared.hasCachedThumbnails(forPath: sensitiveImgURL.path))

            // Reveal again via Cmd+U, then close/hide window -> hideRevealedSensitiveContent() evicts ImageAssetThumbnailLoader.shared.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let imgCachedSecondReveal = await TestSupport.waitUntil(timeout: .seconds(5)) {
                ImageAssetThumbnailLoader.shared.hasCachedThumbnails(forPath: sensitiveImgURL.path)
            }
            #expect(imgCachedSecondReveal)
            historyWindow.hide()
            #expect(!ImageAssetThumbnailLoader.shared.hasCachedThumbnails(forPath: sensitiveImgURL.path))

            // Show window again, select the sensitive SVG row, and test both Cmd+U re-hide and hide() eviction on SVGImageRenderer.shared.
            historyWindow.window.alphaValue = 0
            historyWindow.show()
            harness.model.selectedItemID = sensitiveSVGID
            harness.model.selectedItemIDs = [sensitiveSVGID]
            harness.model.selectedItemIDsInSelectionOrder = [sensitiveSVGID]
            let svgSelectionSynced = await TestSupport.waitUntil(timeout: .seconds(5)) {
                !SVGImageRenderer.shared.hasCachedRendering(for: sensitiveSVGID)
                    && harness.model.selectedItemID == sensitiveSVGID
            }
            #expect(svgSelectionSynced)
            try await Task.sleep(for: .milliseconds(30))

            // Reveal sensitive SVG via Cmd+U -> populates SVGImageRenderer.shared.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let svgCachedOnReveal = await TestSupport.waitUntil(timeout: .seconds(5)) {
                SVGImageRenderer.shared.hasCachedRendering(for: sensitiveSVGID)
            }
            #expect(svgCachedOnReveal)

            // Second Cmd+U re-hides -> evicts SVGImageRenderer.shared immediately.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            #expect(!SVGImageRenderer.shared.hasCachedRendering(for: sensitiveSVGID))

            // Reveal again via Cmd+U, then hide window -> hideRevealedSensitiveContent() evicts SVGImageRenderer.shared.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let svgCachedSecondReveal = await TestSupport.waitUntil(timeout: .seconds(5)) {
                SVGImageRenderer.shared.hasCachedRendering(for: sensitiveSVGID)
            }
            #expect(svgCachedSecondReveal)
            historyWindow.hide()
            #expect(!SVGImageRenderer.shared.hasCachedRendering(for: sensitiveSVGID))

            // (c) Upgrading an existing plain > 8 KB SVG clip to Sensitive evicts its cached plaintext rendering
            //     while preserving knownSVGClipIDs membership so Cmd+U reveal and hydrated preview renders still work and associate ownerID.
            let plainUpgradeSVGID = UUID()
            let plainUpgradeSVGMarkup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\"><!-- "
                + String(repeating: "u", count: 12_200)
                + " --><rect width=\"48\" height=\"48\" fill=\"#0088AA\"/></svg>"
            let savedPlainUpgrade = try harness.historyStore.saveAndReconcileItem(
                ClipboardItem.fixture(
                    id: plainUpgradeSVGID,
                    kind: .text,
                    text: plainUpgradeSVGMarkup,
                    copiedAt: baseTime.addingTimeInterval(30)
                ),
                convertingExternalAssets: true
            ).unloadingContent()
            #expect(!savedPlainUpgrade.isContentLoaded)
            harness.model.items.insert(savedPlainUpgrade, at: 0)

            historyWindow.window.alphaValue = 0
            historyWindow.show()
            harness.model.selectedItemID = plainUpgradeSVGID
            harness.model.selectedItemIDs = [plainUpgradeSVGID]
            harness.model.selectedItemIDsInSelectionOrder = [plainUpgradeSVGID]
            let plainUpgradeCached = await TestSupport.waitUntil(timeout: .seconds(5)) {
                SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID)
            }
            #expect(plainUpgradeCached)

            harness.coordinator.setSensitive(true, for: try #require(harness.currentItem(plainUpgradeSVGID)))
            #expect(!SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID))

            let upgradedItem = try #require(harness.currentItem(plainUpgradeSVGID))
            #expect(upgradedItem.sensitivity == .sensitive)
            #expect(!upgradedItem.isContentLoaded)

            let selectionSettledOnUpgraded = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.model.selectedItemID == plainUpgradeSVGID
                    && !SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID)
            }
            #expect(selectionSettledOnUpgraded)
            try await Task.sleep(for: .milliseconds(30))

            // Cmd+U reveal on the unloaded upgraded SVG row loads decrypted SVG text from store and associates ownerID.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            let upgradedRevealedAndCached = await TestSupport.waitUntil(timeout: .seconds(5)) {
                SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID)
            }
            #expect(upgradedRevealedAndCached)
            #expect(SVGImageRenderer.shared.hasCachedOwnerAssociation(for: plainUpgradeSVGID))

            // Re-hide via Cmd+U evicts the revealed rendering, and a hydrated preview render also still associates ownerID.
            historyWindow.window.sendEvent(try TestSupport.keyDownEvent(keyCode: 32, modifiers: [.command]))
            #expect(!SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID))

            let hydratedUpgraded = try harness.historyStore.loadingContent(of: upgradedItem, scope: .body)
            #expect(hydratedUpgraded.isContentLoaded)
            _ = try #require(SVGImageRenderer.shared.rendering(for: hydratedUpgraded))
            #expect(SVGImageRenderer.shared.hasCachedRendering(for: plainUpgradeSVGID))
            #expect(SVGImageRenderer.shared.hasCachedOwnerAssociation(for: plainUpgradeSVGID))
            SVGImageRenderer.shared.removeRendering(for: plainUpgradeSVGID)
            historyWindow.hide()
        }

        @Test
        func linkPreviewFetcherDefaultSessionIsEphemeralWithoutCacheOrCookies() {
            let configuration = LinkPreviewFetcher().session.configuration
            #expect(configuration.urlCache == nil)
            #expect(configuration.httpCookieStorage == nil)
            #expect(configuration.httpShouldSetCookies == false)
            #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func linkPreviewFetcherTruncatesOversizedHTMLStreamsAndRejectsOversizedImages() async throws {
            BoundedLinkPreviewTestURLProtocol.reset()
            defer {
                BoundedLinkPreviewTestURLProtocol.reset()
            }

            let validPNG = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24, color: .systemTeal)
            let host = BoundedLinkPreviewTestURLProtocol.host

            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/valid-og.png",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Content-Length": "\(validPNG.count)"],
                    body: validPNG
                )
            )
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/valid-icon.png",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Content-Length": "\(validPNG.count)"],
                    body: validPNG
                )
            )

            // 1. Streaming > 512 KB HTML (up to 4 MB if uncanceled) cancels early once 512 KB is reached and parses prefix metadata.
            let streamingHTMLHeader = """
            <!doctype html>
            <html>
            <head>
              <title>Bounded Stream Title</title>
              <meta property="og:description" content="Within 512KB Limit">
              <meta property="og:image" content="https://\(host)/valid-og.png">
              <link rel="icon" href="https://\(host)/valid-icon.png">
            </head>
            <body>
            """
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/streaming-page",
                route: .chunkedStream(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    initialChunk: Data(streamingHTMLHeader.utf8),
                    repeatingChunk: Data(repeating: UInt8(ascii: "a"), count: 32 * 1024),
                    maxAdditionalChunks: 128,
                    interChunkDelay: 0.002
                )
            )

            let testConfig = URLSessionConfiguration.ephemeral
            testConfig.protocolClasses = [BoundedLinkPreviewTestURLProtocol.self]
            let testSession = URLSession(configuration: testConfig)
            defer { testSession.invalidateAndCancel() }
            let fetcher = LinkPreviewFetcher(session: testSession)
            let streamingURL = try #require(URL(string: "https://\(host)/streaming-page"))
            let streamedPreview = try #require(await fetcher.fetchPreview(for: streamingURL))
            #expect(streamedPreview.title == "Bounded Stream Title")
            #expect(streamedPreview.description == "Within 512KB Limit")
            #expect(streamedPreview.image != nil)
            #expect(streamedPreview.favicon != nil)
            #expect(streamedPreview.imagePNGData != nil)
            #expect(streamedPreview.faviconPNGData != nil)

            #expect(await TestSupport.waitUntil {
                BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/streaming-page").didStopLoading
            }, "LinkPreviewFetcher must cancel HTML stream once 512 KB limit is reached")
            let htmlStreamMetrics = BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/streaming-page")
            #expect(htmlStreamMetrics.emittedBytes >= 512 * 1024)
            #expect(htmlStreamMetrics.emittedBytes < 2 * 1024 * 1024, "Cancelled HTML stream must stop well before 4 MB payload completes")

            // 2. Burst > 512 KB HTML ignoring Range header strictly truncates at 512 KB so tags past 512 KB are ignored.
            let prefixHTML = "<html><head><title>Prefix Title</title>"
            let paddingCount = (512 * 1024) - prefixHTML.utf8.count + 4096
            let burstOversizedHTML = prefixHTML
                + String(repeating: " ", count: paddingCount)
                + #"<meta property="og:description" content="Past512KBBoundary"></head></html>"#
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/burst-oversized",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data(burstOversizedHTML.utf8)
                )
            )
            let burstURL = try #require(URL(string: "https://\(host)/burst-oversized"))
            let burstPreview = try #require(await fetcher.fetchPreview(for: burstURL))
            #expect(burstPreview.title == "Prefix Title")
            #expect(burstPreview.description == nil)

            // 3. Oversized > 5 MB Content-Length image header is rejected immediately without reading the 6 MB body.
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/oversized-header.png",
                route: .chunkedStream(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png",
                        "Content-Length": "\(6 * 1024 * 1024)"
                    ],
                    initialChunk: Data(),
                    repeatingChunk: Data(repeating: 0xAB, count: 64 * 1024),
                    maxAdditionalChunks: 96,
                    interChunkDelay: 0.005
                )
            )
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/page-oversized-header-image",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data("""
                    <html><head>
                      <title>Header Guard Page</title>
                      <meta property="og:image" content="https://\(host)/oversized-header.png">
                    </head></html>
                    """.utf8)
                )
            )
            let headerGuardURL = try #require(URL(string: "https://\(host)/page-oversized-header-image"))
            let headerRejectedPreview = try #require(await fetcher.fetchPreview(for: headerGuardURL))
            #expect(headerRejectedPreview.title == "Header Guard Page")
            #expect(headerRejectedPreview.image == nil)
            #expect(await TestSupport.waitUntil {
                BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/oversized-header.png").didStopLoading
            })
            let headerImageMetrics = BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/oversized-header.png")
            #expect(headerImageMetrics.emittedBytes < 512 * 1024, "Oversized Content-Length image must cancel before streaming 6 MB")

            // 4. Chunked/unknown-length > 5 MB image stream and > 512 KB favicon stream are rejected cleanly at their byte limits.
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/oversized-stream.png",
                route: .chunkedStream(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png"],
                    initialChunk: Data(),
                    repeatingChunk: Data(repeating: 0xCD, count: 256 * 1024),
                    maxAdditionalChunks: 32,
                    interChunkDelay: 0.001
                )
            )
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/oversized-favicon.png",
                route: .chunkedStream(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png"],
                    initialChunk: Data(),
                    repeatingChunk: Data(repeating: 0xEF, count: 64 * 1024),
                    maxAdditionalChunks: 16,
                    interChunkDelay: 0.001
                )
            )
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/page-oversized-stream-image",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data("""
                    <html><head>
                      <title>Stream Guard Page</title>
                      <meta property="og:image" content="https://\(host)/oversized-stream.png">
                      <link rel="apple-touch-icon" href="https://\(host)/oversized-favicon.png">
                      <link rel="icon" href="https://\(host)/valid-icon.png">
                    </head></html>
                    """.utf8)
                )
            )
            let streamGuardURL = try #require(URL(string: "https://\(host)/page-oversized-stream-image"))
            let streamRejectedPreview = try #require(await fetcher.fetchPreview(for: streamGuardURL))
            #expect(streamRejectedPreview.title == "Stream Guard Page")
            #expect(streamRejectedPreview.image == nil, "Chunked image exceeding 5 MB must be rejected")
            #expect(streamRejectedPreview.favicon != nil, "Rejected > 512 KB favicon must fall back to subsequent valid favicon")
            #expect(await TestSupport.waitUntil {
                BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/oversized-stream.png").didStopLoading
                    && BoundedLinkPreviewTestURLProtocol.metrics(forPath: "/oversized-favicon.png").didStopLoading
            })

            // 5. Multi-frame favicon selects largest pixel-area frame (64x64 over 16x16) and normalizes to PNG off-main.
            let frame16PNG = try TestSupport.makePNGData(pixelWidth: 16, pixelHeight: 16, color: .systemRed)
            let frame64PNG = try TestSupport.makePNGData(pixelWidth: 64, pixelHeight: 64, color: .systemGreen)
            let src16 = try #require(CGImageSourceCreateWithData(frame16PNG as CFData, nil))
            let src64 = try #require(CGImageSourceCreateWithData(frame64PNG as CFData, nil))
            let img16 = try #require(CGImageSourceCreateImageAtIndex(src16, 0, nil))
            let img64 = try #require(CGImageSourceCreateImageAtIndex(src64, 0, nil))
            let multiFrameTIFF = NSMutableData()
            let tiffDest = try #require(CGImageDestinationCreateWithData(multiFrameTIFF, UTType.tiff.identifier as CFString, 2, nil))
            CGImageDestinationAddImage(tiffDest, img16, nil)
            CGImageDestinationAddImage(tiffDest, img64, nil)
            #expect(CGImageDestinationFinalize(tiffDest))

            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/multi-icon.tiff",
                route: .complete(statusCode: 200, headers: ["Content-Type": "image/tiff"], body: multiFrameTIFF as Data)
            )
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/multi-icon-page",
                route: .complete(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html"],
                    body: Data("<html><head><title>Multi</title><link rel=\"icon\" href=\"https://\(host)/multi-icon.tiff\"></head></html>".utf8)
                )
            )
            let multiPageURL = try #require(URL(string: "https://\(host)/multi-icon-page"))
            let multiPreview = try #require(await fetcher.fetchPreview(for: multiPageURL))
            let encodedFaviconPNG = try #require(multiPreview.faviconPNGData)
            #expect(encodedFaviconPNG.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            let decodedFavSrc = try #require(CGImageSourceCreateWithData(encodedFaviconPNG as CFData, nil))
            let decodedFavProps = try #require(CGImageSourceCopyPropertiesAtIndex(decodedFavSrc, 0, nil) as? [CFString: Any])
            #expect((decodedFavProps[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 64)
            #expect((decodedFavProps[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 64)

            // 6. Non-2xx/3xx HTTP response is rejected cleanly.
            BoundedLinkPreviewTestURLProtocol.setRoute(
                path: "/error-page",
                route: .complete(statusCode: 500, headers: ["Content-Type": "text/html"], body: Data("<title>Err</title>".utf8))
            )
            let errorURL = try #require(URL(string: "https://\(host)/error-page"))
            let failedPreview = await fetcher.fetchPreview(for: errorURL)
            #expect(failedPreview == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func itemPreviewDialogWebViewBlocksUnsafeSchemesAndUsesNonPersistentDataStore() async throws {
            TestSupport.ensureAppKitInitialized()

            var openedURLs: [URL] = []
            let linkItem = ClipboardItem.fixture(
                kind: .link,
                text: "https://preview-test.clipbook.invalid/article"
            )
            let controller = ItemPreviewDialogController(
                item: linkItem,
                maximumContentSize: NSSize(width: 900, height: 640),
                detectsSensitiveContent: true,
                revealsSensitiveContent: false,
                presentation: .sheet,
                showsPreview: true,
                loadContent: { item, _ in item },
                openExternalURL: { url in
                    openedURLs.append(url)
                }
            )
            defer {
                controller.tearDownContent()
                TestSupport.drainDelayedPerforms([controller])
            }

            _ = controller.view

            func findWebView(in root: NSView) -> WKWebView? {
                if let webView = root as? WKWebView {
                    return webView
                }
                for subview in root.subviews {
                    if let found = findWebView(in: subview) {
                        return found
                    }
                }
                return nil
            }

            let webView = try #require(findWebView(in: controller.view))
            #expect(webView.configuration.websiteDataStore.isPersistent == false)
            #expect(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
            #expect(webView.navigationDelegate === controller)
            #expect(webView.uiDelegate === controller)
            #expect(
                controller.responds(
                    to: #selector(
                        WKNavigationDelegate.webView(
                            _:decidePolicyFor:decisionHandler:
                        ) as (WKNavigationDelegate) -> ((WKWebView, WKNavigationAction, @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) -> Void)?
                    )
                )
            )

            let navigationDelegate = try #require(webView.navigationDelegate)
            let uiDelegate = try #require(webView.uiDelegate)

            func decidePolicy(for request: URLRequest) throws -> WKNavigationActionPolicy {
                var recordedPolicy: WKNavigationActionPolicy?
                navigationDelegate.webView?(
                    webView,
                    decidePolicyFor: StubWebNavigationAction(request: request),
                    decisionHandler: { policy in
                        recordedPolicy = policy
                    }
                )
                return try #require(recordedPolicy)
            }

            let blockedURLStrings = [
                "file:///etc/passwd",
                "smb://fileserver.local/share",
                "ssh://git@example.com/repo",
                "custom-app://open?action=launch",
                "javascript:alert(1)",
                "mailto:user@example.com"
            ]

            for rawURL in blockedURLStrings {
                let url = try #require(URL(string: rawURL))
                let request = URLRequest(url: url)
                #expect(try decidePolicy(for: request) == .cancel, "decidePolicyFor must cancel \(rawURL)")
                let childWebView = uiDelegate.webView?(
                    webView,
                    createWebViewWith: webView.configuration,
                    for: StubWebNavigationAction(request: request),
                    windowFeatures: WKWindowFeatures()
                )
                #expect(childWebView == nil)
            }
            #expect(openedURLs.isEmpty, "Blocked non-http(s) schemes must never invoke openExternalURL")

            var nilURLRequest = URLRequest(url: try #require(URL(string: "https://example.com")))
            nilURLRequest.url = nil
            #expect(try decidePolicy(for: nilURLRequest) == .cancel)
            #expect(
                uiDelegate.webView?(
                    webView,
                    createWebViewWith: webView.configuration,
                    for: StubWebNavigationAction(request: nilURLRequest),
                    windowFeatures: WKWindowFeatures()
                ) == nil
            )
            #expect(openedURLs.isEmpty)

            // about:blank is allowed inside the preview web view, but never dispatched to an external opener.
            for blankString in ["about:blank", "ABOUT:BLANK"] {
                let blankURL = try #require(URL(string: blankString))
                let blankRequest = URLRequest(url: blankURL)
                #expect(try decidePolicy(for: blankRequest) == .allow)
                let blankChild = uiDelegate.webView?(
                    webView,
                    createWebViewWith: webView.configuration,
                    for: StubWebNavigationAction(request: blankRequest),
                    windowFeatures: WKWindowFeatures()
                )
                #expect(blankChild == nil)
            }
            #expect(openedURLs.isEmpty)

            // Standard http(s) navigations are allowed in-place and forwarded to the injected opener for target="_blank".
            let httpsURL = try #require(URL(string: "https://example.com/docs"))
            let httpURL = try #require(URL(string: "http://example.com/docs"))
            #expect(try decidePolicy(for: URLRequest(url: httpsURL)) == .allow)
            #expect(try decidePolicy(for: URLRequest(url: httpURL)) == .allow)

            #expect(
                uiDelegate.webView?(
                    webView,
                    createWebViewWith: webView.configuration,
                    for: StubWebNavigationAction(request: URLRequest(url: httpsURL)),
                    windowFeatures: WKWindowFeatures()
                ) == nil
            )
            #expect(
                uiDelegate.webView?(
                    webView,
                    createWebViewWith: webView.configuration,
                    for: StubWebNavigationAction(request: URLRequest(url: httpURL)),
                    windowFeatures: WKWindowFeatures()
                ) == nil
            )
            #expect(openedURLs == [httpsURL, httpURL])

            // Ungestured on-load JS window.open(...) and synthetic target="_blank" click must never auto-invoke openExternalURL.
            openedURLs.removeAll()
            let autoPopupHTML = """
            <!doctype html>
            <html><body>
            <a id="autoLink" href="https://example.com/synthetic-click" target="_blank">go</a>
            <script>
              window.open("https://example.com/window-open");
              document.getElementById("autoLink").click();
              window.__popupProbeDone = true;
            </script>
            </body></html>
            """
            webView.loadHTMLString(autoPopupHTML, baseURL: try #require(URL(string: "https://example.com")))
            var probeCompleted = false
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript("window.__popupProbeDone === true") as? Bool) == true {
                    probeCompleted = true
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(probeCompleted)
            #expect(openedURLs.isEmpty, "Ungestured JavaScript popups must be blocked by javaScriptCanOpenWindowsAutomatically == false")
        }
    }
}

@MainActor
private final class ToolbarDelegateSpy: HistoryToolbarDelegate {
    var selectedTags: [(ClipBook.Tag.ID, Bool)] = []

    func historyToolbar(_ toolbar: HistoryToolbar, didChangeSearchQuery query: String) {}
    func historyToolbar(_ toolbar: HistoryToolbar, didRequestMoveSelection direction: HistorySelectionDirection) {}
    func historyToolbar(_ toolbar: HistoryToolbar, didSelectSortOption sortOption: HistorySortOption) {}
    func historyToolbar(_ toolbar: HistoryToolbar, didSetFilterContentType contentType: HistoryFilterContentType, isSelected: Bool) {}

    func historyToolbar(_ toolbar: HistoryToolbar, didSetFilterTagID tagID: ClipBook.Tag.ID, isSelected: Bool) {
        selectedTags.append((tagID, isSelected))
    }

    func historyToolbar(
        _ toolbar: HistoryToolbar,
        didSetFilterSourceApplicationID sourceApplicationID: HistorySourceApplication.ID,
        isSelected: Bool
    ) {}

    func historyToolbar(_ toolbar: HistoryToolbar, didRequestClearFilterGroup group: SearchTokenGroup) {}
    func historyToolbarDidRequestClearFilters(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestToggleSortOrder(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestPaste(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestCopy(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestCopyTextFromImage(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestCopyTextFromQRCode(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestOpenInBrowser(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestMergeSelection(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestTogglePin(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestToggleCopySequenceMode(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestTogglePreviewPane(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestToggleDetails(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestToggleImageTiles(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestToggleCompactHistory(_ toolbar: HistoryToolbar) {}
    func historyToolbarDidRequestCommandDialog(_ toolbar: HistoryToolbar) {}
}

@MainActor
private func allViewDescendants(in root: NSView, includeGlassContentView: Bool = true) -> [NSView] {
    var visited = Set<ObjectIdentifier>()
    var ordered: [NSView] = []
    func walk(_ view: NSView) {
        guard visited.insert(ObjectIdentifier(view)).inserted else { return }
        ordered.append(view)
        if includeGlassContentView,
           #available(macOS 26.0, *),
           let glassView = view as? NSGlassEffectView,
           let contentView = glassView.contentView {
            walk(contentView)
        }
        for subview in view.subviews {
            walk(subview)
        }
    }
    walk(root)
    return ordered
}

@MainActor
private func findEditableTextView(in root: NSView) -> NSTextView? {
    if let textView = root as? NSTextView, textView.isEditable {
        return textView
    }
    for subview in root.subviews {
        if let found = findEditableTextView(in: subview) {
            return found
        }
    }
    return nil
}

@MainActor
private func findEditableTextField(in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.isEditable {
        return field
    }
    for subview in root.subviews {
        if let found = findEditableTextField(in: subview) {
            return found
        }
    }
    return nil
}

@MainActor
private final class StubWebNavigationAction: WKNavigationAction {
    private let stubbedRequest: URLRequest

    init(request: URLRequest) {
        self.stubbedRequest = request
        super.init()
    }

    override var request: URLRequest {
        stubbedRequest
    }
}

private nonisolated final class BoundedLinkPreviewTestURLProtocol: URLProtocol {
    nonisolated static let host = "linkpreview-bounds-test.clipbook.invalid"

    nonisolated enum Route: Sendable {
        case complete(statusCode: Int, headers: [String: String], body: Data)
        case chunkedStream(
            statusCode: Int,
            headers: [String: String],
            initialChunk: Data,
            repeatingChunk: Data,
            maxAdditionalChunks: Int,
            interChunkDelay: TimeInterval
        )
    }

    nonisolated struct RouteMetrics: Sendable {
        var emittedBytes = 0
        var didStopLoading = false
    }

    private nonisolated struct RegistryState: Sendable {
        var routes: [String: Route] = [:]
        var metricsByPath: [String: RouteMetrics] = [:]
    }

    private nonisolated static let registry = OSAllocatedUnfairLock(initialState: RegistryState())
    private nonisolated static let streamQueue = DispatchQueue(
        label: "com.ikryanov.clipbook.tests.bounded-link-preview-stream",
        attributes: .concurrent
    )

    private nonisolated let instanceLock = NSLock()
    private nonisolated var isStopped = false

    nonisolated static func reset() {
        registry.withLock { state in
            state.routes.removeAll()
            state.metricsByPath.removeAll()
        }
    }

    nonisolated static func setRoute(path: String, route: Route) {
        registry.withLock { state in
            state.routes[path] = route
            state.metricsByPath[path] = RouteMetrics()
        }
    }

    nonisolated static func metrics(forPath path: String) -> RouteMetrics {
        registry.withLock { state in
            state.metricsByPath[path] ?? RouteMetrics()
        }
    }

    override nonisolated class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override nonisolated func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path.isEmpty ? "/" : url.path
        let route = Self.registry.withLock { $0.routes[path] }

        guard let route else {
            if let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                client?.urlProtocol(self, didReceive: notFound, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        switch route {
        case let .complete(statusCode, headers, body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                Self.registry.withLock { $0.metricsByPath[path, default: RouteMetrics()].emittedBytes += body.count }
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case let .chunkedStream(statusCode, headers, initialChunk, repeatingChunk, maxAdditionalChunks, interChunkDelay):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !initialChunk.isEmpty {
                let delivered = deliverIfActive(initialChunk, forPath: path)
                if !delivered {
                    return
                }
            }
            emitRemainingChunks(
                index: 0,
                maxCount: maxAdditionalChunks,
                chunk: repeatingChunk,
                delay: interChunkDelay,
                path: path
            )
        }
    }

    private nonisolated func emitRemainingChunks(
        index: Int,
        maxCount: Int,
        chunk: Data,
        delay: TimeInterval,
        path: String
    ) {
        instanceLock.lock()
        let alreadyStopped = isStopped
        instanceLock.unlock()
        if alreadyStopped {
            return
        }
        guard index < maxCount else {
            instanceLock.lock()
            let canFinish = !isStopped
            if canFinish {
                client?.urlProtocolDidFinishLoading(self)
            }
            instanceLock.unlock()
            return
        }

        nonisolated(unsafe) weak let weakSelf = self
        let work: @Sendable () -> Void = {
            guard let strongSelf = weakSelf else { return }
            guard strongSelf.deliverIfActive(chunk, forPath: path) else { return }
            strongSelf.emitRemainingChunks(
                index: index + 1,
                maxCount: maxCount,
                chunk: chunk,
                delay: delay,
                path: path
            )
        }

        if delay > 0 {
            Self.streamQueue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            Self.streamQueue.async(execute: work)
        }
    }

    private nonisolated func deliverIfActive(_ chunk: Data, forPath path: String) -> Bool {
        instanceLock.lock()
        let canSend = !isStopped
        if canSend {
            client?.urlProtocol(self, didLoad: chunk)
        }
        instanceLock.unlock()
        if canSend {
            Self.registry.withLock {
                $0.metricsByPath[path, default: RouteMetrics()].emittedBytes += chunk.count
            }
        }
        return canSend
    }

    override nonisolated func stopLoading() {
        let path = request.url.map { $0.path.isEmpty ? "/" : $0.path } ?? "/"
        instanceLock.lock()
        isStopped = true
        instanceLock.unlock()
        Self.registry.withLock {
            $0.metricsByPath[path, default: RouteMetrics()].didStopLoading = true
        }
    }
}
