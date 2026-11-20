import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class PasteboardMonitor {
    static let ghostType = PasteboardReader.ghostType

    private enum PendingRecognitionSource {
        case pngData(Data)
        case imageFile(URL)
    }

    weak var delegate: PasteboardMonitorDelegate?
    // Pausing or resuming skips whatever was copied while capture was paused:
    // the change count moves up to the pasteboard's, a deferred re-read of an
    // earlier change is dropped, and a read already in flight is abandoned,
    // since it may be looking at content copied after the switch.
    var isPaused = false {
        didSet {
            if isPaused != oldValue {
                lastChangeCount = pasteboard.changeCount
                deferredReadAttemptsRemaining = 0
                readGeneration += 1
            }
        }
    }

    private let pasteboard: NSPasteboard
    private let now: @Sendable () -> Date
    private let historyStore: HistoryStore
    private let fileManager: FileManager
    private var timer: Timer?
    private var lastChangeCount: Int
    private var preferences = AppPreferences() {
        didSet {
            if preferences.ignoredAppsText != oldValue.ignoredAppsText {
                ignoredApplicationEntries = preferences.ignoredApplicationEntries
            }
        }
    }
    // Parsed from the setting when it changes rather than on every poll, ten
    // times a second.
    private var ignoredApplicationEntries = AppPreferences().ignoredApplicationEntries
    private var lastCopySequencePasteTime = Date.distantPast
    private var pendingCopyAndMergeItem: ClipboardItem?
    private var pendingCopyAndMergeDeadline = Date.distantPast
    private let checkPasteboardInterval: TimeInterval = 0.1
    private let copySequenceThreshold: TimeInterval = 30
    private let copyAndMergeHoldInterval: TimeInterval = 0.5
    // Chromium-based apps (Slack, Chrome, etc.) clear the pasteboard first, which bumps
    // changeCount, and write the actual data slightly later without bumping it again.
    // When a pasteboard change yields no readable content, keep re-reading it for a
    // short period instead of skipping the change permanently.
    private let maxDeferredReadAttempts = 30
    private var deferredReadAttemptsRemaining = 0
    // The pasteboard is read on a queue of its own: a read waits for the
    // application that owns the pasteboard for as long as it takes to hand its
    // data over, and the main thread must stay free in the meantime. Reads run
    // one at a time, so a poll that finds one still running starts no other.
    private let readQueue = DispatchQueue(label: "com.ikryanov.clipbook.v2.pasteboard-reader", qos: .userInitiated)
    // Reading the text of an image can take seconds, and much longer the first
    // time after launch. It has a queue of its own so the pasteboard is read
    // meanwhile; a read that waited for it missed the copies made in between.
    private let textRecognitionQueue = DispatchQueue(label: "com.ikryanov.clipbook.v2.image-text", qos: .utility)
    private var pendingRecognitionsByItemID: [ClipboardItem.ID: PendingRecognitionSource] = [:]
    private var pendingPNGDataByItemID: [ClipboardItem.ID: Data] = [:]
    private var inFlightImageRecognitionIDs: Set<ClipboardItem.ID> = []
    private var isReadInFlight = false
    // A read that was started before the monitor was stopped belongs to no
    // one when it finishes, and its result is dropped.
    private var readGeneration = 0
    private var recognitionGeneration: UInt64 = 0
    nonisolated private let computeImageDigest: @Sendable (Data) -> String
    nonisolated private let findStoredImage: @Sendable (String) -> StoredImage?
    nonisolated private let recognizeImageData: @Sendable (Data) -> RecognizedImageContent
    nonisolated private let recognizeImageFile: @Sendable (URL) -> RecognizedImageContent

    nonisolated private static func makeImageDigestCallback(store: HistoryStore) -> @Sendable (Data) -> String {
        { data in
            store.computeImageDigest(forPNGData: data)
        }
    }

    nonisolated private static func makeFindStoredImageCallback(store: HistoryStore) -> @Sendable (String) -> StoredImage? {
        { digest in
            guard let item = try? store.fetchItem(kind: .image, contentKey: digest),
                  let assetPath = item.assetPath else {
                return nil
            }

            return StoredImage(
                assetPath: assetPath,
                recognizedContent: RecognizedImageContent(text: item.text, qrCodeText: item.qrCodeText)
            )
        }
    }

    init(
        historyStore: HistoryStore,
        fileManager: FileManager,
        supportDirectory _: URL,
        pasteboard: NSPasteboard = .general,
        now: @escaping @Sendable () -> Date = { Date() },
        recognizeImageData: @escaping @Sendable (Data) -> RecognizedImageContent = ImageTextRecognizer.recognizeContent(ofPNGData:),
        recognizeImageFile: @escaping @Sendable (URL) -> RecognizedImageContent = ImageTextRecognizer.recognizeContent(ofImageAt:)
    ) {
        self.historyStore = historyStore
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.now = now
        self.recognizeImageData = recognizeImageData
        self.recognizeImageFile = recognizeImageFile
        computeImageDigest = Self.makeImageDigestCallback(store: historyStore)
        findStoredImage = Self.makeFindStoredImageCallback(store: historyStore)
        lastChangeCount = pasteboard.changeCount
    }

    func isImageRecognitionPending(for id: ClipboardItem.ID) -> Bool {
        inFlightImageRecognitionIDs.contains(id)
    }

    func resumePendingImageRecognitions(for items: [ClipboardItem]) {
        for item in items where item.kind == .image
            && item.hasUnverifiedEncryptedImageAsset
            && !SensitiveContent.shouldEncryptAtRest(item)
            && !item.hasRecognizedText
            && !item.hasQRCodeText
            && !inFlightImageRecognitionIDs.contains(item.id) {
            guard let assetURL = item.assetURL,
                  let pngData = try? ImageAssetStore.readAssetData(
                      at: assetURL,
                      role: .image,
                      ownerClipID: item.id,
                      requiresEncryption: true
                  ) else {
                continue
            }
            inFlightImageRecognitionIDs.insert(item.id)
            recognizeText(ofPNGData: pngData, inItemWithID: item.id)
        }
    }

    func start(preferences: AppPreferences) {
        self.preferences = preferences
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkPasteboardInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        readGeneration += 1
        recognitionGeneration &+= 1
        if let pendingID = pendingCopyAndMergeItem?.id {
            discardPendingCaptureResources(for: pendingID)
        }
        clearPendingCopyAndMergeItem()
        pendingPNGDataByItemID.removeAll()
        pendingRecognitionsByItemID.removeAll()
        inFlightImageRecognitionIDs.removeAll()
    }

    func updatePreferences(_ preferences: AppPreferences) {
        if !preferences.copyAndMergeEnabled {
            if let pendingID = pendingCopyAndMergeItem?.id {
                discardPendingCaptureResources(for: pendingID)
            }
            clearPendingCopyAndMergeItem()
        }
        self.preferences = preferences
    }

    func markCopySequencePasteBoundary() {
        lastCopySequencePasteTime = now()
    }

    #if DEBUG
    func processReadResultForTesting(_ result: PasteboardReadResult) {
        finishRead(result, generation: readGeneration)
    }
    #endif

    /// One timer tick. Internal so tests can drive a poll without the timer;
    /// awaiting the returned task waits for the read to finish.
    @discardableResult
    func poll() -> Task<Void, Never>? {
        guard !isPaused else {
            return nil
        }

        guard !isReadInFlight else {
            // The read is waiting for the application that owns the pasteboard.
            // An item held for Copy & Merge still goes to the history on time.
            flushPendingCopyAndMergeItemIfExpiredLoggingFailure()
            return nil
        }

        isReadInFlight = true
        let request = PasteboardReadRequest(
            lastChangeCount: lastChangeCount,
            retriesUnchangedPasteboard: deferredReadAttemptsRemaining > 0,
            ignoresTransientContent: preferences.ignoreTransientContent,
            ignoresConcealedContent: preferences.confidentialContentLifetime == ContentLifetime.dontSave,
            ignoredApplicationEntries: ignoredApplicationEntries,
            computeImageDigest: computeImageDigest,
            findStoredImage: findStoredImage
        )
        let generation = readGeneration
        let readQueue = readQueue
        nonisolated(unsafe) let pasteboard = self.pasteboard
        return Task { [weak self] in
            let result = await withCheckedContinuation { continuation in
                readQueue.async {
                    continuation.resume(returning: PasteboardReader.read(request, from: pasteboard))
                }
            }
            self?.finishRead(result, generation: generation)
        }
    }

    private func finishRead(_ result: PasteboardReadResult, generation: Int) {
        isReadInFlight = false
        guard generation == readGeneration else {
            return
        }

        let item = capturedItem(from: result)
        if preferences.copyAndMergeEnabled {
            do {
                try handleCopyAndMerge(item)
            } catch {
                if let pendingID = pendingCopyAndMergeItem?.id {
                    discardPendingCaptureResources(for: pendingID)
                }
                if let itemID = item?.id {
                    discardPendingCaptureResources(for: itemID)
                }
                clearPendingCopyAndMergeItem()
                NSLog("ClipBook history write failed: \(error.localizedDescription)")
            }
        } else if let item {
            do {
                try capture(item)
            } catch {
                discardPendingCaptureResources(for: item.id)
                NSLog("ClipBook history write failed: \(error.localizedDescription)")
            }
        }
    }

    private func discardPendingCaptureResources(for id: ClipboardItem.ID) {
        pendingPNGDataByItemID.removeValue(forKey: id)
        pendingRecognitionsByItemID.removeValue(forKey: id)
    }

    private func capturedItem(from result: PasteboardReadResult) -> ClipboardItem? {
        if case .unchanged = result.outcome {
            return nil
        }

        let isNewChange = result.changeCount != lastChangeCount
        if isNewChange {
            lastChangeCount = result.changeCount
            deferredReadAttemptsRemaining = 0
        }

        switch result.outcome {
        case .unchanged:
            return nil
        case .skipped:
            deferredReadAttemptsRemaining = 0
            return nil
        case .empty:
            if isNewChange {
                // The writer may still be filling the pasteboard. Retry on subsequent polls.
                deferredReadAttemptsRemaining = maxDeferredReadAttempts
            } else if deferredReadAttemptsRemaining > 0 {
                deferredReadAttemptsRemaining -= 1
            }
            return nil
        case .content(let content):
            deferredReadAttemptsRemaining = 0
            var pendingPNGData: Data?
            var pendingRecognition: PendingRecognitionSource?
            switch content.payload {
            case .image(_, let pngData, _, _, _, _, _, _, let reusesStoredFile):
                // An image already in the history comes with the text read from it.
                if !reusesStoredFile, let pngData {
                    pendingPNGData = pngData
                    pendingRecognition = .pngData(pngData)
                }
            case .files(let paths, _, _):
                if paths.count == 1, let path = paths.first, ClipboardItem.isImageFile(at: path) {
                    pendingRecognition = .imageFile(URL(fileURLWithPath: path))
                }
            case .richText, .text:
                break
            }
            guard let item = capturableItem(
                makeItem(from: content),
                isConcealed: content.isConcealed
            ) else {
                return nil
            }

            if let pendingPNGData {
                pendingPNGDataByItemID[item.id] = pendingPNGData
            }
            if let pendingRecognition {
                pendingRecognitionsByItemID[item.id] = pendingRecognition
            }
            return item
        }
    }

    private func makeItem(from content: PasteboardContent) -> ClipboardItem {
        let copiedAt = now()
        switch content.payload {
        case .files(let paths, let byteSize, let recognizedContent):
            let fileNames = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " ")
            let searchText = [fileNames, recognizedContent.text, recognizedContent.qrCodeText]
                .compactMap { $0 }
                .joined(separator: " ")
            return ClipboardItem(
                kind: .file,
                text: recognizedContent.text,
                qrCodeText: recognizedContent.qrCodeText,
                filePaths: paths,
                sourceAppName: content.sourceAppName,
                sourceBundleIdentifier: content.sourceBundleIdentifier,
                copiedAt: copiedAt,
                byteSize: byteSize,
                searchText: searchText
            )
        case .image(let id, _, let existingAssetPath, let pixelWidth, let pixelHeight, let byteSize, let recognizedContent, let digest, _):
            let searchText = ClipboardItem.makeSearchText(
                title: nil,
                text: recognizedContent.text,
                filePaths: [],
                tagNames: [],
                sourceAppName: content.sourceAppName,
                qrCodeText: recognizedContent.qrCodeText
            )
            return ClipboardItem(
                id: id,
                kind: .image,
                title: nil,
                text: recognizedContent.text,
                qrCodeText: recognizedContent.qrCodeText,
                assetPath: existingAssetPath,
                imageDigest: digest,
                imageWidth: pixelWidth,
                imageHeight: pixelHeight,
                sourceAppName: content.sourceAppName,
                sourceBundleIdentifier: content.sourceBundleIdentifier,
                copiedAt: copiedAt,
                byteSize: byteSize,
                searchText: searchText
            )
        case .richText(let plainText, let rtf, let html):
            let classifiedKind = plainText.map {
                ClipboardKind.classifyText($0, treatDigitNumbersAsColor: preferences.treatDigitNumbersAsColor)
            }
            let kind: ClipboardKind
            switch classifiedKind {
            case .some(.text), .none:
                kind = .richText
            case .some(let semanticKind):
                kind = semanticKind
            }
            return ClipboardItem(
                kind: kind,
                text: plainText,
                rtfData: kind == .richText ? rtf : nil,
                html: kind == .richText ? html : nil,
                sourceAppName: content.sourceAppName,
                sourceBundleIdentifier: content.sourceBundleIdentifier,
                copiedAt: copiedAt,
                byteSize: (kind == .richText ? (rtf?.count ?? 0) + (html?.utf8.count ?? 0) : 0) + (plainText?.utf8.count ?? 0),
                searchText: ClipboardItem.makeSearchText(title: nil, text: plainText, filePaths: [], tagNames: [], sourceAppName: content.sourceAppName)
            )
        case .text(let text):
            return ClipboardItem(
                kind: ClipboardKind.classifyText(text, treatDigitNumbersAsColor: preferences.treatDigitNumbersAsColor),
                text: text,
                sourceAppName: content.sourceAppName,
                sourceBundleIdentifier: content.sourceBundleIdentifier,
                copiedAt: copiedAt,
                byteSize: text.utf8.count,
                searchText: text
            )
        }
    }

    /// An item of a kind whose "Keep history" period is Never is dropped.
    /// So is a secret when sensitive content is not saved. Confidential content
    /// and secrets kept for a limited time get their expiry date here, and
    /// confidential content is hidden in the history.
    private func capturableItem(_ item: ClipboardItem, isConcealed: Bool) -> ClipboardItem? {
        var lifetimes: [Int] = []
        if isConcealed {
            lifetimes.append(preferences.confidentialContentLifetime)
        }
        if preferences.sensitiveContentLifetime != ContentLifetime.keep, isSensitiveContent(item) {
            lifetimes.append(preferences.sensitiveContentLifetime)
        }

        guard preferences.capturesHistory(for: item.kind), !lifetimes.contains(ContentLifetime.dontSave) else {
            return nil
        }

        var item = item
        if isConcealed {
            item.sensitivity = .sensitive
        }
        if let lifetime = lifetimes.filter({ $0 > 0 }).min() {
            item.expiresAt = ContentLifetime.expiryDate(for: lifetime, from: item.copiedAt)
        }
        return item
    }

    /// A copy of an item the user said is not sensitive is not treated as a
    /// secret, whatever its content looks like.
    private func isSensitiveContent(_ item: ClipboardItem) -> Bool {
        guard SensitiveContent.containsSensitiveContent(item) else {
            return false
        }

        let parts = item.contentKeyComponents
        let storedItem = try? historyStore.fetchItem(
            kind: item.kind,
            contentKey: parts.canonicalContent,
            htmlDigest: parts.htmlDigest
        )
        return storedItem?.sensitivity != .notSensitive
    }

    private func handleCopyAndMerge(_ item: ClipboardItem?) throws {
        guard let item else {
            try flushPendingCopyAndMergeItemIfExpired()
            return
        }

        if let pendingItem = pendingCopyAndMergeItem {
            let pendingID = pendingItem.id
            clearPendingCopyAndMergeItem()
            do {
                if isDuplicateCopyAndMergeItem(item, of: pendingItem) {
                    discardPendingCaptureResources(for: pendingID)
                    try mergeCopiedItem(item)
                } else {
                    try capture(pendingItem)
                    holdPendingCopyAndMergeItem(item)
                }
            } catch {
                discardPendingCaptureResources(for: pendingID)
                discardPendingCaptureResources(for: item.id)
                throw error
            }
        } else {
            holdPendingCopyAndMergeItem(item)
        }
    }

    private func flushPendingCopyAndMergeItemIfExpired() throws {
        guard let pendingItem = pendingCopyAndMergeItem,
              now() >= pendingCopyAndMergeDeadline else {
            return
        }

        let pendingID = pendingItem.id
        clearPendingCopyAndMergeItem()
        do {
            try capture(pendingItem)
        } catch {
            discardPendingCaptureResources(for: pendingID)
            throw error
        }
    }

    private func flushPendingCopyAndMergeItemIfExpiredLoggingFailure() {
        do {
            try flushPendingCopyAndMergeItemIfExpired()
        } catch {
            if let pendingID = pendingCopyAndMergeItem?.id {
                discardPendingCaptureResources(for: pendingID)
            }
            clearPendingCopyAndMergeItem()
            NSLog("ClipBook history write failed: \(error.localizedDescription)")
        }
    }

    private func holdPendingCopyAndMergeItem(_ item: ClipboardItem) {
        pendingCopyAndMergeItem = item
        pendingCopyAndMergeDeadline = now().addingTimeInterval(copyAndMergeHoldInterval)
    }

    private func clearPendingCopyAndMergeItem() {
        pendingCopyAndMergeItem = nil
        pendingCopyAndMergeDeadline = .distantPast
    }

    private func mergeCopiedItem(_ item: ClipboardItem) throws {
        guard let targetItem = try copyAndMergeTargetItem(),
              let mergedItem = try copyAndMergedItem(sourceItem: item, targetItem: targetItem) else {
            try capture(item)
            return
        }

        defer {
            discardPendingCaptureResources(for: item.id)
        }
        try saveMergedItem(mergedItem)
    }

    private func isDuplicateCopyAndMergeItem(_ item: ClipboardItem, of pendingItem: ClipboardItem) -> Bool {
        item.hasSameContent(as: pendingItem)
    }

    @discardableResult
    private func capture(_ item: ClipboardItem) throws -> ClipboardItem {
        let sourceItemID = item.id
        let pendingPNGData = pendingPNGDataByItemID.removeValue(forKey: sourceItemID)
        var pendingRecognition = pendingRecognitionsByItemID.removeValue(forKey: sourceItemID)
        defer {
            discardPendingCaptureResources(for: sourceItemID)
        }

        var item = item
        let updatesCopySequence = preferences.copySequenceModeEnabled
        var updatedItems: [ClipboardItem] = []
        if updatesCopySequence {
            let sequenceTrackingResult = try itemWithTrackedCopySequence(item)
            item = sequenceTrackingResult.item
            updatedItems = sequenceTrackingResult.updatedItems
        }

        var newlyStagedAssetURL: URL?
        if item.kind == .image, let pngData = pendingPNGData {
            let parts = item.contentKeyComponents
            let existing = try? historyStore.fetchItem(
                kind: .image,
                contentKey: parts.canonicalContent,
                htmlDigest: parts.htmlDigest
            )
            let targetID = existing?.id ?? sourceItemID
            item.id = targetID
            if let existingAssetPath = existing?.assetPath,
               fileManager.fileExists(atPath: existingAssetPath) {
                item.assetPath = existingAssetPath
                item.text = existing?.text
                item.qrCodeText = existing?.qrCodeText
                pendingRecognition = nil
            } else {
                let stagedURL = try historyStore.writeManagedAsset(
                    pngData: pngData,
                    role: .image,
                    clipID: targetID,
                    encrypted: true
                )
                newlyStagedAssetURL = stagedURL
                item.assetPath = stagedURL.path
            }
        } else if pendingRecognition != nil, item.kind == .file {
            let parts = item.contentKeyComponents
            if let storedItem = try historyStore.fetchItem(
                kind: .file,
                contentKey: parts.canonicalContent,
                htmlDigest: parts.htmlDigest
            ) {
                // Copying a file again keeps the text read from it before until the
                // file is read again.
                item.text = storedItem.text
                item.qrCodeText = storedItem.qrCodeText
            }
        }

        let capturedItem: ClipboardItem
        do {
            capturedItem = try historyStore.capture(item, updatesCopySequence: updatesCopySequence)
        } catch {
            if let newlyStagedAssetURL {
                ImageAssetStore.secureUnlink(at: newlyStagedAssetURL)
            }
            throw error
        }

        notifyCapture(capturedItem, updatedItems: updatedItems)
        if let pendingRecognition {
            switch pendingRecognition {
            case .pngData(let pngData):
                inFlightImageRecognitionIDs.insert(capturedItem.id)
                recognizeText(ofPNGData: pngData, inItemWithID: capturedItem.id)
            case .imageFile(let url):
                recognizeText(ofImageAt: url, inItemWithID: capturedItem.id)
            }
        }
        return capturedItem
    }

    private func recognizeText(ofPNGData pngData: Data, inItemWithID itemID: ClipboardItem.ID) {
        let recognize = recognizeImageData
        let generation = recognitionGeneration
        textRecognitionQueue.async { [weak self] in
            let content = recognize(pngData)
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == generation else {
                    return
                }

                self.inFlightImageRecognitionIDs.remove(itemID)
                self.delegate?.pasteboardMonitor(self, didRecognize: content, inItemWithID: itemID)
            }
        }
    }

    private func recognizeText(ofImageAt url: URL, inItemWithID itemID: ClipboardItem.ID) {
        let recognize = recognizeImageFile
        let generation = recognitionGeneration
        textRecognitionQueue.async { [weak self] in
            let content = recognize(url)
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == generation else {
                    return
                }

                self.delegate?.pasteboardMonitor(self, didRecognize: content, inItemWithID: itemID)
            }
        }
    }

    private func saveMergedItem(_ mergedItem: ClipboardItem) throws {
        let saved = try historyStore.saveAndReconcileItem(mergedItem, convertingExternalAssets: false)
        if preferences.copyToClipboardAfterMerge,
           let text = saved.text {
            copyMergedTextToClipboard(text, isConcealed: SensitiveContent.shouldEncryptAtRest(saved))
            lastChangeCount = pasteboard.changeCount
        }
        notifyCapture(saved, updatedItems: [])
    }

    private func notifyCapture(_ item: ClipboardItem, updatedItems: [ClipboardItem]) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            delegate?.pasteboardMonitor(self, didCapture: item, updatedItems: updatedItems)
        }
    }

    private func copyAndMergeTargetItem() throws -> ClipboardItem? {
        try historyStore.fetchMostRecentItem { !$0.isFavorite && !$0.isCorruptPlaceholder }
    }

    private func copyAndMergedItem(sourceItem: ClipboardItem, targetItem: ClipboardItem) throws -> ClipboardItem? {
        var targetItem = targetItem
        guard let targetText = copyAndMergeText(for: targetItem),
              let copiedText = copyAndMergeText(for: sourceItem) else {
            return nil
        }

        let mergedText = targetText + copyAndMergeSeparator() + copiedText
        let tagNamesByID = Dictionary(uniqueKeysWithValues: try historyStore.fetchTags().map { ($0.id, $0.name) })
        targetItem.text = mergedText
        targetItem.removeFormatting()
        targetItem.assetPath = nil
        targetItem.filePaths = []
        targetItem.kind = ClipboardKind.classifyText(
            mergedText,
            treatDigitNumbersAsColor: preferences.treatDigitNumbersAsColor
        )
        targetItem.copiedAt = sourceItem.copiedAt
        targetItem.byteSize = mergedText.utf8.count
        targetItem.copyCount += 1
        targetItem.linkPreviewDetails = nil
        if sourceItem.sensitivity == .sensitive || targetItem.sensitivity == .sensitive {
            targetItem.sensitivity = .sensitive
        } else if targetItem.sensitivity == .notSensitive && sourceItem.sensitivity != .notSensitive {
            targetItem.sensitivity = nil
        }
        // The merged text holds the copied content, so it goes when that
        // content would have gone, unless the user keeps the item.
        if let sourceExpiry = sourceItem.expiresAt, !targetItem.isKeptByUser {
            targetItem.expiresAt = min(targetItem.expiresAt ?? sourceExpiry, sourceExpiry)
        }
        targetItem = targetItem.rebuildingSearchText(tagNames: targetItem.tags.compactMap { tagNamesByID[$0] })
        return targetItem
    }

    private func copyAndMergeText(for item: ClipboardItem) -> String? {
        switch item.kind {
        case .text, .richText, .link, .email, .color:
            return item.text
        case .image, .file:
            return nil
        }
    }

    private func copyAndMergeSeparator() -> String {
        switch CopyAndMergeSeparatorPreference(preferenceValue: preferences.copyAndMergeSeparator) {
        case .newLine:
            return "\n"
        case .space:
            return " "
        case .comma:
            return ", "
        case .empty:
            return ""
        }
    }

    private func copyMergedTextToClipboard(_ text: String, isConcealed: Bool) {
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.ghostType)
        if isConcealed {
            pasteboard.setData(Data(), forType: PasteboardReader.concealedType)
        }
        pasteboard.setString(text, forType: .string)
    }

    private func itemWithTrackedCopySequence(_ item: ClipboardItem) throws -> (item: ClipboardItem, updatedItems: [ClipboardItem]) {
        var trackedItem = item
        guard let mostRecentClip = try mostRecentClipForSequenceTracking(item: item) else {
            return (trackedItem, [])
        }
        var updatedItems: [ClipboardItem] = []

        let timeDiff = item.copiedAt.timeIntervalSince(mostRecentClip.copiedAt)
        let pasteHappenedAfterLastCopy = lastCopySequencePasteTime > mostRecentClip.copiedAt

        if pasteHappenedAfterLastCopy {
            trackedItem.copySequenceID = nil
            trackedItem.copySequenceOrder = nil
        } else if timeDiff < copySequenceThreshold, let sequenceID = mostRecentClip.copySequenceID {
            trackedItem.copySequenceID = sequenceID
            trackedItem.copySequenceOrder = (mostRecentClip.copySequenceOrder ?? 0) + 1
        } else if timeDiff < copySequenceThreshold {
            // The store keeps the ID to the whole second. An ID with a fraction
            // would no longer equal itself once an item is read back, and the
            // items still in memory would fall out of the sequence of those
            // that were, which changes the order they are pasted in.
            let sequenceID = Date(timeIntervalSince1970: mostRecentClip.copiedAt.timeIntervalSince1970.rounded(.down))
            var updatedMostRecentClip = mostRecentClip
            updatedMostRecentClip.copySequenceID = sequenceID
            updatedMostRecentClip.copySequenceOrder = 0
            try historyStore.upsert(updatedMostRecentClip)
            updatedItems.append(updatedMostRecentClip)

            trackedItem.copySequenceID = sequenceID
            trackedItem.copySequenceOrder = 1
        } else {
            trackedItem.copySequenceID = nil
            trackedItem.copySequenceOrder = nil
        }

        return (trackedItem, updatedItems)
    }

    /// The clip copied right before `item`. A copy of content that is already
    /// in the history updates the item it has there, so that item is not the
    /// one before it.
    private func mostRecentClipForSequenceTracking(item: ClipboardItem) throws -> ClipboardItem? {
        try historyStore.fetchMostRecentItem { clip in
            !clip.isCorruptPlaceholder && !clip.hasSameContent(as: item)
        }
    }
}
