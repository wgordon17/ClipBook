import Darwin
import Foundation
import os
import SwiftUI
import AppKit
import Carbon
import Combine
import UniformTypeIdentifiers

private enum ClipboardImageExportError: LocalizedError {
  case unsupportedItem
  case missingImageFile

  var errorDescription: String? {
    switch self {
    case .unsupportedItem:
      return L10n.string("This clipboard item cannot be saved as an image file.")
    case .missingImageFile:
      return L10n.string("The image file for this clipboard item could not be found.")
    }
  }
}

nonisolated enum ArchiveExportMode: Equatable, Sendable {
  case unencryptedIncludingSensitive
  case unencryptedSkippingSensitive
  case encrypted(passphrase: String)
}

@MainActor
final class AppCoordinator: ObservableObject {
  let model: AppModel
  
  private let preferencesStore: PreferencesStore
  nonisolated let historyStore: any HistoryStore
  private let clipboardMonitor: PasteboardMonitor
  private let pasteService: PasteService
  private let globalShortcuts: GlobalShortcutService
  private let updateService: UpdateService
  private let licensingService: LicensingService
  private let fileManager: FileManager
  private let supportDirectory: URL
  /// What `savePreferences()` last applied. Comparing against it keeps a change to one
  /// setting from registering the hotkeys again or touching the login item.
  private var lastAppliedPreferences: AppPreferences?
  let filePreviewCache: FilePreviewCache
  #if (CLIPBOOK_COMMERCIAL && canImport(ClipBookCommercialLicensing)) || CLIPBOOK_COMMERCIAL_IN_TREE
  private static let v1PreferencesDomain = "com.ikryanov.clipbook"
  private static let v1LicenseKeyPreferenceKey = "license_key"
  #endif
  private let linkPreviewFetcher = LinkPreviewFetcher()
  private var linkPreviewTasksByItemID: [UUID: Task<Void, Never>] = [:]
  private var pendingLinkPreviewModelUpdatesByItemID: [UUID: ClipboardItem] = [:]
  private var linkPreviewModelUpdateTask: Task<Void, Never>?
  private let soundService = SoundService()
  @Published var settingsSection: SettingsSection = .general
  private var historyWindow: HistoryWindow?
  private var settingsWindow: SettingsWindow?
  private var onboardingWindow: OnboardingWindow?
  /// Where the menu bar icon is on screen, or nil when it isn't showing. The
  /// app delegate owns the icon and sets this and the highlight below.
  var menuBarIconFrame: (() -> NSRect?)?
  var highlightMenuBarIcon: (() -> Void)?
  private var cancellables: Set<AnyCancellable> = []
  private var pasteNextItemID: ClipboardItem.ID?
  private var isTrialSheetPresented = false
  private static let retentionCheckInterval: TimeInterval = 60 * 60
  private static let orphanedStoredFileMinimumAge: TimeInterval = 10 * 60
  private nonisolated let maintenanceQueue = DispatchQueue(
    label: "com.ikryanov.clipbook.v2.maintenance",
    qos: .utility
  )
  private nonisolated let orphanSweepGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
  private var retentionTimer: Timer?
  private var expiryTimer: Timer?
  private var isRetentionPromptPresented = false
  private var isHistoryArchiveOperationRunning = false
  private var areGlobalShortcutsSuspended = false
  private var hasBoundLifecycleObservers = false
  @Published private(set) var licenseState: LicensingService.State = .unavailable
  @Published private(set) var trialNotice: TrialNotice?
  /// Fires when something tried to use an item while the history is read-only,
  /// so the notice above the history can point out why nothing happened.
  let readOnlyHistoryActionAttempts = PassthroughSubject<Void, Never>()
  /// Fires each time the history window is brought on screen.
  let historyPanelDidShow = PassthroughSubject<Void, Never>()
  /// Fires for every item taken from the clipboard into the history.
  let capturedClipboardItems = PassthroughSubject<ClipboardItem, Never>()
  /// Undoes moving items to the Trash and putting them back. It belongs to
  /// the history rather than to a window, so a deletion can be undone the next
  /// time the history is opened.
  private let historyUndoManager: UndoManager = {
    let undoManager = UndoManager()
    undoManager.levelsOfUndo = 50
    return undoManager
  }()

  /// After the trial the history keeps showing and taking in new items, but
  /// its items can no longer be copied, pasted, edited or otherwise reused.
  var isHistoryReadOnly: Bool {
    licenseState.isTrialExpired
  }
  
  init(
    model: AppModel,
    preferencesStore: PreferencesStore,
    historyStore: HistoryStore,
    clipboardMonitor: PasteboardMonitor,
    pasteService: PasteService,
    globalShortcuts: GlobalShortcutService,
    updateService: UpdateService,
    licensingService: LicensingService,
    fileManager: FileManager,
    supportDirectory: URL
  ) {
    self.model = model
    self.preferencesStore = preferencesStore
    self.historyStore = historyStore
    self.clipboardMonitor = clipboardMonitor
    self.pasteService = pasteService
    self.globalShortcuts = globalShortcuts
    self.updateService = updateService
    self.licensingService = licensingService
    self.fileManager = fileManager
    self.supportDirectory = supportDirectory
    self.filePreviewCache = FilePreviewCache(
      directory: supportDirectory.appendingPathComponent("FilePreviews", isDirectory: true),
      fileManager: fileManager
    )
    model.storeLockState = historyStore.lockState
    licensingService.$state
      .sink { [weak self] state in
        self?.licenseState = state
        self?.updateTrialNotice()
      }
      .store(in: &cancellables)
  }
  
  func loadAndReconcilePreferences() {
    model.preferences = preferencesStore.load()
    model.forkPreferences = preferencesStore.loadForkPreferences()
  }

  func applyUpdatePreferences() {
    updateService.setAutomaticallyChecksForUpdates(model.preferences.checkForUpdatesAutomatically)
  }

  func start() {
    loadAndReconcilePreferences()
    #if DEBUG
    applyDebugTrialDates()
    #endif
    #if (CLIPBOOK_COMMERCIAL && canImport(ClipBookCommercialLicensing)) || CLIPBOOK_COMMERCIAL_IN_TREE
    activateV1LicenseKeyIfNeeded()
    #endif
    refreshLicensingState()
    model.historySortOption = HistorySortOption(preferenceValue: model.preferences.historySortOption)
    model.isHistorySortReversed = model.preferences.isHistorySortReversed
    applyLanguage()
    applyUpdatePreferences()
    var shouldSavePreferences = false
    if model.preferences.deleteItemShortcut == "delete" {
      model.preferences.deleteItemShortcut = AppPreferences.defaultDeleteItemShortcut
      shouldSavePreferences = true
    }
    if model.preferences.toggleFavoriteShortcut == "f" {
      model.preferences.toggleFavoriteShortcut = AppPreferences.defaultToggleFavoriteShortcut
      shouldSavePreferences = true
    }
    if shouldSavePreferences {
      preferencesStore.save(model.preferences)
    }
    let initialLockState = syncStoreLockState()
    if initialLockState == .unlocked {
      let didLoadHistory = loadHistory(sweepsCaches: false)
      if syncStoreLockState() == .unlocked {
        clearHistoryAfterRebootIfNeeded()
        applyRetention()
        deleteExpiredItems()
        if didLoadHistory {
          pruneFilePreviewCache()
          removeOrphanedStoredFiles()
        }
      }
    } else {
      model.lastError = Self.lockedStoreErrorMessage(for: initialLockState)
    }
    scheduleRetentionChecks()
    if !hasBoundLifecycleObservers {
      hasBoundLifecycleObservers = true
      observeWakeForExpiredItems()
      observeTrashVisibility()
    }
    configurePanel()
    configureShortcuts()
    clipboardMonitor.delegate = self
    clipboardMonitor.start(preferences: model.preferences)
    clipboardMonitor.isPaused = model.isPaused || historyStore.lockState != .unlocked
    applyAppearance()
    #if DEBUG
    // `-ClipBookShowOnboarding YES` on the command line shows onboarding
    // again without resetting the preferences it is recorded in.
    let forcesOnboarding = UserDefaults.standard.bool(forKey: "ClipBookShowOnboarding")
    #else
    let forcesOnboarding = false
    #endif
    if !model.preferences.hasCompletedOnboarding || forcesOnboarding {
      showOnboarding()
    } else if model.preferences.showMainWindowAtStartup {
      showHistoryPanel()
    }
  }
  
  func stop() {
    historyWindow?.saveWindowFrame()
    savePreferences()
    if model.preferences.clearHistoryOnQuit, historyStore.lockState == .unlocked {
      clearHistory()
    }
    ImageDragFiles.removeAll()
    stopBackgroundWorkForTesting()
  }

  func isImageRecognitionPending(for id: ClipboardItem.ID) -> Bool {
    clipboardMonitor.isImageRecognitionPending(for: id)
  }

  @discardableResult
  func retryUnlockHistoryStore() -> Bool {
    model.lastError = nil
    do {
      try historyStore.retryUnlock()
      _ = syncStoreLockState()
      let didLoadHistory = loadHistory(sweepsCaches: false)
      if syncStoreLockState() == .unlocked {
        clearHistoryAfterRebootIfNeeded()
        applyRetention()
        deleteExpiredItems()
        if didLoadHistory {
          pruneFilePreviewCache()
          removeOrphanedStoredFiles()
        }
      }
      let isUnlocked = syncStoreLockState() == .unlocked
      clipboardMonitor.isPaused = model.isPaused || !isUnlocked
      return isUnlocked
    } catch {
      let currentLockState = syncStoreLockState()
      model.lastError = PersistenceErrorLocalization.message(for: error)
      clipboardMonitor.isPaused = model.isPaused || currentLockState != .unlocked
      return false
    }
  }

  @discardableResult
  private func syncStoreLockState() -> StoreLockState {
    let current = historyStore.lockState
    if model.storeLockState != current {
      model.storeLockState = current
    }
    return current
  }

  private static func lockedStoreErrorMessage(for lockState: StoreLockState) -> String? {
    switch lockState {
    case .unlocked:
      return nil
    case .locked(let reason):
      return PersistenceErrorLocalization.message(for: HistoryStoreError.encryptionKeyUnavailable(reason))
    case .keyMismatch:
      return PersistenceErrorLocalization.message(for: HistoryStoreError.encryptionKeyMismatch)
    }
  }

  nonisolated func cancelOrphanedFileSweeps(waitUntilDone: Bool = true) {
    orphanSweepGeneration.withLock { $0 &+= 1 }
    if waitUntilDone {
      maintenanceQueue.sync {}
    }
  }

  nonisolated func fetchSearchTexts(
    for ids: [UUID],
    trashed: Bool,
    tagNamesByID: [Tag.ID: String],
    isCancelled: () -> Bool
  ) throws -> [String?]? {
    try historyStore.fetchSearchTexts(
      for: ids,
      trashed: trashed,
      tagNamesByID: tagNamesByID,
      isCancelled: isCancelled
    )
  }

  func cancelBackgroundMaintenance() {
    cancelLinkPreviewTasks()
    retentionTimer?.invalidate()
    retentionTimer = nil
    expiryTimer?.invalidate()
    expiryTimer = nil
    cancelOrphanedFileSweeps(waitUntilDone: true)
  }

  /// Stops background tasks, timers, pasteboard polling, and global shortcuts
  /// without saving window frames, applying preferences, or clearing history.
  func stopBackgroundWorkForTesting() {
    cancelBackgroundMaintenance()
    clipboardMonitor.stop()
    globalShortcuts.unregisterAll()
  }
  
  /// The window a quit confirmation is shown on: the history window or
  /// Settings, whichever the user is in, or nil when neither is on screen.
  /// A dialog already open over it (an item preview, for instance) keeps its
  /// place and gets the confirmation on top of it.
  var quitConfirmationWindow: NSWindow? {
    let windows = [historyWindow?.window, settingsWindow?.window]
      .compactMap { $0 }
      .filter(\.isVisible)
    var window = windows.first { $0.isKeyWindow || $0.attachedSheet?.isKeyWindow == true } ?? windows.first
    while let sheet = window?.attachedSheet {
      window = sheet
    }
    return window
  }

  func showHistoryPanel(ignoresNextResignKey: Bool = false, activatesApp: Bool = false) {
    guard !isHistoryArchiveOperationRunning else {
      return
    }

    recordTrialUsage()
    configurePanel()
    interruptCopySequenceTracking()
    resetPasteNextPointer()
    if activatesApp {
      NSApp.activate(ignoringOtherApps: true)
    }
    historyWindow?.show(ignoresNextResignKey: ignoresNextResignKey, beside: visibleOnboardingWindow?.window)
    presentTrialSheetIfNeeded()
    historyPanelDidShow.send()
  }
  
  func hideHistoryPanel() {
    historyWindow?.hide()
  }

  // A pinned panel is meant to stay on screen, so pasting leaves it visible.
  // The panel is non-activating, which keeps the paste target frontmost even
  // while the panel holds key focus, so the keystroke still lands in the app
  // the user pasted into.
  //
  // When the target is not the frontmost app (a non-activating panel of
  // another app, such as Easydict's pinned window), that panel has to be key
  // to take the keystroke, and the window server does not reliably hand focus
  // back to it once this panel gives it up. The target window is made key
  // explicitly instead, and a pinned panel takes key focus back afterwards.
  private func hideHistoryWindowForPaste() {
    let isPinned = !model.preferences.hideOnFocusLoss
    guard onboardingPasteTarget == nil else {
      if !isPinned {
        historyWindow?.hideForPaste()
      }
      return
    }

    pasteService.resolvePasteTarget()
    if !isPinned {
      historyWindow?.hideForPaste()
    }
    guard !pasteService.pasteTargetIsFrontmostApplication(),
          pasteService.giveKeyFocusToTargetWindow(),
          isPinned else {
      return
    }
    historyWindow?.retakeKeyFocusAfterPaste()
  }

  func toggleHistoryPanel() {
    guard !isHistoryArchiveOperationRunning else {
      return
    }

    configurePanel()
    guard historyWindow?.isVisible == false else {
      historyWindow?.toggle()
      return
    }

    recordTrialUsage()
    interruptCopySequenceTracking()
    resetPasteNextPointer()
    historyWindow?.show(beside: visibleOnboardingWindow?.window)
    presentTrialSheetIfNeeded()
    historyPanelDidShow.send()
  }

  func toggleHistoryPanelPin() {
    model.preferences.hideOnFocusLoss.toggle()
    savePreferences()
    historyWindow?.applyPreferences()
  }

  func toggleCopySequenceMode() {
    model.preferences.copySequenceModeEnabled.toggle()
    savePreferences()
  }
  
  func openSettings(section: SettingsSection = .general) {
    settingsSection = SettingsSection.visibleSections.contains(section) ? section : .general
    if settingsWindow == nil {
      settingsWindow = SettingsWindow(model: model, coordinator: self)
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.show()
  }

  func exportableHistoryContainsSensitiveItems() -> Bool {
    model.items.contains { $0.expiresAt == nil && SensitiveContent.shouldEncryptAtRest($0) }
  }

  @discardableResult
  func beginExportHistoryArchive(
    mode: ArchiveExportMode = .unencryptedIncludingSensitive,
    destinationURL: URL? = nil,
    progress: @escaping (ClipBookArchiveProgress) -> Void,
    completion: @escaping (Result<ClipBookArchiveExportResult, Error>) -> Void
  ) -> Bool {
    guard !isHistoryArchiveOperationRunning, syncStoreLockState() == .unlocked else {
      return false
    }

    let url: URL
    if let destinationURL {
      url = destinationURL
    } else {
      let panel = NSSavePanel()
      panel.title = L10n.string("Export History and Tags")
      panel.nameFieldStringValue = "ClipBook Export.clipbookarchive"
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false

      guard panel.runModal() == .OK, let selectedURL = panel.url else {
        return false
      }
      url = selectedURL
    }

    // Content kept for a limited time does not outlive it in an archive.
    var items = model.items.filter { $0.expiresAt == nil }
    let passphrase: String?
    switch mode {
    case .unencryptedIncludingSensitive:
      passphrase = nil
    case .unencryptedSkippingSensitive:
      items = items.filter { !SensitiveContent.shouldEncryptAtRest($0) }
      passphrase = nil
    case .encrypted(let exportPassphrase):
      passphrase = exportPassphrase
    }
    let tags = model.tags
    // FileManager is thread-safe; the archive is written on a background queue.
    nonisolated(unsafe) let fileManager = self.fileManager
    let supportDirectory = self.supportDirectory
    let reportProgress: (ClipBookArchiveProgress) -> Void = { progressValue in
      DispatchQueue.main.async {
        progress(progressValue)
      }
    }
    isHistoryArchiveOperationRunning = true

    let historyStore = self.historyStore
    DispatchQueue.global(qos: .userInitiated).async {
      let archiveService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: supportDirectory)
      do {
        try archiveService.export(
          items: items,
          tags: tags,
          to: url,
          passphrase: passphrase,
          loadItem: { item in
            try historyStore.loadingContent(of: item, scope: .full)
          },
          progress: reportProgress
        )
        let result = ClipBookArchiveExportResult(url: url, itemCount: items.count, tagCount: tags.count)
        DispatchQueue.main.async {
          self.isHistoryArchiveOperationRunning = false
          self.deleteExpiredItems()
          completion(.success(result))
        }
      } catch {
        DispatchQueue.main.async {
          self.isHistoryArchiveOperationRunning = false
          self.deleteExpiredItems()
          completion(.failure(error))
        }
      }
    }

    return true
  }

  func chooseImportArchiveURL() -> URL? {
    let panel = NSOpenPanel()
    panel.title = L10n.string("Import History and Tags")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK else {
      return nil
    }
    return panel.url
  }

  func inspectArchive(at url: URL) throws -> ClipBookArchiveInspection {
    let archiveService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: supportDirectory)
    return try archiveService.inspect(at: url)
  }

  func verifyArchivePassphrase(_ passphrase: String, for url: URL) async throws {
    nonisolated(unsafe) let fileManager = self.fileManager
    let supportDirectory = self.supportDirectory
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let archiveService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: supportDirectory)
        do {
          try archiveService.verifyPassphrase(passphrase, at: url)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  @discardableResult
  func performImportHistoryArchive(
    from url: URL,
    passphrase: String? = nil,
    progress: @escaping (ClipBookArchiveProgress) -> Void,
    completion: @escaping (Result<ClipBookArchiveImportResult, Error>) -> Void
  ) -> Bool {
    guard !isHistoryArchiveOperationRunning, syncStoreLockState() == .unlocked else {
      return false
    }

    // The import runs on a background queue while clipboard monitoring is
    // stopped, so nothing else touches the store until it completes.
    nonisolated(unsafe) let fileManager = self.fileManager
    let supportDirectory = self.supportDirectory
    let historyStore = self.historyStore
    let reportProgress: (ClipBookArchiveProgress) -> Void = { progressValue in
      DispatchQueue.main.async {
        progress(progressValue)
      }
    }
    isHistoryArchiveOperationRunning = true
    clipboardMonitor.stop()
    cancelOrphanedFileSweeps(waitUntilDone: true)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let archiveService = ClipBookArchiveService(fileManager: fileManager, supportDirectory: supportDirectory)
      do {
        let result = try archiveService.import(
          from: url,
          into: historyStore,
          passphrase: passphrase,
          progress: reportProgress
        )
        DispatchQueue.main.async { [weak self] in
          guard let self else {
            return
          }
          ImageAssetThumbnailLoader.shared.removeThumbnails(inDirectory: self.supportDirectory)
          // Checked before anything can run the retention check again, which
          // would delete the expired items without asking.
          let expiredItems = self.expiredItems(among: result.itemIDs)
          self.isRetentionPromptPresented = !expiredItems.isEmpty
          self.clipboardMonitor.start(preferences: self.model.preferences)
          self.clipboardMonitor.isPaused = self.model.isPaused || self.syncStoreLockState() != .unlocked
          let didLoadHistory = self.loadHistory(sweepsCaches: false)
          self.isHistoryArchiveOperationRunning = false
          self.deleteExpiredItems()
          if didLoadHistory {
            self.pruneFilePreviewCache()
            self.removeOrphanedStoredFiles()
          }
          completion(.success(result))
          if !expiredItems.isEmpty {
            self.confirmKeepingExpiredImportedItems(expiredItems)
          }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self else {
            return
          }
          ImageAssetThumbnailLoader.shared.removeThumbnails(inDirectory: self.supportDirectory)
          self.clipboardMonitor.start(preferences: self.model.preferences)
          self.clipboardMonitor.isPaused = self.model.isPaused || self.syncStoreLockState() != .unlocked
          self.isHistoryArchiveOperationRunning = false
          self.deleteExpiredItems()
          completion(.failure(error))
        }
      }
    }

    return true
  }

  func showOnboarding() {
    if onboardingWindow == nil {
      onboardingWindow = OnboardingWindow(model: model, coordinator: self)
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    onboardingWindow?.show()
  }

  func completeOnboarding(openHistory: Bool = false) {
    model.preferences.hasCompletedOnboarding = true
    savePreferences()
    let finish = { [weak self] in
      guard let self else {
        return
      }
      self.highlightMenuBarIcon?()
      NSApp.setActivationPolicy(.accessory)
      if openHistory {
        self.showHistoryPanel(ignoresNextResignKey: true, activatesApp: true)
      } else if self.model.preferences.showMainWindowAtStartup {
        self.showHistoryPanel()
      }
    }

    // The window flies into the menu bar icon to show where ClipBook lives
    // from now on. Closing the window clears `onboardingWindow`.
    if let iconFrame = menuBarIconFrame?(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      onboardingWindow?.closeFlying(toMenuBarIconAt: iconFrame, completion: finish)
    } else {
      onboardingWindow?.close()
      finish()
    }
    onboardingWindow = nil
  }

  private var visibleOnboardingWindow: OnboardingWindow? {
    onboardingWindow?.isVisible == true ? onboardingWindow : nil
  }

  /// The onboarding window, when a paste from the history goes there. While
  /// ClipBook itself is the active app the history pastes into onboarding
  /// within the app, which needs no Accessibility permission; onboarding asks
  /// for that permission only after the user has tried pasting.
  private var onboardingPasteTarget: OnboardingWindow? {
    NSApp.isActive ? visibleOnboardingWindow : nil
  }

  func onboardingDidClose() {
    onboardingWindow = nil
    restoreAccessoryActivationPolicyAfterWindowClose()
  }

  func settingsDidClose() {
    // A recorder that was still waiting for a combination must not leave the
    // global shortcuts off once the window is gone.
    setGlobalShortcutsSuspended(false)
    restoreAccessoryActivationPolicyAfterWindowClose()
  }

  // windowWillClose arrives while the window is still on screen. Leaving the
  // regular activation policy at that point can leave the window drawn on
  // screen while AppKit treats it as closed, so it ignores every click. The
  // switch waits until the window has been ordered out.
  private func restoreAccessoryActivationPolicyAfterWindowClose() {
    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.settingsWindow?.window.isVisible != true,
            self.onboardingWindow == nil else {
        return
      }

      NSApp.setActivationPolicy(.accessory)
    }
  }
  
  func togglePaused() {
    model.isPaused.toggle()
    clipboardMonitor.isPaused = model.isPaused || historyStore.lockState != .unlocked
  }
  
  /// The settings whose effects `savePreferences()` applies again.
  struct PreferenceChanges: Equatable {
    var appearance: Bool
    var language: Bool
    var launchAtLogin: Bool
    var automaticUpdateChecks: Bool
    var globalShortcuts: Bool
  }

  /// What changed from `previous` to `current`. Everything counts as changed
  /// when nothing has been applied yet.
  static func preferenceChanges(from previous: AppPreferences?, to current: AppPreferences) -> PreferenceChanges {
    func changed<Value: Equatable>(_ keyPath: KeyPath<AppPreferences, Value>) -> Bool {
      previous?[keyPath: keyPath] != current[keyPath: keyPath]
    }

    return PreferenceChanges(
      appearance: changed(\.appearance),
      language: changed(\.language),
      launchAtLogin: changed(\.launchAtLogin),
      automaticUpdateChecks: changed(\.checkForUpdatesAutomatically),
      globalShortcuts: changed(\.globalShortcuts)
    )
  }

  func savePreferences() {
    let current = model.preferences
    let changes = Self.preferenceChanges(from: lastAppliedPreferences, to: current)

    preferencesStore.save(current)
    preferencesStore.saveForkPreferences(model.forkPreferences)
    if changes.appearance {
      applyAppearance()
    }
    if changes.language {
      applyLanguage()
    }
    clipboardMonitor.updatePreferences(model.preferences)
    if !model.preferences.showPreviewForLinks {
      cancelLinkPreviewTasks()
    }
    if changes.launchAtLogin {
      LaunchAtLoginService.setEnabled(current.launchAtLogin)
    }
    if changes.automaticUpdateChecks {
      applyUpdatePreferences()
    }
    if changes.globalShortcuts {
      configureShortcuts()
    }
    // After applyLanguage, which can normalize `language`, so the next call sees no change.
    lastAppliedPreferences = model.preferences
  }

  func persistPreferences() {
    preferencesStore.save(model.preferences)
    preferencesStore.saveForkPreferences(model.forkPreferences)
  }

  func refreshLicensingState() {
    licensingService.refresh(licenseKey: model.preferences.licenseKey)
  }

  // The v1 key is taken over only on the first launch of v2. After that the
  // License settings field is left to the user, so a key they deactivate or
  // clear there isn't brought back from v1.
  #if (CLIPBOOK_COMMERCIAL && canImport(ClipBookCommercialLicensing)) || CLIPBOOK_COMMERCIAL_IN_TREE
  private func activateV1LicenseKeyIfNeeded() {
    guard !model.preferences.hasMigratedV1LicenseKey else {
      return
    }

    model.preferences.hasMigratedV1LicenseKey = true
    guard model.preferences.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let licenseKey = v1LicenseKey()
    else {
      persistPreferences()
      return
    }

    // The key is shown in the License settings even if the activation fails.
    model.preferences.licenseKey = licenseKey
    persistPreferences()
    Task { [weak self] in
      do {
        try await self?.activateLicenseKey(licenseKey)
      } catch {
        self?.model.lastError = error.localizedDescription
      }
    }
  }

  private func v1LicenseKey() -> String? {
    guard let preferences = UserDefaults.standard.persistentDomain(forName: Self.v1PreferencesDomain),
          let licenseKey = preferences[Self.v1LicenseKeyPreferenceKey] as? String else {
      return nil
    }

    let sanitizedLicenseKey = licenseKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
    guard !sanitizedLicenseKey.isEmpty else {
      return nil
    }

    return sanitizedLicenseKey
  }
  #endif

  func activateLicenseKey(_ licenseKey: String) async throws {
    let sanitizedLicenseKey = licenseKey.replacingOccurrences(of: " ", with: "")
    try await licensingService.activate(licenseKey: sanitizedLicenseKey)
    model.preferences.licenseKey = sanitizedLicenseKey
    savePreferences()
  }

  // The key stays in preferences, so it's still in the License settings to
  // activate again later. Activation is tracked by the licensing runtime key,
  // which deactivation removes, not by the stored key.
  func deactivateLicenseKey() async throws {
    try await licensingService.deactivate(licenseKey: model.preferences.licenseKey)
  }

  // Keeps what the user left in the License settings field while the license
  // isn't activated, so it's still there the next time the settings open.
  func updateUnactivatedLicenseKey(_ licenseKey: String) {
    guard !licenseState.isActivated,
          model.preferences.licenseKey != licenseKey else {
      return
    }

    model.preferences.licenseKey = licenseKey
    persistPreferences()
  }

  /// While the discount after the trial runs, its code goes along to the
  /// pricing page, which hands it to the checkout.
  func openBuyLicenseURL() {
    guard var components = URLComponents(string: "https://clipbook.app/pricing/") else {
      return
    }

    if case .discount(let endsAt) = trialNotice, Date() < endsAt {
      components.queryItems = [URLQueryItem(name: "discount", value: TrialOffer.discountCode)]
    }
    guard let url = components.url else {
      return
    }

    NSWorkspace.shared.open(url)
  }

  func sendTrialExpiredFeedback(_ feedback: TrialExpiredFeedback) {
    model.preferences.hasProvidedTrialExpiredFeedback = true
    persistPreferences()

    let reasons = feedback.reasons.isEmpty
      ? L10n.string("No reason selected")
      : feedback.reasons.joined(separator: ", ")
    let message = feedback.message.isEmpty
      ? L10n.string("Not provided")
      : feedback.message
    let email = feedback.email.isEmpty
      ? L10n.string("Not provided")
      : feedback.email
    let body = """
    \(L10n.string("Reasons")): \(reasons)

    \(L10n.string("Feedback")):
    \(message)

    \(L10n.string("Email")):
    \(email)
    """

    Task {
      await licensingService.sendFeedback(text: body)
    }
  }
  
  /// Deletes the history for good, the Trash included, as clearing it on quit
  /// or after a restart is meant to leave nothing behind.
  func clearHistory() {
    let lockState = syncStoreLockState()
    guard lockState == .unlocked else {
      model.lastError = Self.lockedStoreErrorMessage(for: lockState)
      return
    }
    cancelOrphanedFileSweeps(waitUntilDone: false)
    ImageDragFiles.removeAll()
    do {
      let keepingItems = model.preferences.keepFavoritesOnClearHistory
      let deletedItems = model.items.filter { !keepingItems || !shouldKeepWhenClearingHistory($0) }
        + (try historyStore.fetchTrashedItems())
      try historyStore.clear(keepingFavoritesAndTaggedItems: keepingItems)
      if keepingItems {
        deletedItems.forEach(removeLinkPreviewFiles)
        removeFilePreviewFiles(for: deletedItems, remainingItems: model.items.filter(shouldKeepWhenClearingHistory))
      } else {
        ImageAssetThumbnailLoader.shared.removeAll()
        ImageAssetThumbnailLoader.shared.removeThumbnails(inDirectory: linkPreviewsDirectory)
        scrubManagedDirectoryFiles(at: linkPreviewsDirectory)
        try? fileManager.removeItem(at: linkPreviewsDirectory)
        filePreviewCache.removeAll()
      }
      removeAssetFiles(for: deletedItems, remainingItems: model.items.filter { keepingItems && shouldKeepWhenClearingHistory($0) })
      model.remove(Set(deletedItems.map(\.id)))
      HistoryRowTextCache.removeAll()
    } catch {
      _ = syncStoreLockState()
      model.lastError = PersistenceErrorLocalization.message(for: error)
    }
  }

  /// The "Delete All" command acts on what the list currently shows, so
  /// narrowing the history to a single app, tag or search query and running it
  /// removes just those items instead of the whole history.
  func clearHistoryWithWarningIfNeeded() {
    guard allowsUsingHistoryItems() else {
      return
    }

    // What the Trash shows is already deleted, so deleting all of it empties it.
    guard !model.isShowingTrash else {
      emptyTrash()
      return
    }

    guard model.isHistoryNarrowed else {
      guard shouldProceedWithClearHistory(isNarrowed: false) else {
        return
      }

      guard model.preferences.isTrashEnabled else {
        clearHistory()
        return
      }

      let keepingItems = model.preferences.keepFavoritesOnClearHistory
      do {
        try moveToTrash(model.items.filter { !keepingItems || !shouldKeepWhenClearingHistory($0) })
      } catch {
        model.lastError = error.localizedDescription
      }
      return
    }

    let deletedItems = clearableHistoryItems()
    guard !deletedItems.isEmpty, shouldProceedWithClearHistory(isNarrowed: true) else {
      return
    }

    do {
      try moveToTrash(deletedItems)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func clearableHistoryItems() -> [ClipboardItem] {
    let keepingItems = model.preferences.keepFavoritesOnClearHistory
    return model.filteredItems.filter { !keepingItems || !shouldKeepWhenClearingHistory($0) }
  }
  
  func pasteSelection() {
    guard allowsUsingHistoryItems() else {
      return
    }

    let selectedItems = model.selectedItems
    guard !selectedItems.isEmpty else {
      return
    }

    guard selectedItems.count > 1 else {
      guard let item = selectedItems.first else {
        return
      }
      paste(item, variant: preferredPasteVariant(for: item.kind))
      return
    }

    let variants = Dictionary(uniqueKeysWithValues: selectedItems.map { item in
      (item.id, preferredPasteVariant(for: item.kind))
    })
    paste(selectedItems, variants: variants)
  }

  /// Pastes the selected items and then removes them from the history, which
  /// suits single-use content such as one-time codes.
  func pasteAndDeleteSelection() {
    pasteAndDelete(model.selectedItems)
  }

  /// Without a variant each item is pasted the way the paste shortcut pastes it.
  func pasteAndDelete(_ items: [ClipboardItem], variant: PasteVariant? = nil) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard canPasteAndDelete(items) else {
      return
    }

    let variants = Dictionary(uniqueKeysWithValues: items.map { item in
      (item.id, variant ?? preferredPasteVariant(for: item.kind))
    })
    paste(items, variants: variants, deletesAfterPaste: true)
  }

  /// Items the history always keeps cannot be deleted by pasting them, so the
  /// action is not offered for them at all rather than pasting without
  /// deleting.
  func canPasteAndDelete(_ items: [ClipboardItem]) -> Bool {
    !items.isEmpty && items.allSatisfy { item in
      !(model.preferences.keepFavoritesOnClearHistory && shouldKeepWhenClearingHistory(item))
    }
  }

  // While the history panel is open the highlighted item is what the user
  // expects to paste, so the paste-next hotkeys stay out of the way instead of
  // hiding the panel and pasting a different item.
  private func pasteNextItemFromGlobalShortcut(variant: PasteVariant?, deletesAfterPaste: Bool = false) {
    guard historyWindow?.isVisible != true else {
      return
    }

    pasteNextItem(variant: variant, deletesAfterPaste: deletesAfterPaste)
  }

  private func pasteNextItem(variant: PasteVariant?, deletesAfterPaste: Bool = false) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let items = model.filteredHistoryItems
    let pasteNextItems = historyItemsForPasteNext(in: items)
    guard let item = historyItemForPasteNext(in: pasteNextItems) else {
      return
    }

    // An item the history always keeps is pasted without being deleted, so the
    // hotkey still moves on to the next item instead of getting stuck on it.
    let deletesItem = deletesAfterPaste && canPasteAndDelete([item])
    var nextItemID = nextHistoryItemID(after: item.id, in: pasteNextItems)
    if deletesItem, nextItemID == item.id {
      nextItemID = nil
    }
    paste(item, variant: variant ?? preferredPasteVariant(for: item.kind), deletesAfterPaste: deletesItem) { [weak self] in
      self?.clipboardMonitor.markCopySequencePasteBoundary()
      self?.pasteNextItemID = nextItemID
      self?.selectSingleHistoryItem(nextItemID)
    }
  }

  private func preferredPasteVariant(for kind: ClipboardKind) -> PasteVariant {
    switch kind {
    case .text, .richText, .link, .email, .color:
      return model.preferences.preferPastingAsPlainText ? .plainText : .standard
    case .image, .file:
      return .standard
    }
  }
  
  func paste(_ item: ClipboardItem, variant: PasteVariant = .standard) {
    paste(item, variant: variant) {}
  }

  private func paste(
    _ item: ClipboardItem,
    variant: PasteVariant,
    deletesAfterPaste: Bool = false,
    onSuccess: @escaping @MainActor () -> Void
  ) {
    guard allowsUsingHistoryItems() else {
      return
    }

    hideHistoryWindowForPaste()
    // The synthetic Cmd+V is posted directly to the target application's
    // process, so there is no need to wait for the window server to settle key
    // focus after the panel is hidden; pasting runs synchronously right away.
    do {
      try pasteRecordingHistory(item, variant: variant, deletesAfterPaste: deletesAfterPaste)
      onSuccess()
    } catch {
      model.lastError = error.localizedDescription
      showAccessibilityAlertIfNeeded(error)
    }
  }

  private func pasteRecordingHistory(
    _ item: ClipboardItem,
    variant: PasteVariant,
    deletesAfterPaste: Bool = false
  ) throws {
    if let onboardingPasteTarget {
      try pasteService.copy(item, variant: variant)
      onboardingPasteTarget.paste(item)
    } else {
      try pasteService.paste(item, variant: variant)
    }
    playSound(.paste)
    // The pasteboard already holds the item's data at this point, so removing
    // the item (and its asset files) cannot affect what gets pasted.
    if deletesAfterPaste {
      try moveToTrash([item])
      interruptCopySequenceTracking()
      return
    }

    let updated = try recordHistoryAction(for: item, incrementsCopyCount: true)
    updated.map(model.replace)
    interruptCopySequenceTracking()
  }

  private func historyItemForPasteNext(in items: [ClipboardItem]) -> ClipboardItem? {
    guard !items.isEmpty else {
      return nil
    }

    // A remembered selection is what the history shows when it opens, so it is
    // also what gets pasted next. Pasting the next item moves the selection on.
    if !model.preferences.rememberHistorySelection,
       let pasteNextItemID,
       let pasteNextItem = items.first(where: { $0.id == pasteNextItemID }) {
      return pasteNextItem
    }

    if let selectedItemID = model.selectedItemID,
       let selectedItem = items.first(where: { $0.id == selectedItemID }) {
      return selectedItem
    }

    return items.first
  }

  /// Internal so tests can reach the paste-next ordering rule without pasting.
  func historyItemsForPasteNext(in items: [ClipboardItem]) -> [ClipboardItem] {
    guard model.preferences.pinFavoritesToTop,
          !model.selectedHistoryFilterContentTypes.contains(.favorites) else {
      return items
    }

    let nonFavorites = items.filter { !$0.isFavorite }
    return nonFavorites.isEmpty ? items : nonFavorites
  }

  private func nextHistoryItemID(after itemID: ClipboardItem.ID, in items: [ClipboardItem]) -> ClipboardItem.ID? {
    guard !items.isEmpty,
          let index = items.firstIndex(where: { $0.id == itemID }) else {
      return nil
    }

    let nextIndex = items.index(after: index)
    if nextIndex < items.endIndex {
      return items[nextIndex].id
    }

    return items.first?.id
  }

  private func selectSingleHistoryItem(_ itemID: ClipboardItem.ID?) {
    model.selectedItemID = itemID
    model.selectedItemIDs = itemID.map { [$0] } ?? []
    model.selectedItemIDsInSelectionOrder = itemID.map { [$0] } ?? []
  }

  private func resetPasteNextPointer() {
    pasteNextItemID = historyItemsForPasteNext(in: model.filteredHistoryItems).first?.id
  }

  var defaultMultiPasteKey: PasteInterItemAction {
    PasteInterItemAction(preferenceValue: model.preferences.multiPasteKey)
  }

  func setDefaultMultiPasteKey(_ action: PasteInterItemAction) {
    model.preferences.multiPasteKey = action.rawValue
    preferencesStore.save(model.preferences)
  }

  func paste(
    _ items: [ClipboardItem],
    variants: [ClipboardItem.ID: PasteVariant],
    interItemAction: PasteInterItemAction? = nil,
    deletesAfterPaste: Bool = false
  ) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard let firstItem = items.first else {
      return
    }

    // Without an explicit key the items are pasted with the key from the
    // settings between them, so every way of pasting several items agrees.
    let interItemAction = interItemAction ?? defaultMultiPasteKey

    hideHistoryWindowForPaste()
    // The first item is pasted synchronously so a multi-item paste starts as
    // instantly as a single-item paste. Only the remaining items run on a task,
    // which they need for the inter-item delays.

    do {
      try pasteRecordingHistory(
        firstItem,
        variant: variants[firstItem.id] ?? .standard,
        deletesAfterPaste: deletesAfterPaste
      )
    } catch {
      model.lastError = error.localizedDescription
      showAccessibilityAlertIfNeeded(error)
      return
    }

    // Onboarding takes a single item, and the keys typed between items
    // would need Accessibility permission anyway.
    let remainingItems = items.dropFirst()
    guard !remainingItems.isEmpty, onboardingPasteTarget == nil else {
      return
    }

    Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      do {
        for item in remainingItems {
          try await pasteService.perform(interItemAction)
          try await Task.sleep(for: .milliseconds(160))
          try pasteRecordingHistory(
            item,
            variant: variants[item.id] ?? .standard,
            deletesAfterPaste: deletesAfterPaste
          )
        }
      } catch {
        model.lastError = error.localizedDescription
        showAccessibilityAlertIfNeeded(error)
      }
    }
  }
  
  @discardableResult
  func copy(_ item: ClipboardItem) -> Bool {
    copy(item, variant: .standard)
  }

  @discardableResult
  func copy(_ item: ClipboardItem, variant: PasteVariant) -> Bool {
    guard allowsUsingHistoryItems() else {
      return false
    }

    do {
      try pasteService.copy(item, variant: variant)
      // Copying from the history puts the item on the clipboard, so it counts
      // as a copy the same way a paste does.
      if let updated = try recordHistoryAction(for: item, incrementsCopyCount: true) {
        model.replace(updated)
      }
      interruptCopySequenceTracking()
      playSound(.copy)
      return true
    } catch {
      model.lastError = error.localizedDescription
      return false
    }
  }
  
  @discardableResult
  func copyPlainText(_ item: ClipboardItem) -> Bool {
    copy(item, variant: .plainText)
  }

  @discardableResult
  func copyText(_ text: String, isConcealed: Bool = false) -> Bool {
    guard allowsUsingHistoryItems() else {
      return false
    }

    do {
      try pasteService.copyText(text, markAsGhost: false, markAsConcealed: isConcealed)
      interruptCopySequenceTracking()
      playSound(.copy)
      return true
    } catch {
      model.lastError = error.localizedDescription
      return false
    }
  }

  func mergeSelection() {
    merge(model.selectedItems)
  }

  func merge(_ items: [ClipboardItem]) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard items.count > 1,
          let text = mergedText(from: items) else {
      return
    }

    do {
      // The merged item comes from the app of the item its text starts with,
      // as Copy & Merge keeps the app of the item it appends to. The app in
      // front while merging has nothing to do with the content.
      let sensitivity: ItemSensitivity? = items.contains(where: { $0.sensitivity == .sensitive })
        ? .sensitive
        : nil
      let expiresAt = items.compactMap(\.expiresAt).min()
      let item = ClipboardItem(
        kind: ClipboardKind.classifyText(text, treatDigitNumbersAsColor: model.preferences.treatDigitNumbersAsColor),
        text: text,
        sourceAppName: items[0].sourceAppName,
        sourceBundleIdentifier: items[0].sourceBundleIdentifier,
        byteSize: text.utf8.count,
        searchText: text,
        sensitivity: sensitivity,
        expiresAt: expiresAt
      )
      try deleteExistingMatches(for: item)
      let saved = try historyStore.saveAndReconcileItem(item, convertingExternalAssets: true)
      model.insert(saved)
      if saved.expiresAt != nil {
        deleteExpiredItems()
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  @discardableResult
  func copyMergedSelection() -> Bool {
    copyMerged(model.selectedItems)
  }

  @discardableResult
  func copyMerged(_ items: [ClipboardItem]) -> Bool {
    guard allowsUsingHistoryItems() else {
      return false
    }

    guard items.count > 1,
          let text = mergedText(from: items) else {
      return false
    }

    let markAsConcealed = items.contains(where: SensitiveContent.shouldEncryptAtRest)
      || (!items.allSatisfy { $0.sensitivity == .notSensitive }
          && SensitiveContent.detectsBodySecretAtRest(kind: .text, text: text, qrCodeText: nil, html: nil))

    do {
      try pasteService.copyText(text, markAsGhost: true, markAsConcealed: markAsConcealed)
      interruptCopySequenceTracking()
      playSound(.copy)
      return true
    } catch {
      model.lastError = error.localizedDescription
      return false
    }
  }
  
  func deleteSelection() {
    delete(model.selectedItems)
  }

  func delete(_ items: [ClipboardItem]) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard !items.isEmpty else {
      return
    }
    
    do {
      try moveToTrash(items)
      playSound(.delete)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Deletes the items from the store for good, drops their cached previews,
  /// and takes them out of the model. Items in the Trash are deleted the same
  /// way as items in the history.
  private func removeFromHistory(_ items: [ClipboardItem]) throws {
    guard !items.isEmpty else {
      return
    }

    let deletedItemIDs = Set(items.map(\.id))
    try historyStore.delete(ids: items.map(\.id))
    // A menu or a row may hold a copy of an item from before its link preview
    // was saved, so the files are taken from the item as the history has it now.
    var currentItemsByID: [ClipboardItem.ID: ClipboardItem] = [:]
    for item in model.items where deletedItemIDs.contains(item.id) && currentItemsByID[item.id] == nil {
      currentItemsByID[item.id] = item
    }
    for item in model.trashedItems where deletedItemIDs.contains(item.id) && currentItemsByID[item.id] == nil {
      currentItemsByID[item.id] = item
    }
    let items = items.map { currentItemsByID[$0.id] ?? $0 }
    items.forEach(removeLinkPreviewFiles)
    if items.contains(where: { !$0.filePaths.isEmpty || $0.assetPath != nil }) {
      // An item in the Trash keeps its files, so they are spared as long as it
      // or an item in the history still names them.
      let remainingItems = model.items.filter { !deletedItemIDs.contains($0.id) }
        + ((try? historyStore.fetchTrashedItems()) ?? []).filter { !deletedItemIDs.contains($0.id) }
      removeFilePreviewFiles(for: items, remainingItems: remainingItems)
      removeAssetFiles(for: items, remainingItems: remainingItems)
    }
    model.remove(deletedItemIDs)
    HistoryRowTextCache.removeAll()
  }

  // MARK: - Trash

  /// Moves the items to the Trash, where they keep their files and can be
  /// put back until the Trash period runs out. With the Trash turned off they
  /// are deleted for good. So is an item whose content the history hides,
  /// since a secret the user deletes is expected to be gone.
  private func moveToTrash(_ items: [ClipboardItem]) throws {
    guard !items.isEmpty else {
      return
    }

    guard model.preferences.isTrashEnabled else {
      try removeFromHistory(items)
      return
    }

    let sensitiveItems = items.filter(SensitiveContent.shouldEncryptAtRest)
    try removeFromHistory(sensitiveItems)

    let sensitiveItemIDs = Set(sensitiveItems.map(\.id))
    let trashedItemIDs = items.map(\.id).filter { !sensitiveItemIDs.contains($0) }
    guard !trashedItemIDs.isEmpty else {
      return
    }

    let selection = model.selection
    let deletedAt = Date()
    try historyStore.moveToTrash(ids: trashedItemIDs, at: deletedAt)
    let trashedIDSet = Set(trashedItemIDs)
    let currentItemsByID = Dictionary(
      model.items.filter { trashedIDSet.contains($0.id) }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let trashedItems = items
      .filter { trashedIDSet.contains($0.id) }
      .map { item -> ClipboardItem in
        var item = currentItemsByID[item.id] ?? item
        item.deletedAt = deletedAt
        return item
      }
    model.remove(trashedIDSet)
    model.insertIntoTrash(trashedItems)

    historyUndoManager.registerUndo(withTarget: self) { coordinator in
      coordinator.restoreFromTrash(ids: trashedItemIDs, selection: selection)
    }
  }

  /// Puts items in the Trash back in the history. Undoing it moves them back.
  /// An undone deletion brings back the selection it was made with.
  private func restoreFromTrash(ids: [ClipboardItem.ID], selection: HistorySelection? = nil) {
    let idSet = Set(ids)
    do {
      let restoredItems = try historyStore.fetchTrashedItems().filter { idSet.contains($0.id) }
      guard !restoredItems.isEmpty else {
        return
      }

      try historyStore.restoreFromTrash(ids: restoredItems.map(\.id))
      model.remove(Set(restoredItems.map(\.id)))
      model.restore(restoredItems, selection: selection)
      let restoredItemIDs = restoredItems.map(\.id)
      historyUndoManager.registerUndo(withTarget: self) { coordinator in
        coordinator.moveToTrash(ids: restoredItemIDs)
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Moves items of the history to the Trash again, when a restore is undone.
  private func moveToTrash(ids: [ClipboardItem.ID]) {
    let idSet = Set(ids)
    do {
      try moveToTrash(model.items.filter { idSet.contains($0.id) })
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func putBack(_ items: [ClipboardItem]) {
    guard allowsUsingHistoryItems() else {
      return
    }

    restoreFromTrash(ids: items.map(\.id))
  }

  func undoHistoryChange() {
    guard allowsUsingHistoryItems(), historyUndoManager.canUndo else {
      return
    }

    historyUndoManager.undo()
  }

  func redoHistoryChange() {
    guard allowsUsingHistoryItems(), historyUndoManager.canRedo else {
      return
    }

    historyUndoManager.redo()
  }

  /// Deletes items in the Trash for good, once the user confirms it.
  func deleteImmediately(_ items: [ClipboardItem]) {
    guard allowsUsingHistoryItems(), !items.isEmpty else {
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = items.count == 1
      ? L10n.string("Are you sure you want to delete this item immediately?")
      : L10n.string("Are you sure you want to delete %d items immediately?", items.count)
    alert.informativeText = L10n.string("You can't undo this action.")
    let deleteButton = alert.addButton(withTitle: L10n.string("Delete"))
    deleteButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.string("Cancel"))
    presentOnHistoryWindow(alert) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else {
        return
      }

      do {
        try removeFromHistory(items)
        playSound(.delete)
      } catch {
        model.lastError = error.localizedDescription
      }
    }
  }

  /// Deletes everything in the Trash for good, once the user confirms it. From
  /// Settings the confirmation is a sheet on the settings window.
  func emptyTrash(fromSettings: Bool = false) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let items: [ClipboardItem]
    do {
      items = try historyStore.fetchTrashedItems()
    } catch {
      model.lastError = error.localizedDescription
      return
    }
    guard !items.isEmpty else {
      // The history shows that the Trash is empty, but Settings does not,
      // so the button would otherwise seem to do nothing.
      if fromSettings {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Trash is empty")
        alert.informativeText = L10n.string("There are no items to delete.")
        present(alert) { _ in }
      }
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.string("Are you sure you want to permanently erase the items in the Trash?")
    alert.informativeText = L10n.string("You can't undo this action.")
    let emptyButton = alert.addButton(withTitle: L10n.string("Empty Trash"))
    emptyButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.string("Cancel"))
    let deleteItems = { [weak self] in
      do {
        try self?.removeFromHistory(items)
        self?.playSound(.delete)
      } catch {
        self?.model.lastError = error.localizedDescription
      }
    }
    let completion = { (response: NSApplication.ModalResponse) in
      if response == .alertFirstButtonReturn {
        deleteItems()
      }
    }
    if fromSettings {
      present(alert, completionHandler: completion)
    } else {
      presentOnHistoryWindow(alert, completionHandler: completion)
    }
  }

  /// Shows the alert as a sheet on the history window while it is on screen,
  /// so the history stays open behind it, or as a modal alert otherwise. A
  /// sheet still closing, such as the command palette, goes first.
  private func presentOnHistoryWindow(
    _ alert: NSAlert,
    completionHandler: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    guard let window = historyWindow?.window, window.isVisible else {
      completionHandler(alert.runModal())
      return
    }

    alert.beginSheetModal(for: window, completionHandler: completionHandler)
  }

  /// Applies a new Trash period. Items that have been in the Trash longer
  /// are deleted right away, as they would be on the next check.
  func setTrashRetentionDays(_ days: Int) {
    guard days != model.preferences.trashRetentionDays else {
      return
    }

    model.preferences.trashRetentionDays = days
    savePreferences()
    purgeExpiredTrashedItems()
  }

  /// Deletes the items that have been in the Trash longer than its period,
  /// or all of them once the Trash is turned off.
  private func purgeExpiredTrashedItems() {
    guard historyStore.lockState == .unlocked else {
      return
    }
    let days = model.preferences.trashRetentionDays
    let cutoff = days > 0
      ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
      : Date.distantFuture
    do {
      try removeFromHistory(try historyStore.fetchItems(trashedBefore: cutoff))
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// The Trash is read from the store when it is shown and let go when it is
  /// not. The change arrives before the filter is stored, so the list built
  /// for the Trash already has its items.
  private func observeTrashVisibility() {
    model.$selectedHistoryFilterContentTypes
      .map { $0.contains(.trash) }
      .removeDuplicates()
      .sink { [weak self] isShowingTrash in
        self?.setTrashLoaded(isShowingTrash)
      }
      .store(in: &cancellables)
  }

  private func setTrashLoaded(_ isLoaded: Bool) {
    guard isLoaded else {
      if !model.trashedItems.isEmpty {
        model.trashedItems = []
      }
      return
    }
    guard historyStore.lockState == .unlocked else {
      if !model.trashedItems.isEmpty {
        model.trashedItems = []
      }
      return
    }

    purgeExpiredTrashedItems()
    do {
      model.trashedItems = try historyStore.fetchTrashedItems()
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  // MARK: - History retention

  /// Applies a new "Keep history" period for one group of item kinds. When
  /// items already exceed it, the user is asked before they are deleted;
  /// cancelling restores the previous period.
  func setRetentionDays(_ days: Int, for clipType: RetentionClipType) {
    let keyPath = clipType.preferenceKeyPath
    let previousDays = model.preferences[keyPath: keyPath]
    guard days != previousDays else {
      return
    }

    model.preferences[keyPath: keyPath] = days
    let policy = HistoryRetentionPolicy(preferences: model.preferences, kinds: clipType.kinds)
    var expiredItems: [ClipboardItem] = []
    if !policy.isEmpty {
      do {
        expiredItems = try historyStore.fetchItems(expiredBy: policy)
      } catch {
        model.lastError = error.localizedDescription
      }
    }
    guard !expiredItems.isEmpty else {
      savePreferences()
      return
    }

    isRetentionPromptPresented = true
    presentRetentionChangeAlert { [weak self] confirmed in
      guard let self else {
        return
      }
      isRetentionPromptPresented = false
      guard confirmed else {
        model.preferences[keyPath: keyPath] = previousDays
        return
      }
      do {
        try removeFromHistory(expiredItems)
      } catch {
        model.lastError = error.localizedDescription
      }
      savePreferences()
    }
  }

  private func presentRetentionChangeAlert(completion: @escaping (Bool) -> Void) {
    presentDeletionAlert(
      message: L10n.string("You have items older than the new history limit. Do you want to delete these older items and apply the new limit?"),
      completion: completion
    )
  }

  /// The items among `itemIDs` that have outlived their "Keep history" period.
  private func expiredItems(among itemIDs: Set<ClipboardItem.ID>) -> [ClipboardItem] {
    let policy = HistoryRetentionPolicy(preferences: model.preferences)
    guard !policy.isEmpty, !itemIDs.isEmpty else {
      return []
    }

    do {
      return try historyStore.fetchItems(expiredBy: policy).filter { itemIDs.contains($0.id) }
    } catch {
      model.lastError = error.localizedDescription
      return []
    }
  }

  /// An archive can bring in items older than the "Keep history" period of
  /// their type, which the next retention check would delete without a word.
  /// The user either keeps them, which makes those types unlimited, or
  /// deletes them right away. The retention check waits for the answer.
  private func confirmKeepingExpiredImportedItems(_ expiredItems: [ClipboardItem]) {
    let expiredKinds = Set(expiredItems.map(\.kind))
    let clipTypes = RetentionClipType.allCases.filter { !$0.kinds.isDisjoint(with: expiredKinds) }
    let listFormatter = ListFormatter()
    listFormatter.locale = L10n.currentLocale
    let clipTypeTitles = listFormatter.string(from: clipTypes.map(\.title)) ?? ""

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.string("Some imported items are older than the history limit. Do you want to keep them?")
    alert.informativeText = L10n.string("Keeping them sets the history limit for %@ to Unlimited. Otherwise they will be deleted.", clipTypeTitles)
    alert.addButton(withTitle: L10n.string("Keep Items"))
    let deleteButton = alert.addButton(withTitle: L10n.string("Delete"))
    deleteButton.hasDestructiveAction = true

    present(alert) { [weak self] response in
      guard let self else {
        return
      }
      isRetentionPromptPresented = false
      if response == .alertFirstButtonReturn {
        for clipType in clipTypes {
          model.preferences[keyPath: clipType.preferenceKeyPath] = AppPreferences.unlimitedRetentionDays
        }
        savePreferences()
      } else {
        do {
          try removeFromHistory(expiredItems)
        } catch {
          model.lastError = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Ignored applications

  /// Adds applications to the ignore list. When the history already holds
  /// items copied from them, the user is asked whether to delete those too.
  /// Declining keeps the items but still ignores the applications.
  func addIgnoredApplications(atPaths paths: [String]) {
    let existingEntries = model.preferences.ignoredApplicationEntries
    var addedApplications: [IgnoredApplication] = []
    for path in paths where !existingEntries.contains(path) && !addedApplications.contains(where: { $0.path == path }) {
      addedApplications.append(IgnoredApplication(path: path))
    }
    guard !addedApplications.isEmpty else {
      return
    }

    model.preferences.ignoredAppsText = (existingEntries + addedApplications.map(\.path)).joined(separator: "\n")
    savePreferences()

    let keepsProtectedItems = model.preferences.keepFavoritesOnClearHistory
    var items: [ClipboardItem] = []
    do {
      items = try historyStore.fetchItems { item in
        addedApplications.contains { $0.matches(item) }
          && !(keepsProtectedItems && shouldKeepWhenClearingHistory(item))
      }
    } catch {
      model.lastError = error.localizedDescription
    }
    guard !items.isEmpty else {
      return
    }

    let message = addedApplications.count == 1
      ? L10n.string("You have items copied from %@. Do you want to delete these items?", addedApplications[0].name)
      : L10n.string("You have items copied from the newly ignored applications. Do you want to delete these items?")
    presentDeletionAlert(message: message) { [weak self] confirmed in
      guard let self, confirmed else {
        return
      }
      do {
        try removeFromHistory(items)
      } catch {
        model.lastError = error.localizedDescription
      }
    }
  }

  // MARK: - Sensitive content

  /// Applies how long confidential content is kept. It applies to content
  /// copied from now on.
  func setConfidentialContentLifetime(_ lifetime: Int) {
    guard lifetime != model.preferences.confidentialContentLifetime else {
      return
    }

    model.preferences.confidentialContentLifetime = lifetime
    savePreferences()
  }

  /// Applies how long sensitive content is kept. A period applies to secrets
  /// copied from now on. Not saving them only stops new secrets from coming
  /// in: when the history already holds some, the user is asked whether to
  /// delete them, and declining keeps them.
  func setSensitiveContentLifetime(_ lifetime: Int) {
    guard lifetime != model.preferences.sensitiveContentLifetime else {
      return
    }

    model.preferences.sensitiveContentLifetime = lifetime
    savePreferences()
    guard lifetime == ContentLifetime.dontSave else {
      return
    }

    let keepsProtectedItems = model.preferences.keepFavoritesOnClearHistory
    var items: [ClipboardItem] = []
    do {
      items = try historyStore.fetchItems { item in
        SensitiveContent.containsSensitiveContent(item)
          && !(keepsProtectedItems && shouldKeepWhenClearingHistory(item))
      }
    } catch {
      model.lastError = error.localizedDescription
    }
    guard !items.isEmpty else {
      return
    }

    let message = items.count == 1
      ? L10n.string("Your history contains an item with sensitive content. Do you want to delete it?")
      : L10n.string("Your history contains %d items with sensitive content. Do you want to delete these items?", items.count)
    presentDeletionAlert(message: message) { [weak self] confirmed in
      guard let self, confirmed else {
        return
      }
      do {
        try removeFromHistory(items)
      } catch {
        model.lastError = error.localizedDescription
      }
    }
  }

  /// A Delete/Cancel alert on the settings window whose details spell out
  /// whether favorites and tagged items are spared.
  private func presentDeletionAlert(message: String, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    if model.preferences.keepFavoritesOnClearHistory {
      alert.informativeText = L10n.string("Favorites and tagged items won't be deleted. This action cannot be undone.")
    } else {
      alert.informativeText = L10n.string("Favorites and tagged items will be deleted too. This action cannot be undone.")
    }
    let deleteButton = alert.addButton(withTitle: L10n.string("Delete"))
    deleteButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.string("Cancel"))

    present(alert) { response in
      completion(response == .alertFirstButtonReturn)
    }
  }

  /// Shows the alert on the settings window, or as a modal alert when the
  /// settings aren't open.
  private func present(_ alert: NSAlert, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
    if let settingsWindow {
      settingsWindow.presentAlert(alert, completionHandler: completionHandler)
    } else {
      completionHandler(alert.runModal())
    }
  }

  /// Removes items that outlived their "Keep history" period. Nothing is
  /// deleted while the user is still deciding on a new period, since they
  /// may cancel it, nor while an archive is being imported, since its items
  /// are checked once it is in.
  private func applyRetention() {
    guard !isRetentionPromptPresented,
          !isHistoryArchiveOperationRunning,
          historyStore.lockState == .unlocked else {
      return
    }

    purgeExpiredTrashedItems()
    let policy = HistoryRetentionPolicy(preferences: model.preferences)
    guard !policy.isEmpty else {
      return
    }

    do {
      try removeFromHistory(try historyStore.fetchItems(expiredBy: policy))
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Deletes the items whose own expiry date has come, such as confidential
  /// content kept for a limited time, and sets a timer for the next one.
  /// They skip the Trash. While an archive is written or read, the items are
  /// left alone; this runs again once that is done.
  private func deleteExpiredItems() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    guard !isHistoryArchiveOperationRunning,
          historyStore.lockState == .unlocked else {
      return
    }

    do {
      let now = Date()
      let expiredItems = try historyStore.fetchItems(expiringBy: now)
      if !expiredItems.isEmpty {
        try removeFromHistory(expiredItems)
      }
      if let nextExpiryDate = try historyStore.nextExpiryDate() {
        scheduleExpiryCheck(at: max(nextExpiryDate, now.addingTimeInterval(1)))
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func scheduleExpiryCheck(at date: Date) {
    let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.deleteExpiredItems()
      }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  /// A timer does not count the time the Mac sleeps, so items that came due
  /// during sleep are deleted on wake.
  private func observeWakeForExpiredItems() {
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.deleteExpiredItems()
      }
      .store(in: &cancellables)
  }

  /// Items also expire while nothing is being copied, so the check repeats
  /// on a timer in addition to running after each capture.
  private func scheduleRetentionChecks() {
    retentionTimer?.invalidate()
    let timer = Timer(timeInterval: Self.retentionCheckInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.applyRetention()
      }
    }
    timer.tolerance = 60
    RunLoop.main.add(timer, forMode: .common)
    retentionTimer = timer
  }

  func canMerge(_ items: [ClipboardItem]) -> Bool {
    items.count > 1 && items.allSatisfy { item in
      switch item.kind {
      case .text, .richText, .link, .email, .color:
        return item.hasTextContent
      case .file:
        return !item.filePaths.isEmpty
      case .image:
        return false
      }
    }
  }

  private static func hasMultipleNonEmptyLines(in text: String) -> Bool {
    guard text.contains(where: \.isNewline) else {
      return false
    }
    var nonEmptyLineCount = 0
    var index = text.startIndex
    while index < text.endIndex {
      let lineEnd = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
      if text[index..<lineEnd].unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) {
        nonEmptyLineCount += 1
        if nonEmptyLineCount > 1 {
          return true
        }
      }
      guard lineEnd < text.endIndex else {
        break
      }
      index = text.index(after: lineEnd)
    }
    return false
  }

  func canSplit(_ item: ClipboardItem) -> Bool {
    guard (item.kind == .text || item.kind == .richText), item.hasTextContent else {
      return false
    }
    if item.isContentLoaded {
      guard let text = item.text else {
        return false
      }
      return Self.hasMultipleNonEmptyLines(in: text)
    }
    if let textPreview = item.textPreview, Self.hasMultipleNonEmptyLines(in: textPreview) {
      return true
    }
    let previewCoversFullText = item.characterCount <= ClipboardItem.textPreviewBodyLimit
      && (item.textPreview?.utf16.count ?? 0) < ClipboardItem.textPreviewMaxUTF16Length - 2
      && !(item.hasFormatting && item.textPreview == nil)
    if previewCoversFullText {
      return false
    }
    return splitTextParts(for: item).count > 1
  }

  func split(_ item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let parts = splitTextParts(for: item)
    guard parts.count > 1 else {
      return
    }

    do {
      // Each part is a millisecond older than the one above it, so the history
      // lists the parts in the order they had in the text. With one shared
      // time the sort would fall back to the random item IDs.
      let splitAt = Date()
      let propagatedSensitivity: ItemSensitivity? = item.sensitivity == .sensitive ? .sensitive : nil
      let propagatedExpiresAt: Date? = item.isKeptByUser ? nil : item.expiresAt
      let newItems = parts.enumerated().map { index, text in
        let copiedAt = splitAt.addingTimeInterval(-0.001 * Double(index))
        return ClipboardItem(
          kind: ClipboardKind.classifyText(text, treatDigitNumbersAsColor: model.preferences.treatDigitNumbersAsColor),
          text: text,
          sourceAppName: item.sourceAppName,
          sourceBundleIdentifier: item.sourceBundleIdentifier,
          copiedAt: copiedAt,
          firstCopiedAt: copiedAt,
          byteSize: text.utf8.count,
          sensitivity: propagatedSensitivity,
          expiresAt: propagatedExpiresAt
        )
      }

      var savedItems: [ClipboardItem] = []
      savedItems.reserveCapacity(newItems.count)
      try historyStore.performInTransaction {
        for newItem in newItems {
          let saved = try historyStore.saveAndReconcileItem(newItem, convertingExternalAssets: false)
          savedItems.append(saved)
        }
      }
      let unloadedSavedItems = savedItems.map { $0.unloadingContent() }
      model.items.insert(contentsOf: unloadedSavedItems, at: 0)
      model.selectedItemID = unloadedSavedItems.first?.id
      model.selectedItemIDs = Set(unloadedSavedItems.map(\.id))
      model.selectedItemIDsInSelectionOrder = unloadedSavedItems.map(\.id)
      if savedItems.contains(where: { $0.expiresAt != nil }) {
        deleteExpiredItems()
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }
  
  func delete(_ item: ClipboardItem) {
    delete([item])
  }
  
  func toggleFavorite(_ item: ClipboardItem) {
    do {
      var updated = item
      updated.isFavorite.toggle()
      if !updated.isFavorite {
        updated.favoriteOrder = nil
      }
      try historyStore.upsert(updated)
      model.replace(updated)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Hides the content of the item in the history, or shows it again. Showing
  /// it is remembered as the user's choice, so content the app would hide on
  /// its own stays visible too.
  func setSensitive(_ isSensitive: Bool, for item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    do {
      guard let updated = try historyStore.setSensitivity(
        isSensitive ? .sensitive : .notSensitive,
        for: item.id
      ) else {
        return
      }
      reconcileSideEffectsAfterItemMutation(previous: item, updated: updated)
      model.replace(updated)
      if item.expiresAt != updated.expiresAt {
        deleteExpiredItems()
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func isItemHiddenInUI(_ item: ClipboardItem) -> Bool {
    if let contentVC = historyWindow?.window.contentViewController as? HistoryContentViewController {
      return contentVC.hidesSensitiveContent(of: item)
    }
    return SensitiveContent.isMasked(item, detectsAutomatically: model.preferences.detectSensitiveContent)
  }

  private func reconcileSideEffectsAfterItemMutation(previous: ClipboardItem, updated: ClipboardItem) {
    let wasEncrypted = SensitiveContent.shouldEncryptAtRest(previous)
    let nowEncrypted = SensitiveContent.shouldEncryptAtRest(updated)

    if let prevAsset = previous.assetPath, prevAsset != updated.assetPath {
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: prevAsset)
    }
    if let prevPreview = previous.linkPreviewDetails?.imagePath,
       prevPreview != updated.linkPreviewDetails?.imagePath {
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: prevPreview)
    }
    if let prevFavicon = previous.linkPreviewDetails?.faviconPath,
       prevFavicon != updated.linkPreviewDetails?.faviconPath {
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: prevFavicon)
    }

    if nowEncrypted {
      linkPreviewTasksByItemID[updated.id]?.cancel()
      linkPreviewTasksByItemID[updated.id] = nil
      pendingLinkPreviewModelUpdatesByItemID[updated.id] = nil

      if updated.kind == .image {
        ImageDragFiles.removeAll()
        if isItemHiddenInUI(updated), let currentAsset = updated.assetPath {
          ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: currentAsset)
        }
      }

      if updated.kind == .file && !updated.filePaths.isEmpty {
        filePreviewCache.removePreviews(forFilePaths: Set(updated.filePaths))
        if !wasEncrypted || isItemHiddenInUI(updated) {
          for path in updated.filePaths {
            ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: path)
          }
        }
      }

      if updated.kind == .link, isItemHiddenInUI(updated) {
        if let imgPath = updated.linkPreviewDetails?.imagePath {
          ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: imgPath)
        }
        if let favPath = updated.linkPreviewDetails?.faviconPath {
          ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: favPath)
        }
      }

      if !wasEncrypted {
        HistoryRowTextCache.removeAll()
      }
    }
  }

  func setFavorite(_ isFavorite: Bool, for items: [ClipboardItem]) {
    var updatedItems: [ClipboardItem] = []
    for item in items where item.isFavorite != isFavorite {
      var updated = item
      updated.isFavorite = isFavorite
      if !isFavorite {
        updated.favoriteOrder = nil
      }
      updatedItems.append(updated)
    }
    guard !updatedItems.isEmpty else {
      return
    }

    do {
      if updatedItems.count == 1, let single = updatedItems.first {
        try historyStore.upsert(single)
        model.replace(single)
      } else {
        try historyStore.performInTransaction {
          for updated in updatedItems {
            try historyStore.upsert(updated)
          }
        }
        model.replace(updatedItems)
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Moves the favorites with the given IDs, keeping their relative order, so
  /// they sit right before the favorite `targetItemID` names among the pinned
  /// favorites, or at the end when it is nil. Every favorite ends up with an
  /// explicit order so the arrangement survives whatever sort and filter the
  /// history is in, not just the rows that were visible for the drag.
  func moveFavorites(_ itemIDs: [UUID], before targetItemID: UUID?) {
    let movingIDs = Set(itemIDs)
    let favorites = model.favoritesInDisplayOrder
    let movingItems = favorites.filter { movingIDs.contains($0.id) }
    var arrangedItems = favorites.filter { !movingIDs.contains($0.id) }
    guard !movingItems.isEmpty else {
      return
    }

    let insertionIndex = targetItemID.flatMap { targetID in
      arrangedItems.firstIndex { $0.id == targetID }
    } ?? arrangedItems.count
    arrangedItems.insert(contentsOf: movingItems, at: insertionIndex)

    var updatedItems: [ClipboardItem] = []
    for (order, item) in arrangedItems.enumerated() where item.favoriteOrder != order {
      var updated = item
      updated.favoriteOrder = order
      updatedItems.append(updated)
    }
    guard !updatedItems.isEmpty else {
      return
    }

    do {
      try historyStore.performInTransaction {
        for item in updatedItems {
          try historyStore.upsert(item)
        }
      }
      model.replace(updatedItems)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Moves the items of the tag with the given IDs, keeping their relative
  /// order, so they sit right before the item `targetItemID` names among the
  /// items of the tag, or at the end when it is nil. Like favorites, every
  /// item of the tag ends up with an explicit place, so the arrangement holds
  /// whatever other filter or search narrowed the list during the drag.
  func moveItems(_ itemIDs: [UUID], inTag tagID: Tag.ID, before targetItemID: UUID?) {
    let movingIDs = Set(itemIDs)
    let taggedItems = model.itemsInTagOrder(tagID)
    let movingItems = taggedItems.filter { movingIDs.contains($0.id) }
    var arrangedItems = taggedItems.filter { !movingIDs.contains($0.id) }
    guard !movingItems.isEmpty else {
      return
    }

    let insertionIndex = targetItemID.flatMap { targetID in
      arrangedItems.firstIndex { $0.id == targetID }
    } ?? arrangedItems.count
    arrangedItems.insert(contentsOf: movingItems, at: insertionIndex)

    var updatedItems: [ClipboardItem] = []
    for (order, item) in arrangedItems.enumerated() where item.tagOrders[tagID] != order {
      var updated = item
      updated.tagOrders[tagID] = order
      updatedItems.append(updated)
    }
    guard !updatedItems.isEmpty else {
      return
    }

    do {
      try historyStore.performInTransaction {
        for item in updatedItems {
          try historyStore.upsert(item)
        }
      }
      model.replace(updatedItems)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func rename(_ item: ClipboardItem, title: String?) {
    guard allowsUsingHistoryItems() else {
      return
    }

    do {
      var updated = item
      updated.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      updated = updated.rebuildingSearchText(tagNames: model.tagNames(for: updated.tags))
      let convertsAssets = !(updated.kind == .image && isImageRecognitionPending(for: updated.id))
      let saved = try historyStore.saveAndReconcileItem(updated, convertingExternalAssets: convertsAssets)
      reconcileSideEffectsAfterItemMutation(previous: item, updated: saved)
      model.replace(saved)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func editContent(_ item: ClipboardItem, text: String) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard item.kind.canEditTextContent else {
      model.lastError = "\(item.kind.title) cannot be edited."
      return
    }

    let item = (try? historyStore.loadingContent(of: item, scope: .body)) ?? item

    do {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        try moveToTrash([item])
        return
      }

      var updated = item
      let previousContentKey = updated.contentKey
      updated.text = text
      updated.byteSize = text.utf8.count
      updated.kind = ClipboardKind.classifyText(text, treatDigitNumbersAsColor: model.preferences.treatDigitNumbersAsColor)
      if item.kind == .richText {
        updated.removeFormatting()
      }
      if updated.kind != .link || updated.contentKey != previousContentKey {
        removeLinkPreviewFiles(for: updated)
        updated.linkPreviewDetails = nil
        linkPreviewTasksByItemID[item.id]?.cancel()
        linkPreviewTasksByItemID[item.id] = nil
        pendingLinkPreviewModelUpdatesByItemID[item.id] = nil
      }
      updated = updated.rebuildingSearchText(tagNames: model.tagNames(for: updated.tags))
      let convertsAssets = !(updated.kind == .image && isImageRecognitionPending(for: updated.id))
      let saved = try historyStore.saveAndReconcileItem(updated, convertingExternalAssets: convertsAssets)
      reconcileSideEffectsAfterItemMutation(previous: item, updated: saved)
      model.replace(saved)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func transform(_ item: ClipboardItem, using transform: ClipboardTextTransform) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let item = (try? historyStore.loadingContent(of: item, scope: .body)) ?? item
    guard let text = item.text else {
      model.lastError = "\(item.kind.title) cannot be transformed."
      return
    }

    do {
      var updated = item
      let previousContentKey = updated.contentKey
      let transformedText = transform.apply(to: text)
      updated.text = transformedText
      updated.byteSize = transformedText.utf8.count
      updated.kind = ClipboardKind.classifyText(
        transformedText,
        treatDigitNumbersAsColor: model.preferences.treatDigitNumbersAsColor
      )
      if item.kind == .richText {
        updated.removeFormatting()
      }
      if updated.kind != .link || updated.contentKey != previousContentKey {
        removeLinkPreviewFiles(for: updated)
        updated.linkPreviewDetails = nil
        linkPreviewTasksByItemID[item.id]?.cancel()
        linkPreviewTasksByItemID[item.id] = nil
        pendingLinkPreviewModelUpdatesByItemID[item.id] = nil
      }
      updated = updated.rebuildingSearchText(tagNames: model.tagNames(for: updated.tags))
      let convertsAssets = !(updated.kind == .image && isImageRecognitionPending(for: updated.id))
      let saved = try historyStore.saveAndReconcileItem(updated, convertingExternalAssets: convertsAssets)
      reconcileSideEffectsAfterItemMutation(previous: item, updated: saved)
      model.replace(saved)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func toggleTag(_ tag: Tag, for item: ClipboardItem) {
    updateTags(for: [item]) { tags in
      if tags.contains(tag.id) {
        tags.removeAll { $0 == tag.id }
      } else {
        tags.append(tag.id)
      }
    }
  }

  func addTag(_ tag: Tag, to item: ClipboardItem) {
    addTag(tag, to: [item])
  }

  func addTag(_ tag: Tag, to items: [ClipboardItem]) {
    updateTags(for: items.filter { !$0.tags.contains(tag.id) }) { tags in
      tags.append(tag.id)
    }
  }

  func removeTag(_ tag: Tag, from items: [ClipboardItem]) {
    updateTags(for: items.filter { $0.tags.contains(tag.id) }) { tags in
      tags.removeAll { $0 == tag.id }
    }
  }

  @discardableResult
  func createTag(name: String, color: NSColor) -> Tag? {
    do {
      let tag = try historyStore.createTag(name: name, color: color.tagHexString)
      if let index = model.tags.firstIndex(where: { $0.id == tag.id }) {
        model.tags[index] = tag
      } else {
        model.tags.append(tag)
      }
      return tag
    } catch {
      model.lastError = error.localizedDescription
      return nil
    }
  }

  func createTag(name: String, color: NSColor, for item: ClipboardItem) {
    createTag(name: name, color: color, for: [item])
  }

  func createTag(name: String, color: NSColor, for items: [ClipboardItem]) {
    guard !items.isEmpty, let tag = createTag(name: name, color: color) else {
      return
    }
    addTag(tag, to: items)
  }

  func updateTag(_ tag: Tag, name: String, color: NSColor) {
    do {
      let updatedTag = try historyStore.updateTag(id: tag.id, name: name, color: color.tagHexString)
      if let index = model.tags.firstIndex(where: { $0.id == tag.id }) {
        model.tags[index] = updatedTag
      } else {
        model.tags.append(updatedTag)
      }
      let tagNamesByID = Dictionary(uniqueKeysWithValues: model.tags.map { ($0.id, $0.name) })
      let updatedItems = model.items.compactMap { item -> ClipboardItem? in
        guard item.tags.contains(tag.id) else {
          return nil
        }
        return item.rebuildingSearchText(tagNames: item.tags.compactMap { tagNamesByID[$0] })
      }
      if !updatedItems.isEmpty {
        model.replace(updatedItems)
      }
      if model.trashedItems.contains(where: { $0.tags.contains(tag.id) }) {
        model.trashedItems = model.trashedItems.map { item in
          guard item.tags.contains(tag.id) else {
            return item
          }
          return item.rebuildingSearchText(tagNames: item.tags.compactMap { tagNamesByID[$0] })
            .unloadingContent()
        }
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func deleteTag(_ tag: Tag) {
    do {
      try historyStore.deleteTag(id: tag.id)
      model.tags.removeAll { $0.id == tag.id }
      model.selectedHistoryFilterTagIDs.remove(tag.id)

      let remainingTagNamesByID = Dictionary(
        uniqueKeysWithValues: model.tags.map { ($0.id, $0.name) }
      )
      let updatedItems = model.items.compactMap { item -> ClipboardItem? in
        guard item.tags.contains(tag.id) else {
          return nil
        }
        var updated = item
        updated.tags.removeAll { $0 == tag.id }
        return updated.rebuildingSearchText(tagNames: updated.tags.compactMap { remainingTagNamesByID[$0] })
      }
      if !updatedItems.isEmpty {
        model.replace(updatedItems)
      }
      if model.trashedItems.contains(where: { $0.tags.contains(tag.id) }) {
        model.trashedItems = model.trashedItems.map { item in
          guard item.tags.contains(tag.id) else {
            return item
          }
          var updated = item
          updated.tags.removeAll { $0 == tag.id }
          return updated.rebuildingSearchText(tagNames: updated.tags.compactMap { remainingTagNamesByID[$0] })
            .unloadingContent()
        }
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func updateTags(for items: [ClipboardItem], update: (inout [Int]) -> Void) {
    guard !items.isEmpty else {
      return
    }

    do {
      let tagNamesByID = Dictionary(uniqueKeysWithValues: model.tags.map { ($0.id, $0.name) })
      let updatedItems = items.map { item -> ClipboardItem in
        var updated = item
        update(&updated.tags)
        updated.tags.sort {
          (tagNamesByID[$0] ?? "").localizedCaseInsensitiveCompare(tagNamesByID[$1] ?? "") == .orderedAscending
        }
        return updated.rebuildingSearchText(tagNames: updated.tags.compactMap { tagNamesByID[$0] })
      }

      if updatedItems.count == 1, let single = updatedItems.first {
        try historyStore.upsert(single)
        model.replace(single)
      } else {
        try historyStore.performInTransaction {
          for updated in updatedItems {
            try historyStore.upsert(updated)
          }
        }
        model.replace(updatedItems)
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  func openInBrowser(_ item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let resolvedItem = (!item.isContentLoaded && item.browserURL == nil)
      ? loadingContent(of: item, scope: .body)
      : item
    guard let url = resolvedItem.browserURL else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @discardableResult
  func saveImageAsFile(_ item: ClipboardItem, presenting window: NSWindow, completion: (() -> Void)? = nil) -> Bool {
    guard allowsUsingHistoryItems() else {
      completion?()
      return false
    }

    guard item.kind == .image,
          let assetURL = item.assetURL else {
      model.lastError = ClipboardImageExportError.unsupportedItem.localizedDescription
      completion?()
      return false
    }

    guard fileManager.fileExists(atPath: assetURL.path) else {
      model.lastError = ClipboardImageExportError.missingImageFile.localizedDescription
      completion?()
      return false
    }

    let panel = NSSavePanel()
    panel.title = L10n.string("Save Image")
    panel.nameFieldStringValue = defaultImageExportFileName(for: item)
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    panel.beginSheetModal(for: window) { [weak self] response in
      defer {
        completion?()
      }

      guard response == .OK, let destinationURL = panel.url else {
        return
      }

      do {
        let data = try ImageAssetStore.readAssetData(
          at: assetURL,
          role: .image,
          ownerClipID: item.id,
          requiresEncryption: SensitiveContent.shouldEncryptAtRest(item)
        )
        try data.write(to: destinationURL, options: .atomic)
      } catch {
        self?.model.lastError = error.localizedDescription
      }
    }

    return true
  }

  func loadLinkPreviewIfNeeded(for item: ClipboardItem) {
    guard model.preferences.showPreviewForLinks,
          item.kind == .link,
          !SensitiveContent.shouldEncryptAtRest(item),
          item.linkPreviewDetails == nil,
          pendingLinkPreviewModelUpdatesByItemID[item.id] == nil else {
      return
    }

    updateLinkPreview(for: item, force: false)
  }

  func updateLink(_ item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    updateLinkPreview(for: item, force: true)
  }

  func openInAssociatedApplication(_ item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    let resolvedItem = (!item.isContentLoaded && item.kind == .link && item.browserURL == nil)
      ? loadingContent(of: item, scope: .body)
      : item
    // A link opens in the browser that handles its address, the same
    // application the preview names on its Open in ... button.
    guard let url = resolvedItem.quickLookURL ?? resolvedItem.browserURL,
          let application = AssociatedApplication.forOpening(url, iconSize: NSSize(width: 22, height: 22)) else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    weak let weakSelf = self
    NSWorkspace.shared.open([url], withApplicationAt: application.url, configuration: configuration) { _, error in
      if let error {
        let message = error.localizedDescription
        Task { @MainActor in
          weakSelf?.model.lastError = message
        }
      }
    }
  }

  func open(_ item: ClipboardItem, with applicationURL: URL) {
    guard allowsUsingHistoryItems() else {
      return
    }

    guard let url = item.quickLookURL else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    weak let weakSelf = self
    NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
      if let error {
        let message = error.localizedDescription
        Task { @MainActor in
          weakSelf?.model.lastError = message
        }
      }
    }
  }

  private func defaultImageExportFileName(for item: ClipboardItem) -> String {
    guard let dimensions = item.imageDimensions else {
      return "image.png"
    }

    return "image_\(dimensions.width)x\(dimensions.height).png"
  }

  private func mergedText(from items: [ClipboardItem]) -> String? {
    let contents = items.compactMap(mergeText(for:))
    guard contents.count == items.count else {
      return nil
    }

    return contents.joined(separator: "\n")
  }

  private func updateLinkPreview(for item: ClipboardItem, force: Bool) {
    guard item.kind == .link,
          force || item.linkPreviewDetails == nil,
          force || pendingLinkPreviewModelUpdatesByItemID[item.id] == nil,
          linkPreviewTasksByItemID[item.id] == nil else {
      return
    }
    let resolvedItem = (!item.isContentLoaded && item.browserURL == nil)
      ? loadingContent(of: item, scope: .body)
      : item
    guard let url = resolvedItem.browserURL else {
      return
    }

    linkPreviewTasksByItemID[item.id] = Task { [weak self, linkPreviewFetcher] in
      let preview = await linkPreviewFetcher.fetchPreview(for: url)
      // A cancelled fetch returns no preview, which is not the page having none.
      let isCancelled = Task.isCancelled
      await MainActor.run {
        guard let self else {
          return
        }

        self.linkPreviewTasksByItemID[item.id] = nil
        guard !isCancelled else {
          return
        }

        self.persistLinkPreview(preview, itemID: item.id, url: url)
      }
    }
  }

  private func persistLinkPreview(_ preview: LinkPreview?, itemID: ClipboardItem.ID, url: URL) {
    // The item may have been deleted while its page was fetched. Saving the
    // preview then would leave its files behind and write the deleted item
    // back to the store, where it came back on the next launch.
    guard var updated = model.items.first(where: { $0.id == itemID }) else {
      return
    }

    let normalizedURL = ClipboardItem.normalizedLinkContentKey(for: url)
    let wasAlreadyEncrypted = SensitiveContent.shouldEncryptAtRest(updated)
    var candidate = updated
    candidate.linkPreviewDetails = LinkPreviewDetails(
      url: normalizedURL,
      title: preview?.title,
      description: preview?.description,
      imagePath: nil,
      faviconPath: nil,
      fetchedAt: Date()
    )
    let encryptAssets = SensitiveContent.shouldEncryptAtRest(candidate)

    if !wasAlreadyEncrypted && encryptAssets && !updated.isKeptByUser && updated.sensitivity != .notSensitive {
      let lifetime = model.preferences.sensitiveContentLifetime
      if lifetime == ContentLifetime.dontSave {
        return
      }
      if lifetime > 0, let previewExpiry = ContentLifetime.expiryDate(for: lifetime, from: updated.copiedAt) {
        if let existingExpiry = updated.expiresAt {
          updated.expiresAt = min(existingExpiry, previewExpiry)
        } else {
          updated.expiresAt = previewExpiry
        }
      }
    }

    do {
      removeLinkPreviewFiles(for: updated)
      let imagePath = try writeLinkPreviewImage(
        preview?.image,
        itemID: updated.id,
        role: .linkPreview,
        encrypted: encryptAssets
      )
      let faviconPath = try writeLinkPreviewImage(
        preview?.favicon,
        itemID: updated.id,
        role: .linkFavicon,
        encrypted: encryptAssets
      )
      updated.linkPreviewDetails = LinkPreviewDetails(
        url: normalizedURL,
        title: preview?.title,
        description: preview?.description,
        imagePath: imagePath,
        faviconPath: faviconPath,
        fetchedAt: Date()
      )
      updated = updated.rebuildingSearchText(tagNames: model.tagNames(for: updated.tags))
      let saved = try historyStore.saveAndReconcileItem(updated, convertingExternalAssets: false)
      if saved.expiresAt != nil {
        deleteExpiredItems()
      }
      scheduleLinkPreviewModelUpdate(saved)
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func scheduleLinkPreviewModelUpdate(_ item: ClipboardItem) {
    pendingLinkPreviewModelUpdatesByItemID[item.id] = item
    linkPreviewModelUpdateTask?.cancel()

    linkPreviewModelUpdateTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else {
        return
      }

      self?.applyPendingLinkPreviewModelUpdates()
    }
  }

  private func applyPendingLinkPreviewModelUpdates() {
    let updates = Array(pendingLinkPreviewModelUpdatesByItemID.values)
    pendingLinkPreviewModelUpdatesByItemID.removeAll()
    linkPreviewModelUpdateTask = nil

    // An item deleted while its preview was saved is not brought back.
    let historyItemIDs = Set(model.items.map(\.id))
    let historyUpdates = updates.filter { historyItemIDs.contains($0.id) }
    guard !historyUpdates.isEmpty else {
      return
    }

    model.replace(historyUpdates)
  }

  private var linkPreviewsDirectory: URL {
    supportDirectory.appendingPathComponent("LinkPreviews", isDirectory: true)
  }

  private func writeLinkPreviewImage(
    _ image: NSImage?,
    itemID: UUID,
    role: AssetRole,
    encrypted: Bool
  ) throws -> String? {
    guard let image,
          let data = pngData(from: image) else {
      return nil
    }

    let url = try historyStore.writeManagedAsset(
      pngData: data,
      role: role,
      clipID: itemID,
      encrypted: encrypted
    )
    return url.path
  }

  private func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff) else {
      return nil
    }

    return representation.representation(using: .png, properties: [:])
  }

  /// The item with its stored content read for the requested scope.
  func loadingContent(of item: ClipboardItem, scope: ClipboardContentScope = .full) -> ClipboardItem {
    (try? historyStore.loadingContent(of: item, scope: scope)) ?? item
  }

  private nonisolated static func canonicalDirectoryURL(_ directoryURL: URL) -> URL {
    let standardized = directoryURL.standardizedFileURL
    if standardized.path == "/" || standardized.path.isEmpty {
      return standardized
    }
    var st = stat()
    if stat(standardized.path, &st) == 0 {
      return standardized.resolvingSymlinksInPath().standardizedFileURL
    }
    let parent = canonicalDirectoryURL(standardized.deletingLastPathComponent())
    return parent
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
      .standardizedFileURL
  }

  private nonisolated static func canonicalFilePath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: false)
    var st = stat()
    if Darwin.lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK {
      return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    let parent = canonicalDirectoryURL(url.deletingLastPathComponent())
    return parent
      .appendingPathComponent(url.lastPathComponent, isDirectory: false)
      .standardizedFileURL
      .path
  }

  private func isContainedInManagedDirectory(_ fileURL: URL, directory: URL) -> Bool {
    let parentURL = fileURL.deletingLastPathComponent()
    var parentStat = stat()
    guard Darwin.lstat(parentURL.path, &parentStat) == 0,
          (parentStat.st_mode & S_IFMT) == S_IFDIR else {
      return false
    }
    let canonicalDirPrefix = Self.canonicalDirectoryURL(directory).path + "/"
    let canonicalCandidatePath = Self.canonicalFilePath(fileURL.path)
    return canonicalCandidatePath.hasPrefix(canonicalDirPrefix)
      && Self.canonicalDirectoryURL(parentURL).path == Self.canonicalDirectoryURL(directory).path
  }

  private func scrubManagedDirectoryFiles(at directory: URL) {
    var dirStat = stat()
    guard Darwin.lstat(directory.path, &dirStat) == 0,
          (dirStat.st_mode & S_IFMT) == S_IFDIR,
          let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
          ) else {
      return
    }
    for entry in entries {
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: entry.path)
      ImageAssetStore.secureUnlink(at: entry)
    }
  }

  private func removeLinkPreviewFiles(for item: ClipboardItem) {
    guard let details = item.linkPreviewDetails else {
      return
    }

    [details.imagePath, details.faviconPath].forEach { path in
      guard let path, !path.isEmpty else {
        return
      }

      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: path)
      let fileURL = URL(fileURLWithPath: path, isDirectory: false)
      guard isContainedInManagedDirectory(fileURL, directory: linkPreviewsDirectory) else {
        return
      }
      ImageAssetStore.secureUnlink(at: fileURL)
    }
  }

  private var imagesDirectory: URL {
    supportDirectory.appendingPathComponent("Images", isDirectory: true)
  }

  /// Deletes the image files of deleted items. Each captured or imported image
  /// has a file of its own, but a file another item still names is kept
  /// anyway, and nothing outside the images folder is ever deleted.
  private func removeAssetFiles(for deletedItems: [ClipboardItem], remainingItems: [ClipboardItem]) {
    if deletedItems.contains(where: { $0.kind == .image || $0.assetPath != nil }) {
      ImageDragFiles.removeAll()
    }
    let deletedPaths = Set(deletedItems.compactMap(\.assetPath))
    guard !deletedPaths.isEmpty else {
      return
    }

    let remainingCanonicalPaths = Set(remainingItems.compactMap(\.assetPath).map(Self.canonicalFilePath))
    for path in deletedPaths {
      let canonicalPath = Self.canonicalFilePath(path)
      guard !remainingCanonicalPaths.contains(canonicalPath) else {
        continue
      }
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: path)
      let fileURL = URL(fileURLWithPath: path, isDirectory: false)
      guard isContainedInManagedDirectory(fileURL, directory: imagesDirectory) else {
        continue
      }
      ImageAssetStore.secureUnlink(at: fileURL)
    }
  }

  /// Deletes the files in the images and link previews folders that no item
  /// names any more. They were left behind by versions that kept the files of
  /// a deleted item or saved a link preview for an item deleted while it was
  /// fetched, and by an import that replaced an item, which copies its files
  /// again under new names. The store is read in the background, and a file
  /// changed in the last few minutes is kept, since a capture, a link preview
  /// or an import writes the file before it saves the item.
  private func removeOrphanedStoredFiles() {
    guard !isHistoryArchiveOperationRunning,
          historyStore.lockState == .unlocked else {
      return
    }

    nonisolated(unsafe) let fileManager = self.fileManager
    let historyStore = self.historyStore
    let directories = [imagesDirectory, linkPreviewsDirectory]
    // The loaded items must all be among the files the store reports, or the
    // store was not read right and nothing is deleted.
    let loadedFileNames = Set(model.items.flatMap(\.storedFilePaths).map { URL(fileURLWithPath: $0).lastPathComponent })
    let minimumAge = Self.orphanedStoredFileMinimumAge
    let orphanSweepGeneration = self.orphanSweepGeneration
    let generation = orphanSweepGeneration.withLock {
      $0 &+= 1
      return $0
    }

    maintenanceQueue.async {
      guard orphanSweepGeneration.withLock({ $0 == generation }) else {
        return
      }
      guard let referencedPaths = try? historyStore.fetchStoredFilePaths() else {
        return
      }
      guard orphanSweepGeneration.withLock({ $0 == generation }) else {
        return
      }

      // Files are matched by name, so a history whose files moved with a
      // renamed home folder keeps them. The names start with the item's ID,
      // so no two items share one.
      let referencedFileNames = Set(referencedPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
      guard loadedFileNames.isSubset(of: referencedFileNames) else {
        return
      }

      let cutoff = Date().addingTimeInterval(-minimumAge)
      for directory in directories {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
          options: [.skipsHiddenFiles]
        ) else {
          continue
        }

        for fileURL in fileURLs where !referencedFileNames.contains(fileURL.lastPathComponent) {
          guard orphanSweepGeneration.withLock({ $0 == generation }) else {
            return
          }
          guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                modifiedAt < cutoff else {
            continue
          }

          ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: fileURL.path)
          if fileURL.pathExtension.lowercased() == "enc" || ImageAssetStore.isEncryptedAssetFile(at: fileURL) {
            ImageAssetStore.secureUnlink(at: fileURL)
          } else {
            try? fileManager.removeItem(at: fileURL)
          }
        }
      }
    }
  }

  private func removeFilePreviewFiles(for deletedItems: [ClipboardItem], remainingItems: [ClipboardItem]) {
    let deletedFilePaths = Set(deletedItems.flatMap(\.filePaths))
    guard !deletedFilePaths.isEmpty else {
      return
    }

    let remainingCanonicalPaths = Set(remainingItems.flatMap(\.filePaths).map(Self.canonicalFilePath))
    let removedPaths = Set(
      deletedFilePaths.filter { !remainingCanonicalPaths.contains(Self.canonicalFilePath($0)) }
    )
    guard !removedPaths.isEmpty else {
      return
    }
    filePreviewCache.removePreviews(forFilePaths: removedPaths)
    for path in removedPaths {
      ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: path)
    }
  }

  private func pruneFilePreviewCache() {
    filePreviewCache.prune {
      var keptFilePaths = Set<String>()
      for item in model.items where !SensitiveContent.shouldEncryptAtRest(item) {
        keptFilePaths.formUnion(item.filePaths)
      }
      if let trashedItems = try? historyStore.fetchTrashedItems() {
        for item in trashedItems where !SensitiveContent.shouldEncryptAtRest(item) {
          keptFilePaths.formUnion(item.filePaths)
        }
      }
      return keptFilePaths
    }
  }

  private func cancelLinkPreviewTasks() {
    linkPreviewTasksByItemID.values.forEach { $0.cancel() }
    linkPreviewTasksByItemID.removeAll()
    linkPreviewModelUpdateTask?.cancel()
    linkPreviewModelUpdateTask = nil
    pendingLinkPreviewModelUpdatesByItemID.removeAll()
  }

  private func mergeText(for item: ClipboardItem) -> String? {
    switch item.kind {
    case .text, .richText, .link, .email, .color:
      let loaded = item.isContentLoaded ? item : loadingContent(of: item, scope: .body)
      return loaded.text
    case .file:
      return item.filePaths.isEmpty ? nil : item.filePaths.joined(separator: "\n")
    case .image:
      return nil
    }
  }

  private func splitTextParts(for item: ClipboardItem) -> [String] {
    guard item.kind == .text || item.kind == .richText else {
      return []
    }
    let loaded = item.isContentLoaded ? item : loadingContent(of: item, scope: .body)
    guard let text = loaded.text,
          text.contains(where: \.isNewline) else {
      return []
    }

    return text
      .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func deleteExistingMatches(for item: ClipboardItem) throws {
    var deletedIDs: Set<ClipboardItem.ID> = []
    for existingItem in model.items where
      existingItem.id != item.id
      && existingItem.kind == item.kind
      && !existingItem.isKeptByUser
      && existingItem.title == nil
      && existingItem.linkPreviewDetails == nil
      && existingItem.sourceAppName == item.sourceAppName
      && existingItem.characterCount == item.characterCount
      && existingItem.textPreview == item.textPreview
    {
      let loaded = try historyStore.loadingContent(of: existingItem, scope: .body)
      guard loaded.text == item.text,
            (loaded.qrCodeText ?? "").isEmpty,
            loaded.filePaths == item.filePaths else {
        continue
      }
      try historyStore.delete(existingItem.id)
      deletedIDs.insert(existingItem.id)
      let remainingItems = model.items.filter { !deletedIDs.contains($0.id) }
      removeFilePreviewFiles(for: [existingItem], remainingItems: remainingItems)
      removeAssetFiles(for: [existingItem], remainingItems: remainingItems)
    }
    if !deletedIDs.isEmpty {
      model.remove(deletedIDs)
    }
  }

  private func recordHistoryAction(for item: ClipboardItem, incrementsCopyCount: Bool) throws -> ClipboardItem? {
    let copiedAt = model.preferences.updatesHistoryAfterAction ? Date() : nil
    guard copiedAt != nil || incrementsCopyCount else {
      return nil
    }

    return try historyStore.recordAction(item.id, copiedAt: copiedAt, incrementsCopyCount: incrementsCopyCount)
  }

  private func interruptCopySequenceTracking() {
    clipboardMonitor.markCopySequencePasteBoundary()
  }
  
  func showInFinder(_ item: ClipboardItem) {
    guard allowsUsingHistoryItems() else {
      return
    }

    if let url = item.quickLookURL {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
  
  func checkForUpdates() {
    updateService.checkForUpdates(presenting: NSApp.keyWindow)
  }

  func rememberPasteTarget() {
    pasteService.rememberPasteTarget()
  }
  
  private func configurePanel() {
    if historyWindow == nil {
      historyWindow = HistoryWindow(model: model, coordinator: self)
    }
  }

  // The trial runs for the days the history was opened on, so opening it is
  // what counts as using the app.
  private func recordTrialUsage() {
    #if CLIPBOOK_COMMERCIAL
    licensingService.recordTrialUsage(licenseKey: model.preferences.licenseKey)
    #endif
    updateTrialNotice()
  }

  /// `true` when items may be used. Otherwise the attempt is pointed out, and
  /// the caller does nothing.
  private func allowsUsingHistoryItems() -> Bool {
    guard isHistoryReadOnly else {
      return true
    }

    notifyReadOnlyHistoryActionAttempt()
    return false
  }

  func notifyReadOnlyHistoryActionAttempt() {
    NSSound.beep()
    readOnlyHistoryActionAttempts.send()
  }

  func updateTrialNotice(now: Date = Date()) {
    let notice: TrialNotice?
    switch licenseState {
    case .trial(let daysLeft) where daysLeft <= TrialOffer.daysLeftToShowNotice:
      if let dismissedDaysLeft = model.preferences.dismissedTrialNoticeDaysLeft, daysLeft >= dismissedDaysLeft {
        notice = nil
      } else {
        notice = .endingSoon(daysLeft: daysLeft)
      }
    case .trialExpired:
      if let offeredAt = model.preferences.trialDiscountOfferedAt,
         now < offeredAt.addingTimeInterval(TrialOffer.discountDuration) {
        notice = .discount(endsAt: offeredAt.addingTimeInterval(TrialOffer.discountDuration))
      } else {
        notice = .ended
      }
    default:
      notice = nil
    }

    if trialNotice != notice {
      trialNotice = notice
    }
  }

  func dismissTrialNotice() {
    guard case .endingSoon(let daysLeft) = trialNotice else {
      return
    }

    model.preferences.dismissedTrialNoticeDaysLeft = daysLeft
    persistPreferences()
    updateTrialNotice()
  }

  /// Shows the discount again, from the notice above the history.
  func showTrialDiscountOffer() {
    guard case .discount(let endsAt) = trialNotice,
          Date() < endsAt,
          !isTrialSheetPresented,
          historyWindow?.isVisible == true else {
      return
    }

    _ = presentTrialSheet(.discount(endsAt: endsAt))
  }

  func copyTrialDiscountCode() {
    // Marked so the code doesn't end up in the history it is meant to unlock.
    try? pasteService.copyText(TrialOffer.discountCode, markAsGhost: true)
    playSound(.copy)
  }

  /// The history shows the dialog about the end of the trial the first time it
  /// opens after the trial, and the discount a week later if the app is still
  /// in use. From then on the notice above the history takes over.
  private func presentTrialSheetIfNeeded(now: Date = Date()) {
    guard licenseState.isTrialExpired,
          !isTrialSheetPresented,
          historyWindow?.isVisible == true else {
      return
    }

    guard let trialExpiredAt = model.preferences.trialExpiredAt else {
      if presentTrialSheet(.trialExpired) {
        model.preferences.trialExpiredAt = now
        persistPreferences()
      }
      return
    }

    guard model.preferences.trialDiscountOfferedAt == nil,
          now >= trialExpiredAt.addingTimeInterval(TrialOffer.delayBeforeDiscount) else {
      return
    }

    let discountEndsAt = now.addingTimeInterval(TrialOffer.discountDuration)
    if presentTrialSheet(.discount(endsAt: discountEndsAt)) {
      model.preferences.trialDiscountOfferedAt = now
      persistPreferences()
      updateTrialNotice(now: now)
    }
  }

  private func presentTrialSheet(_ sheet: TrialSheet) -> Bool {
    guard let historyWindow else {
      return false
    }

    // The dialog is a sheet of the panel, like the item preview, so it takes
    // text without the app turning into a regular one. Switching back to an
    // accessory app once it closes would take the panel off the screen for a
    // moment.
    let didPresentSheet = historyWindow.showTrialSheet(
      sheet,
      hasProvidedFeedback: model.preferences.hasProvidedTrialExpiredFeedback,
      onSendFeedback: { [weak self] feedback in
        self?.sendTrialExpiredFeedback(feedback)
      },
      onCopyDiscountCode: { [weak self] in
        self?.copyTrialDiscountCode()
      },
      onDismiss: { [weak self] action in
        guard let self else {
          return
        }

        self.isTrialSheetPresented = false
        switch action {
        case .close:
          // The history stays open to be looked through read-only.
          break
        case .activateLicense:
          self.hideHistoryPanel()
          self.openSettings(section: .license)
        case .buyLicense:
          self.hideHistoryPanel()
          self.openBuyLicenseURL()
        }
      }
    )
    isTrialSheetPresented = didPresentSheet
    return didPresentSheet
  }

  #if DEBUG
  // Launching with `-DebugTrialExpiredDaysAgo <days>` (together with
  // `-DebugTrialDaysLeft 0`) previews the dialogs and notices that follow the
  // trial: 0 shows the trial-ended dialog, 7 or more the discount. Adding
  // `-DebugTrialDiscountOfferedHoursAgo <hours>` previews the running offer.
  private func applyDebugTrialDates() {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: "DebugTrialExpiredDaysAgo") != nil else {
      return
    }

    let now = Date()
    let daysAgo = defaults.double(forKey: "DebugTrialExpiredDaysAgo")
    model.preferences.trialExpiredAt = daysAgo > 0 ? now.addingTimeInterval(-daysAgo * 24 * 60 * 60) : nil
    model.preferences.trialDiscountOfferedAt = defaults.object(forKey: "DebugTrialDiscountOfferedHoursAgo") == nil
      ? nil
      : now.addingTimeInterval(-defaults.double(forKey: "DebugTrialDiscountOfferedHoursAgo") * 60 * 60)
    model.preferences.dismissedTrialNoticeDaysLeft = nil
  }
  #endif

  // A visible panel that lost key focus (a pinned one, for instance) is
  // brought back rather than closed, so the shortcut still reaches it.
  private func handleShowHistoryShortcut() {
    if model.preferences.showHistoryShortcutClosesHistory, historyWindow?.isKeyAndVisible == true {
      hideHistoryPanel()
      return
    }

    showHistoryPanel()
  }

  // A registered global shortcut is taken by the system before it reaches any
  // window, so the shortcut recorder in Settings would trigger the action
  // instead of capturing the combination.
  func setGlobalShortcutsSuspended(_ isSuspended: Bool) {
    guard areGlobalShortcutsSuspended != isSuspended else {
      return
    }

    areGlobalShortcutsSuspended = isSuspended
    configureShortcuts()
  }

  private func configureShortcuts() {
    globalShortcuts.unregisterAll()
    guard !areGlobalShortcutsSuspended else {
      return
    }

    globalShortcuts.register(.showHistory, shortcut: model.preferences.showHistoryShortcut) { [weak self] in
      Task { @MainActor in
        self?.handleShowHistoryShortcut()
      }
    }
    globalShortcuts.register(.pauseCapture, shortcut: model.preferences.pauseShortcut) { [weak self] in
      Task { @MainActor in
        self?.togglePaused()
      }
    }
    globalShortcuts.register(.pasteNext, shortcut: model.preferences.pasteNextShortcut) { [weak self] in
      Task { @MainActor in
        self?.pasteNextItemFromGlobalShortcut(variant: nil)
      }
    }
    globalShortcuts.register(.pasteNextRich, shortcut: model.preferences.pasteNextRichShortcut) { [weak self] in
      Task { @MainActor in
        self?.pasteNextItemFromGlobalShortcut(variant: .standard)
      }
    }
    globalShortcuts.register(.pasteNextAndDelete, shortcut: model.preferences.pasteNextAndDeleteShortcut) { [weak self] in
      Task { @MainActor in
        self?.pasteNextItemFromGlobalShortcut(variant: nil, deletesAfterPaste: true)
      }
    }
    globalShortcuts.register(.pasteNextRichAndDelete, shortcut: model.preferences.pasteNextRichAndDeleteShortcut) { [weak self] in
      Task { @MainActor in
        self?.pasteNextItemFromGlobalShortcut(variant: .standard, deletesAfterPaste: true)
      }
    }
  }
  
  @discardableResult
  func loadHistory(sweepsCaches: Bool = true) -> Bool {
    let lockState = syncStoreLockState()
    guard lockState == .unlocked else {
      model.tags = []
      model.items = []
      model.trashedItems = []
      model.selectedItemID = nil
      model.selectedItemIDs = []
      model.selectedItemIDsInSelectionOrder = []
      model.lastError = Self.lockedStoreErrorMessage(for: lockState)
      return false
    }

    do {
      model.tags = try historyStore.fetchTags()
      model.items = try historyStore.fetchAll()
      if model.isShowingTrash {
        model.trashedItems = try historyStore.fetchTrashedItems()
      }
      _ = syncStoreLockState()
      if sweepsCaches {
        pruneFilePreviewCache()
        removeOrphanedStoredFiles()
      }
      model.selectedItemID = model.items.first?.id
      model.selectedItemIDs = model.selectedItemID.map { [$0] } ?? []
      model.selectedItemIDsInSelectionOrder = model.selectedItemID.map { [$0] } ?? []
      return true
    } catch {
      _ = syncStoreLockState()
      model.lastError = PersistenceErrorLocalization.message(for: error)
      return false
    }
  }

  // `ProcessInfo.systemUptime` pauses while the Mac is asleep, so subtracting
  // it from `Date()` drifts forward by the time spent asleep, and the next
  // launch takes that for a reboot. `kern.boottime` is the actual boot time.
  nonisolated static func systemBootTime() -> Date {
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.stride
    if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 {
      return Date(timeIntervalSince1970: Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000)
    }
    return Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
  }

  /// Whether the Mac restarted since `previousBootTime` was recorded. One-sided:
  /// a reboot makes the boot time later. A stored value ahead of the current one
  /// is a clock adjustment or a time derived from `systemUptime`, which runs
  /// ahead of the real boot time by the time spent asleep.
  nonisolated static func isReboot(previousBootTime: TimeInterval?, currentBootTime: TimeInterval) -> Bool {
    guard let previousBootTime else {
      return false
    }
    return currentBootTime - previousBootTime > 60
  }

  func clearHistoryAfterRebootIfNeeded(
    kernelBootTime: TimeInterval = AppCoordinator.systemBootTime().timeIntervalSince1970,
    uptimeRelativeBootTime: TimeInterval = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime).timeIntervalSince1970
  ) {
    guard historyStore.lockState == .unlocked else {
      return
    }
    // The first launch after updating from a build that stored only the uptime
    // estimate falls back to it. The estimate is never earlier than the real
    // boot time, so the one-sided check below still ignores time spent asleep,
    // and a restart since that launch still counts as a reboot.
    let previousBootTime = preferencesStore.lastKnownKernelBootTime()
      ?? preferencesStore.lastKnownUptimeRelativeBootTime()
    preferencesStore.recordBootTimes(
      kernelBootTime: kernelBootTime,
      uptimeRelativeBootTime: uptimeRelativeBootTime
    )

    guard model.preferences.clearHistoryOnReboot,
          Self.isReboot(previousBootTime: previousBootTime, currentBootTime: kernelBootTime) else {
      return
    }

    clearHistory()
  }

  private func shouldKeepWhenClearingHistory(_ item: ClipboardItem) -> Bool {
    item.isFavorite || !item.tags.isEmpty
  }

  private func shouldProceedWithClearHistory(isNarrowed: Bool) -> Bool {
    guard model.preferences.warnOnClearHistory else {
      return true
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    let keepsProtectedItems = model.preferences.keepFavoritesOnClearHistory
    let movesToTrash = model.preferences.isTrashEnabled
    if isNarrowed {
      alert.messageText = L10n.string("Are you sure you want to delete all filtered history items?")
      switch (keepsProtectedItems, movesToTrash) {
      case (true, true):
        alert.informativeText = L10n.string("The history items currently shown, except favorites and tagged items, will be moved to the Trash.")
      case (false, true):
        alert.informativeText = L10n.string("The history items currently shown, including favorites and tagged items, will be moved to the Trash.")
      case (true, false):
        alert.informativeText = L10n.string("This will delete the history items currently shown, except favorites and tagged items. This action cannot be undone.")
      case (false, false):
        alert.informativeText = L10n.string("This will delete the history items currently shown, including favorites and tagged items. This action cannot be undone.")
      }
    } else {
      alert.messageText = L10n.string("Are you sure you want to clear entire history?")
      switch (keepsProtectedItems, movesToTrash) {
      case (true, true):
        alert.informativeText = L10n.string("All history items except favorites and tagged items will be moved to the Trash.")
      case (false, true):
        alert.informativeText = L10n.string("All history items including favorites and tagged items will be moved to the Trash.")
      case (true, false):
        alert.informativeText = L10n.string("This will delete all history items except favorites and tagged items. This action cannot be undone.")
      case (false, false):
        alert.informativeText = L10n.string("This will delete all history items including favorites and tagged items. This action cannot be undone.")
      }
    }
    let deleteAllButton = alert.addButton(withTitle: L10n.string("Delete All"))
    deleteAllButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.string("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }
  
  private func applyAppearance() {
    switch model.preferences.appearance {
    case .system:
      NSApp.appearance = nil
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  private func applyLanguage() {
    let previousLanguage = L10n.languageIdentifier
    L10n.setLanguage(model.preferences.language)
    let appliedLanguage = L10n.languageIdentifier
    if model.preferences.language != appliedLanguage {
      model.preferences.language = appliedLanguage
    }
    if previousLanguage != appliedLanguage {
      model.localizationRevision = UUID()
    }
  }
  
  private func showAccessibilityAlertIfNeeded(_ error: Error) {
    guard case PasteServiceError.accessibilityPermissionRequired = error else {
      return
    }
    let alert = NSAlert()
    alert.messageText = L10n.string("Accessibility permission is required")
    alert.informativeText = L10n.string("ClipBook needs Accessibility permission to paste into the previously active app.")
    alert.addButton(withTitle: L10n.string("Open Settings"))
    alert.addButton(withTitle: L10n.string("Cancel"))
    if alert.runModal() == .alertFirstButtonReturn {
      AccessibilityPermission.openSettings()
    }
  }

  func playSound(_ effect: SoundEffect) {
    guard model.preferences.isSoundEffectEnabled(effect) else {
      return
    }

    soundService.play(effect)
  }

  // Previews are played from Settings when a sound effect is switched on, so
  // they ignore the preferences the user is currently editing.
  func previewSound(_ effect: SoundEffect) {
    soundService.play(effect)
  }
}

private extension NSColor {
  var tagHexString: String {
    let color = usingColorSpace(.sRGB) ?? self
    let red = max(0, min(255, Int(round(color.redComponent * 255))))
    let green = max(0, min(255, Int(round(color.greenComponent * 255))))
    let blue = max(0, min(255, Int(round(color.blueComponent * 255))))
    return String(format: "#%02X%02X%02X", red, green, blue)
  }
}

extension AppCoordinator: PasteboardMonitorDelegate {
  func pasteboardMonitor(
    _ monitor: PasteboardMonitor,
    didCapture item: ClipboardItem,
    updatedItems: [ClipboardItem]
  ) {
    if item.kind == .image,
       SensitiveContent.shouldEncryptAtRest(item),
       model.items.contains(where: { $0.id == item.id && !SensitiveContent.shouldEncryptAtRest($0) }) {
      ImageDragFiles.removeAll()
    }
    updatedItems.forEach(model.replace)
    // Copying the content of an item in the Trash brings that item back.
    if model.trashedItems.contains(where: { $0.id == item.id }) {
      model.remove([item.id])
    }
    model.insert(item)
    applyRetention()
    if item.expiresAt != nil {
      deleteExpiredItems()
    }
    resetPasteNextPointer()
    playSound(.copy)
    capturedClipboardItems.send(item)
  }

  func pasteboardMonitor(
    _ monitor: PasteboardMonitor,
    didRecognize content: RecognizedImageContent,
    inItemWithID itemID: ClipboardItem.ID
  ) {
    do {
      let outcome = try historyStore.finalizeRecognizedImage(
        id: itemID,
        content: content,
        sensitiveContentLifetime: model.preferences.sensitiveContentLifetime
      )

      let upgradedImageToEncrypted = outcome.updated?.kind == .image
        && outcome.updated.map(SensitiveContent.shouldEncryptAtRest) == true
        && !(outcome.previous.map(SensitiveContent.shouldEncryptAtRest) ?? false)
      if outcome.purged || upgradedImageToEncrypted {
        ImageDragFiles.removeAll()
      }

      if let oldPath = outcome.previous?.assetPath,
         outcome.purged
           || oldPath != outcome.updated?.assetPath
           || (outcome.updated.map(isItemHiddenInUI) == true) {
        ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: oldPath)
      }

      if let prev = outcome.previous,
         prev.kind == .file,
         outcome.purged || outcome.updated.map(SensitiveContent.shouldEncryptAtRest) == true {
        filePreviewCache.removePreviews(forFilePaths: Set(prev.filePaths))
        if outcome.purged || (outcome.updated.map(isItemHiddenInUI) ?? true) {
          for path in prev.filePaths {
            ImageAssetThumbnailLoader.shared.removeThumbnails(forPath: path)
          }
        }
      }

      if outcome.purged {
        model.remove([itemID])
        HistoryRowTextCache.removeAll()
        deleteExpiredItems()
        return
      }

      if let updated = outcome.updated {
        if outcome.isTrashed {
          if model.isShowingTrash {
            model.replace(updated)
          }
        } else {
          model.replace(updated)
        }
        if updated.expiresAt != nil {
          deleteExpiredItems()
        }
      }
    } catch {
      model.lastError = error.localizedDescription
    }
  }
}
