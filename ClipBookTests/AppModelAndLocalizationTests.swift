@testable import ClipBook
import AppKit
import Foundation
import SQLite3
import Testing

@Suite
enum AppModelAndLocalizationTests {
    @Suite
    struct AppModelSearchAndSelectionTests {
        @Test
        @MainActor
        func caseInsensitiveSearch() {
            let model = AppModel()
            let cafeResume = ClipboardItem.fixture(
                kind: .text,
                text: "Café Latté & Résumé Notes",
                sourceAppName: "Notes",
                copiedAt: Date(timeIntervalSince1970: 300)
            )
            let cafeOnly = ClipboardItem.fixture(
                kind: .text,
                text: "Cafe Mocha Recipe",
                sourceAppName: "Notes",
                copiedAt: Date(timeIntervalSince1970: 200)
            )
            let unrelated = ClipboardItem.fixture(
                kind: .text,
                text: "Plain clipboard entry",
                sourceAppName: "Terminal",
                copiedAt: Date(timeIntervalSince1970: 100)
            )
            model.items = [cafeResume, cafeOnly, unrelated]

            model.searchQuery = "  RÉSUMÉ  "
            #expect(model.isHistorySearchActive)
            #expect(model.isHistoryNarrowed)
            #expect(model.filteredItems.map(\.id) == [cafeResume.id])

            model.searchQuery = "latté & résumé"
            #expect(model.filteredItems.map(\.id) == [cafeResume.id])

            model.searchQuery = "notes"
            #expect(model.filteredItems.map(\.id) == [cafeResume.id, cafeOnly.id])

            model.searchQuery = "   "
            #expect(!model.isHistorySearchActive)
            #expect(!model.isHistoryNarrowed)
            #expect(model.filteredItems.count == 3)
        }

        @Test
        @MainActor
        func foldedSearchCacheInvalidationOnEdit() {
            let model = AppModel()
            let sharedID = UUID()
            let original = ClipboardItem.fixture(
                id: sharedID,
                kind: .text,
                text: "Initial Alpha Keyword",
                copiedAt: Date(timeIntervalSince1970: 200)
            )
            let secondary = ClipboardItem.fixture(
                kind: .text,
                text: "Secondary Entry",
                copiedAt: Date(timeIntervalSince1970: 100)
            )
            model.items = [original, secondary]

            model.searchQuery = "alpha"
            #expect(model.filteredItems.map(\.id) == [sharedID])

            let updatedInPlace = ClipboardItem.fixture(
                id: sharedID,
                kind: .text,
                text: "Updated Omega Keyword",
                copiedAt: Date(timeIntervalSince1970: 200)
            )
            model.replace(updatedInPlace)

            #expect(model.filteredItems.isEmpty)
            model.searchQuery = "omega"
            #expect(model.filteredItems.map(\.id) == [sharedID])
        }

        @Test
        @MainActor
        func filterGroupIntersectionAndFavoritesNarrowing() {
            let model = AppModel()
            let workTag = Tag(id: 1, name: "Work", color: "#FF0000")
            let personalTag = Tag(id: 2, name: "Personal", color: "#00FF00")
            let urgentTag = Tag(id: 3, name: "Urgent", color: "#0000FF")
            model.tags = [personalTag, urgentTag, workTag]

            func item(
                _ kind: ClipboardKind,
                _ text: String?,
                app: (name: String, bundleID: String),
                at seconds: TimeInterval,
                tag: ClipBook.Tag
            ) -> ClipboardItem {
                .fixture(
                    kind: kind,
                    text: text,
                    sourceAppName: app.name,
                    sourceBundleIdentifier: app.bundleID,
                    copiedAt: Date(timeIntervalSince1970: seconds),
                    isFavorite: true,
                    tags: [tag.id]
                )
            }
            let safari = (name: "Safari", bundleID: "com.apple.Safari")
            let favLinkSafariWork = item(.link, "https://example.com/work", app: safari, at: 500, tag: workTag)
            var nonFavLinkSafariWork = item(.link, "https://example.com/nonfav", app: safari, at: 400, tag: workTag)
            nonFavLinkSafariWork.isFavorite = false
            let favTextSafariWork = item(.text, "Favorite Safari note", app: safari, at: 300, tag: workTag)
            let favImageChromeUrgent = item(
                .image, nil, app: (name: "Chrome", bundleID: "com.google.Chrome"), at: 200, tag: urgentTag
            )
            let favTextNotesPersonal = item(
                .text, "Personal note", app: (name: "Notes", bundleID: "com.apple.Notes"), at: 100, tag: personalTag
            )

            model.items = [
                favLinkSafariWork,
                nonFavLinkSafariWork,
                favTextSafariWork,
                favImageChromeUrgent,
                favTextNotesPersonal,
            ]

            model.selectedHistoryFilterContentTypes = [.favorites, .links, .images]
            #expect(model.filteredItems.map(\.id) == [favLinkSafariWork.id, favImageChromeUrgent.id])

            model.selectedHistoryFilterTagIDs = [workTag.id, personalTag.id]
            #expect(model.filteredItems.map(\.id) == [favLinkSafariWork.id])

            let chromeSourceID = HistorySourceApplication.id(forName: "Chrome")
            let safariSourceID = HistorySourceApplication.id(forName: "Safari")
            model.selectedHistoryFilterSourceApplicationIDs = [chromeSourceID]
            #expect(model.filteredItems.isEmpty)

            model.selectedHistoryFilterSourceApplicationIDs = [chromeSourceID, safariSourceID]
            #expect(model.filteredItems.map(\.id) == [favLinkSafariWork.id])

            model.clearHistoryFilters()
            #expect(!model.isHistoryFilterActive)
            #expect(model.filteredItems.count == 5)
        }

        @Test
        @MainActor
        func removeExhaustedSourceApplicationFilterSelectsFirstFilteredItem() {
            let model = AppModel()
            let safariOnlyItem = ClipboardItem.fixture(
                kind: .text,
                text: "Only Safari item",
                sourceAppName: "Safari",
                sourceBundleIdentifier: "com.apple.Safari",
                copiedAt: Date(timeIntervalSince1970: 300)
            )
            let notesFirst = ClipboardItem.fixture(
                kind: .text,
                text: "Notes item 1",
                sourceAppName: "Notes",
                sourceBundleIdentifier: "com.apple.Notes",
                copiedAt: Date(timeIntervalSince1970: 200)
            )
            let notesSecond = ClipboardItem.fixture(
                kind: .text,
                text: "Notes item 2",
                sourceAppName: "Notes",
                sourceBundleIdentifier: "com.apple.Notes",
                copiedAt: Date(timeIntervalSince1970: 100)
            )
            model.items = [safariOnlyItem, notesFirst, notesSecond]

            let safariSourceID = HistorySourceApplication.id(forName: "Safari")
            model.selectedHistoryFilterSourceApplicationIDs = [safariSourceID]
            model.selectedItemID = safariOnlyItem.id
            model.selectedItemIDs = [safariOnlyItem.id]
            model.selectedItemIDsInSelectionOrder = [safariOnlyItem.id]

            #expect(model.filteredItems.map(\.id) == [safariOnlyItem.id])

            model.remove(safariOnlyItem.id)

            #expect(model.selectedHistoryFilterSourceApplicationIDs.isEmpty)
            #expect(model.filteredItems.map(\.id) == [notesFirst.id, notesSecond.id])
            #expect(model.selectedItemID == notesFirst.id)
            #expect(model.selectedItemIDs == [notesFirst.id])
            #expect(model.selectedItemIDsInSelectionOrder == [notesFirst.id])
        }

        @Test
        @MainActor
        func removePrimarySelectedItemPreservesMultiSelection() {
            let model = AppModel()
            let first = ClipboardItem.fixture(text: "First", copiedAt: Date(timeIntervalSince1970: 300))
            let second = ClipboardItem.fixture(text: "Second", copiedAt: Date(timeIntervalSince1970: 200))
            let third = ClipboardItem.fixture(text: "Third", copiedAt: Date(timeIntervalSince1970: 100))
            model.items = [first, second, third]

            model.selectedItemID = first.id
            model.selectedItemIDs = [first.id, second.id, third.id]
            model.selectedItemIDsInSelectionOrder = [third.id, first.id, second.id]

            model.remove(first.id)

            #expect(model.selectedItemID == third.id)
            #expect(model.selectedItemIDs == [second.id, third.id])
            #expect(model.selectedItemIDsInSelectionOrder == [third.id, second.id])
            #expect(model.selectedItems.map(\.id) == [third.id, second.id])
        }

        @Test
        @MainActor
        func replaceUpdatesTrashedItemsWithoutResurrection() {
            let model = AppModel()
            let activeItem = ClipboardItem.fixture(
                kind: .text,
                text: "Active item",
                copiedAt: Date(timeIntervalSince1970: 300)
            )
            let trashedItem = ClipboardItem.fixture(
                kind: .image,
                text: nil,
                copiedAt: Date(timeIntervalSince1970: 200),
                deletedAt: Date(timeIntervalSince1970: 250)
            )
            let unloadedTrashedNotInMemory = ClipboardItem.fixture(
                kind: .link,
                text: "https://example.com",
                copiedAt: Date(timeIntervalSince1970: 100),
                deletedAt: Date(timeIntervalSince1970: 150)
            )

            model.items = [activeItem]
            model.trashedItems = [trashedItem]

            var ocrUpdatedTrashed = trashedItem
            ocrUpdatedTrashed.text = "Recognized OCR in trash"
            model.replace(ocrUpdatedTrashed)

            #expect(model.items.map(\.id) == [activeItem.id])
            #expect(model.trashedItems.count == 1)
            #expect(model.trashedItems.first?.isContentLoaded == false)
            #expect(model.trashedItems.first?.hasRecognizedText == true)
            #expect(model.trashedItems.first?.previewText == "Recognized OCR in trash")

            model.replace(unloadedTrashedNotInMemory)
            #expect(model.items.map(\.id) == [activeItem.id])

            var batchUpdatedTrashed = ocrUpdatedTrashed
            batchUpdatedTrashed.title = "Trashed Image Title"
            let newFirst = ClipboardItem.fixture(text: "New First", copiedAt: Date(timeIntervalSince1970: 500))
            let newSecond = ClipboardItem.fixture(text: "New Second", copiedAt: Date(timeIntervalSince1970: 400))
            var updatedActive = activeItem
            updatedActive.title = "Updated Active"

            model.replace([batchUpdatedTrashed, unloadedTrashedNotInMemory, newFirst, newSecond, updatedActive])

            #expect(model.trashedItems.map(\.id) == [trashedItem.id])
            #expect(model.trashedItems.first?.title == "Trashed Image Title")
            #expect(model.items.map(\.id) == [newFirst.id, newSecond.id, activeItem.id])
            #expect(model.items.last?.title == "Updated Active")
        }

        @Test
        @MainActor
        func replaceInsertsANewItemOnceEvenWhenTheBatchRepeatsIt() {
            let model = AppModel()
            let existing = ClipboardItem.fixture(text: "Existing", copiedAt: Date(timeIntervalSince1970: 100))
            model.items = [existing]

            let newItem = ClipboardItem.fixture(text: "New, first version", copiedAt: Date(timeIntervalSince1970: 300))
            var newItemLater = newItem
            newItemLater.text = "New, latest version"
            let other = ClipboardItem.fixture(text: "Other", copiedAt: Date(timeIntervalSince1970: 200))

            model.replace([newItem, other, newItemLater])

            #expect(model.items.map(\.id) == [newItem.id, other.id, existing.id])
            #expect(model.items.first?.isContentLoaded == false)
            #expect(model.items.first?.previewText == "New, latest version")
        }

        @Test
        @MainActor
        func replaceUpdatesAnExistingItemOnceEvenWhenTheBatchRepeatsIt() {
            let model = AppModel()
            let item = ClipboardItem.fixture(text: "Original", copiedAt: Date(timeIntervalSince1970: 200))
            let other = ClipboardItem.fixture(text: "Other", copiedAt: Date(timeIntervalSince1970: 100))
            model.items = [item, other, item]

            var firstUpdate = item
            firstUpdate.title = "First update"
            var secondUpdate = item
            secondUpdate.title = "Second update"
            model.replace([firstUpdate, secondUpdate])

            #expect(model.items.map(\.id) == [item.id, other.id])
            #expect(model.items.first?.title == "Second update")
        }

        @Test
        @MainActor
        func restoreRemovesFromTrashedItemsAndRestoresSelection() {
            let model = AppModel()
            let existingActive = ClipboardItem.fixture(
                text: "Existing Active",
                copiedAt: Date(timeIntervalSince1970: 100)
            )
            let trashedOne = ClipboardItem.fixture(
                text: "Trashed One",
                copiedAt: Date(timeIntervalSince1970: 300),
                deletedAt: Date(timeIntervalSince1970: 350)
            )
            let trashedTwo = ClipboardItem.fixture(
                text: "Trashed Two",
                copiedAt: Date(timeIntervalSince1970: 200),
                deletedAt: Date(timeIntervalSince1970: 250)
            )

            model.items = [existingActive]
            model.trashedItems = [trashedOne, trashedTwo]

            let savedSelection = HistorySelection(
                itemID: trashedOne.id,
                itemIDs: [trashedOne.id],
                itemIDsInSelectionOrder: [trashedOne.id]
            )

            model.restore([trashedOne], selection: savedSelection)

            #expect(model.trashedItems.map(\.id) == [trashedTwo.id])
            #expect(model.items.contains { $0.id == trashedOne.id && $0.deletedAt == nil })
            #expect(model.selectedItemID == trashedOne.id)
            #expect(model.selectedItemIDs == [trashedOne.id])
        }

        @Test
        @MainActor
        func unloadedHeaderInsertionTagMutationInvalidationAndStoreAwareCorpusDonorReuse() throws {
            try TestSupport.withTemporaryHistoryStore { baseStore, directory in
                let spyStore = SpyHistoryStore(base: baseStore)
                let model = AppModel()

                let tagOps = try spyStore.createTag(name: "OpsVault", color: "#3B85ED")
                let tagDocs = try spyStore.createTag(name: "DocsTeam", color: "#2196F3")
                model.tags = [tagOps, tagDocs]

                let body40KB = String(repeating: "x", count: 40_000) + "TAIL_SENTINEL_AT_40KB"
                let rtfBytes = try TestSupport.makeRTFData(text: body40KB)
                let htmlMarkup = "<article><p>\(body40KB)</p></article>"

                let richSaved = try spyStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        kind: .richText,
                        text: body40KB,
                        rtfData: rtfBytes,
                        html: htmlMarkup,
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        tags: [tagOps.id]
                    ),
                    convertingExternalAssets: true
                )
                let plainSaved = try spyStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        kind: .text,
                        text: "Plain untagged note",
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                        tags: []
                    ),
                    convertingExternalAssets: true
                )
                let qrSaved = try spyStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        kind: .image,
                        text: "QR badge",
                        qrCodeText: "QR_PAYLOAD_TOKEN_987",
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_250)
                    ),
                    convertingExternalAssets: true
                )

                // AppModel.insert, insertIntoTrash, restore, and replace strip body + formatting while preserving header flags.
                model.insert(richSaved)
                model.insert(plainSaved)
                model.insert(qrSaved)
                #expect(model.items.count == 3)
                #expect(model.items.allSatisfy { !$0.isContentLoaded && !$0.isFormattingLoaded && $0.searchText.isEmpty })

                let richInModel = try #require(model.items.first { $0.id == richSaved.id })
                #expect(richInModel.text == nil)
                #expect(richInModel.html == nil)
                #expect(richInModel.rtfData == nil)
                #expect(richInModel.characterCount == body40KB.count)
                #expect(richInModel.hasFormatting)
                #expect(richInModel.storedContentKey == richSaved.storedContentKey)

                model.selectedHistoryFilterContentTypes = [.trash]
                model.insertIntoTrash([richSaved])
                #expect(model.trashedItems.first?.isContentLoaded == false)
                #expect(model.trashedItems.first?.searchText.isEmpty == true)
                model.selectedHistoryFilterContentTypes = []
                model.restore([richSaved], selection: nil)
                #expect(model.items.allSatisfy { !$0.isContentLoaded && $0.searchText.isEmpty })

                // Idle: cachedSearchCorpus is nil until a search corpus is built.
                #expect(model.prepareSearchCorpusDescriptor().cachedCorpus == nil)

                // First makeSearchCorpus(using:) resolves complete short headers in RAM and hydrates only incomplete/QR items from SQLite.
                spyStore.resetRecordedCalls()
                let corpus1 = model.makeSearchCorpus(using: spyStore)
                #expect(corpus1.hasCompleteTexts)
                #expect(spyStore.fetchSearchTextsCalls.count == 1)
                #expect(Set(spyStore.fetchSearchTextsCalls[0].ids) == [richSaved.id, qrSaved.id])
                #expect(corpus1.texts.contains { $0.contains("Plain untagged note") })
                #expect(corpus1.texts.contains { $0.contains("QR_PAYLOAD_TOKEN_987") })
                #expect(model.prepareSearchCorpusDescriptor().cachedCorpus === corpus1)

                // Repeat makeSearchCorpus(using:) at same sortedListRevision returns cached corpus with 0 DB calls.
                spyStore.resetRecordedCalls()
                let corpus2 = model.makeSearchCorpus(using: spyStore)
                #expect(corpus2 === corpus1)
                #expect(spyStore.fetchSearchTextsCalls.isEmpty)

                // Direct model.tags mutation invalidates sortedListRevision + cachedSearchCorpus,
                // and incremental donor reuse reuses untagged plainSaved while querying ONLY tagged richSaved!
                let revBeforeTagRename = model.sortedListRevision
                model.tags = [ClipBook.Tag(id: tagOps.id, name: "RenamedSecOps", color: tagOps.color), tagDocs]
                #expect(model.sortedListRevision != revBeforeTagRename)
                #expect(model.prepareSearchCorpusDescriptor().cachedCorpus == nil)

                // Make corpus1 the donor via installSearchResult before building the next corpus.
                let seedResult = try #require(
                    HistorySearchJob().run(
                        corpus: corpus1,
                        terms: HistorySearchTerms(query: "TAIL_SENTINEL_AT_40KB"),
                        locale: .current
                    )
                )
                model.installSearchResult(seedResult)

                spyStore.resetRecordedCalls()
                let corpusAfterDirectTagMutation = model.makeSearchCorpus(using: spyStore)
                #expect(corpusAfterDirectTagMutation.hasCompleteTexts)
                #expect(spyStore.fetchSearchTextsCalls.count == 1)
                #expect(spyStore.fetchSearchTextsCalls[0].ids == [richSaved.id])
                #expect(corpusAfterDirectTagMutation.texts.contains { $0.contains("RenamedSecOps") && $0.contains("TAIL_SENTINEL_AT_40KB") })

                // Unpersisted incomplete (>8 KB) header fallback sets hasCompleteTexts == false, revision slot == 0, and does NOT cache.
                let unpersisted = ClipboardItem.fixture(
                    kind: .text,
                    text: "Transient unpersisted clip " + String(repeating: "u", count: 9_000),
                    copiedAt: Date(timeIntervalSince1970: 1_700_000_300)
                )
                model.insert(unpersisted)
                spyStore.resetRecordedCalls()
                let degradedCorpus = model.makeSearchCorpus(using: spyStore)
                #expect(!degradedCorpus.hasCompleteTexts)
                let unpersistedSlot = try #require(degradedCorpus.indexByID()[unpersisted.id])
                #expect(degradedCorpus.revisions[unpersistedSlot] == 0)
                #expect(degradedCorpus.texts[unpersistedSlot].contains("Transient unpersisted clip"))
                #expect(model.prepareSearchCorpusDescriptor().cachedCorpus == nil)

                // Downgrading unsealed sensitivity columns while tampering clip_contents.text on an isEncrypted=1 row
                // must NOT bypass AEAD verification via RAM header resolution (isStoredEncrypted stays true).
                let secretToken = ["sk", "-live-tamper-", "99887766554433221100aabb"].joined()
                let secretSaved = try spyStore.saveAndReconcileItem(
                    ClipboardItem.fixture(
                        kind: .text,
                        text: "Bearer \(secretToken)",
                        copiedAt: Date(timeIntervalSince1970: 1_700_000_400)
                    ),
                    convertingExternalAssets: true
                )
                #expect(secretSaved.isStoredEncrypted)
                #expect(!secretSaved.hasCompleteHeaderSearchText)

                // Flip unsealed clips.containsRestSecret=0 and corrupt clip_contents.text directly in SQLite.
                let dbURL = directory.appendingPathComponent("History.sqlite")
                var rawDB: OpaquePointer?
                #expect(sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
                defer { sqlite3_close(rawDB) }
                let tamperSQL = """
                    UPDATE clips SET containsRestSecret = 0, sensitivity = 'notSensitive' WHERE id = '\(secretSaved.id.uuidString)';
                    UPDATE clip_contents SET text = X'DEADBEEF' WHERE clipId = '\(secretSaved.id.uuidString)';
                    """
                #expect(sqlite3_exec(rawDB, tamperSQL, nil, nil, nil) == SQLITE_OK)

                let fetchedAfterTamper = try spyStore.fetchAll()
                let tamperedHeader = try #require(fetchedAfterTamper.first { $0.id == secretSaved.id })
                #expect(tamperedHeader.isStoredEncrypted)
                #expect(!tamperedHeader.hasCompleteHeaderSearchText)

                let tamperModel = AppModel()
                tamperModel.items = [tamperedHeader]
                spyStore.resetRecordedCalls()
                let tamperCorpus = tamperModel.makeSearchCorpus(using: spyStore)
                #expect(spyStore.fetchSearchTextsCalls.map(\.ids) == [[secretSaved.id]])
                #expect(tamperCorpus.texts == [""])
            }
        }
    }

    @Suite
    struct HistoryOrderingTests {
        /// Whether `lhs` sorts ahead of `rhs`, read from a two-item history whose
        /// input order puts `rhs` first, so a stable sort cannot hide the answer.
        @MainActor
        private static func ordersBefore(
            _ lhs: ClipboardItem,
            _ rhs: ClipboardItem,
            in model: AppModel
        ) -> Bool {
            model.items = [rhs, lhs]
            return model.filteredItems.first?.id == lhs.id
        }

        /// The three items sort differently by every option, so each row below pins one ordering down.
        @Test(arguments: [
            (option: HistorySortOption.lastCopyTime, reversed: false, order: ["A", "B", "C"]),
            (option: HistorySortOption.lastCopyTime, reversed: true, order: ["C", "B", "A"]),
            (option: HistorySortOption.firstCopyTime, reversed: false, order: ["B", "C", "A"]),
            (option: HistorySortOption.firstCopyTime, reversed: true, order: ["A", "C", "B"]),
            (option: HistorySortOption.numberOfCopies, reversed: false, order: ["B", "C", "A"]),
            (option: HistorySortOption.numberOfCopies, reversed: true, order: ["A", "C", "B"]),
            (option: HistorySortOption.size, reversed: false, order: ["B", "C", "A"]),
            (option: HistorySortOption.size, reversed: true, order: ["A", "C", "B"])
        ])
        @MainActor
        func sortOptionsAndReverseOrdering(option: HistorySortOption, reversed: Bool, order: [String]) {
            let model = AppModel()
            model.preferences.pinFavoritesToTop = false
            model.preferences.copySequenceModeEnabled = false

            let itemA = ClipboardItem.fixture(
                text: "A",
                copiedAt: Date(timeIntervalSince1970: 300),
                firstCopiedAt: Date(timeIntervalSince1970: 100),
                byteSize: 50,
                copyCount: 2
            )
            let itemB = ClipboardItem.fixture(
                text: "B",
                copiedAt: Date(timeIntervalSince1970: 200),
                firstCopiedAt: Date(timeIntervalSince1970: 300),
                byteSize: 500,
                copyCount: 10
            )
            let itemC = ClipboardItem.fixture(
                text: "C",
                copiedAt: Date(timeIntervalSince1970: 100),
                firstCopiedAt: Date(timeIntervalSince1970: 200),
                byteSize: 150,
                copyCount: 5
            )
            model.items = [itemC, itemA, itemB]

            model.historySortOption = option
            model.isHistorySortReversed = reversed
            #expect(model.filteredItems.compactMap(\.text) == order)
        }

        @Test
        @MainActor
        func pinFavoritesToTopAndFavoriteOrder() {
            let model = AppModel()
            var prefs = AppPreferences()
            prefs.pinFavoritesToTop = true
            prefs.copySequenceModeEnabled = false
            model.preferences = prefs
            model.historySortOption = .lastCopyTime

            let unarrangedFavNew = ClipboardItem.fixture(
                text: "Unarranged Fav New",
                copiedAt: Date(timeIntervalSince1970: 200),
                isFavorite: true,
                favoriteOrder: nil
            )
            let arrangedFavFirst = ClipboardItem.fixture(
                text: "Arranged Fav 0",
                copiedAt: Date(timeIntervalSince1970: 100),
                isFavorite: true,
                favoriteOrder: 0
            )
            let arrangedFavSecond = ClipboardItem.fixture(
                text: "Arranged Fav 1",
                copiedAt: Date(timeIntervalSince1970: 400),
                isFavorite: true,
                favoriteOrder: 1
            )
            let regularNew = ClipboardItem.fixture(
                text: "Regular New",
                copiedAt: Date(timeIntervalSince1970: 500),
                isFavorite: false
            )
            let regularOld = ClipboardItem.fixture(
                text: "Regular Old",
                copiedAt: Date(timeIntervalSince1970: 300),
                isFavorite: false
            )

            model.items = [regularOld, arrangedFavSecond, regularNew, arrangedFavFirst, unarrangedFavNew]
            model.isHistorySortReversed = false
            #expect(
                model.filteredItems.map(\.id) == [
                    unarrangedFavNew.id,
                    arrangedFavFirst.id,
                    arrangedFavSecond.id,
                    regularNew.id,
                    regularOld.id,
                ]
            )

            model.isHistorySortReversed = true
            #expect(
                model.filteredItems.map(\.id) == [
                    unarrangedFavNew.id,
                    arrangedFavFirst.id,
                    arrangedFavSecond.id,
                    regularOld.id,
                    regularNew.id,
                ]
            )
        }

        @Test
        @MainActor
        func copySequenceOrderingPermutations() {
            let model = AppModel()
            var prefs = AppPreferences()
            prefs.pinFavoritesToTop = false
            prefs.copySequenceModeEnabled = true
            model.preferences = prefs

            let sharedGroupDate = Date(timeIntervalSince1970: 1_000)

            // The non-sequence item has the smallest id and the same copiedAt as the
            // first sequence item. Without a rule that puts sequence items ahead of
            // non-sequence items in the same group, the pairs would run in a cycle
            // (C before A by id, A before B by sequence order, B before C by time).
            let itemC = ClipboardItem.fixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                text: "Non-Sequence Same GroupDate",
                copiedAt: sharedGroupDate,
                copySequenceID: nil,
                copySequenceOrder: nil
            )
            let itemA = ClipboardItem.fixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                text: "Sequence First",
                copiedAt: sharedGroupDate,
                copySequenceID: sharedGroupDate,
                copySequenceOrder: 1
            )
            let itemB = ClipboardItem.fixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                text: "Sequence Second",
                copiedAt: Date(timeIntervalSince1970: 1_020),
                copySequenceID: sharedGroupDate,
                copySequenceOrder: 2
            )

            let elements = [itemA, itemB, itemC]

            #expect(Self.ordersBefore(itemA, itemB, in: model))
            #expect(Self.ordersBefore(itemB, itemC, in: model))
            #expect(Self.ordersBefore(itemA, itemC, in: model))

            for x in elements {
                for y in elements where x.id != y.id {
                    let xy = Self.ordersBefore(x, y, in: model)
                    let yx = Self.ordersBefore(y, x, in: model)
                    #expect(xy != yx)
                }
            }

            for x in elements {
                for y in elements where y.id != x.id {
                    for z in elements where z.id != y.id && z.id != x.id {
                        if Self.ordersBefore(x, y, in: model) && Self.ordersBefore(y, z, in: model) {
                            #expect(Self.ordersBefore(x, z, in: model))
                        }
                    }
                }
            }

            let permutations: [[ClipboardItem]] = [
                [itemA, itemB, itemC],
                [itemA, itemC, itemB],
                [itemB, itemA, itemC],
                [itemB, itemC, itemA],
                [itemC, itemA, itemB],
                [itemC, itemB, itemA],
            ]
            let expectedOrder = [itemA.id, itemB.id, itemC.id]
            for permutation in permutations {
                model.items = permutation
                #expect(model.filteredItems.map(\.id) == expectedOrder)
            }
        }
    }

    @Suite
    struct ArchiveAndPersistenceCatalogTests {
        private static let requiredNonSourceLocales = [
            "de",
            "en-GB",
            "es",
            "it",
            "ja",
            "pt-BR",
            "zh-Hans"
        ]

        private static let persistenceAndArchiveCatalogKeys: [String] = [
            "History Unlocked",
            "History Locked",
            "History Encryption Key Mismatch",
            "%@ Unlock Keychain and click Unlock History to resume clipboard capture.",
            "The history database was encrypted with a different key than the current Keychain key. Restore the matching Keychain key and click Unlock History.",
            "Unable to open the ClipBook history database.",
            "The history database was encrypted with a different key than the current Keychain key.",
            "Unable to verify or decrypt protected history data.",
            "The archive encryption passphrase or key derivation parameters are invalid.",
            "Unable to migrate the history database: %@",
            "The history encryption key could not be found in Keychain.",
            "Keychain is locked and cannot unlock the history encryption key right now.",
            "Access to the history encryption key in Keychain was canceled.",
            "Keychain authentication failed while accessing the history encryption key.",
            "The stored history encryption key data is corrupted or invalid.",
            "Unable to access the history encryption key (Keychain status %@).",
            "ClipBook archive version %d is not supported.",
            "The archive is missing %@.",
            "The archive contains an invalid asset path: %@.",
            "A passphrase is required to unlock this encrypted ClipBook archive.",
            "The archive passphrase cannot be empty.",
            "The archive passphrase is incorrect.",
            "The encrypted ClipBook archive is damaged or was modified (%@).",
            "The archive encryption parameters are invalid or unsupported.",
            "Unlock History...",
            "Unlock History",
            "Encrypt archive with passphrase",
            "Protect exported history items, tags, and copied image assets with AES-256-GCM encryption.",
            "Export Contains Sensitive Items",
            "Encrypt Archive...",
            "Skip Sensitive Items",
            "Export Unencrypted Anyway",
            "Your clipboard history includes sensitive items such as passwords, API keys, or protected images. Unencrypted archives store them in plain text.",
            "Exported %d items and %d tags to %@.",
            "Imported %d items and %d tags.",
            "Passphrase",
            "Confirm Passphrase",
            "Passphrases do not match.",
            "Encrypt Archive",
            "Unlock Encrypted Archive",
            "Enter a passphrase to encrypt this archive. You will need the same passphrase to import or recover it later.",
            "Enter the passphrase for %@.",
            "Unlock",
            "Importing History",
            "Exporting History",
            "History Imported",
            "History Exported",
            "Import Failed",
            "Export Failed",
            "The license key cannot be deactivated :("
        ]

        @Test
        func archiveEncryptionAndLockCatalogCompletenessAndFormatSpecifierParity() throws {
            // Self-test positional specifier parser on reordered "%2$@ ... %1$d" and escaped "%%".
            #expect(Self.formatSpecifierMap(in: "100%% plain") == [:])
            #expect(
                Self.formatSpecifierMap(in: "In %2$@: %1$d Objekte")
                    == Self.formatSpecifierMap(in: "%d items in %@")
            )
            #expect(Self.formatSpecifierMap(in: "In %2$@: %1$d Objekte") == [1: "d", 2: "@"])

            let xcstringsURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ClipBook/Localizable.xcstrings")
            let rawData = try Data(contentsOf: xcstringsURL)
            let root = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
            #expect(root["sourceLanguage"] as? String == "en")

            let stringsDict = try #require(root["strings"] as? [String: Any])

            for key in Self.persistenceAndArchiveCatalogKeys {
                let entry = try #require(stringsDict[key] as? [String: Any], Comment(rawValue: "Missing xcstrings key: \(key)"))
                let localizations = try #require(
                    entry["localizations"] as? [String: Any],
                    Comment(rawValue: "Missing localizations dictionary for key: \(key)")
                )

                let englishSource: String
                if let enEntry = localizations["en"] as? [String: Any],
                   let enUnit = enEntry["stringUnit"] as? [String: Any],
                   let enValue = enUnit["value"] as? String {
                    #expect(enUnit["state"] as? String == "translated", Comment(rawValue: "\(key) [en]"))
                    #expect(!enValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Comment(rawValue: "\(key) [en]"))
                    englishSource = enValue
                } else {
                    englishSource = key
                }
                let expectedSpecifiers = Self.formatSpecifierMap(in: englishSource)

                for locale in Self.requiredNonSourceLocales {
                    let localeEntry = try #require(
                        localizations[locale] as? [String: Any],
                        Comment(rawValue: "Missing locale \(locale) for key: \(key)")
                    )
                    let unit = try #require(
                        localeEntry["stringUnit"] as? [String: Any],
                        Comment(rawValue: "Missing stringUnit in \(locale) for key: \(key)")
                    )
                    let state = unit["state"] as? String
                    let value = (unit["value"] as? String) ?? ""
                    #expect(state == "translated", Comment(rawValue: "Untranslated state in \(locale) for key: \(key)"))
                    #expect(
                        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        Comment(rawValue: "Empty translation in \(locale) for key: \(key)")
                    )
                    let actualSpecifiers = Self.formatSpecifierMap(in: value)
                    #expect(
                        actualSpecifiers == expectedSpecifiers,
                        Comment(rawValue: "Format specifier mismatch in \(locale) for key '\(key)': \(actualSpecifiers) != \(expectedSpecifiers)")
                    )
                }
            }
        }

        private static func formatSpecifierMap(in format: String) -> [Int: String] {
            let pattern = #"%(\%|(?:([1-9][0-9]*)\$)?[-+ #0]*(?:[0-9]+)?(?:\.[0-9]+)?(hh|h|ll|l|z|t|j|q|L)?([@dDiuUxXoOfeEgGcCsSpaAF]))"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return [:]
            }

            let nsRange = NSRange(format.startIndex..<format.endIndex, in: format)
            let matches = regex.matches(in: format, range: nsRange)
            var result: [Int: String] = [:]
            var implicitPosition = 0

            for match in matches {
                if let wholeBodyRange = Range(match.range(at: 1), in: format),
                   format[wholeBodyRange] == "%" {
                    continue
                }

                let position: Int
                if match.range(at: 2).location != NSNotFound,
                   let posRange = Range(match.range(at: 2), in: format),
                   let explicitPos = Int(format[posRange]) {
                    position = explicitPos
                } else {
                    implicitPosition += 1
                    position = implicitPosition
                }

                let lengthMod: String
                if match.range(at: 3).location != NSNotFound,
                   let lenRange = Range(match.range(at: 3), in: format) {
                    lengthMod = String(format[lenRange])
                } else {
                    lengthMod = ""
                }

                guard match.range(at: 4).location != NSNotFound,
                      let convRange = Range(match.range(at: 4), in: format) else {
                    continue
                }
                let rawConv = String(format[convRange])
                let normalizedConv = (rawConv == "i") ? "d" : rawConv
                result[position] = lengthMod + normalizedConv
            }

            return result
        }
    }
}

extension SharedProcessStateTests {
    @Suite
    struct LocalizationAndExtensionTests {
        @Test
        @MainActor
        func l10nSetLanguageAndFallback() {
            defer {
                L10n.setLanguage("en")
            }

            L10n.setLanguage("de")
            #expect(L10n.languageIdentifier == "de")
            #expect(L10n.currentLocale.identifier.hasPrefix("de"))

            let untrimmedKey = "NonExistent_Localization_Key_For_Test"
            #expect(L10n.string(forKey: untrimmedKey) == untrimmedKey)
            #expect(!L10n.string("All Types").isEmpty)
            #expect(L10n.string(forKey: "Items: %d", 42).contains("42"))

            L10n.setLanguage("fr-CA")
            #expect(L10n.languageIdentifier == "en")
            #expect(L10n.currentLocale.identifier == "en")
        }

        @Test
        @MainActor
        func persistenceErrorAndStoreLockLocalizationAcrossLanguages() {
            defer {
                L10n.setLanguage("en")
            }

            let errorCases: [(label: String, error: Error, expectedSubstring: String?)] = [
                ("openFailed", HistoryStoreError.openFailed, nil),
                ("keyNotFound", HistoryStoreError.encryptionKeyUnavailable(.notFound), nil),
                ("interactionNotAllowed", HistoryStoreError.encryptionKeyUnavailable(.interactionNotAllowed), nil),
                ("userCanceled", HistoryStoreError.encryptionKeyUnavailable(.userCanceled), nil),
                ("authFailed", HistoryStoreError.encryptionKeyUnavailable(.authFailed), nil),
                ("corruptKeyData", HistoryStoreError.encryptionKeyUnavailable(.corruptKeyData), nil),
                ("unexpectedStatus", HistoryStoreError.encryptionKeyUnavailable(.unexpectedStatus(-25308)), "-25308"),
                ("encryptionKeyMismatch", HistoryStoreError.encryptionKeyMismatch, nil),
                ("authenticationFailed", HistoryStoreError.authenticationFailed, nil),
                ("invalidArchiveKeyParameters", HistoryStoreError.invalidArchiveKeyParameters, nil),
                ("migrationFailed", HistoryStoreError.migrationFailed("V4_TO_V5_TOKEN"), "V4_TO_V5_TOKEN"),
                ("unsupportedVersion", ClipBookArchiveError.unsupportedVersion(99), "99"),
                ("missingFile", ClipBookArchiveError.missingFile("manifest.json"), "manifest.json"),
                ("invalidAssetPath", ClipBookArchiveError.invalidAssetPath("../escape.png"), "../escape.png"),
                ("passphraseRequired", ClipBookArchiveError.passphraseRequired, nil),
                ("emptyPassphrase", ClipBookArchiveError.emptyPassphrase, nil),
                ("incorrectPassphrase", ClipBookArchiveError.incorrectPassphrase, nil),
                ("corruptedEncryptedArchive", ClipBookArchiveError.corruptedEncryptedArchive("tags.json.enc"), "tags.json.enc"),
                ("invalidKeyParameters", ClipBookArchiveError.invalidKeyParameters, nil)
            ]

            L10n.setLanguage("en")
            let enUnlockedTitle = PersistenceErrorLocalization.statusTitle(for: .unlocked)
            let enLockedTitle = PersistenceErrorLocalization.statusTitle(for: .locked(.interactionNotAllowed))
            let enMismatchTitle = PersistenceErrorLocalization.statusTitle(for: .keyMismatch)
            #expect(enUnlockedTitle == "History Unlocked")
            #expect(enLockedTitle == "History Locked")
            #expect(enMismatchTitle == "History Encryption Key Mismatch")
            #expect(PersistenceErrorLocalization.statusMessage(for: .unlocked).isEmpty)

            let enLockedMessage = PersistenceErrorLocalization.statusMessage(for: .locked(.interactionNotAllowed))
            let enMismatchMessage = PersistenceErrorLocalization.statusMessage(for: .keyMismatch)
            #expect(enLockedMessage.contains("Keychain is locked"))
            #expect(enLockedMessage.contains("Unlock History"))
            #expect(enMismatchMessage.contains("different key"))

            var englishMessages: [String: String] = [:]
            for testCase in errorCases {
                let msg = PersistenceErrorLocalization.message(for: testCase.error)
                #expect(!msg.isEmpty, Comment(rawValue: "en \(testCase.label)"))
                #expect(
                    msg == testCase.error.localizedDescription,
                    Comment(rawValue: "en \(testCase.label) matches errorDescription")
                )
                if let sub = testCase.expectedSubstring {
                    #expect(msg.contains(sub), Comment(rawValue: "en \(testCase.label) missing \(sub)"))
                }
                englishMessages[testCase.label] = msg
            }

            let customError = NSError(
                domain: "com.clipbook.tests",
                code: 77,
                userInfo: [NSLocalizedDescriptionKey: "Custom fallback error message"]
            )
            #expect(PersistenceErrorLocalization.message(for: customError) == "Custom fallback error message")

            L10n.setLanguage("de")
            let deUnlockedTitle = PersistenceErrorLocalization.statusTitle(for: .unlocked)
            let deLockedTitle = PersistenceErrorLocalization.statusTitle(for: .locked(.interactionNotAllowed))
            let deMismatchTitle = PersistenceErrorLocalization.statusTitle(for: .keyMismatch)
            #expect(!deUnlockedTitle.isEmpty && deUnlockedTitle != enUnlockedTitle)
            #expect(!deLockedTitle.isEmpty && deLockedTitle != enLockedTitle)
            #expect(!deMismatchTitle.isEmpty && deMismatchTitle != enMismatchTitle)
            #expect(PersistenceErrorLocalization.statusMessage(for: .unlocked).isEmpty)

            let deLockedMessage = PersistenceErrorLocalization.statusMessage(for: .locked(.interactionNotAllowed))
            let deMismatchMessage = PersistenceErrorLocalization.statusMessage(for: .keyMismatch)
            #expect(!deLockedMessage.isEmpty && deLockedMessage != enLockedMessage)
            #expect(!deMismatchMessage.isEmpty && deMismatchMessage != enMismatchMessage)

            for testCase in errorCases {
                let deMsg = PersistenceErrorLocalization.message(for: testCase.error)
                #expect(!deMsg.isEmpty, Comment(rawValue: "de \(testCase.label)"))
                #expect(deMsg != englishMessages[testCase.label], Comment(rawValue: "de \(testCase.label) did not translate"))
                if let sub = testCase.expectedSubstring {
                    #expect(deMsg.contains(sub), Comment(rawValue: "de \(testCase.label) missing \(sub)"))
                }
            }
        }

        @Test
        func workspaceApplicationLookupByName() {
            let workspace = NSWorkspace.shared

            #expect(workspace.applicationURL(named: "DefinitelyNonExistentClipBookApp_12345") == nil)

            let finderURL = workspace.applicationURL(named: "Finder")
            #expect(finderURL != nil)
            #expect(finderURL?.lastPathComponent == "Finder.app")

            let finderWithExtensionURL = workspace.applicationURL(named: "Finder.app")
            #expect(finderWithExtensionURL == finderURL)
        }

        @Test
        func osTypeFourCharCodePaddingAndTruncation() {
            #expect(OSType("CLPB") == 0x434C_5042)
            #expect(OSType("AB") == 0x4142_2020)
            #expect(OSType("A") == 0x4120_2020)
            #expect(OSType("") == 0x2020_2020)
            #expect(OSType("CLIPBOOK") == OSType("CLIP"))
            #expect(OSType("CLIPBOOK") == 0x434C_4950)
        }
    }
}
