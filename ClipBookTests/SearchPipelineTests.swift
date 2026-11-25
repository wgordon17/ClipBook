@testable import ClipBook
import AppKit
import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing

@Suite
struct SearchPipelineTests {
    @Test
    func searchTermsTokenizationAndASCIIClassification() {
        let empty = HistorySearchTerms(query: "   \n\t  ")
        #expect(empty.isEmpty)
        #expect(empty.values.isEmpty)
        #expect(empty.asciiTerms.isEmpty)

        let terms = HistorySearchTerms(query: "  Alpha\t9[\nCafé  \r\nv2_beta ")
        #expect(!terms.isEmpty)
        #expect(terms.values == ["Alpha", "9[", "Café", "v2_beta"])
        #expect(terms.asciiTerms.count == 4)

        #expect(terms.asciiTerms[0]?.lowercasedBytes == Array("alpha".utf8))
        #expect(terms.asciiTerms[0]?.containsDigit == false)

        #expect(terms.asciiTerms[1]?.lowercasedBytes == Array("9[".utf8))
        #expect(terms.asciiTerms[1]?.containsDigit == true)

        #expect(terms.asciiTerms[2] == nil)

        #expect(terms.asciiTerms[3]?.lowercasedBytes == Array("v2_beta".utf8))
        #expect(terms.asciiTerms[3]?.containsDigit == true)

        let withNUL = HistorySearchTerms(values: ["ab\0cd", "plain\u{7F}"])
        #expect(withNUL.asciiTerms[0] == nil)
        #expect(withNUL.asciiTerms[1] == nil)

        #expect(HistorySearchTerms(query: "foo   bar") == HistorySearchTerms(query: "foo bar"))
        #expect(HistorySearchTerms(query: "foo bar") != HistorySearchTerms(query: "FOO bar"))
    }

    @Test
    func matcherParityWithFoundationAcrossScriptsSymbolsAndLocales() {
        let locales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "tr_TR"),
            Locale(identifier: "az"),
            Locale(identifier: "de_DE"),
            Locale(identifier: "da_DK"),
            Locale(identifier: "es_ES")
        ]

        let haystacks = [
            "",
            "Hello World ClipBook 2026",
            "Café",
            "Cafe\u{0301}",
            "ca\u{0301}fe",
            "cafe",
            "año",
            "an\u{0303}o",
            "ano",
            "Søren Łódź Æther Œuvre Straße ø ł æ œ ß",
            "a≠b",
            "a≮b",
            "a≯b",
            "a\u{00AD}b",
            "한글 테스트",
            "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF} 테스트",
            "東京タワー 🚀 ClipBook",
            "日本語テキスト ✨",
            "abc\0def",
            "İstanbul ışık İSTANBUL I\u{0307}stanbul IŞIK",
            "Aalborg Ålborg llama chico",
            "東京 9[ café",
            "東京 ９[ café",
            "한글 99 test",
            "résumé ٤٢ 9["
        ]

        let queries = [
            "",
            "   ",
            "hello",
            "HELLO world",
            "hello mars",
            "cafe",
            "café",
            "Cafe\u{0301}",
            "ca\u{0301}fe",
            "ano",
            "año",
            "an\u{0303}o",
            "o",
            "ø",
            "l",
            "ł",
            "ae",
            "æ",
            "oe",
            "œ",
            "ss",
            "ß",
            "s",
            "=",
            "a=b",
            "!=",
            "<=",
            "<",
            ">",
            "≠",
            "ab",
            "a\u{00AD}b",
            "한글",
            "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}",
            "東京",
            "🚀",
            "东京",
            "abc",
            "def",
            "c\0d",
            "abcdef",
            "istanbul",
            "İstanbul",
            "ışık",
            "i",
            "I",
            "aa",
            "å",
            "ll",
            "ch",
            "9[",
            "9",
            "42",
            "東京 9["
        ]

        for locale in locales {
            for haystack in haystacks {
                for query in queries {
                    let terms = HistorySearchTerms(query: query)
                    let actual = HistorySearchMatcher.matches(haystack, terms, locale: locale)
                    let expected = terms.values.allSatisfy { term in
                        haystack.range(
                            of: term,
                            options: [.caseInsensitive, .diacriticInsensitive],
                            range: nil,
                            locale: locale
                        ) != nil
                    }
                    #expect(
                        actual == expected,
                        "Mismatch for locale=\(locale.identifier) haystack=\(String(reflecting: haystack)) query=\(String(reflecting: query)): got \(actual), expected \(expected)"
                    )
                }
            }
        }
    }

    @Test
    func matcherAndHighlighterAgreeAcrossMultiWordAndDiacriticQueries() {
        let font = NSFont.systemFont(ofSize: 13)
        let baseColor = NSColor.labelColor
        let highlightColor = HistorySearchMatchHighlighter.highlightColor
        let locale = Locale.current

        let samples = [
            "Café résumé naïve world",
            "Feliz año nuevo 2026",
            "Plain ASCII alpha beta gamma",
            "東京タワー ClipBook 🚀",
            "a\u{00AD}b soft hyphen"
        ]
        let singleTermQueries = ["cafe", "résumé", "ano", "alpha", "9[", "東京", "ab", "missing"]
        let multiTermQueries = ["cafe world", "resume naive", "alpha gamma", "cafe missing", "feliz ano"]

        func hasHighlightedCharacter(in attributed: NSAttributedString) -> Bool {
            var found = false
            attributed.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, stop in
                if (value as? NSColor) == highlightColor {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        for text in samples {
            for query in singleTermQueries {
                let terms = HistorySearchTerms(query: query)
                let matched = HistorySearchMatcher.matches(text, terms, locale: locale)
                let attributed = HistorySearchMatchHighlighter.attributedString(
                    text: text,
                    font: font,
                    textColor: baseColor,
                    searchQuery: query
                )
                #expect(
                    hasHighlightedCharacter(in: attributed) == matched,
                    "Single-term highlighter disagreement for text=\(text) query=\(query)"
                )
            }

            for query in multiTermQueries {
                let terms = HistorySearchTerms(query: query)
                let matched = HistorySearchMatcher.matches(text, terms, locale: locale)
                let attributed = HistorySearchMatchHighlighter.attributedString(
                    text: text,
                    font: font,
                    textColor: baseColor,
                    searchQuery: query
                )
                if matched {
                    #expect(hasHighlightedCharacter(in: attributed))
                    let nsText = text as NSString
                    for term in terms.values {
                        let range = nsText.range(
                            of: term,
                            options: HistorySearchMatcher.compareOptions,
                            range: NSRange(location: 0, length: nsText.length),
                            locale: locale
                        )
                        #expect(range.location != NSNotFound)
                        if range.location != NSNotFound {
                            let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                            #expect(color == highlightColor)
                        }
                    }
                }
            }
        }
    }

    @Test
    func searchCorpusCancellationAndPrefixRefinementBitmapReuse() throws {
        let locale = Locale(identifier: "en_US")
        let texts = [
            "alpha beta",
            "delta epsilon",
            "Àlpha diacritic",
            "alpaca farm",
            "unrelated ascii row",
            "ALPHA2 digit suffix",
            "Æther",
            "ﬁlter ligature",
            "Straße",
            "Maß"
        ]
        let ids = texts.map { _ in UUID() }
        let corpus = HistorySearchCorpus(revision: 7, ids: ids, texts: texts)

        let cancelledJob = HistorySearchJob()
        cancelledJob.cancel()
        #expect(cancelledJob.isCancelled)
        #expect(cancelledJob.run(corpus: corpus, terms: HistorySearchTerms(query: "alp"), locale: locale) == nil)

        let initialJob = HistorySearchJob()
        let initialResult = try #require(
            initialJob.run(corpus: corpus, terms: HistorySearchTerms(query: "alp"), locale: locale)
        )
        #expect(initialResult.matches == [true, false, true, true, false, true, false, false, false, false])
        #expect(initialResult.matchCount == 4)
        #expect(initialResult.indexByID.count == texts.count)

        // Strict ASCII prefix refinement ("alp" -> "alpha") reuses previous bitmap for ASCII misses
        // while still matching non-ASCII "Àlpha diacritic".
        let refinedJob = HistorySearchJob()
        let refinedResult = try #require(
            refinedJob.run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "alpha"),
                locale: locale,
                previous: initialResult
            )
        )
        #expect(refinedResult.matches == [true, false, true, false, false, true, false, false, false, false])
        #expect(refinedResult.matchCount == 3)
        #expect(refinedResult.indexByID == initialResult.indexByID)

        // Foundation parity on "Æther" ("a" -> "ae"), plus true `false -> true` prefix-refinement
        // transitions on non-ASCII ligature "ﬁlter" ("f" -> "fi") and sharp-s "Maß" ("s" -> "ss")
        // / "Straße" ("stras" -> "strass"), exercising HistorySearchCorpus's non-ASCII re-evaluation path.
        let aResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: HistorySearchTerms(query: "a"), locale: locale)
        )
        #expect(aResult.matches[6] == false)
        let aeResult = try #require(
            HistorySearchJob().run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "ae"),
                locale: locale,
                previous: aResult
            )
        )
        #expect(
            aeResult.matches[6]
                == ("Æther".range(of: "ae", options: HistorySearchMatcher.compareOptions, locale: locale) != nil)
        )

        let fResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: HistorySearchTerms(query: "f"), locale: locale)
        )
        #expect(fResult.matches[7] == false)
        let fiResult = try #require(
            HistorySearchJob().run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "fi"),
                locale: locale,
                previous: fResult
            )
        )
        #expect(fiResult.matches[7] == true)

        let sResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: HistorySearchTerms(query: "s"), locale: locale)
        )
        #expect(sResult.matches[9] == false)
        let ssResult = try #require(
            HistorySearchJob().run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "ss"),
                locale: locale,
                previous: sResult
            )
        )
        #expect(ssResult.matches[8] == true)
        #expect(ssResult.matches[9] == true)

        let strasResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: HistorySearchTerms(query: "stras"), locale: locale)
        )
        #expect(strasResult.matches[8] == false)
        let strassResult = try #require(
            HistorySearchJob().run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "strass"),
                locale: locale,
                previous: strasResult
            )
        )
        #expect(strassResult.matches[8] == true)

        // Non-prefix query ("delta") must not skip rows that were false in `initialResult`.
        let disjointJob = HistorySearchJob()
        let disjointResult = try #require(
            disjointJob.run(
                corpus: corpus,
                terms: HistorySearchTerms(query: "delta"),
                locale: locale,
                previous: initialResult
            )
        )
        #expect(disjointResult.matches == [false, true, false, false, false, false, false, false, false, false])
        #expect(disjointResult.matchCount == 1)

        // Danish (`da_DK`): verifies Foundation parity on "a" -> "aa" refinement across ICU versions
        // (including the `false -> true` transition on "Aalborg"/"Ålborg" when ICU contracts "aa").
        let daLocale = Locale(identifier: "da_DK")
        let daTexts = ["Aalborg", "Ålborg", "plain"]
        let daCorpus = HistorySearchCorpus(revision: 8, ids: daTexts.map { _ in UUID() }, texts: daTexts)
        let daAResult = try #require(
            HistorySearchJob().run(corpus: daCorpus, terms: HistorySearchTerms(query: "a"), locale: daLocale)
        )
        let expectedDaA = daTexts.map {
            $0.range(of: "a", options: HistorySearchMatcher.compareOptions, locale: daLocale) != nil
        }
        #expect(daAResult.matches == expectedDaA)
        let daAAResult = try #require(
            HistorySearchJob().run(
                corpus: daCorpus,
                terms: HistorySearchTerms(query: "aa"),
                locale: daLocale,
                previous: daAResult
            )
        )
        let expectedDaAA = daTexts.map {
            $0.range(of: "aa", options: HistorySearchMatcher.compareOptions, locale: daLocale) != nil
        }
        #expect(daAAResult.matches == expectedDaAA)
        if "aa".range(of: "a", options: HistorySearchMatcher.compareOptions, locale: daLocale) == nil {
            #expect(daAResult.matches == [false, false, true])
            #expect(daAAResult.matches == [true, true, false])
        }

        // Turkish (`tr_TR`): dotted/dotless I folding disables the ASCII prefilter and matches Foundation parity.
        let trLocale = Locale(identifier: "tr_TR")
        let trTexts = ["İstanbul", "I\u{0307}stanbul", "ISPARTA", "ısparta", "isparta", "plain"]
        let trCorpus = HistorySearchCorpus(revision: 9, ids: trTexts.map { _ in UUID() }, texts: trTexts)
        let trIResult = try #require(
            HistorySearchJob().run(corpus: trCorpus, terms: HistorySearchTerms(query: "i"), locale: trLocale)
        )
        let expectedTrI = trTexts.map {
            $0.range(of: "i", options: HistorySearchMatcher.compareOptions, locale: trLocale) != nil
        }
        #expect(trIResult.matches == expectedTrI)
        let trIsResult = try #require(
            HistorySearchJob().run(
                corpus: trCorpus,
                terms: HistorySearchTerms(query: "is"),
                locale: trLocale,
                previous: trIResult
            )
        )
        let expectedTrIs = trTexts.map {
            $0.range(of: "is", options: HistorySearchMatcher.compareOptions, locale: trLocale) != nil
        }
        #expect(trIsResult.matches == expectedTrIs)

        // Multi-chunk corpus (`count > 512`, `checkStride = 64`) containing `> 400`-byte non-ASCII
        // matching entries (`warmUpFontCascadeIfNeeded`) matches Foundation parity.
        let longNonASCIIMatch = "東京タワー ✨\n" + String(repeating: "日本語テキスト needle cascade ", count: 24)
        #expect(longNonASCIIMatch.utf8.count > 400)
        let largeTexts: [String] = (0..<600).map { index in
            switch index {
            case 17, 305, 589:
                return "\(longNonASCIIMatch) #\(index)"
            case 42, 411:
                return "Àlpha needle diacritic row \(index)"
            case 128, 512:
                return "ascii needle row \(index)"
            default:
                return "unmatched filler entry \(index)"
            }
        }
        let largeCorpus = HistorySearchCorpus(
            revision: 10,
            ids: largeTexts.map { _ in UUID() },
            texts: largeTexts
        )
        let largeNeeResult = try #require(
            HistorySearchJob().run(corpus: largeCorpus, terms: HistorySearchTerms(query: "nee"), locale: locale)
        )
        let largeNeedleResult = try #require(
            HistorySearchJob().run(
                corpus: largeCorpus,
                terms: HistorySearchTerms(query: "needle"),
                locale: locale,
                previous: largeNeeResult
            )
        )
        let expectedLargeNeedle = largeTexts.map {
            $0.range(of: "needle", options: HistorySearchMatcher.compareOptions, locale: locale) != nil
        }
        #expect(largeNeedleResult.matches == expectedLargeNeedle)
        #expect(largeNeedleResult.matchCount == 7)

        let nonASCIICascadeTerms = HistorySearchTerms(query: "日本語 needle")
        let nonASCIICascadeResult = try #require(
            HistorySearchJob().run(corpus: largeCorpus, terms: nonASCIICascadeTerms, locale: locale)
        )
        let expectedNonASCICI = largeTexts.map { haystack in
            nonASCIICascadeTerms.values.allSatisfy { term in
                haystack.range(of: term, options: HistorySearchMatcher.compareOptions, locale: locale) != nil
            }
        }
        #expect(nonASCIICascadeResult.matches == expectedNonASCICI)
        #expect(nonASCIICascadeResult.matchCount == 3)
    }

    @Test
    @MainActor
    func appModelMultiTermSearchAndSingleTagOrderingCacheInvalidation() {
        let model = AppModel()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        var olderFirstInTag = ClipboardItem.fixture(
            text: "alpha older manual-first",
            copiedAt: baseDate,
            tags: [1, 2]
        )
        olderFirstInTag.tagOrders = [1: 0]

        var newerSecondInTag = ClipboardItem.fixture(
            text: "alpha beta newer manual-second",
            copiedAt: baseDate.addingTimeInterval(60),
            tags: [1, 2]
        )
        newerSecondInTag.tagOrders = [1: 1]

        let untaggedNewest = ClipboardItem.fixture(
            text: "beta gamma untagged",
            copiedAt: baseDate.addingTimeInterval(120),
            tags: []
        )

        model.items = [olderFirstInTag, newerSecondInTag, untaggedNewest]
        #expect(model.filteredItems.map(\.id) == [untaggedNewest.id, newerSecondInTag.id, olderFirstInTag.id])

        let revisionBeforeSearch = model.sortedListRevision
        model.searchQuery = "alpha"
        #expect(model.sortedListRevision == revisionBeforeSearch)
        #expect(model.filteredItems.map(\.id) == [newerSecondInTag.id, olderFirstInTag.id])

        model.searchQuery = "alpha beta"
        #expect(model.sortedListRevision == revisionBeforeSearch)
        #expect(model.filteredItems.map(\.id) == [newerSecondInTag.id])

        model.searchQuery = ""
        #expect(model.sortedListRevision == revisionBeforeSearch)

        // Entering single-tag filter activates manual `orderingTagID` and invalidates cached sort order.
        model.selectedHistoryFilterTagIDs = [1]
        #expect(model.orderingTagID == 1)
        let singleTagRevision = model.sortedListRevision
        #expect(singleTagRevision != revisionBeforeSearch)
        #expect(model.filteredItems.map(\.id) == [olderFirstInTag.id, newerSecondInTag.id])

        // Widening to two tags leaves single-tag `orderingTagID` and restores `copiedAt` sort order.
        model.selectedHistoryFilterTagIDs = [1, 2]
        #expect(model.orderingTagID == nil)
        #expect(model.sortedListRevision != singleTagRevision)
        #expect(model.filteredItems.map(\.id) == [newerSecondInTag.id, olderFirstInTag.id])
    }

    @Test
    @MainActor
    func previewFieldAndTextRowRedrawWhenTogglingHidesSensitiveContent() throws {
        TestSupport.ensureAppKitInitialized()

        let baseFont = NSFont.systemFont(ofSize: 13)
        let field = HistoryTextPreviewField()
        let literalMasked = "Token \(SensitiveContent.inlineMask) suffix"
        let bulletLocation = (literalMasked as NSString).range(of: SensitiveContent.inlineMask).location

        field.update(
            previewText: literalMasked,
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: true,
            widthHint: 480
        )
        let hiddenFont = try #require(
            field.attributedStringValue.attribute(.font, at: bulletLocation, effectiveRange: nil) as? NSFont
        )
        #expect(abs(hiddenFont.pointSize - baseFont.pointSize * 0.42) < 0.01)

        // Same `previewText` with `hidesSensitiveContent: false` must invalidate `RenderedState` and redraw unscaled.
        field.update(
            previewText: literalMasked,
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: false,
            widthHint: 480
        )
        let revealedFont = try #require(
            field.attributedStringValue.attribute(.font, at: bulletLocation, effectiveRange: nil) as? NSFont
        )
        #expect(abs(revealedFont.pointSize - baseFont.pointSize) < 0.01)

        // Toggling back to `true` restores mask font scaling.
        field.update(
            previewText: literalMasked,
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: true,
            widthHint: 480
        )
        let rehiddenFont = try #require(
            field.attributedStringValue.attribute(.font, at: bulletLocation, effectiveRange: nil) as? NSFont
        )
        #expect(abs(rehiddenFont.pointSize - baseFont.pointSize * 0.42) < 0.01)

        // End-to-end `HistoryItemRowTextView` toggle with runtime-assembled token.
        let token = ["sk", "-", String(repeating: "a1B2c3D4", count: 4)].joined()
        let item = ClipboardItem.fixture(kind: .text, text: "API key \(token) active")
        let row = HistoryItemRowTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 48))

        row.configure(
            item: item,
            quickPasteIndex: 1,
            tableWidth: 480,
            detectsSensitiveContent: true,
            revealsSensitiveContent: false
        )
        #expect(row.hidesSensitiveContent)

        row.configure(
            item: item,
            quickPasteIndex: 1,
            tableWidth: 480,
            detectsSensitiveContent: true,
            revealsSensitiveContent: true
        )
        #expect(!row.hidesSensitiveContent)
    }

    @Test
    func previewFormatterCutPreservesInlineAndCardMaskSpansAcrossBoundaries() {
        let inlineMasked = "Key \(SensitiveContent.inlineMask) trailing context words"
        let inlinePreview = HistoryTextPreviewFormatter.preview(from: inlineMasked)

        for budget in 1...inlineMasked.count {
            let (cutPreview, _) = HistoryTextPreviewFormatter.cut(inlinePreview, toVisibleCharacters: budget)
            if cutPreview.text.contains("●") {
                let ranges = SensitiveContent.maskRanges(in: cutPreview.text)
                #expect(
                    ranges.count == 1 && ranges[0].length == SensitiveContent.inlineMask.utf16.count,
                    "Inline mask split at budget=\(budget): \(cutPreview.text)"
                )
            }
        }

        let cardMask = "●●●● ●●●● ●●●● 4242"
        let cardMasked = "Card \(cardMask) trailing context words"
        let cardPreview = HistoryTextPreviewFormatter.preview(from: cardMasked)

        for budget in 1...cardMasked.count {
            let (cutPreview, _) = HistoryTextPreviewFormatter.cut(cardPreview, toVisibleCharacters: budget)
            if cutPreview.text.contains("●") {
                let ranges = SensitiveContent.maskRanges(in: cutPreview.text)
                #expect(
                    ranges.map(\.length) == [4, 4, 4],
                    "Card mask split at budget=\(budget): \(cutPreview.text)"
                )
                #expect(cutPreview.text.contains(cardMask))
            }
        }

        // `boundedString` via `preview(from:characterLimit:)` also preserves mask spans.
        let boundedInline = HistoryTextPreviewFormatter.preview(from: inlineMasked, characterLimit: 7)
        #expect(SensitiveContent.maskRanges(in: boundedInline.text).map(\.length) == [8])

        let boundedCard = HistoryTextPreviewFormatter.preview(from: cardMasked, characterLimit: 12)
        #expect(SensitiveContent.maskRanges(in: boundedCard.text).map(\.length) == [4, 4, 4])
        #expect(boundedCard.text.contains(cardMask))

        // Masks ending directly at `endIndex` with no trailing text do not report a cut or append "...".
        let inlineAtEnd = "Key \(SensitiveContent.inlineMask)"
        let inlineAtEndPreview = HistoryTextPreviewFormatter.preview(from: inlineAtEnd)
        for budget in 5..<inlineAtEnd.count {
            let (cutPreview, isCut) = HistoryTextPreviewFormatter.cut(inlineAtEndPreview, toVisibleCharacters: budget)
            #expect(!isCut, "Unexpected isCut at budget=\(budget)")
            #expect(!cutPreview.text.hasSuffix("..."))
            #expect(cutPreview.text == inlineAtEnd)
        }
        let boundedInlineAtEnd = HistoryTextPreviewFormatter.preview(from: inlineAtEnd, characterLimit: 6)
        #expect(!boundedInlineAtEnd.text.hasSuffix("..."))
        #expect(boundedInlineAtEnd.text == inlineAtEnd)

        let cardAtEnd = "Card \(cardMask)"
        let cardAtEndPreview = HistoryTextPreviewFormatter.preview(from: cardAtEnd)
        for budget in 6..<cardAtEnd.count {
            let (cutPreview, isCut) = HistoryTextPreviewFormatter.cut(cardAtEndPreview, toVisibleCharacters: budget)
            #expect(!isCut, "Unexpected isCut at budget=\(budget)")
            #expect(!cutPreview.text.hasSuffix("..."))
            #expect(cutPreview.text == cardAtEnd)
        }
        let boundedCardAtEnd = HistoryTextPreviewFormatter.preview(from: cardAtEnd, characterLimit: 6)
        #expect(!boundedCardAtEnd.text.hasSuffix("..."))
        #expect(boundedCardAtEnd.text == cardAtEnd)

        // Multi-line/tabbed input preserves pre-cut `symbolRanges`, drops post-cut `symbolRanges`,
        // and keeps every range within `0...cutPreview.text.utf16.count`.
        let tabbedMultiline = "col1\tKey \(SensitiveContent.inlineMask)\ncol2"
        let tabbedPreview = HistoryTextPreviewFormatter.preview(from: tabbedMultiline)
        #expect(tabbedPreview.symbolRanges.count == 2)
        let preMaskSymbolRange = tabbedPreview.symbolRanges[0]
        let (cutAtMask, wasCutAtMask) = HistoryTextPreviewFormatter.cut(tabbedPreview, toVisibleCharacters: 10)
        #expect(wasCutAtMask)
        #expect(cutAtMask.symbolRanges == [preMaskSymbolRange])

        for budget in 1...tabbedPreview.text.count {
            let (cutPreview, _) = HistoryTextPreviewFormatter.cut(tabbedPreview, toVisibleCharacters: budget)
            let utf16Count = cutPreview.text.utf16.count
            for range in cutPreview.symbolRanges {
                #expect(range.location >= 0 && range.length > 0)
                #expect(NSMaxRange(range) <= utf16Count)
            }
        }
    }

    @Test
    @MainActor
    func previewFieldInvalidatesRenderedStateWhenSymbolRangesChangeAcrossIdenticalDisplayText() throws {
        TestSupport.ensureAppKitInitialized()

        let baseFont = NSFont.systemFont(ofSize: 13)
        let field = HistoryTextPreviewField()
        let expectedDisplayText = "col1\(HistoryTextPreviewFormatter.tabSymbol)col2"
        let arrowLocation = (expectedDisplayText as NSString)
            .range(of: HistoryTextPreviewFormatter.tabSymbol)
            .location
        let symbolColor = HistoryPreviewSymbolAppearance.color(for: field)

        field.update(
            previewText: "col1\tcol2",
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: false,
            widthHint: 480
        )
        #expect(field.attributedStringValue.string == expectedDisplayText)
        let textColorAtStart = try #require(
            field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        )
        let tabSymbolColor = try #require(
            field.attributedStringValue.attribute(.foregroundColor, at: arrowLocation, effectiveRange: nil) as? NSColor
        )
        #expect(tabSymbolColor == symbolColor)
        #expect(tabSymbolColor != textColorAtStart)

        // Updating to a literal arrow produces the exact same `displayText` ("col1→col2") with empty `symbolRanges`.
        field.update(
            previewText: expectedDisplayText,
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: false,
            widthHint: 480
        )
        #expect(field.attributedStringValue.string == expectedDisplayText)
        let literalArrowColor = try #require(
            field.attributedStringValue.attribute(.foregroundColor, at: arrowLocation, effectiveRange: nil) as? NSColor
        )
        #expect(literalArrowColor == textColorAtStart)
        #expect(literalArrowColor != symbolColor)

        // Switching back to a tab character restores symbol coloring on the arrow range.
        field.update(
            previewText: "col1\tcol2",
            searchQuery: "",
            font: baseFont,
            textColor: .labelColor,
            maximumNumberOfLines: 2,
            wrappingMode: .byWordWrapping,
            hidesSensitiveContent: false,
            widthHint: 480
        )
        let restoredSymbolColor = try #require(
            field.attributedStringValue.attribute(.foregroundColor, at: arrowLocation, effectiveRange: nil) as? NSColor
        )
        #expect(restoredSymbolColor == symbolColor)
    }

    @Test
    func previewFormatterBoundedStringOnLargeLeadingWhitespacePreservesMasks() {
        let leadingWhitespace = String(repeating: " \n\t", count: 4_000)

        let inlineBody = "Prefix \(SensitiveContent.inlineMask) trailing words after mask"
        let inlineInput = leadingWhitespace + inlineBody
        for limit in 8...14 {
            let preview = HistoryTextPreviewFormatter.preview(from: inlineInput, characterLimit: limit)
            #expect(
                SensitiveContent.maskRanges(in: preview.text).map(\.length) == [8],
                "Inline mask corrupted at characterLimit=\(limit): \(preview.text)"
            )
            #expect(preview.text == "Prefix \(SensitiveContent.inlineMask)...")
        }

        let wideMask = String(repeating: "●", count: 40)
        let wideInput = leadingWhitespace + "Token \(wideMask) trailing words"
        for limit in [7, 20, 35, 45] {
            let preview = HistoryTextPreviewFormatter.preview(from: wideInput, characterLimit: limit)
            #expect(
                SensitiveContent.maskRanges(in: preview.text).map(\.length) == [40],
                "Wide inline mask corrupted at characterLimit=\(limit): \(preview.text)"
            )
            #expect(preview.text == "Token \(wideMask)...")
        }

        let cardMask = "●●●● ●●●● ●●●● 4242"
        let cardInput = leadingWhitespace + "Card \(cardMask) trailing words after card"
        for limit in 6...23 {
            let preview = HistoryTextPreviewFormatter.preview(from: cardInput, characterLimit: limit)
            #expect(
                SensitiveContent.maskRanges(in: preview.text).map(\.length) == [4, 4, 4],
                "Card mask corrupted at characterLimit=\(limit): \(preview.text)"
            )
            #expect(preview.text == "Card \(cardMask)...")
        }
    }

    @Test
    @MainActor
    func appModelIgnoresStaleLocaleSearchResult() throws {
        let currentLocale = Locale.current
        let terms = HistorySearchTerms(query: "i")
        let matchesUnderCurrentLocale = HistorySearchMatcher.matches("I", terms, locale: currentLocale)
        let mismatchedLocale = matchesUnderCurrentLocale
            ? Locale(identifier: "tr_TR")
            : Locale(identifier: "en_US")
        #expect(HistorySearchMatcher.matches("I", terms, locale: mismatchedLocale) != matchesUnderCurrentLocale)

        let model = AppModel()
        let item = ClipboardItem.fixture(
            kind: .text,
            text: "I",
            sourceAppName: nil,
            sourceBundleIdentifier: nil,
            searchText: "I"
        )
        model.items = [item]
        model.searchQuery = "i"

        let corpus = model.makeSearchCorpus()
        let staleLocaleResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: terms, locale: mismatchedLocale)
        )
        #expect(staleLocaleResult.matches == [!matchesUnderCurrentLocale])
        model.installSearchResult(staleLocaleResult)

        // Positional fast path (`!hasContentTypes && !hasTags && !hasSources`) ignores mismatched locale.
        #expect((model.filteredItems.map(\.id) == [item.id]) == matchesUnderCurrentLocale)

        // Non-fast-path filter loop (`hasContentTypes == true`) also ignores mismatched locale.
        model.selectedHistoryFilterContentTypes = [.text]
        #expect((model.filteredItems.map(\.id) == [item.id]) == matchesUnderCurrentLocale)
        model.selectedHistoryFilterContentTypes = []

        let currentLocaleResult = try #require(
            HistorySearchJob().run(corpus: corpus, terms: terms, locale: currentLocale)
        )
        model.installSearchResult(currentLocaleResult)
        #expect((model.filteredItems.map(\.id) == [item.id]) == matchesUnderCurrentLocale)
    }

    @Test
    func mayContainSecretPrefilterCoversEverySecretPatternAndLongTextThreshold() {
        #expect(!SensitiveContentDetector.mayContainSecret(in: ""))
        #expect(!SensitiveContentDetector.mayContainSecret(in: "Ordinary prose with letters, commas, and spaces only."))
        #expect(!SensitiveContentDetector.mayContainSecret(in: "日本語テキスト 한글 Café résumé"))

        // Runtime-assembled fixtures covering digits, delimiters, and letter-only prefix families.
        let samples = [
            ["AI", "za", String(repeating: "B", count: 35)].joined(),
            ["AK", "IA", String(repeating: "Q", count: 16)].joined(),
            ["AS", "IA", String(repeating: "R", count: 16)].joined(),
            ["S", "G.", String(repeating: "m", count: 22), ".", String(repeating: "n", count: 43)].joined(),
            ["ey", "J", String(repeating: "a", count: 24), ".", "ey", "J", String(repeating: "b", count: 24)].joined(),
            ["sk", "-", String(repeating: "a1B2c3D4", count: 4)].joined(),
            ["ghp", "_", String(repeating: "x9Y8z7", count: 6)].joined(),
            "password=alphabeta",
            "https://user:secret@example.com",
            "Bearer abcdefghijklmnop1"
        ]
        for sample in samples {
            #expect(
                SensitiveContentDetector.mayContainSecret(in: sample),
                "Prefilter rejected sample: \(sample.prefix(6))"
            )
        }

        // Long ordinary prose (>= 16,000 UTF-8 bytes) passes through so secrets beyond the prefix are still scanned.
        let underLimit = String(repeating: "abcd ", count: 3_199)
        #expect(underLimit.utf8.count < 16_000)
        #expect(!SensitiveContentDetector.mayContainSecret(in: underLimit))

        let atOrOverLimit = String(repeating: "abcd ", count: 3_201)
        #expect(atOrOverLimit.utf8.count >= 16_000)
        #expect(SensitiveContentDetector.mayContainSecret(in: atOrOverLimit))
    }
}

extension SharedProcessStateTests {
    @Suite(.serialized)
    struct HistorySearchControllerTests {
        @Test
        @MainActor
        func debouncesSearchQueryUpdatesOffMainThread() async throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            try harness.seedHistory([
                ClipboardItem.fixture(text: "Alpha entry", copiedAt: base),
                ClipboardItem.fixture(text: "Beta needle", copiedAt: base.addingTimeInterval(10)),
                ClipboardItem.fixture(text: "Gamma needle", copiedAt: base.addingTimeInterval(20))
            ])

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller] + controller.children) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)

            controller.historyToolbar(toolbar, didChangeSearchQuery: "needle")
            #expect(harness.model.searchQuery.isEmpty)

            let completed = await TestSupport.waitUntil {
                harness.model.searchQuery == "needle"
                    && harness.model.searchResult?.terms == HistorySearchTerms(query: "needle")
            }
            #expect(completed)
            #expect(harness.model.filteredItems.count == 2)
        }

        @Test
        @MainActor
        func trailingWhitespacePreservesSelectionWhileTermChangesSelectFirstMatch() async throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let secondMatch = ClipboardItem.fixture(text: "Needle older", copiedAt: base)
            let firstMatch = ClipboardItem.fixture(text: "Needle newer", copiedAt: base.addingTimeInterval(10))
            let unrelated = ClipboardItem.fixture(text: "Unrelated top", copiedAt: base.addingTimeInterval(20))
            try harness.seedHistory([secondMatch, firstMatch, unrelated])

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller] + controller.children) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)
            controller.selectFirstHistoryItem()
            #expect(harness.model.selectedItemID == unrelated.id)

            controller.historyToolbar(toolbar, didChangeSearchQuery: "needle")
            let settled = await TestSupport.waitUntil {
                harness.model.searchQuery == "needle"
                    && harness.model.searchResult?.terms == HistorySearchTerms(query: "needle")
            }
            #expect(settled)
            #expect(harness.model.selectedItemID == firstMatch.id)

            // Move selection to the second match, then type trailing whitespace (unchanged parsed terms).
            controller.historyToolbar(toolbar, didRequestMoveSelection: .down)
            #expect(harness.model.selectedItemID == secondMatch.id)

            controller.historyToolbar(toolbar, didChangeSearchQuery: "needle   ")
            #expect(harness.model.searchQuery == "needle   ")
            #expect(harness.model.selectedItemID == secondMatch.id)
        }

        @Test
        @MainActor
        func flushesPendingSearchSynchronouslyOnSelectionMove() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let targetSecond = ClipboardItem.fixture(text: "Target second", copiedAt: base)
            let targetFirst = ClipboardItem.fixture(text: "Target first", copiedAt: base.addingTimeInterval(10))
            let unrelatedTop = ClipboardItem.fixture(text: "Unrelated top", copiedAt: base.addingTimeInterval(20))
            try harness.seedHistory([targetSecond, targetFirst, unrelatedTop])

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller] + controller.children) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)
            controller.selectFirstHistoryItem()
            #expect(harness.model.selectedItemID == unrelatedTop.id)

            controller.historyToolbar(toolbar, didChangeSearchQuery: "target")
            #expect(harness.model.searchQuery.isEmpty)

            controller.historyToolbar(toolbar, didRequestMoveSelection: .down)
            #expect(harness.model.searchQuery == "target")
            #expect(harness.model.filteredItems.map(\.id) == [targetFirst.id, targetSecond.id])
            #expect(harness.model.selectedItemID == targetSecond.id)
        }

        @Test
        @MainActor
        func flushesPendingSearchSynchronouslyOnToolbarCopySortAndOpenSelection() throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let targetSecond = ClipboardItem.fixture(text: "Target second", copiedAt: base)
            let targetFirst = ClipboardItem.fixture(text: "Target first", copiedAt: base.addingTimeInterval(10))
            let unrelatedTop = ClipboardItem.fixture(text: "Unrelated top", copiedAt: base.addingTimeInterval(20))
            try harness.seedHistory([targetSecond, targetFirst, unrelatedTop])

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller] + controller.children) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)
            controller.selectFirstHistoryItem()
            #expect(harness.model.selectedItemID == unrelatedTop.id)

            // `historyToolbarDidRequestCopy` flushes pending debounced query before copying selection.
            controller.historyToolbar(toolbar, didChangeSearchQuery: "target")
            #expect(harness.model.searchQuery.isEmpty)
            controller.historyToolbarDidRequestCopy(toolbar)
            #expect(harness.model.searchQuery == "target")
            #expect(harness.model.selectedItemID == targetFirst.id)
            #expect(harness.pasteboard.string(forType: .string) == "Target first")

            // `selectHistoryItemOnOpen` flushes pending debounced query before resolving selection.
            controller.historyToolbar(toolbar, didChangeSearchQuery: "second")
            #expect(harness.model.searchQuery == "target")
            controller.selectHistoryItemOnOpen()
            #expect(harness.model.searchQuery == "second")
            #expect(harness.model.selectedItemID == targetSecond.id)

            // `historyToolbarDidRequestToggleSortOrder` flushes pending debounced query before reversing order.
            controller.historyToolbar(toolbar, didChangeSearchQuery: "target")
            #expect(harness.model.searchQuery == "second")
            controller.historyToolbarDidRequestToggleSortOrder(toolbar)
            #expect(harness.model.searchQuery == "target")
            #expect(harness.model.isHistorySortReversed)
        }

        @Test
        @MainActor
        func refreshesInstalledSearchOnItemsMutationAndClearsPendingSearchAfterHiddenInterval() async throws {
            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let alpha = ClipboardItem.fixture(text: "Alpha entry", copiedAt: base)
            let beta = ClipboardItem.fixture(text: "Beta needle", copiedAt: base.addingTimeInterval(10))
            let gamma = ClipboardItem.fixture(text: "Gamma needle", copiedAt: base.addingTimeInterval(20))
            try harness.seedHistory([alpha, beta, gamma])

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller] + controller.children) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)

            controller.historyToolbar(toolbar, didChangeSearchQuery: "needle")
            let initialInstalled = await TestSupport.waitUntil {
                harness.model.searchQuery == "needle"
                    && harness.model.searchResult?.revision == harness.model.sortedListRevision
            }
            #expect(initialInstalled)
            #expect(harness.model.filteredItems.map(\.id) == [gamma.id, beta.id])

            let revisionBeforeInsert = harness.model.sortedListRevision
            let delta = ClipboardItem.fixture(text: "Delta needle", copiedAt: base.addingTimeInterval(30))
            harness.model.insert(delta)
            #expect(harness.model.sortedListRevision != revisionBeforeInsert)

            let refreshed = await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            }
            #expect(refreshed)
            #expect(harness.model.filteredItems.map(\.id) == [delta.id, gamma.id, beta.id])

            // Clearing after hidden interval while a debounced search is pending cancels it and resets search.
            controller.historyToolbar(toolbar, didChangeSearchQuery: "alpha")
            controller.clearSearchAfterHiddenInterval()
            #expect(harness.model.searchQuery.isEmpty)
            #expect(harness.model.searchResult == nil)
            #expect(harness.model.filteredItems.count == 4)

            // Also cancels a debounced search queued from an empty query so it never fires later.
            controller.historyToolbar(toolbar, didChangeSearchQuery: "beta")
            #expect(harness.model.searchQuery.isEmpty)
            controller.clearSearchAfterHiddenInterval()
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.model.searchQuery.isEmpty)
            #expect(harness.model.searchResult == nil)
            #expect(harness.model.filteredItems.count == 4)
        }

        @Test
        @MainActor
        func rowTextCacheSkipsRevealedSecretsAndEmptiesOnPermanentDeleteAndClearHistory() throws {
            TestSupport.ensureAppKitInitialized()

            let harness = try TestSupport.makeTestCoordinator()
            defer { harness.cleanup() }
            harness.model.preferences.trashRetentionDays = 0

            let uniqueSuffix = UUID().uuidString
            let token = ["sk", "-", String(repeating: "z9Y8x7W6", count: 4)].joined()
            let secretText = "Revealed token \(token) \(uniqueSuffix)"
            let ordinaryText = "Ordinary cached row text \(uniqueSuffix)"
            let secondText = "Second cached row text \(uniqueSuffix)"

            let secretItem = ClipboardItem.fixture(kind: .text, text: secretText)
            let ordinaryItem = ClipboardItem.fixture(kind: .text, text: ordinaryText)
            let secondItem = ClipboardItem.fixture(kind: .text, text: secondText)
            try harness.seedHistory([secretItem, ordinaryItem, secondItem])

            let row = HistoryItemRowTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 48))

            // Revealed sensitive content is never placed into the shared row text cache.
            row.configure(
                item: secretItem,
                quickPasteIndex: 1,
                tableWidth: 480,
                detectsSensitiveContent: true,
                revealsSensitiveContent: true
            )
            #expect(!row.hidesSensitiveContent)
            #expect(HistoryRowTextCache.preview(for: secretText) == nil)

            // Ordinary row text is cached, and permanent deletion (`isTrashEnabled == false`) empties the cache.
            row.configure(
                item: ordinaryItem,
                quickPasteIndex: 1,
                tableWidth: 480,
                detectsSensitiveContent: true,
                revealsSensitiveContent: false
            )
            #expect(HistoryRowTextCache.preview(for: ordinaryText) != nil)
            harness.coordinator.delete([ordinaryItem])
            #expect(HistoryRowTextCache.preview(for: ordinaryText) == nil)

            // Clearing history also empties the row text cache.
            row.configure(
                item: secondItem,
                quickPasteIndex: 1,
                tableWidth: 480,
                detectsSensitiveContent: true,
                revealsSensitiveContent: false
            )
            #expect(HistoryRowTextCache.preview(for: secondText) != nil)
            harness.coordinator.clearHistory()
            #expect(HistoryRowTextCache.preview(for: secondText) == nil)
        }

        @Test
        @MainActor
        func imageRowTitleCacheRetriesUnreadableAssetUntilFileIsReadable() throws {
            TestSupport.ensureAppKitInitialized()

            func visibleLabels(in root: NSView) -> [String] {
                var strings: [String] = []
                if let label = root as? HistoryFixedTextColorLabel, !label.isHidden, label.superview != nil {
                    strings.append(label.text)
                }
                for subview in root.subviews where !subview.isHidden {
                    strings.append(contentsOf: visibleLabels(in: subview))
                }
                return strings
            }

            try TestSupport.withTemporaryDirectory { tempDir in
                let assetURL = tempDir.appendingPathComponent("\(UUID().uuidString).png")
                let item = ClipboardItem.fixture(
                    kind: .image,
                    title: nil,
                    text: nil,
                    assetPath: assetURL.path,
                    byteSize: 2_048
                )

                let row = HistoryItemRowImageView(frame: NSRect(x: 0, y: 0, width: 480, height: 48))

                // Before the file exists on disk, the row shows "Image" without caching that fallback title.
                row.configure(item: item, quickPasteIndex: 1, tableWidth: 480)
                #expect(visibleLabels(in: row).contains("Image"))

                // Once the PNG exists at the same `assetPath`, reconfiguring reads and caches its pixel dimensions.
                let pngData = try TestSupport.makePNGData(
                    pixelWidth: 288,
                    pixelHeight: 144,
                    dpi: 72.0,
                    color: .systemBlue
                )
                try pngData.write(to: assetURL)

                row.configure(item: item, quickPasteIndex: 1, tableWidth: 480)
                #expect(visibleLabels(in: row).contains("Image (288x144)"))
            }
        }

        @Test
        @MainActor
        func historyReloadUpdatesHighlightsCompactRowsMutatedItemsAndShiftedSectionHeadersOffscreen() throws {
            TestSupport.ensureAppKitInitialized()

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            defer { window.orderOut(nil) }

            let history = History(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
            window.contentView = history

            func findPreviewField(in root: NSView) -> HistoryTextPreviewField? {
                if let field = root as? HistoryTextPreviewField, !field.isHidden {
                    return field
                }
                for subview in root.subviews where !subview.isHidden {
                    if let found = findPreviewField(in: subview) {
                        return found
                    }
                }
                return nil
            }

            func hasHighlightedCharacter(in attributed: NSAttributedString) -> Bool {
                var found = false
                attributed.enumerateAttribute(
                    .foregroundColor,
                    in: NSRange(location: 0, length: attributed.length)
                ) { value, _, stop in
                    if (value as? NSColor) == HistorySearchMatchHighlighter.highlightColor {
                        found = true
                        stop.pointee = true
                    }
                }
                return found
            }

            func rowIndex(of itemID: UUID) throws -> Int {
                try #require(
                    history.tableRows.indices.first { history.tableRows.itemID(at: $0) == itemID }
                )
            }

            func reload(
                items: [ClipboardItem],
                tags: [ClipBook.Tag] = [],
                searchQuery: String = "",
                groupPinnedFavorites: Bool = false,
                sectionDate: ((ClipboardItem) -> Date?)? = nil,
                showsTiles: Bool = false,
                showsCompactRows: Bool = false
            ) {
                let firstID = items.first?.id
                history.reload(
                    items: items,
                    availableTags: tags,
                    selectedItemID: firstID,
                    selectedItemIDs: firstID.map { [$0] } ?? [],
                    searchQuery: searchQuery,
                    showCommandNumberShortcut: true,
                    showPreviewForLinks: true,
                    detectSensitiveContent: true,
                    showDividers: false,
                    preferPastingAsPlainText: true,
                    groupPinnedFavorites: groupPinnedFavorites,
                    sectionDate: sectionDate,
                    showsTiles: showsTiles,
                    showsCompactRows: showsCompactRows,
                    onSelectFirstItem: { _ in }
                )
                history.layoutSubtreeIfNeeded()
                history.tableView.layoutSubtreeIfNeeded()
                history.tileGrid.layoutSubtreeIfNeeded()
                history.displayIfNeeded()
            }

            let tagA = ClipBook.Tag(id: 1, name: "Work", color: "#3366FF")
            let tagB = ClipBook.Tag(id: 2, name: "Urgent", color: "#FF5533")
            let now = Date(timeIntervalSince1970: 1_700_050_000)

            let textAlpha = ClipboardItem.fixture(
                kind: .text,
                text: "Alpha needle item",
                copiedAt: now,
                tags: [tagA.id, tagB.id]
            )
            let textBeta = ClipboardItem.fixture(
                kind: .text,
                text: "Beta needle item",
                copiedAt: now.addingTimeInterval(-10)
            )
            let imageGamma = ClipboardItem.fixture(
                kind: .image,
                title: nil,
                text: nil,
                copiedAt: now.addingTimeInterval(-20),
                byteSize: 4_096,
                searchText: "Gamma picture"
            )

            // 1. Initial non-compact reload.
            reload(items: [textAlpha, textBeta, imageGamma], tags: [tagA, tagB])
            #expect(!history.showsCompactRows)
            #expect(history.tableView.rowHeight == HistoryRow.height)

            let initialAlphaRow = try rowIndex(of: textAlpha.id)
            let initialAlphaCell = try #require(
                history.tableView.view(atColumn: 0, row: initialAlphaRow, makeIfNecessary: false) as? HistoryItemRowTextView
            )
            let initialGammaRow = try rowIndex(of: imageGamma.id)
            let initialGammaCell = try #require(
                history.tableView.view(atColumn: 0, row: initialGammaRow, makeIfNecessary: false) as? HistoryItemRowImageView
            )
            #expect(!initialAlphaCell.isCompact)
            #expect(!initialGammaCell.isCompact)
            #expect(initialAlphaCell.searchQuery.isEmpty)
            let alphaFieldBeforeSearch = try #require(findPreviewField(in: initialAlphaCell))
            #expect(!hasHighlightedCharacter(in: alphaFieldBeforeSearch.attributedStringValue))

            // 2. Narrowing search (`removedRowIndexes != nil`) updates surviving cell highlights in place.
            reload(items: [textAlpha, textBeta], tags: [tagA, tagB], searchQuery: "needle")
            let narrowedAlphaRow = try rowIndex(of: textAlpha.id)
            let narrowedAlphaCell = try #require(
                history.tableView.view(atColumn: 0, row: narrowedAlphaRow, makeIfNecessary: false) as? HistoryItemRowTextView
            )
            #expect(narrowedAlphaCell === initialAlphaCell)
            #expect(narrowedAlphaCell.searchQuery == "needle")
            let alphaFieldDuringSearch = try #require(findPreviewField(in: narrowedAlphaCell))
            #expect(hasHighlightedCharacter(in: alphaFieldDuringSearch.attributedStringValue))

            // Clearing search (`insertedRowIndexes != nil`) clears highlight attributes in place.
            reload(items: [textAlpha, textBeta, imageGamma], tags: [tagA, tagB], searchQuery: "")
            #expect(narrowedAlphaCell.searchQuery.isEmpty)
            #expect(!hasHighlightedCharacter(in: alphaFieldDuringSearch.attributedStringValue))

            // 3. Mutating a surviving visible item alongside row removal/insertion reloads that cell.
            var mutatedAlpha = textAlpha
            mutatedAlpha.tags = [tagA.id]
            mutatedAlpha.title = "Renamed Alpha"
            reload(items: [mutatedAlpha, textBeta], tags: [tagA, tagB], searchQuery: "needle")
            let reloadedAlphaAfterRemoval = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: mutatedAlpha.id), makeIfNecessary: false) as? HistoryItemRowTextView
            )
            #expect(reloadedAlphaAfterRemoval.configuredItem == mutatedAlpha)
            #expect(reloadedAlphaAfterRemoval.configuredItem?.tags == [tagA.id])
            #expect(reloadedAlphaAfterRemoval.configuredItem?.title == "Renamed Alpha")

            mutatedAlpha.title = "Expanded Alpha"
            reload(items: [mutatedAlpha, textBeta, imageGamma], tags: [tagA, tagB], searchQuery: "")
            let reloadedAlphaAfterInsertion = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: mutatedAlpha.id), makeIfNecessary: false) as? HistoryItemRowTextView
            )
            #expect(reloadedAlphaAfterInsertion.configuredItem == mutatedAlpha)
            #expect(reloadedAlphaAfterInsertion.configuredItem?.title == "Expanded Alpha")

            // 4. Toggling `showsCompactRows` (`false -> true` while narrowing, `true -> false` while expanding).
            reload(items: [mutatedAlpha, imageGamma], tags: [tagA, tagB], showsCompactRows: true)
            #expect(history.showsCompactRows)
            #expect(history.tableView.showsCompactRows)
            #expect(history.tableView.rowHeight == HistoryRow.compactHeight)
            let compactAlphaCell = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: mutatedAlpha.id), makeIfNecessary: false) as? HistoryItemRowTextView
            )
            let compactImageCell = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: imageGamma.id), makeIfNecessary: false) as? HistoryItemRowImageView
            )
            #expect(compactAlphaCell.isCompact)
            #expect(compactImageCell.isCompact)

            reload(items: [mutatedAlpha, textBeta, imageGamma], tags: [tagA, tagB], showsCompactRows: false)
            #expect(!history.showsCompactRows)
            #expect(!history.tableView.showsCompactRows)
            #expect(history.tableView.rowHeight == HistoryRow.height)
            let expandedAlphaCell = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: mutatedAlpha.id), makeIfNecessary: false) as? HistoryItemRowTextView
            )
            let expandedImageCell = try #require(
                history.tableView.view(atColumn: 0, row: try rowIndex(of: imageGamma.id), makeIfNecessary: false) as? HistoryItemRowImageView
            )
            #expect(!expandedAlphaCell.isCompact)
            #expect(!expandedImageCell.isCompact)

            // 5. Inserting 2+ sections at index 0 updates displaced former row-0 section header
            // from `sectionHeaderFirstHeight` (28pt) to `sectionHeaderHeight` (36pt) even when pushed offscreen.
            window.setContentSize(NSSize(width: 520, height: 120))
            history.frame = NSRect(x: 0, y: 0, width: 520, height: 120)

            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            let todayDate = todayStart.addingTimeInterval(3_600)
            let yesterdayDate = try #require(calendar.date(byAdding: .day, value: -1, to: todayDate))

            let yesterdayItem = ClipboardItem.fixture(text: "Yesterday entry", copiedAt: yesterdayDate)
            reload(
                items: [yesterdayItem],
                groupPinnedFavorites: true,
                sectionDate: { $0.copiedAt }
            )
            #expect(history.tableRows.isSectionHeader(at: 0))
            #expect(history.tableView.rect(ofRow: 0).height == HistoryRow.sectionHeaderFirstHeight)

            let favoriteItems = (0..<3).map { index in
                ClipboardItem.fixture(
                    text: "Pinned favorite \(index)",
                    copiedAt: todayDate.addingTimeInterval(Double(100 - index)),
                    isFavorite: true
                )
            }
            let todayItems = (0..<3).map { index in
                ClipboardItem.fixture(
                    text: "Today item \(index)",
                    copiedAt: todayDate.addingTimeInterval(Double(50 - index)),
                    isFavorite: false
                )
            }

            reload(
                items: favoriteItems + todayItems + [yesterdayItem],
                groupPinnedFavorites: true,
                sectionDate: { $0.copiedAt }
            )
            // Favorites header (0) + 3 favorites (1..3) + Today header (4) + 3 today (5..7) + Yesterday header (8).
            let shiftedYesterdayHeaderRow = 8
            #expect(history.tableRows.isSectionHeader(at: 0))
            #expect(history.tableRows.isSectionHeader(at: 4))
            #expect(history.tableRows.isSectionHeader(at: shiftedYesterdayHeaderRow))
            #expect(history.tableView.rect(ofRow: 0).height == HistoryRow.sectionHeaderFirstHeight)
            #expect(history.tableView.rect(ofRow: 4).height == HistoryRow.sectionHeaderHeight)
            #expect(history.tableView.rect(ofRow: shiftedYesterdayHeaderRow).height == HistoryRow.sectionHeaderHeight)

            // 6. Switching to `showsTiles: true` populates `HistoryTileGridView` with section headers and tiles,
            // then switches cleanly back to `showsTiles: false`.
            window.setContentSize(NSSize(width: 520, height: 360))
            history.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
            let tileItems = [
                favoriteItems[0],
                ClipboardItem.fixture(
                    kind: .image,
                    title: nil,
                    text: nil,
                    copiedAt: todayDate.addingTimeInterval(200),
                    byteSize: 2_048,
                    searchText: "Today tile image"
                ),
                todayItems[0],
                yesterdayItem
            ]
            reload(
                items: tileItems,
                groupPinnedFavorites: true,
                sectionDate: { $0.copiedAt },
                showsTiles: true
            )
            #expect(history.showsTiles)
            #expect(history.rowsView === history.tileGrid)
            #expect(history.tileGrid.rows.count == history.tableRows.count)
            #expect(history.tileGrid.rows.isSectionHeader(at: 0))
            #expect(history.tileGrid.line(ofRow: 0) == nil)
            #expect(history.tileGrid.line(ofRow: 1) == 0)
            let visibleTileViews = history.tileGrid.subviews.compactMap { $0 as? HistoryTileView }.filter { !$0.isHidden }
            let visibleTileHeaders = history.tileGrid.subviews.compactMap { $0 as? HistorySectionHeaderCellView }.filter { !$0.isHidden }
            #expect(visibleTileViews.count == tileItems.count)
            #expect(visibleTileHeaders.count == 3)

            reload(
                items: tileItems,
                groupPinnedFavorites: true,
                sectionDate: { $0.copiedAt },
                showsTiles: false
            )
            #expect(!history.showsTiles)
            #expect(history.rowsView === history.tableView)
            #expect(history.tableView.numberOfRows == history.tableRows.count)
        }

        @Test
        @MainActor
        func lazySearchLifecyclePrefixReuseIncrementalDonorReuseFallbackAndTrashIsolation() async throws {
            TestSupport.ensureAppKitInitialized()

            URLProtocol.registerClass(SearchTestLinkPreviewURLProtocol.self)
            defer { URLProtocol.unregisterClass(SearchTestLinkPreviewURLProtocol.self) }

            let (harness, spyStore, _) = try TestSupport.makeSpiedTestCoordinator()
            defer { harness.cleanup() }

            let baseTime = Date(timeIntervalSince1970: 1_710_300_000)
            let tagAlpha = try spyStore.createTag(name: "ProjectAlpha", color: "#3B85ED")
            let tagBeta = try spyStore.createTag(name: "KeepBeta", color: "#22AA66")

            let sentinel40KB = "TAIL_SENTINEL_AT_40KB"
            let body40KB = "confidential_header " + String(repeating: "d", count: 40_000) + " " + sentinel40KB
            let secretToken = ["sk", "-live-search-", String(repeating: "m4N6pQ8r", count: 4)].joined()
            let secretBody = "Bearer \(secretToken) confidential_vault_secret"
            #expect(SensitiveContent.shouldEncryptAtRest(.fixture(kind: .text, text: secretBody)))

            let pngData = try TestSupport.makePNGData(pixelWidth: 24, pixelHeight: 24)
            let ocrImgID = UUID()
            let ocrImgURL = try spyStore.writeManagedAsset(pngData: pngData, role: .image, clipID: ocrImgID, encrypted: true)

            let item40KB = ClipboardItem.fixture(
                kind: .text,
                text: body40KB,
                copiedAt: baseTime.addingTimeInterval(10)
            )
            let itemSecret = ClipboardItem.fixture(
                kind: .text,
                text: secretBody,
                copiedAt: baseTime.addingTimeInterval(20)
            )
            let itemUnicode = ClipboardItem.fixture(
                kind: .text,
                text: "Straße Maß ﬁlter Cafe\u{0301} confidential_unicode",
                copiedAt: baseTime.addingTimeInterval(30)
            )
            let itemTagged = ClipboardItem.fixture(
                kind: .text,
                text: "Tagged engineering note",
                copiedAt: baseTime.addingTimeInterval(40),
                tags: [tagAlpha.id, tagBeta.id]
            )
            let itemDeletable = ClipboardItem.fixture(
                kind: .text,
                text: "Disposable filler item",
                copiedAt: baseTime.addingTimeInterval(50)
            )
            let itemLink = ClipboardItem.fixture(
                kind: .link,
                text: "https://linkpreview-search-test.clipbook.invalid/doc?" + String(repeating: "u", count: 9_000),
                copiedAt: baseTime.addingTimeInterval(60)
            )
            let itemPendingOCR = ClipboardItem.fixture(
                id: ocrImgID,
                kind: .image,
                text: nil,
                assetPath: ocrImgURL.path,
                copiedAt: baseTime.addingTimeInterval(70)
            )
            let itemTrashed = ClipboardItem.fixture(
                kind: .text,
                text: "trashed_only_needle confidential_trashed",
                copiedAt: baseTime.addingTimeInterval(5)
            )

            for item in [item40KB, itemSecret, itemUnicode, itemTagged, itemDeletable, itemLink, itemPendingOCR, itemTrashed] {
                try spyStore.saveAndReconcileItem(item, convertingExternalAssets: true)
            }
            try spyStore.moveToTrash(ids: [itemTrashed.id], at: Date().addingTimeInterval(-60))

            spyStore.resetRecordedCalls()
            #expect(harness.coordinator.loadHistory(sweepsCaches: false))

            // (a) Idle: cachedSearchCorpus is nil, 0 fetchSearchTexts calls, and model.items holds 0 full searchText strings.
            #expect(harness.model.items.count == 7)
            #expect(harness.model.items.allSatisfy { !$0.isContentLoaded && $0.searchText.isEmpty })
            #expect(harness.model.prepareSearchCorpusDescriptor().cachedCorpus == nil)
            #expect(harness.model.searchResult == nil)
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)

            let controller = HistoryContentViewController(model: harness.model, coordinator: harness.coordinator)
            defer { TestSupport.drainDelayedPerforms([controller]) }
            _ = controller.view
            let toolbar = HistoryToolbar()
            toolbar.delegate = controller
            controller.attachToolbar(toolbar)

            func findView<T: NSView>(ofType _: T.Type, in root: NSView) -> T? {
                if let matched = root as? T {
                    return matched
                }
                for subview in root.subviews {
                    if let found = findView(ofType: T.self, in: subview) {
                        return found
                    }
                }
                return nil
            }
            let listPaneView = try #require(findView(ofType: History.self, in: controller.view))
            let listTableView = try #require(findView(ofType: NSTableView.self, in: listPaneView))

            @MainActor
            func runSearchAndWait(_ query: String) async {
                controller.historyToolbar(toolbar, didChangeSearchQuery: query)
                let settled = await TestSupport.waitUntil {
                    harness.model.searchQuery == query
                        && harness.model.searchResult?.terms == HistorySearchTerms(query: query)
                        && harness.model.searchResult?.revision == harness.model.sortedListRevision
                }
                #expect(settled, "Search did not settle for query=\(query)")
            }

            // (b) Active search: resolves complete short headers in RAM and hydrates only incomplete/encrypted items
            //     (40 KB body, >9 KB link, and isEncrypted == 1 secret) via fetchSearchTexts on searchQueue!
            spyStore.resetRecordedCalls()
            await runSearchAndWait(sentinel40KB)
            #expect(spyStore.fetchSearchTextsCalls.count == 1)
            #expect(Set(spyStore.fetchSearchTextsCalls[0].ids) == [item40KB.id, itemSecret.id, itemLink.id])
            #expect(!spyStore.fetchSearchTextsCalls[0].trashed)
            #expect(harness.model.filteredItems.map(\.id) == [item40KB.id])
            #expect(harness.model.prepareSearchCorpusDescriptor().cachedCorpus != nil)

            // Subsequent queries at the same sortedListRevision reuse cachedSearchCorpus with 0 DB calls!
            spyStore.resetRecordedCalls()
            await runSearchAndWait("confidential_vault_secret")
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.map(\.id) == [itemSecret.id])

            await runSearchAndWait("strass fi café")
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.map(\.id) == [itemUnicode.id])

            // Strict prefix refinements "con" -> "conf" -> "confi" perform 0 extra fetchSearchTexts calls!
            await runSearchAndWait("con")
            await runSearchAndWait("conf")
            await runSearchAndWait("confi")
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(Set(harness.model.filteredItems.map(\.id)) == [item40KB.id, itemSecret.id, itemUnicode.id])

            // (c.1) Toggling Favorite, flipping sort order, and deleting an item mid-search perform 0 fetchSearchTexts calls
            //       while preserving 40 KB tail and decrypted secret matches!
            spyStore.resetRecordedCalls()
            harness.coordinator.toggleFavorite(try #require(harness.currentItem(item40KB.id)))
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty, "Favorite toggle mid-search must perform 0 fetchSearchTexts calls")

            controller.historyToolbarDidRequestToggleSortOrder(toolbar)
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty, "Sort-order flip mid-search must perform 0 fetchSearchTexts calls")

            harness.coordinator.delete(try #require(harness.currentItem(itemDeletable.id)))
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty, "Deleting an item mid-search must perform 0 fetchSearchTexts calls")
            #expect(Set(harness.model.filteredItems.map(\.id)) == [item40KB.id, itemSecret.id, itemUnicode.id])

            // Also verify 40 KB tail sentinel is still intact inside the donor-reused corpus!
            await runSearchAndWait(sentinel40KB)
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.map(\.id) == [item40KB.id])
            await runSearchAndWait("confi")
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)

            // (c.2) Capturing 1 >8 KB item mid-search queries fetchSearchTexts for ONLY [capturedID] (1 ID)!
            spyStore.resetRecordedCalls()
            let captured9KBText = String(repeating: "c", count: 9_500) + " confi_captured_tail"
            harness.pasteboard.clearContents()
            harness.pasteboard.setString(captured9KBText, forType: .string)
            await harness.clipboardMonitor.pollAndWaitForDelivery()
            let newlyCaptured = try #require(harness.model.items.first)
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.map(\.ids) == [[newlyCaptured.id]])
            #expect(harness.model.filteredItems.contains { $0.id == newlyCaptured.id })

            // (c.3) Editing 1 >8 KB item mid-search queries fetchSearchTexts for ONLY [editedID] (1 ID)!
            spyStore.resetRecordedCalls()
            let edited9KBText = String(repeating: "e", count: 9_600) + " confi_edited_tail"
            harness.coordinator.editContent(newlyCaptured, text: edited9KBText)
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.map(\.ids) == [[newlyCaptured.id]])
            #expect(harness.model.filteredItems.contains { $0.id == newlyCaptured.id })

            // (c.4) Completing post-OCR didRecognize mid-search with short non-sensitive text resolves in RAM (0 DB calls)!
            spyStore.resetRecordedCalls()
            harness.coordinator.pasteboardMonitor(
                harness.clipboardMonitor,
                didRecognize: RecognizedImageContent(text: "OCR recognized confi_diagram", qrCodeText: nil),
                inItemWithID: ocrImgID
            )
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.contains { $0.id == ocrImgID })

            // (c.5) Persisting a link preview on >9 KB URL mid-search queries fetchSearchTexts for ONLY [itemLink.id] (1 ID)!
            spyStore.resetRecordedCalls()
            harness.coordinator.updateLink(try #require(harness.currentItem(itemLink.id)))
            let linkPreviewRefreshed = await TestSupport.waitUntil(timeout: .seconds(5)) {
                harness.currentItem(itemLink.id)?.linkPreviewDetails != nil
                    && harness.model.searchResult?.revision == harness.model.sortedListRevision
            }
            #expect(linkPreviewRefreshed)
            #expect(spyStore.fetchSearchTextsCalls.map(\.ids) == [[itemLink.id]])
            #expect(harness.model.filteredItems.contains { $0.id == itemLink.id })

            // (c.6) Tag rename & delete (both via coordinator.updateTag/deleteTag AND direct model.tags mutation)
            //       invalidate stale tag matches on short tagged items in RAM (0 DB calls) while reusing all untagged donors!
            await runSearchAndWait("ProjectAlpha")
            #expect(harness.model.filteredItems.map(\.id) == [itemTagged.id])

            spyStore.resetRecordedCalls()
            harness.coordinator.updateTag(tagAlpha, name: "RenamedOmegaTag", color: .systemBlue)
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.isEmpty, "Stale tag name ProjectAlpha must no longer match after rename")

            spyStore.resetRecordedCalls()
            await runSearchAndWait("RenamedOmegaTag")
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.map(\.id) == [itemTagged.id])

            // Direct model.tags mutation also invalidates tagNamesByID on tagged items in RAM while reusing untagged donors!
            spyStore.resetRecordedCalls()
            harness.model.tags = [
                ClipBook.Tag(id: tagAlpha.id, name: "DirectMutatedTag", color: tagAlpha.color),
                tagBeta,
            ]
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.isEmpty)

            // Sync DB tag name and delete the tag mid-search: resolves in RAM and clears match!
            _ = try spyStore.updateTag(id: tagAlpha.id, name: "DirectMutatedTag", color: tagAlpha.color)
            await runSearchAndWait("DirectMutatedTag")
            #expect(harness.model.filteredItems.map(\.id) == [itemTagged.id])

            let tagToDelete = try #require(harness.model.tags.first { $0.id == tagAlpha.id })
            spyStore.resetRecordedCalls()
            harness.coordinator.deleteTag(tagToDelete)
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.isEmpty)

            // (c.7) Degraded fallback corpus (fetchSearchTexts throw) sets hasCompleteTexts == false and revisions[slot] == 0
            //       for every unhydrated item, never caches as complete, and re-hydrates cleanly once fetchSearchTexts succeeds again!
            controller.clearSearchAfterHiddenInterval()
            #expect(harness.model.searchQuery.isEmpty)

            spyStore.shouldThrowOnFetchSearchTexts = true
            spyStore.resetRecordedCalls()
            await runSearchAndWait(sentinel40KB)
            let degradedResult = try #require(harness.model.searchResult)
            #expect(!degradedResult.corpus.hasCompleteTexts)
            let degraded40KBSlot = try #require(degradedResult.indexByID[item40KB.id])
            #expect(degradedResult.corpus.revisions[degraded40KBSlot] == 0)
            #expect(harness.model.prepareSearchCorpusDescriptor().cachedCorpus == nil)
            #expect(harness.model.filteredItems.isEmpty, "Header fallback lacks >8 KB tail sentinel while store throws")
            #expect(await TestSupport.waitUntil { listPaneView.items.isEmpty && listTableView.numberOfRows == 0 })

            // Re-querying the SAME search term once store recovers re-hydrates via applyPendingSearchQuery's hasCompleteTexts == false guard
            // and reloads listPaneView even though HistorySearchTerms is unchanged!
            spyStore.shouldThrowOnFetchSearchTexts = false
            spyStore.resetRecordedCalls()
            controller.historyToolbar(toolbar, didChangeSearchQuery: sentinel40KB)
            let recovered = await TestSupport.waitUntil {
                harness.model.searchResult?.corpus.hasCompleteTexts == true
                    && listPaneView.items.map(\.id) == [item40KB.id]
            }
            #expect(recovered)
            #expect(spyStore.fetchSearchTextsCalls.count == 1)
            #expect(harness.model.filteredItems.map(\.id) == [item40KB.id])
            #expect(listPaneView.items.map(\.id) == [item40KB.id])
            #expect(listTableView.numberOfRows >= 1)
            #expect(harness.model.selectedItemID == item40KB.id)

            // Also verify recovery when query changes only by trailing whitespace (HistorySearchTerms unchanged, model.searchQuery changed).
            controller.clearSearchAfterHiddenInterval()
            spyStore.shouldThrowOnFetchSearchTexts = true
            await runSearchAndWait(sentinel40KB)
            #expect(await TestSupport.waitUntil { listPaneView.items.isEmpty && listTableView.numberOfRows == 0 })
            spyStore.shouldThrowOnFetchSearchTexts = false
            spyStore.resetRecordedCalls()
            controller.historyToolbar(toolbar, didChangeSearchQuery: sentinel40KB + " ")
            let recoveredWhitespace = await TestSupport.waitUntil {
                harness.model.searchResult?.corpus.hasCompleteTexts == true
                    && listPaneView.items.map(\.id) == [item40KB.id]
            }
            #expect(recoveredWhitespace)
            #expect(harness.model.filteredItems.map(\.id) == [item40KB.id])
            #expect(listPaneView.items.map(\.id) == [item40KB.id])
            #expect(listTableView.numberOfRows >= 1)
            #expect(harness.model.selectedItemID == item40KB.id)

            // (c.8) Toggling Trash (isShowingTrash) never cross-contaminates Active vs Trash results!
            await runSearchAndWait("trashed_only_needle")
            #expect(harness.model.filteredItems.isEmpty)

            harness.model.trashedItems = try spyStore.fetchTrashedItems()
            spyStore.resetRecordedCalls()
            harness.model.selectedHistoryFilterContentTypes = [.trash]
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(spyStore.fetchSearchTextsCalls.isEmpty)
            #expect(harness.model.filteredItems.map(\.id) == [itemTrashed.id])

            harness.model.selectedHistoryFilterContentTypes = []
            #expect(await TestSupport.waitUntil {
                harness.model.searchResult?.revision == harness.model.sortedListRevision
            })
            #expect(harness.model.filteredItems.isEmpty)

            // (d) Clear: clearing searchQuery releases cachedSearchCorpus, searchResult, and lastCompletedSearchResult!
            controller.historyToolbar(toolbar, didChangeSearchQuery: "")
            #expect(harness.model.searchQuery.isEmpty)
            #expect(harness.model.searchResult == nil)
            #expect(harness.model.prepareSearchCorpusDescriptor().cachedCorpus == nil)

            // Advance sortedListRevision while idle (Favorite toggle) and search again: because lastCompletedSearchResult
            // was also cleared, ALL incomplete/encrypted active items must be fetched fresh rather than donated!
            harness.coordinator.toggleFavorite(try #require(harness.currentItem(item40KB.id)))
            spyStore.resetRecordedCalls()
            await runSearchAndWait("confi")
            #expect(spyStore.fetchSearchTextsCalls.count == 1)
            let expectedIncompleteIDs = Set(harness.model.items.filter { !$0.hasCompleteHeaderSearchText }.map(\.id))
            #expect(Set(spyStore.fetchSearchTextsCalls[0].ids) == expectedIncompleteIDs)

            controller.clearSearchAfterHiddenInterval()
            #expect(harness.model.searchQuery.isEmpty)
            #expect(harness.model.searchResult == nil)
            #expect(harness.model.prepareSearchCorpusDescriptor().cachedCorpus == nil)
        }

        @Test(.timeLimit(.minutes(2)))
        @MainActor
        func scaleAndColdFirstKeystrokeGateAcross5k25kAnd100kRows() throws {
            TestSupport.ensureAppKitInitialized()

            try TestSupport.withTemporaryDirectory { supportDir in
                let masterKey = SymmetricKey(size: .bits256)
                let keyProvider = InMemoryDatabaseKeyProvider(key: masterKey)
                let dbURL = supportDir.appendingPathComponent("History.sqlite")

                // Initialize genuine v5 schema + key_verifier_v1 via GRDBHistoryStore, then close before bulk SQLite seeding.
                do {
                    let initStore = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                    _ = try initStore.fetchAll()
                    initStore.close()
                }

                let suiteName = "com.ikryanov.clipbook.tests.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suiteName))
                defaults.removePersistentDomain(forName: suiteName)
                defer { TestSupport.removeDefaultsSuite(named: suiteName) }

                var seededRowCount = 0
                var cumulativeBodyUTF8Bytes: Int64 = 0
                var cumulativeHTMLUTF8Bytes: Int64 = 0
                var expectedTailSentinelIDs = Set<UUID>()
                var expectedEncryptedSentinelIDs = Set<UUID>()
                var perfSummaryRows: [String] = []

                for milestone in [5_000, 25_000, 100_000] {
                    let batchStats = try Self.bulkInsertSyntheticV5Rows(
                        at: dbURL,
                        masterKey: masterKey,
                        startIndex: seededRowCount,
                        endIndex: milestone
                    )
                    seededRowCount = milestone
                    cumulativeBodyUTF8Bytes += batchStats.bodyUTF8Bytes
                    cumulativeHTMLUTF8Bytes += batchStats.htmlUTF8Bytes
                    expectedTailSentinelIDs.formUnion(batchStats.tailSentinelIDs)
                    expectedEncryptedSentinelIDs.formUnion(batchStats.encryptedSentinelIDs)

                    let baseStore = GRDBHistoryStore(directory: supportDir, keyProvider: keyProvider)
                    let spyStore = SpyHistoryStore(base: baseStore)

                    let pasteboard = NSPasteboard.withUniqueName()
                    let preferencesStore = PreferencesStore(userDefaults: defaults)
                    var prefs = AppPreferences()
                    prefs.warnOnClearHistory = false
                    prefs.soundEffectsEnabled = false
                    prefs.launchAtLogin = false
                    prefs.showPreviewForLinks = false
                    preferencesStore.save(prefs)

                    let model = AppModel()
                    model.preferences = prefs
                    let monitor = PasteboardMonitor(
                        historyStore: spyStore,
                        fileManager: .default,
                        pasteboard: pasteboard
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
                        clipboardMonitor: monitor,
                        pasteService: pasteService,
                        globalShortcuts: GlobalShortcutService(isEnabled: false),
                        updateService: TestNoOpUpdateService(),
                        licensingService: LicensingService(),
                        fileManager: .default,
                        supportDirectory: supportDir
                    )

                    do {
                        defer {
                            coordinator.stopBackgroundWorkForTesting()
                            coordinator.cancelBackgroundMaintenance()
                            monitor.stop()
                            spyStore.close()
                            pasteboard.releaseGlobally()
                        }

                        // 1. Measure unloaded fetchAll() header load time & resident phys_footprint delta.
                        let baselineFootprint = Self.currentPhysFootprintBytes()
                        let fetchStart = ContinuousClock.now
                        let headers = try spyStore.fetchAll()
                        let fetchElapsed = ContinuousClock.now - fetchStart
                        let postHeaderFootprint = Self.currentPhysFootprintBytes()

                        #expect(headers.count == milestone)
                        #expect(headers.allSatisfy { !$0.isContentLoaded && $0.searchText.isEmpty })
                        #expect(fetchElapsed < .seconds(15), "Unloaded fetchAll() took \(fetchElapsed) at \(milestone) rows")

                        let headerFootprintDelta = max(0, postHeaderFootprint - baselineFootprint)
                        // Eagerly hydrated items hold both text and searchText plus formatting in memory.
                        let eagerHydratedEquivalentBytes = cumulativeBodyUTF8Bytes * 2 + cumulativeHTMLUTF8Bytes
                        #expect(
                            headerFootprintDelta < eagerHydratedEquivalentBytes / 2,
                            "Unloaded header phys_footprint delta (\(headerFootprintDelta) B) exceeded fraction of eager hydrated payload (\(eagerHydratedEquivalentBytes) B) at \(milestone) rows"
                        )

                        // 2. Populate AppModel & HistoryContentViewController; verify idle corpus is nil.
                        model.items = headers
                        #expect(model.prepareSearchCorpusDescriptor().cachedCorpus == nil)

                        let controller = HistoryContentViewController(model: model, coordinator: coordinator)
                        defer { TestSupport.drainDelayedPerforms([controller]) }
                        _ = controller.view
                        let toolbar = HistoryToolbar()
                        toolbar.delegate = controller
                        controller.attachToolbar(toolbar)

                        // 3. Cold first-keystroke fetchSearchTexts (incomplete/encrypted rows only) + HistorySearchJob.run + flush!
                        let expectedSQLiteFetchCount = headers.filter { !$0.hasCompleteHeaderSearchText }.count
                        #expect(expectedSQLiteFetchCount < milestone)
                        spyStore.resetRecordedCalls()
                        let query = "scale_needle"
                        let firstKeystrokeStart = ContinuousClock.now
                        controller.historyToolbar(toolbar, didChangeSearchQuery: query)
                        controller.selectHistoryItemOnOpen()
                        let firstKeystrokeElapsed = ContinuousClock.now - firstKeystrokeStart

                        #expect(firstKeystrokeElapsed < .seconds(20), "Cold first-keystroke took \(firstKeystrokeElapsed) at \(milestone) rows")
                        #expect(spyStore.fetchSearchTextsCalls.count == 1)
                        #expect(spyStore.fetchSearchTextsCalls[0].ids.count == expectedSQLiteFetchCount)

                        let searchResult = try #require(model.searchResult)
                        #expect(searchResult.corpus.hasCompleteTexts)
                        #expect(searchResult.matches.count == milestone)

                        // Verify >8 KB tail sentinels and decrypted isEncrypted == 1 sentinels matched.
                        for tailID in expectedTailSentinelIDs {
                            let idx = try #require(searchResult.indexByID[tailID])
                            #expect(searchResult.matches[idx], "40 KB tail row \(tailID) missed at \(milestone) rows")
                        }
                        for encID in expectedEncryptedSentinelIDs {
                            let idx = try #require(searchResult.indexByID[encID])
                            #expect(searchResult.matches[idx], "Encrypted row \(encID) missed at \(milestone) rows")
                        }

                        // Verify 0 match mismatches against Foundation String.range(of:options:locale:) across ALL rows!
                        let locale = Locale.current
                        var mismatchCount = 0
                        for (index, haystack) in searchResult.corpus.texts.enumerated() {
                            let expected = haystack.range(
                                of: query,
                                options: [.caseInsensitive, .diacriticInsensitive],
                                range: nil,
                                locale: locale
                            ) != nil
                            if searchResult.matches[index] != expected {
                                mismatchCount += 1
                            }
                        }
                        #expect(mismatchCount == 0, "Found \(mismatchCount) Foundation parity mismatches at \(milestone) rows")

                        // 4. Warm prefix refinement + single-item 40 KB hydration + capture latency metrics.
                        let warmStart = ContinuousClock.now
                        controller.historyToolbar(toolbar, didChangeSearchQuery: "scale_needle_tail")
                        controller.selectHistoryItemOnOpen()
                        let warmElapsed = ContinuousClock.now - warmStart

                        controller.clearSearchAfterHiddenInterval()
                        #expect(model.prepareSearchCorpusDescriptor().cachedCorpus == nil)
                        #expect(model.searchResult == nil)

                        var hydrate40KBMS = 0.0
                        if let richHeader = headers.first(where: { $0.kind == .richText }) {
                            let hydrateStart = ContinuousClock.now
                            let loaded = try spyStore.loadingContent(of: richHeader, scope: .full)
                            hydrate40KBMS = Self.durationMilliseconds(ContinuousClock.now - hydrateStart)
                            #expect(loaded.html != nil)
                        }

                        var capturePlainMedMS: Double?
                        var captureSecretMedMS: Double?
                        if milestone == 100_000 {
                            var plainTimes: [Double] = []
                            for i in 0..<20 {
                                let item = ClipboardItem(
                                    kind: .text,
                                    text: "Perf plain capture #\(i) \(UUID().uuidString)",
                                    sourceAppName: "ScaleApp",
                                    sourceBundleIdentifier: "com.example.scale"
                                )
                                let t0 = ContinuousClock.now
                                _ = try spyStore.capture(item, updatesCopySequence: false)
                                plainTimes.append(Self.durationMilliseconds(ContinuousClock.now - t0))
                            }
                            plainTimes.sort()
                            capturePlainMedMS = plainTimes[10]

                            let tokenPrefix = ["sk", "-perf-"].joined()
                            var secretTimes: [Double] = []
                            for i in 0..<20 {
                                let item = ClipboardItem(
                                    kind: .text,
                                    text: "Bearer \(tokenPrefix)\(i)-\(UUID().uuidString)",
                                    sourceAppName: "ScaleApp",
                                    sourceBundleIdentifier: "com.example.scale",
                                    sensitivity: .sensitive
                                )
                                let t0 = ContinuousClock.now
                                _ = try spyStore.capture(item, updatesCopySequence: false)
                                secretTimes.append(Self.durationMilliseconds(ContinuousClock.now - t0))
                            }
                            secretTimes.sort()
                            captureSecretMedMS = secretTimes[10]
                        }

                        let dbSizeMB = Double(Self.sqliteDiskBytes(in: supportDir)) / (1024.0 * 1024.0)
                        let fetchMS = Self.durationMilliseconds(fetchElapsed)
                        let ramDeltaMB = Double(headerFootprintDelta) / (1024.0 * 1024.0)
                        let coldMS = Self.durationMilliseconds(firstKeystrokeElapsed)
                        let warmMS = Self.durationMilliseconds(warmElapsed)
                        let capSummary = if let p = capturePlainMedMS, let s = captureSecretMedMS {
                            String(format: "%.2f / %.2f ms", p, s)
                        } else {
                            "—"
                        }
                        perfSummaryRows.append(String(
                            format: "| %dk | %.1f MB | %.1f ms | %.1f MB | %.1f ms (%d DB rows) | %.1f ms | %.2f ms | %@ |",
                            milestone / 1_000, dbSizeMB, fetchMS, ramDeltaMB, coldMS, expectedSQLiteFetchCount, warmMS, hydrate40KBMS, capSummary
                        ))
                    }
                }

                if let summaryPath = ProcessInfo.processInfo.environment["PERF_SUMMARY_PATH"],
                   !summaryPath.isEmpty {
                    let markdown = ([
                        "### Persistence & Search Scale Metrics (Debug Test Build)",
                        "",
                        "| Rows | DB Size | Startup `fetchAll()` | Idle RAM Δ (`phys_footprint`) | Cold 1st-Keystroke Search | Warm Prefix Refinement | Hydrate 40 KB Row | Capture (plain / secret med) |",
                        "|---:|---:|---:|---:|---:|---:|---:|---:|",
                    ] + perfSummaryRows + [""]).joined(separator: "\n")
                    let summaryURL = URL(fileURLWithPath: summaryPath)
                    try FileManager.default.createDirectory(
                        at: summaryURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(markdown.utf8).write(to: summaryURL, options: .atomic)
                }
            }
        }

        private nonisolated static func durationMilliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
        }

        private nonisolated static func sqliteDiskBytes(in directory: URL) -> Int64 {
            let fileManager = FileManager.default
            var total: Int64 = 0
            for fileName in ["History.sqlite", "History.sqlite-wal", "History.sqlite-shm"] {
                let path = directory.appendingPathComponent(fileName).path
                if let attrs = try? fileManager.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? NSNumber {
                    total += size.int64Value
                }
            }
            return total
        }

        private nonisolated static func currentPhysFootprintBytes() -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
                }
            }
            return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        }

        private nonisolated struct BulkSeedStats {
            let bodyUTF8Bytes: Int64
            let htmlUTF8Bytes: Int64
            let tailSentinelIDs: [UUID]
            let encryptedSentinelIDs: [UUID]
        }

        private nonisolated static func bulkInsertSyntheticV5Rows(
            at dbURL: URL,
            masterKey: SymmetricKey,
            startIndex: Int,
            endIndex: Int
        ) throws -> BulkSeedStats {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                throw HistoryStoreError.openFailed
            }
            defer { sqlite3_close(db) }

            let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw TestSQLiteFixtureError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            let clipSQL = """
                INSERT INTO clips (
                    id, kind, copiedAt, firstCopiedAt, deletedAt, expiresAt,
                    copySequenceID, copySequenceOrder, byteSize, copyCount,
                    isFavorite, favoriteOrder, sourceAppName, sourceBundleIdentifier,
                    sensitivity, isEncrypted, title, textPreview, characterCount,
                    containsPreviewSecret, containsRestSecret, hasRecognizedText,
                    hasQRCodeText, isSVGText, hasFormatting, htmlDigest, imageDigest,
                    imageWidth, imageHeight, assetPath, filePathsData, linkPreviewData, contentKey
                ) VALUES (
                    ?, ?, ?, ?, NULL, NULL,
                    NULL, NULL, ?, 1,
                    0, NULL, 'ScaleApp', 'com.example.scale',
                    ?, ?, NULL, ?, ?,
                    ?, ?, 0,
                    0, 0, ?, ?, NULL,
                    NULL, NULL, NULL, ?, NULL, ?
                );
                """
            let contentSQL = """
                INSERT INTO clip_contents (clipId, text, qrCodeText, rtf, html)
                VALUES (?, ?, NULL, NULL, ?);
                """

            var clipStmt: OpaquePointer?
            var contentStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, clipSQL, -1, &clipStmt, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, contentSQL, -1, &contentStmt, nil) == SQLITE_OK,
                  let clipStmt,
                  let contentStmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(clipStmt)
                sqlite3_finalize(contentStmt)
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw TestSQLiteFixtureError.prepareFailed(msg)
            }
            defer {
                sqlite3_finalize(clipStmt)
                sqlite3_finalize(contentStmt)
            }

            let derivedKeys = ClipBookDerivedKeys(masterKey: masterKey)
            let emptyFilePathsBytes = Array("[]".utf8)
            let largePrefix8KB = String(repeating: "L", count: ClipboardItem.textPreviewBodyLimit)
            let largeBody40KB = largePrefix8KB + String(repeating: "b", count: 32_000) + " SCALE_NEEDLE_TAIL_40KB"
            let largeBodyUTF8 = Array(largeBody40KB.utf8)
            let largePreviewUTF8 = Array(largePrefix8KB.utf8)
            let largeCharCount = Int64(largeBody40KB.count)

            let largeHTML40KB = "<article>" + String(repeating: "h", count: 40_000) + "</article>"
            let largeHTMLUTF8 = Array(largeHTML40KB.utf8)
            let largeHTMLDigestUTF8 = Array(ContentDigest.sha256(Data(largeHTMLUTF8)).utf8)

            let unicodeBody = "Café Straße ﬁlter UNICODE_SCALE_NEEDLE entry"
            let unicodeUTF8 = Array(unicodeBody.utf8)
            let unicodeCharCount = Int64(unicodeBody.count)

            let secretToken = ["sk", "-scale-row-", String(repeating: "z8X6cV4b", count: 4)].joined()
            let secretBody = "Bearer \(secretToken) ENCRYPTED_SCALE_NEEDLE"
            let secretPreview = String(secretBody.prefix(ClipboardItem.textPreviewBodyLimit))

            let fillerBody = "Ordinary clipboard history prose entry alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma"
            let fillerUTF8 = Array(fillerBody.utf8)
            let fillerCharCount = Int64(fillerBody.count)

            var totalBodyBytes: Int64 = 0
            var totalHTMLBytes: Int64 = 0
            var tailSentinelIDs: [UUID] = []
            var encryptedSentinelIDs: [UUID] = []
            var contentKeyBytes = [UInt8](repeating: 0, count: 32)

            func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ bytes: [UInt8]) {
                bytes.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), sqlTransient)
                }
            }

            for rowIndex in startIndex..<endIndex {
                sqlite3_reset(clipStmt)
                sqlite3_clear_bindings(clipStmt)
                sqlite3_reset(contentStmt)
                sqlite3_clear_bindings(contentStmt)

                let id = UUID()
                let idString = id.uuidString
                let copiedAt = 1_700_000_000.0 + Double(rowIndex) * 0.001

                let uuidTuple = id.uuid
                withUnsafeBytes(of: uuidTuple) { rawUUID in
                    for b in 0..<16 {
                        contentKeyBytes[b] = rawUUID[b]
                        contentKeyBytes[16 + b] = rawUUID[15 - b] ^ UInt8(truncatingIfNeeded: rowIndex)
                    }
                }

                _ = sqlite3_bind_text(clipStmt, 1, idString, -1, sqlTransient)
                _ = sqlite3_bind_text(contentStmt, 1, idString, -1, sqlTransient)
                _ = sqlite3_bind_double(clipStmt, 3, copiedAt)
                _ = sqlite3_bind_double(clipStmt, 4, copiedAt)

                if rowIndex % 500 == 1 {
                    // Genuine AES-GCM encrypted sensitive row (isEncrypted == 1)
                    let sealedPreview = Array(try HistoryCrypto.sealColumn(
                        Data(secretPreview.utf8),
                        table: "clips",
                        column: "textPreview",
                        clipID: id,
                        keys: derivedKeys
                    ))
                    let sealedFilePaths = Array(try HistoryCrypto.sealColumn(
                        Data(emptyFilePathsBytes),
                        table: "clips",
                        column: "filePathsData",
                        clipID: id,
                        keys: derivedKeys
                    ))
                    let sealedText = Array(try HistoryCrypto.sealColumn(
                        Data(secretBody.utf8),
                        table: "clip_contents",
                        column: "text",
                        clipID: id,
                        keys: derivedKeys
                    ))
                    let hmacKey = Array(HistoryCrypto.contentKey(
                        kind: .text,
                        canonicalContent: secretBody,
                        htmlDigest: nil,
                        keys: derivedKeys
                    ))

                    _ = sqlite3_bind_text(clipStmt, 2, "text", -1, sqlTransient)
                    _ = sqlite3_bind_int64(clipStmt, 5, Int64(secretBody.utf8.count))
                    _ = sqlite3_bind_text(clipStmt, 6, "sensitive", -1, sqlTransient)
                    _ = sqlite3_bind_int64(clipStmt, 7, 1)
                    bindBlob(clipStmt, 8, sealedPreview)
                    _ = sqlite3_bind_int64(clipStmt, 9, Int64(secretBody.count))
                    _ = sqlite3_bind_int64(clipStmt, 10, 1)
                    _ = sqlite3_bind_int64(clipStmt, 11, 1)
                    _ = sqlite3_bind_int64(clipStmt, 12, 0)
                    sqlite3_bind_null(clipStmt, 13)
                    bindBlob(clipStmt, 14, sealedFilePaths)
                    bindBlob(clipStmt, 15, hmacKey)

                    bindBlob(contentStmt, 2, sealedText)
                    sqlite3_bind_null(contentStmt, 3)

                    totalBodyBytes += Int64(secretBody.utf8.count)
                    if encryptedSentinelIDs.count < 16 {
                        encryptedSentinelIDs.append(id)
                    }
                } else if rowIndex % 10 == 0 {
                    // 40 KB body + 40 KB HTML rich row (tail needle is past char 40,000, absent from 8 KB textPreview!)
                    _ = sqlite3_bind_text(clipStmt, 2, "richText", -1, sqlTransient)
                    _ = sqlite3_bind_int64(clipStmt, 5, Int64(largeBodyUTF8.count + largeHTMLUTF8.count))
                    sqlite3_bind_null(clipStmt, 6)
                    _ = sqlite3_bind_int64(clipStmt, 7, 0)
                    bindBlob(clipStmt, 8, largePreviewUTF8)
                    _ = sqlite3_bind_int64(clipStmt, 9, largeCharCount)
                    _ = sqlite3_bind_int64(clipStmt, 10, 0)
                    _ = sqlite3_bind_int64(clipStmt, 11, 0)
                    _ = sqlite3_bind_int64(clipStmt, 12, 1)
                    bindBlob(clipStmt, 13, largeHTMLDigestUTF8)
                    bindBlob(clipStmt, 14, emptyFilePathsBytes)
                    bindBlob(clipStmt, 15, contentKeyBytes)

                    bindBlob(contentStmt, 2, largeBodyUTF8)
                    bindBlob(contentStmt, 3, largeHTMLUTF8)

                    totalBodyBytes += Int64(largeBodyUTF8.count)
                    totalHTMLBytes += Int64(largeHTMLUTF8.count)
                    if tailSentinelIDs.count < 16 {
                        tailSentinelIDs.append(id)
                    }
                } else if rowIndex % 250 == 2 {
                    // Unicode diacritic + ligature + sharp-s folding row
                    _ = sqlite3_bind_text(clipStmt, 2, "text", -1, sqlTransient)
                    _ = sqlite3_bind_int64(clipStmt, 5, Int64(unicodeUTF8.count))
                    sqlite3_bind_null(clipStmt, 6)
                    _ = sqlite3_bind_int64(clipStmt, 7, 0)
                    bindBlob(clipStmt, 8, unicodeUTF8)
                    _ = sqlite3_bind_int64(clipStmt, 9, unicodeCharCount)
                    _ = sqlite3_bind_int64(clipStmt, 10, 0)
                    _ = sqlite3_bind_int64(clipStmt, 11, 0)
                    _ = sqlite3_bind_int64(clipStmt, 12, 0)
                    sqlite3_bind_null(clipStmt, 13)
                    bindBlob(clipStmt, 14, emptyFilePathsBytes)
                    bindBlob(clipStmt, 15, contentKeyBytes)

                    bindBlob(contentStmt, 2, unicodeUTF8)
                    sqlite3_bind_null(contentStmt, 3)

                    totalBodyBytes += Int64(unicodeUTF8.count)
                } else {
                    // Ordinary non-matching filler row
                    _ = sqlite3_bind_text(clipStmt, 2, "text", -1, sqlTransient)
                    _ = sqlite3_bind_int64(clipStmt, 5, Int64(fillerUTF8.count))
                    sqlite3_bind_null(clipStmt, 6)
                    _ = sqlite3_bind_int64(clipStmt, 7, 0)
                    bindBlob(clipStmt, 8, fillerUTF8)
                    _ = sqlite3_bind_int64(clipStmt, 9, fillerCharCount)
                    _ = sqlite3_bind_int64(clipStmt, 10, 0)
                    _ = sqlite3_bind_int64(clipStmt, 11, 0)
                    _ = sqlite3_bind_int64(clipStmt, 12, 0)
                    sqlite3_bind_null(clipStmt, 13)
                    bindBlob(clipStmt, 14, emptyFilePathsBytes)
                    bindBlob(clipStmt, 15, contentKeyBytes)

                    bindBlob(contentStmt, 2, fillerUTF8)
                    sqlite3_bind_null(contentStmt, 3)

                    totalBodyBytes += Int64(fillerUTF8.count)
                }

                guard sqlite3_step(clipStmt) == SQLITE_DONE,
                      sqlite3_step(contentStmt) == SQLITE_DONE else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    throw TestSQLiteFixtureError.stepFailed(msg)
                }
            }

            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw TestSQLiteFixtureError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            return BulkSeedStats(
                bodyUTF8Bytes: totalBodyBytes,
                htmlUTF8Bytes: totalHTMLBytes,
                tailSentinelIDs: tailSentinelIDs,
                encryptedSentinelIDs: encryptedSentinelIDs
            )
        }
    }
}

private nonisolated final class SearchTestLinkPreviewURLProtocol: URLProtocol {
    override nonisolated class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "linkpreview-search-test.clipbook.invalid"
    }

    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override nonisolated func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/html; charset=utf-8"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let html = """
            <!doctype html>
            <html>
            <head>
              <title>ConfidOpenGraphPreviewTitle</title>
              <meta name="description" content="confi_link_preview_description" />
            </head>
            <body></body>
            </html>
            """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override nonisolated func stopLoading() {}
}
