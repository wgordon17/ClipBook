import AppKit
import Foundation
import os

/// Snapshot of the sorted listed items' identifiers and search texts for a
/// single list revision, shared with background search jobs.
nonisolated final class HistorySearchCorpus: Sendable {
    let revision: Int
    let ids: [UUID]
    let revisions: [UInt64]
    let texts: [String]
    let tagNamesByID: [Tag.ID: String]
    let hasCompleteTexts: Bool
    private static let cancellationPollMask = 4_095
    fileprivate let cachedIndexByID = OSAllocatedUnfairLock<[UUID: Int]?>(initialState: nil)

    init(
        revision: Int,
        ids: [UUID],
        revisions: [UInt64] = [],
        texts: [String],
        tagNamesByID: [Tag.ID: String] = [:],
        hasCompleteTexts: Bool = true
    ) {
        self.revision = revision
        self.ids = ids
        self.revisions = revisions.count == ids.count
            ? revisions
            : Array(repeating: 0, count: ids.count)
        self.texts = texts
        self.tagNamesByID = tagNamesByID
        self.hasCompleteTexts = hasCompleteTexts
    }

    func indexByID() -> [UUID: Int] {
        if let cached = cachedIndexByID.withLock({ $0 }) {
            return cached
        }
        var built = [UUID: Int](minimumCapacity: ids.count)
        for (index, id) in ids.enumerated() {
            built[id] = index
        }
        let indexByID = built
        return cachedIndexByID.withLock { state in
            if let existing = state {
                return existing
            }
            state = indexByID
            return indexByID
        }
    }

    func reusableText(for item: ClipboardItem, tagNamesByID: [Tag.ID: String]) -> String? {
        guard hasCompleteTexts,
              item.searchRevision != 0,
              let index = indexByID()[item.id],
              index < revisions.count,
              index < texts.count,
              revisions[index] == item.searchRevision,
              item.tags.isEmpty || item.tags.allSatisfy({ self.tagNamesByID[$0] == tagNamesByID[$0] }) else {
            return nil
        }
        return texts[index]
    }

    static func resolve(
        _ descriptor: AppModel.SearchCorpusDescriptor,
        previousCorpus: HistorySearchCorpus? = nil,
        fetchSearchTexts: ((_ ids: [UUID], _ trashed: Bool, _ tagNamesByID: [Tag.ID: String], _ isCancelled: () -> Bool) throws -> [String?]?)?,
        isCancelled: () -> Bool = { false }
    ) -> HistorySearchCorpus? {
        if isCancelled() {
            return nil
        }
        if let cached = descriptor.cachedCorpus {
            return cached
        }
        if let previousCorpus,
           previousCorpus.revision == descriptor.revision,
           previousCorpus.hasCompleteTexts {
            return previousCorpus
        }

        let count = descriptor.headers.count
        if count == 0 {
            return HistorySearchCorpus(
                revision: descriptor.revision,
                ids: [],
                revisions: [],
                texts: [],
                tagNamesByID: descriptor.tagNamesByID,
                hasCompleteTexts: true
            )
        }

        let primaryDonor = previousCorpus
        let secondaryDonor = (descriptor.donorCorpus === previousCorpus) ? nil : descriptor.donorCorpus
        if primaryDonor?.hasCompleteTexts == true {
            _ = primaryDonor?.indexByID()
        }
        if secondaryDonor?.hasCompleteTexts == true {
            _ = secondaryDonor?.indexByID()
        }

        var ids = [UUID](repeating: UUID(), count: count)
        var revisions = [UInt64](repeating: 0, count: count)
        var texts = [String](repeating: "", count: count)
        var missingSlots: [(slotIndex: Int, id: UUID)] = []

        let headers = descriptor.headers
        let tagNamesByID = descriptor.tagNamesByID
        headers.withUnsafeBufferPointer { buffer in
            for i in 0..<count {
                if (i & cancellationPollMask) == 0, isCancelled() {
                    return
                }
                let header = buffer[i]
                ids[i] = header.id
                if header.isContentLoaded {
                    texts[i] = header.searchText
                    revisions[i] = header.searchRevision
                } else if let reused = primaryDonor?.reusableText(for: header, tagNamesByID: tagNamesByID)
                            ?? secondaryDonor?.reusableText(for: header, tagNamesByID: tagNamesByID) {
                    texts[i] = reused
                    revisions[i] = header.searchRevision
                } else {
                    missingSlots.append((slotIndex: i, id: header.id))
                }
            }
        }

        if isCancelled() {
            return nil
        }

        if missingSlots.isEmpty {
            return HistorySearchCorpus(
                revision: descriptor.revision,
                ids: ids,
                revisions: revisions,
                texts: texts,
                tagNamesByID: tagNamesByID,
                hasCompleteTexts: true
            )
        }

        let fetched = fetchSearchTexts.flatMap { fetch in
            try? fetch(missingSlots.map(\.id), descriptor.isTrashed, tagNamesByID, isCancelled)
        }
        if fetched == nil, isCancelled() {
            return nil
        }

        var usedFallback = false
        headers.withUnsafeBufferPointer { buffer in
            for (offset, slot) in missingSlots.enumerated() {
                if (offset & cancellationPollMask) == 0, isCancelled() {
                    return
                }
                let header = buffer[slot.slotIndex]
                if let fetched, offset < fetched.count, let fetchedText = fetched[offset] {
                    texts[slot.slotIndex] = fetchedText
                    revisions[slot.slotIndex] = header.searchRevision
                } else {
                    usedFallback = true
                    texts[slot.slotIndex] = header.headerFallbackSearchText(tagNamesByID: tagNamesByID)
                    revisions[slot.slotIndex] = 0
                }
            }
        }

        if isCancelled() {
            return nil
        }

        return HistorySearchCorpus(
            revision: descriptor.revision,
            ids: ids,
            revisions: revisions,
            texts: texts,
            tagNamesByID: tagNamesByID,
            hasCompleteTexts: fetched != nil && !usedFallback
        )
    }
}

/// The outcome of matching a `HistorySearchCorpus` against `HistorySearchTerms`.
nonisolated struct HistorySearchResult: Sendable {
    let terms: HistorySearchTerms
    let revision: Int
    let corpus: HistorySearchCorpus
    let matches: [Bool]
    let indexByID: [UUID: Int]
    let matchCount: Int
    let locale: Locale

    init(
        terms: HistorySearchTerms,
        revision: Int,
        corpus: HistorySearchCorpus,
        matches: [Bool],
        indexByID: [UUID: Int],
        matchCount: Int? = nil,
        locale: Locale = .current
    ) {
        self.terms = terms
        self.revision = revision
        self.corpus = corpus
        self.matches = matches
        self.indexByID = indexByID
        self.matchCount = matchCount ?? matches.reduce(0) { $0 + ($1 ? 1 : 0) }
        self.locale = locale
    }
}

/// Runs a cancellable parallel search over a `HistorySearchCorpus`.
nonisolated final class HistorySearchJob: Sendable {
    private static let didWarmUpFontCascade = OSAllocatedUnfairLock(initialState: false)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init() {}

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    private static func isStrictASCIIPrefixRefinement(
        terms: HistorySearchTerms,
        of previousTerms: HistorySearchTerms
    ) -> Bool {
        guard !previousTerms.values.isEmpty,
              terms.values.count >= previousTerms.values.count else {
            return false
        }
        for prevIndex in previousTerms.values.indices {
            guard let prevASCII = previousTerms.asciiTerms[prevIndex],
                  !prevASCII.containsDigit else {
                return false
            }
            var matchedPrefix = false
            for currIndex in terms.values.indices {
                if let currASCII = terms.asciiTerms[currIndex],
                   !currASCII.containsDigit,
                   currASCII.lowercasedBytes.starts(with: prevASCII.lowercasedBytes) {
                    matchedPrefix = true
                    break
                }
            }
            if !matchedPrefix {
                return false
            }
        }
        return true
    }

    // Warming CoreText's font fallback cascade on the background search queue
    // prevents a first-draw main-thread stall when laying out non-ASCII rows.
    private func warmUpFontCascadeIfNeeded(
        texts: [String],
        matches: [Bool],
        terms: HistorySearchTerms
    ) -> Bool {
        let hasNonASCIITerm = terms.asciiTerms.contains(where: { $0 == nil })
        let isFirstWarmUp = Self.didWarmUpFontCascade.withLock {
            let was = $0
            $0 = true
            return !was
        }
        guard isFirstWarmUp || hasNonASCIITerm else {
            return true
        }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 0.5, weight: .regular)
        var warmed = 0
        for index in matches.indices where matches[index] {
            if isCancelled {
                return false
            }
            if texts[index].utf8.count > 400, !texts[index].utf8.allSatisfy({ $0 < 0x80 }) {
                let prefix = String(texts[index].prefix(600)).replacingOccurrences(of: "\n", with: " \u{23CE} ")
                let sample = NSAttributedString(
                    string: prefix,
                    attributes: [.font: font]
                )
                _ = sample.boundingRect(
                    with: NSSize(width: 500, height: 40),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                warmed += 1
                if warmed >= 6 {
                    break
                }
            }
        }
        return !isCancelled
    }

    func run(
        corpus: HistorySearchCorpus,
        terms: HistorySearchTerms,
        locale: Locale,
        previous: HistorySearchResult? = nil
    ) -> HistorySearchResult? {
        guard !isCancelled else {
            return nil
        }

        HistorySearchMatcher.warmUp()

        let allowsPrefilter = HistorySearchMatcher.allowsASCIIPrefilter(for: locale)
        let count = corpus.texts.count
        var matches = [Bool](repeating: false, count: count)
        var matchCount = 0
        let previousMatches: [Bool]? = (
            previous?.corpus === corpus
                && previous?.locale == locale
                && allowsPrefilter
                && previous.map { Self.isStrictASCIIPrefixRefinement(terms: terms, of: $0.terms) } == true
        ) ? previous?.matches : nil

        if count > 0 {
            let chunkCount = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
            let chunkSize = (count + chunkCount - 1) / chunkCount
            let texts = corpus.texts
            let checkStride = count <= 512 ? 1 : 64
            var chunkCounts = [Int](repeating: 0, count: chunkCount)

            matches.withUnsafeMutableBufferPointer { buffer in
                chunkCounts.withUnsafeMutableBufferPointer { countsBuffer in
                    nonisolated(unsafe) let buffer = buffer
                    nonisolated(unsafe) let countsBuffer = countsBuffer
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                        guard !self.isCancelled else {
                            return
                        }
                        let start = chunk * chunkSize
                        let end = min(start + chunkSize, count)
                        guard start < end else {
                            return
                        }
                        var localMatchCount = 0
                        if let previousMatches {
                            for index in start..<end {
                                if (index - start) % checkStride == 0, self.isCancelled {
                                    return
                                }
                                if !previousMatches[index],
                                   texts[index].utf8.allSatisfy({ $0 < 0x80 }) {
                                    continue
                                }
                                let matched = HistorySearchMatcher.matches(
                                    texts[index],
                                    terms,
                                    locale: locale,
                                    allowsPrefilter: allowsPrefilter
                                )
                                buffer[index] = matched
                                if matched {
                                    localMatchCount += 1
                                }
                            }
                        } else {
                            for index in start..<end {
                                if (index - start) % checkStride == 0, self.isCancelled {
                                    return
                                }
                                let matched = HistorySearchMatcher.matches(
                                    texts[index],
                                    terms,
                                    locale: locale,
                                    allowsPrefilter: allowsPrefilter
                                )
                                buffer[index] = matched
                                if matched {
                                    localMatchCount += 1
                                }
                            }
                        }
                        countsBuffer[chunk] = localMatchCount
                    }
                }
            }
            guard !isCancelled else {
                return nil
            }
            matchCount = chunkCounts.reduce(0, +)
            if matchCount > 0, !warmUpFontCascadeIfNeeded(texts: texts, matches: matches, terms: terms) {
                return nil
            }
        }

        guard !isCancelled else {
            return nil
        }

        let indexByID: [UUID: Int]
        if let previous, previous.corpus === corpus {
            indexByID = previous.indexByID
            corpus.cachedIndexByID.withLock {
                if $0 == nil {
                    $0 = indexByID
                }
            }
        } else if let cached = corpus.cachedIndexByID.withLock({ $0 }) {
            indexByID = cached
        } else {
            var built = [UUID: Int](minimumCapacity: corpus.ids.count)
            for (index, id) in corpus.ids.enumerated() {
                if index & 4095 == 0, isCancelled {
                    return nil
                }
                built[id] = index
            }
            indexByID = built
            corpus.cachedIndexByID.withLock { $0 = indexByID }
        }

        guard !isCancelled else {
            return nil
        }

        return HistorySearchResult(
            terms: terms,
            revision: corpus.revision,
            corpus: corpus,
            matches: matches,
            indexByID: indexByID,
            matchCount: matchCount,
            locale: locale
        )
    }
}
