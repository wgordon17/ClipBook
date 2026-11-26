import Darwin
import Foundation
import os

/// The terms a search query looks for in each history item.
nonisolated struct HistorySearchTerms: Equatable, Sendable {
    struct ASCIITerm: Sendable {
        let lowercasedBytes: [UInt8]
        let containsDigit: Bool
        let anchorIndex: Int
        let anchorLower: UInt8
        let anchorUpper: UInt8?
    }

    let values: [String]
    let asciiTerms: [ASCIITerm?]

    init(query: String) {
        self.init(values: query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
    }

    init(values: [String]) {
        self.values = values
        self.asciiTerms = values.map { term in
            guard !term.isEmpty,
                  term.utf8.allSatisfy({ !($0 < 0x09 || ($0 > 0x0D && $0 < 0x20) || $0 == 0x7F || $0 >= 0x80) }) else {
                return nil
            }
            var lowered: [UInt8] = []
            lowered.reserveCapacity(term.utf8.count)
            var hasDigit = false
            var nonLetterAnchorIndex: Int?
            for byte in term.utf8 {
                if byte >= 0x30 && byte <= 0x39 {
                    hasDigit = true
                }
                let lowerByte = (byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte
                if nonLetterAnchorIndex == nil, !(lowerByte >= 0x61 && lowerByte <= 0x7A) {
                    nonLetterAnchorIndex = lowered.count
                }
                lowered.append(lowerByte)
            }
            let anchorIndex = nonLetterAnchorIndex ?? 0
            let anchorLower = lowered[anchorIndex]
            let anchorUpper: UInt8? = (anchorLower >= 0x61 && anchorLower <= 0x7A) ? (anchorLower & ~0x20) : nil
            return ASCIITerm(
                lowercasedBytes: lowered,
                containsDigit: hasDigit,
                anchorIndex: anchorIndex,
                anchorLower: anchorLower,
                anchorUpper: anchorUpper
            )
        }
    }

    var isEmpty: Bool {
        values.isEmpty
    }

    static func == (lhs: HistorySearchTerms, rhs: HistorySearchTerms) -> Bool {
        lhs.values == rhs.values
    }
}

/// Checks whether an item's search text contains every term of a search query.
nonisolated enum HistorySearchMatcher {
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static let enUSLocale = Locale(identifier: "en_US")
    private static let asciiContractionDigraphs: [(digraph: String, prefix: String)] = [
        ("aa", "a"), ("ch", "c"), ("cs", "c"), ("dz", "d"), ("gy", "g"), ("lj", "l"),
        ("ll", "l"), ("ly", "l"), ("nj", "n"), ("ny", "n"), ("rr", "r"), ("sh", "s"),
        ("sz", "s"), ("th", "t"), ("ty", "t"), ("xh", "x"), ("zh", "z"), ("zs", "z")
    ]

    private struct FoldTables: Sendable {
        let digits: [UInt64]
        let letters: [UInt64]
    }

    // Bitmap lookup tables over all Unicode scalar values (0...0x10FFFF) for
    // scalars that Foundation's case- and diacritic-insensitive search can
    // equate with ASCII digits or ASCII letters/punctuation, or ignore inside
    // an ASCII match.
    private static let foldTables: FoldTables = {
        let wordCount = (0x110000 + 63) / 64
        var digits = [UInt64](repeating: 0, count: wordCount)
        var letters = [UInt64](repeating: 0, count: wordCount)

        let chunkWords = 64
        let chunkCount = (wordCount + chunkWords - 1) / chunkWords

        digits.withUnsafeMutableBufferPointer { digitsBuffer in
            letters.withUnsafeMutableBufferPointer { lettersBuffer in
                nonisolated(unsafe) let digitsPtr = digitsBuffer.baseAddress!
                nonisolated(unsafe) let lettersPtr = lettersBuffer.baseAddress!

                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let startWord = chunk * chunkWords
                    let endWord = min(startWord + chunkWords, wordCount)
                    for wordIndex in startWord..<endWord {
                        var digitMask: UInt64 = 0
                        var letterMask: UInt64 = 0
                        let baseScalar = UInt32(wordIndex * 64)
                        for bit in 0..<64 {
                            let value = baseScalar + UInt32(bit)
                            guard value <= 0x10FFFF,
                                  let scalar = Unicode.Scalar(value) else {
                                continue
                            }
                            let properties = scalar.properties
                            if value >= 0x80, properties.numericType != nil {
                                digitMask |= (UInt64(1) << bit)
                            }
                            if Self.computesFoldsToASCIILetters(scalar, properties: properties) {
                                letterMask |= (UInt64(1) << bit)
                            }
                        }
                        digitsPtr[wordIndex] = digitMask
                        lettersPtr[wordIndex] = letterMask
                    }
                }
            }
        }

        return FoldTables(digits: digits, letters: letters)
    }()

    private static let localeAllowsPrefilterCache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    private static func computesFoldsToASCIILetters(
        _ scalar: Unicode.Scalar,
        properties: Unicode.Scalar.Properties
    ) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return value < 0x09 || (value > 0x0D && value < 0x20) || value == 0x7F
        }
        switch value {
        case 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3FFFF:
            return false
        default:
            break
        }

        let categoryAllowed: Bool
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .format, .control,
             .modifierLetter, .modifierSymbol, .otherLetter, .mathSymbol:
            categoryAllowed = true
        default:
            categoryAllowed = false
        }
        guard properties.isCased
            || properties.changesWhenNFKCCaseFolded
            || properties.isDefaultIgnorableCodePoint
            || categoryAllowed else {
            return false
        }

        if properties.lowercaseMapping.utf8.contains(where: { $0 < 0x80 })
            || properties.uppercaseMapping.utf8.contains(where: { $0 < 0x80 })
            || properties.titlecaseMapping.utf8.contains(where: { $0 < 0x80 }) {
            return true
        }
        let string = String(scalar)
        if string.folding(options: Self.compareOptions, locale: nil).utf8.contains(where: { $0 < 0x80 }) {
            return true
        }
        if properties.changesWhenNFKCCaseFolded
            && string.decomposedStringWithCompatibilityMapping.utf8.contains(where: { $0 < 0x80 }) {
            return true
        }
        if string.compare("a", options: Self.compareOptions, locale: enUSLocale) != .orderedAscending
            && string.compare("zzzzzzzz", options: Self.compareOptions, locale: enUSLocale) != .orderedDescending {
            return true
        }
        if "a\(scalar)b".range(of: "ab", options: Self.compareOptions, range: nil, locale: enUSLocale) != nil {
            return true
        }
        return false
    }

    static func warmUp() {
        _ = foldTables
    }

    static func foldsToASCIIDigits(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard value >= 0x80, value <= 0x10FFFF else {
            return false
        }
        let wordIndex = Int(value >> 6)
        let bit = UInt64(1) << (value & 63)
        return (foldTables.digits[wordIndex] & bit) != 0
    }

    static func foldsToASCIILetters(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard value <= 0x10FFFF else {
            return false
        }
        let wordIndex = Int(value >> 6)
        let bit = UInt64(1) << (value & 63)
        return (foldTables.letters[wordIndex] & bit) != 0
    }

    static func allowsASCIIPrefilter(for locale: Locale) -> Bool {
        let identifier = locale.identifier
        if let cached = localeAllowsPrefilterCache.withLock({ $0[identifier] }) {
            return cached
        }
        let allowed = "I".range(of: "i", options: Self.compareOptions, range: nil, locale: locale) != nil
            && "i".range(of: "I", options: Self.compareOptions, range: nil, locale: locale) != nil
            && asciiContractionDigraphs.allSatisfy { digraph, prefix in
                digraph.range(of: prefix, options: Self.compareOptions, range: nil, locale: locale) != nil
            }
        localeAllowsPrefilterCache.withLock { $0[identifier] = allowed }
        return allowed
    }

    @inline(__always)
    private static func isPrintableASCIIWord(_ word: UInt64) -> Bool {
        ((word | (word &+ 0x0101_0101_0101_0101) | (word &- 0x2020_2020_2020_2020)) & 0x8080_8080_8080_8080) == 0
    }

    @inline(__always)
    private static func isAllowedASCIIByte(_ byte: UInt8) -> Bool {
        !(byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F || byte >= 0x80)
    }

    @inline(__always)
    private static func areAllAllowedASCIIBytes(in word: UInt64) -> Bool {
        if isPrintableASCIIWord(word) {
            return true
        }
        var remaining = word
        for _ in 0..<8 {
            if !isAllowedASCIIByte(UInt8(truncatingIfNeeded: remaining)) {
                return false
            }
            remaining >>= 8
        }
        return true
    }

    static func isAllASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = bytes.count
        guard count > 0, let base = bytes.baseAddress else {
            return true
        }
        var offset = 0
        let misalign = Int(bitPattern: base) & 7
        if misalign != 0 {
            let lead = min(count, 8 &- misalign)
            while offset < lead {
                if !isAllowedASCIIByte(base[offset]) {
                    return false
                }
                offset &+= 1
            }
        }
        let wordCount = (count &- offset) >> 3
        if wordCount > 0 {
            let alignedByteBase = base.advanced(by: offset)
            let ok = alignedByteBase.withMemoryRebound(to: UInt64.self, capacity: wordCount) { words -> Bool in
                var wordIndex = 0
                let stride4Limit = wordCount &- 4
                while wordIndex <= stride4Limit {
                    let w0 = words[wordIndex]
                    let w1 = words[wordIndex &+ 1]
                    let w2 = words[wordIndex &+ 2]
                    let w3 = words[wordIndex &+ 3]
                    let combined = (w0 | (w0 &+ 0x0101_0101_0101_0101) | (w0 &- 0x2020_2020_2020_2020))
                        | (w1 | (w1 &+ 0x0101_0101_0101_0101) | (w1 &- 0x2020_2020_2020_2020))
                        | (w2 | (w2 &+ 0x0101_0101_0101_0101) | (w2 &- 0x2020_2020_2020_2020))
                        | (w3 | (w3 &+ 0x0101_0101_0101_0101) | (w3 &- 0x2020_2020_2020_2020))
                    if (combined & 0x8080_8080_8080_8080) != 0 {
                        if !areAllAllowedASCIIBytes(in: w0)
                            || !areAllAllowedASCIIBytes(in: w1)
                            || !areAllAllowedASCIIBytes(in: w2)
                            || !areAllAllowedASCIIBytes(in: w3) {
                            return false
                        }
                    }
                    wordIndex &+= 4
                }
                while wordIndex < wordCount {
                    if !areAllAllowedASCIIBytes(in: words[wordIndex]) {
                        return false
                    }
                    wordIndex &+= 1
                }
                return true
            }
            if !ok {
                return false
            }
            offset &+= wordCount << 3
        }
        while offset < count {
            if !isAllowedASCIIByte(base[offset]) {
                return false
            }
            offset &+= 1
        }
        return true
    }

    private static func containsASCIICaseInsensitive(
        haystack: UnsafeBufferPointer<UInt8>,
        term: HistorySearchTerms.ASCIITerm
    ) -> Bool {
        let haystackCount = haystack.count
        let needle = term.lowercasedBytes
        let needleCount = needle.count
        guard needleCount > 0, haystackCount >= needleCount, let haystackBase = haystack.baseAddress else {
            return needleCount == 0
        }

        let anchorIndex = term.anchorIndex
        let anchorLower = Int32(term.anchorLower)
        let anchorUpper = term.anchorUpper.map(Int32.init)
        let windowEndOffset = haystackCount &- (needleCount &- anchorIndex)
        var searchOffset = anchorIndex
        // Next known position of each anchor case at or after searchOffset; -1 means
        // not yet searched and Int.max means absent from the rest of the haystack.
        // Remembering both keeps the scan linear when one case is rare or missing.
        var nextLowerOffset = -1
        var nextUpperOffset = anchorUpper == nil ? Int.max : -1

        return needle.withUnsafeBufferPointer { needleBuffer in
            guard let needleBase = needleBuffer.baseAddress else {
                return false
            }
            let rawBase = UnsafeRawPointer(haystackBase)
            while searchOffset <= windowEndOffset {
                let remaining = windowEndOffset &- searchOffset &+ 1
                let curPtr = rawBase.advanced(by: searchOffset)
                if nextLowerOffset < searchOffset {
                    nextLowerOffset = Darwin.memchr(curPtr, anchorLower, remaining)
                        .map { UnsafeRawPointer($0) - rawBase } ?? Int.max
                }
                if let anchorUpper, nextUpperOffset < searchOffset {
                    nextUpperOffset = Darwin.memchr(curPtr, anchorUpper, remaining)
                        .map { UnsafeRawPointer($0) - rawBase } ?? Int.max
                }
                let matchedAnchorOffset = min(nextLowerOffset, nextUpperOffset)
                if matchedAnchorOffset == Int.max {
                    return false
                }
                if needleCount == 1 {
                    return true
                }
                let candidateStart = matchedAnchorOffset &- anchorIndex
                var matched = true
                var i = 0
                while i < needleCount {
                    if i != anchorIndex {
                        let b = haystackBase[candidateStart &+ i]
                        let lowered = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
                        if lowered != needleBase[i] {
                            matched = false
                            break
                        }
                    }
                    i &+= 1
                }
                if matched {
                    return true
                }
                searchOffset = matchedAnchorOffset &+ 1
            }
            return false
        }
    }

    static func matches(
        _ text: String,
        _ terms: HistorySearchTerms,
        locale: Locale = .current,
        allowsPrefilter: Bool? = nil,
        knownAllASCII: Bool? = nil
    ) -> Bool {
        var ignoredASCII = false
        return matchesRecordingASCII(
            text,
            terms,
            locale: locale,
            allowsPrefilter: allowsPrefilter,
            knownAllASCII: knownAllASCII,
            isAllASCIIOut: &ignoredASCII
        )
    }

    static func matchesRecordingASCII(
        _ text: String,
        _ terms: HistorySearchTerms,
        locale: Locale = .current,
        allowsPrefilter: Bool? = nil,
        knownAllASCII: Bool? = nil,
        isAllASCIIOut: inout Bool
    ) -> Bool {
        let values = terms.values
        guard !values.isEmpty else {
            isAllASCIIOut = knownAllASCII ?? false
            return true
        }

        let canUsePrefilter = allowsPrefilter ?? allowsASCIIPrefilter(for: locale)
        guard canUsePrefilter else {
            isAllASCIIOut = knownAllASCII ?? false
            for term in values {
                if text.range(of: term, options: Self.compareOptions, range: nil, locale: locale) == nil {
                    return false
                }
            }
            return true
        }

        let original = text
        var contiguous = text
        return contiguous.withUTF8 { haystack in
            let asciiHaystack = knownAllASCII ?? isAllASCII(haystack)
            isAllASCIIOut = asciiHaystack
            var scannedScalars = false
            var hasFoldLetters = false
            var hasFoldDigits = false

            let asciiTerms = terms.asciiTerms
            for index in values.indices {
                let term = values[index]
                guard let asciiTerm = asciiTerms[index] else {
                    if original.range(of: term, options: Self.compareOptions, range: nil, locale: locale) == nil {
                        return false
                    }
                    continue
                }

                let foundBytes = containsASCIICaseInsensitive(
                    haystack: haystack,
                    term: asciiTerm
                )
                if asciiHaystack {
                    if !foundBytes {
                        return false
                    }
                    continue
                }

                if !foundBytes {
                    // On non-ASCII text, Foundation switches to ICU collation search
                    // when a multi-character needle contains an ASCII digit, so only
                    // single-digit or digit-free ASCII needles can be rejected by the
                    // scalar fold tables alone.
                    if !(asciiTerm.containsDigit && asciiTerm.lowercasedBytes.count > 1) {
                        if !scannedScalars {
                            scannedScalars = true
                            let digitsTable = foldTables.digits
                            let lettersTable = foldTables.letters
                            for scalar in original.unicodeScalars {
                                let value = scalar.value
                                let wordIndex = Int(value >> 6)
                                let bit = UInt64(1) << (value & 63)
                                if (lettersTable[wordIndex] & bit) != 0 {
                                    hasFoldLetters = true
                                }
                                if (digitsTable[wordIndex] & bit) != 0 {
                                    hasFoldDigits = true
                                }
                                if hasFoldLetters && hasFoldDigits {
                                    break
                                }
                            }
                        }
                        let canFoldToTerm = hasFoldLetters || (asciiTerm.containsDigit && hasFoldDigits)
                        if !canFoldToTerm {
                            return false
                        }
                    }
                }

                if original.range(of: term, options: Self.compareOptions, range: nil, locale: locale) == nil {
                    return false
                }
            }
            return true
        }
    }
}
