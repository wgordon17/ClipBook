import Foundation

nonisolated enum StoreLockState: Equatable, Sendable {
    case unlocked
    case locked(KeyUnavailableReason)
    case keyMismatch
}

nonisolated struct HistoryStoreCacheHooks: Sendable {
    var registerSVGTextLoader: @Sendable (
        _ loader: @escaping @Sendable (UUID) -> String?,
        _ ownsClip: @escaping @Sendable (UUID) -> Bool,
        _ ownerID: UUID
    ) -> Void
    var unregisterSVGTextLoader: @Sendable (_ ownerID: UUID) -> Void
    var removeSVGRendering: @Sendable (_ clipID: UUID) -> Void
    var removeOwnerSVGRenderings: @Sendable (_ ownerID: UUID) -> Void
    var removeThumbnailsForPath: @Sendable (_ path: String) -> Void
    var removeThumbnailsInDirectory: @Sendable (_ directory: URL) -> Void
    var removeDragCopiesInDirectory: @Sendable (_ directory: URL) -> Void
    var removeAllSensitiveContentCaches: @Sendable () -> Void
}

nonisolated protocol HistoryStore: Sendable {
    var lockState: StoreLockState { get }
    var isOpen: Bool { get }
    func retryUnlock() throws
    func flushPendingFreePageRelease()
    func close()

    func computeImageDigest(forPNGData pngData: Data) -> String
    func writeManagedAsset(
        pngData: Data,
        role: AssetRole,
        clipID: UUID,
        encrypted: Bool,
        preferredPlainExtension: String?,
        sync: Bool
    ) throws -> URL
    func finalizeRecognizedImage(
        id: UUID,
        content: RecognizedImageContent,
        sensitiveContentLifetime: Int
    ) throws -> (updated: ClipboardItem?, previous: ClipboardItem?, isTrashed: Bool, purged: Bool)

    /// The items in the history. Items in the Trash are left out of this and
    /// of every other fetch unless it says otherwise.
    func fetchAll() throws -> [ClipboardItem]
    /// The items in the Trash, the most recently deleted first.
    func fetchTrashedItems() throws -> [ClipboardItem]
    /// The items that were moved to the Trash before `date`.
    func fetchItems(trashedBefore date: Date) throws -> [ClipboardItem]
    /// Marks the items as deleted at `date`. They stay in the store, with
    /// their files, until they are deleted for good.
    func moveToTrash(ids: [UUID], at date: Date) throws
    /// Brings items in the Trash back to the history.
    func restoreFromTrash(ids: [UUID]) throws
    func fetchTags() throws -> [Tag]
    /// Saves a captured item, or updates the item that already holds its
    /// content. An item in the Trash that holds it comes back to the history.
    func capture(_ item: ClipboardItem, updatesCopySequence: Bool) throws -> ClipboardItem
    /// Saves the item. An existing item stays in or out of the Trash.
    func upsert(_ item: ClipboardItem) throws
    @discardableResult
    func saveAndReconcileItem(_ item: ClipboardItem, convertingExternalAssets: Bool) throws -> ClipboardItem
    func setSensitivity(_ sensitivity: ItemSensitivity?, for id: UUID) throws -> ClipboardItem?
    /// Reads the item's stored body and/or formatting for the requested scope.
    func loadingContent(of item: ClipboardItem, scope: ClipboardContentScope) throws -> ClipboardItem
    func createTag(name: String, color: String) throws -> Tag
    func updateTag(id: Tag.ID, name: String, color: String) throws -> Tag
    func deleteTag(id: Tag.ID) throws
    /// Deletes items for good, whether they are in the history or the Trash.
    func delete(_ id: UUID) throws
    func delete(ids: [UUID]) throws
    /// Deletes everything, the Trash included.
    func clear() throws
    /// Deletes the history and the whole Trash, sparing the favorites and
    /// tagged items in the history when asked to.
    func clear(keepingFavoritesAndTaggedItems: Bool) throws
    func recordAction(_ id: UUID, copiedAt: Date?, incrementsCopyCount: Bool) throws -> ClipboardItem?
    func fetchItems(expiredBy policy: HistoryRetentionPolicy) throws -> [ClipboardItem]
    /// The items whose own expiry date is at or before `date`, the items in
    /// the Trash included.
    func fetchItems(expiringBy date: Date) throws -> [ClipboardItem]
    /// The earliest expiry date of an item in the store, if any item has one.
    func nextExpiryDate() throws -> Date?
    /// The latest item of the kind with the content key, the one a capture of
    /// that content updates. It may be in the Trash, which a capture brings
    /// it back from, but an item in the history comes first.
    func fetchItem(kind: ClipboardKind, contentKey: String, htmlDigest: String?) throws -> ClipboardItem?
    /// The files every item in the store refers to, its image and its link
    /// preview pictures, the items in the Trash included.
    func fetchStoredFilePaths() throws -> Set<String>
    /// The asset paths referenced by items currently in the Trash.
    func fetchTrashedAssetPaths() throws -> Set<String>
    func fetchSearchTexts(
        for ids: [UUID],
        trashed: Bool,
        tagNamesByID: [Tag.ID: String],
        isCancelled: () -> Bool
    ) throws -> [String?]?
    func fetchItems(where isIncluded: (ClipboardItem) -> Bool) throws -> [ClipboardItem]
    /// The item copied last among those `isIncluded` accepts. Items are read
    /// from the latest one back and only until one is accepted, so asking
    /// about the top of the history does not read the rest of it.
    func fetchMostRecentItem(where isIncluded: (ClipboardItem) -> Bool) throws -> ClipboardItem?
    /// Runs `body` as a single transaction, so a loop of writes commits once.
    /// Rolls back and rethrows if `body` throws. Nested calls join the
    /// enclosing transaction.
    func performInTransaction(_ body: () throws -> Void) throws
}

nonisolated extension HistoryStore {
    var isOpen: Bool {
        lockState == .unlocked
    }

    func writeManagedAsset(
        pngData: Data,
        role: AssetRole,
        clipID: UUID,
        encrypted: Bool,
        preferredPlainExtension: String? = nil
    ) throws -> URL {
        try writeManagedAsset(
            pngData: pngData,
            role: role,
            clipID: clipID,
            encrypted: encrypted,
            preferredPlainExtension: preferredPlainExtension,
            sync: true
        )
    }

    func fetchTrashedAssetPaths() throws -> Set<String> {
        Set(try fetchTrashedItems().compactMap(\.assetPath))
    }

    func fetchItem(kind: ClipboardKind, contentKey: String) throws -> ClipboardItem? {
        try fetchItem(kind: kind, contentKey: contentKey, htmlDigest: nil)
    }

    func loadingContent(of item: ClipboardItem) throws -> ClipboardItem {
        try loadingContent(of: item, scope: .full)
    }

    @discardableResult
    func saveAndReconcileItem(_ item: ClipboardItem) throws -> ClipboardItem {
        try saveAndReconcileItem(item, convertingExternalAssets: true)
    }
}
