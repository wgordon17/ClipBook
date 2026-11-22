@testable import ClipBook
import AppKit
import Carbon
import Foundation
import GRDB
import Security
import Testing

@Suite
enum ServicesAndUtilitiesTests {
    @Suite
    struct ShortcutsTests {
        @Test
        func parserValidAndInvalidShortcuts() {
            let cmdShiftV = KeyboardShortcutParser.parse("cmd+shift+v")
            let shiftCmdV = KeyboardShortcutParser.parse("SHIFT+COMMAND+V")
            #expect(cmdShiftV != nil)
            #expect(cmdShiftV == shiftCmdV)
            #expect(KeyboardShortcutParser.hasModifiers("cmd+shift+v"))
            #expect(!KeyboardShortcutParser.hasModifiers("return"))

            let ctrlOptDelete = KeyboardShortcutParser.parse("ctrl+alt+delete")
            #expect(ctrlOptDelete != nil)
            #expect(ctrlOptDelete?.modifiers == UInt32(controlKey | optionKey))

            #expect(KeyboardShortcutParser.parse("") == nil)
            #expect(KeyboardShortcutParser.parse("cmd+unknownkey") == nil)
        }

        @Test
        func menuItemKeyEquivalents() throws {
            // The Delete key reports U+007F, which is what a menu item's key equivalent has to be to match it.
            let deleteEquiv = try #require(KeyboardShortcutParser.menuItemKeyEquivalent(for: "cmd+delete"))
            #expect(deleteEquiv.keyEquivalent == "\u{7f}")
            #expect(deleteEquiv.modifierFlags == [.command])

            let forwardDeleteEquiv = try #require(KeyboardShortcutParser.menuItemKeyEquivalent(for: "cmd+forwarddelete"))
            #expect(forwardDeleteEquiv.keyEquivalent == String(Character(UnicodeScalar(NSDeleteFunctionKey)!)))
            #expect(forwardDeleteEquiv.modifierFlags == [.command])

            let keypadPlusEquiv = try #require(KeyboardShortcutParser.menuItemKeyEquivalent(for: "cmd+keypadplus"))
            #expect(keypadPlusEquiv.keyEquivalent == "+")
            #expect(keypadPlusEquiv.modifierFlags.contains(.command))
            #expect(keypadPlusEquiv.modifierFlags.contains(.numericPad))
        }

        @Test
        func shortcutConflictDetection() {
            #expect(ShortcutConflicts.isSameShortcut("cmd+shift+c", "shift+command+c"))
            #expect(!ShortcutConflicts.isSameShortcut("cmd+c", "option+c"))
            #expect(!ShortcutConflicts.isSameShortcut("", "cmd+c"))

            let customAssignments = [
                ShortcutConflicts.Assignment(title: "Copy Item", shortcut: "cmd+c"),
                ShortcutConflicts.Assignment(title: "Delete Item", shortcut: "cmd+delete")
            ]
            #expect(ShortcutConflicts.conflictingActionTitle(for: "command+c", in: customAssignments) == "Copy Item")
            #expect(ShortcutConflicts.conflictingActionTitle(for: "cmd+e", in: customAssignments) == nil)
        }

        @Test
        func disabledGlobalShortcutService() {
            let service = GlobalShortcutService(isEnabled: false)
            #expect(!service.hasHandler(for: .showHistory))

            service.register(.showHistory, shortcut: "shift+cmd+v") {}
            service.register(.pasteNext, shortcut: "control+v") {}
            #expect(service.hasHandler(for: .showHistory))
            #expect(service.hasHandler(for: .pasteNext))
            #expect(!service.hasHandler(for: .pauseCapture))

            service.register(.showHistory, shortcut: "cmd+cmd") {}
            #expect(service.hasHandler(for: .showHistory))

            // A bare key, or one that does not parse, is never registered.
            service.register(.pauseCapture, shortcut: "return") {}
            service.register(.pasteNextRich, shortcut: "cmd+unknownkey") {}
            #expect(!service.hasHandler(for: .pauseCapture))
            #expect(!service.hasHandler(for: .pasteNextRich))

            service.unregisterAll()
            #expect(!service.hasHandler(for: .showHistory))
            #expect(!service.hasHandler(for: .pasteNext))
        }
    }

    @Suite
    struct PreviewCachesSVGRendererAndLicensingTests {
        @Test(.timeLimit(.minutes(1)))
        func previewCacheReportsTheDisplaySizeOfAnImageFileAndRemovesItsDirectory() async throws {
            try await TestSupport.withTemporaryDirectory { tempDir in
                let cacheDir = tempDir.appendingPathComponent("PreviewCache", isDirectory: true)
                let previewCache = FilePreviewCache(directory: cacheDir)
                let imageURL = tempDir.appendingPathComponent("photo.png")
                try TestSupport.makePNGData(pixelWidth: 288, pixelHeight: 144, dpi: 144.0, color: .systemGreen)
                    .write(to: imageURL)

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    _ = previewCache.image(forFileAt: imageURL.path, targetSize: CGSize(width: 64, height: 64)) { _ in
                        continuation.resume()
                    }
                }

                let displaySize = try #require(previewCache.displaySizeForImageFile(at: imageURL.path))
                #expect(abs(displaySize.width - 144) < 0.5)
                #expect(abs(displaySize.height - 72) < 0.5)

                previewCache.removeAll()
                #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func thumbnailLoaderDecodesInTheBackgroundAndForgetsEverythingOnRemoveAll() async throws {
            try await TestSupport.withTemporaryDirectory { tempDir in
                let thumbnailLoader = ImageAssetThumbnailLoader()
                let imageURL = tempDir.appendingPathComponent("photo.png")
                try TestSupport.makePNGData(pixelWidth: 288, pixelHeight: 144, dpi: 144.0, color: .systemGreen)
                    .write(to: imageURL)

                let decodedImage = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                    if let cached = thumbnailLoader.thumbnail(for: imageURL, maximumPixelSize: 128, completion: { image in
                        continuation.resume(returning: image)
                    }) {
                        continuation.resume(returning: cached)
                    }
                }
                let thumbnail = try #require(decodedImage)
                #expect(thumbnail.size.width > 0)
                #expect(thumbnail.size.height > 0)

                thumbnailLoader.removeAll()
                #expect(thumbnailLoader.thumbnail(for: imageURL, maximumPixelSize: 128) { _ in } == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func previewCacheInvalidatesMemoryHitsOnFileEditSymlinkRetargetAndSiblingDirectoryCleanupPreservesOtherDirectories() async throws {
            try await TestSupport.withTemporaryDirectory { tempDir in
                // 1. FilePreviewCache memory hit === cached image, invalidated on file edit and symlink retarget after removePreviews.
                let cacheDir = tempDir.appendingPathComponent("PreviewCacheInvalidation", isDirectory: true)
                let previewCache = FilePreviewCache(directory: cacheDir)
                let targetA = tempDir.appendingPathComponent("target-a.png")
                let targetB = tempDir.appendingPathComponent("target-b.png")
                let symlinkURL = tempDir.appendingPathComponent("current-photo.png")
                try TestSupport.makePNGData(pixelWidth: 80, pixelHeight: 80, color: .systemRed).write(to: targetA)
                try TestSupport.makePNGData(pixelWidth: 160, pixelHeight: 80, color: .systemBlue).write(to: targetB)
                try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetA)

                let generatedFirst: NSImage = await withCheckedContinuation { continuation in
                    _ = previewCache.image(forFileAt: symlinkURL.path, targetSize: CGSize(width: 40, height: 40)) { img in
                        continuation.resume(returning: img)
                    }
                }
                let syncHit = previewCache.image(forFileAt: symlinkURL.path, targetSize: CGSize(width: 40, height: 40)) { _ in }
                #expect(syncHit === generatedFirst)

                // Overwriting targetA with larger payload invalidates signature on synchronous lookup.
                try TestSupport.makePNGData(pixelWidth: 200, pixelHeight: 120, color: .systemOrange).write(to: targetA)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(10)],
                    ofItemAtPath: targetA.path
                )
                var regeneratedAfterEdit: NSImage?
                let staleOrFallback = previewCache.image(forFileAt: symlinkURL.path, targetSize: CGSize(width: 40, height: 40)) { img in
                    regeneratedAfterEdit = img
                }
                #expect(staleOrFallback !== generatedFirst)
                #expect(await TestSupport.waitUntil { regeneratedAfterEdit != nil })

                // Retargeting symlink after removePreviews clears canonicalPathCache and resolves targetB's 2:1 aspect display size.
                previewCache.removePreviews(forFilePaths: [symlinkURL.path, targetA.path])
                try FileManager.default.removeItem(at: symlinkURL)
                try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetB)
                let retargetedSize = try #require(previewCache.displaySizeForImageFile(at: symlinkURL.path))
                #expect(abs(retargetedSize.width - 160) < 0.5)
                #expect(abs(retargetedSize.height - 80) < 0.5)

                // 2. Sibling support directories ("Support" vs "Support2") do not cross-evict thumbnails or drag copies!
                let support1 = tempDir.appendingPathComponent("Support", isDirectory: true)
                let support2 = tempDir.appendingPathComponent("Support2", isDirectory: true)
                let store1 = GRDBHistoryStore(directory: support1, keyProvider: InMemoryDatabaseKeyProvider())
                defer { store1.close() }
                let store2 = GRDBHistoryStore(directory: support2, keyProvider: InMemoryDatabaseKeyProvider())
                defer { store2.close() }

                let clip1 = UUID()
                let clip2 = UUID()
                let samplePNG = try TestSupport.makePNGData(pixelWidth: 32, pixelHeight: 32, color: .systemTeal)
                let enc1 = try store1.writeManagedAsset(pngData: samplePNG, role: .image, clipID: clip1, encrypted: true)
                let enc2 = try store2.writeManagedAsset(pngData: samplePNG, role: .image, clipID: clip2, encrypted: true)
                let ctx1 = ImageAssetThumbnailLoader.ManagedAssetContext(role: .image, ownerClipID: clip1, requiresEncryption: true)
                let ctx2 = ImageAssetThumbnailLoader.ManagedAssetContext(role: .image, ownerClipID: clip2, requiresEncryption: true)

                let loader = ImageAssetThumbnailLoader()
                for (url, ctx) in [(enc1, ctx1), (enc2, ctx2)] {
                    _ = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                        if let hit = loader.thumbnail(for: url, maximumPixelSize: 128, assetContext: ctx, completion: { continuation.resume(returning: $0) }) {
                            continuation.resume(returning: hit)
                        }
                    }
                }
                #expect(loader.thumbnail(for: enc1, maximumPixelSize: 128, assetContext: ctx1) { _ in } != nil)
                #expect(loader.thumbnail(for: enc2, maximumPixelSize: 128, assetContext: ctx2) { _ in } != nil)

                loader.removeThumbnails(inDirectory: support1)
                #expect(loader.thumbnail(for: enc1, maximumPixelSize: 128, assetContext: ctx1) { _ in } == nil)
                #expect(loader.thumbnail(for: enc2, maximumPixelSize: 128, assetContext: ctx2) { _ in } != nil, "Support eviction must not prefix-match Support2")

                defer { ImageDragFiles.removeAll() }
                let dragItem1 = ImageAssetDragItem.make(assetURL: enc1, fileName: "one.png", ownerClipID: clip1, requiresEncryption: true)
                let dragItem2 = ImageAssetDragItem.make(assetURL: enc2, fileName: "two.png", ownerClipID: clip2, requiresEncryption: true)
                let dragURL1 = try #require(dragItem1.string(forType: .fileURL).flatMap(URL.init(string:)))
                let dragURL2 = try #require(dragItem2.string(forType: .fileURL).flatMap(URL.init(string:)))
                #expect(dragURL1.path != enc1.path)
                #expect(dragURL2.path != enc2.path)
                #expect(FileManager.default.fileExists(atPath: dragURL1.path))
                #expect(FileManager.default.fileExists(atPath: dragURL2.path))

                ImageDragFiles.removeCopies(forSupportDirectory: support1)
                #expect(!FileManager.default.fileExists(atPath: dragURL1.path))
                #expect(FileManager.default.fileExists(atPath: dragURL2.path), "Support drag cleanup must preserve Support2 drag copies")
            }
        }

        @Test
        @MainActor
        func svgImageRendererValidationAndRendering() {
            TestSupport.ensureAppKitInitialized()
            let validSVG = """
            <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
              <circle cx="24" cy="24" r="20" fill="#000000"/>
            </svg>
            """
            #expect(SVGImageRenderer.isSVGMarkup(validSVG))

            let htmlWrappedSVG = "<div><svg xmlns=\"http://www.w3.org/2000/svg\"></svg></div>"
            let unclosedSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/>"
            #expect(!SVGImageRenderer.isSVGMarkup(htmlWrappedSVG))
            #expect(!SVGImageRenderer.isSVGMarkup(unclosedSVG))

            let renderer = SVGImageRenderer()
            let item = ClipboardItem.fixture(kind: .text, text: validSVG)
            let rendering = renderer.rendering(for: item)
            #expect(rendering != nil)
            #expect(rendering?.tone == .dark)
        }

        @MainActor
        private final class MockLicensingBackend: LicensingService.Backend {
            var currentState: LicensingService.State = .trial(daysLeft: 7)
            var recordedTrialUsageKeys: [String] = []
            var feedbackMessages: [String] = []

            func refresh(licenseKey: String) -> LicensingService.State {
                currentState
            }

            func recordTrialUsage(licenseKey: String) {
                recordedTrialUsageKeys.append(licenseKey)
            }

            func activate(licenseKey: String) async throws {
                currentState = .activated
            }

            func deactivate(licenseKey: String) async throws {
                currentState = .trial(daysLeft: 5)
            }

            func sendFeedback(text: String) async {
                feedbackMessages.append(text)
            }
        }

        @Test
        @MainActor
        func licensingServiceTransitions() async throws {
            let backend = MockLicensingBackend()
            let service = LicensingService(backend: backend)

            service.refresh(licenseKey: "")
            #expect(service.state == .trial(daysLeft: 7))

            backend.currentState = .trialExpired
            service.refresh(licenseKey: "")
            #expect(service.state == .trialExpired)
            #expect(service.state.isTrialExpired)

            try await service.activate(licenseKey: "VALID-KEY-123")
            #expect(service.state == .activated)
            #expect(service.state.isActivated)

            try await service.deactivate(licenseKey: "VALID-KEY-123")
            #expect(service.state == .trial(daysLeft: 5))

            service.recordTrialUsage(licenseKey: "")
            #expect(backend.recordedTrialUsageKeys == [""])

            await service.sendFeedback(text: "Great app!")
            #expect(backend.feedbackMessages == ["Great app!"])
        }

        @MainActor
        private static func makeOutsideClickTestWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            return window
        }

        @Test
        @MainActor
        func outsideClickDecision() throws {
            TestSupport.ensureAppKitInitialized()
            let window = Self.makeOutsideClickTestWindow()
            defer { window.close() }
            let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let outside = NSPoint(x: window.frame.maxX + 50, y: window.frame.maxY + 50)

            // A window that is not visible is never dismissed.
            #expect(!OutsideClickDismissalMonitor.isOutsideClick(in: nil, of: window, at: outside))

            window.orderFront(nil)
            try #require(window.isVisible)
            #expect(OutsideClickDismissalMonitor.isOutsideClick(in: nil, of: window, at: outside))
            #expect(OutsideClickDismissalMonitor.isOutsideClick(in: window, of: window, at: outside))
            #expect(!OutsideClickDismissalMonitor.isOutsideClick(in: nil, of: window, at: inside))

            // A click in some other window is not this window's business.
            let other = Self.makeOutsideClickTestWindow()
            defer { other.close() }
            #expect(!OutsideClickDismissalMonitor.isOutsideClick(in: other, of: window, at: outside))
        }

        @Test
        @MainActor
        func outsideClickDecisionWithSheets() throws {
            TestSupport.ensureAppKitInitialized()
            let parent = Self.makeOutsideClickTestWindow()
            let sheet = Self.makeOutsideClickTestWindow()
            let other = Self.makeOutsideClickTestWindow()
            defer {
                parent.endSheet(sheet)
                sheet.close()
                parent.close()
                other.close()
            }
            parent.orderFront(nil)
            try #require(parent.isVisible)
            parent.beginSheet(sheet)
            try #require(sheet.sheetParent === parent)
            try #require(parent.attachedSheet === sheet)
            let outside = NSPoint(x: sheet.frame.maxX + 50, y: sheet.frame.maxY + 50)

            // The sheet is dismissed by clicks in its own parent window, but not in unrelated ones.
            #expect(OutsideClickDismissalMonitor.isOutsideClick(in: parent, of: sheet, at: outside))
            #expect(!OutsideClickDismissalMonitor.isOutsideClick(in: other, of: sheet, at: outside))
            // A window with a sheet attached is never dismissed.
            #expect(!OutsideClickDismissalMonitor.isOutsideClick(in: parent, of: parent, at: outside))
        }

        @Test
        @MainActor
        func outsideClickDismissalMonitorStopsAfterInvalidateAndDeinit() throws {
            TestSupport.ensureAppKitInitialized()
            let window = Self.makeOutsideClickTestWindow()
            defer { window.close() }
            window.orderFront(nil)
            try #require(window.isVisible)
            // Park the window away from the real cursor, which decides what is "outside".
            let cursor = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: cursor.x + 2000, y: cursor.y + 2000))
            try #require(!window.frame.contains(cursor))

            func click() throws {
                let event = try #require(NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                ))
                NSApp.sendEvent(event)
            }

            var dismissalCount = 0
            var monitor: OutsideClickDismissalMonitor? = OutsideClickDismissalMonitor(window: window) {
                dismissalCount += 1
            }
            try click()
            #expect(dismissalCount == 1)

            monitor?.invalidate()
            monitor?.invalidate()
            try click()
            #expect(dismissalCount == 1)

            // Releasing a monitor that was not invalidated removes it as well.
            monitor = OutsideClickDismissalMonitor(window: window) {
                dismissalCount += 1
            }
            monitor = nil
            try click()
            #expect(dismissalCount == 1)
        }
    }

    @Suite
    struct AppDirectoriesAndGRDBLinkageTests {
        // Self-contained public X.509 v3 DER certificate fixture (no private key) for SecCertificateCreateWithData.
        private static let testCertificateDERBase64 = """
        MIIEBTCCAm2gAwIBAgIJAPgyU39GTDg0MA0GCSqGSIb3DQEBCwUAMCUxIzAhBgNV
        BAMMGkNsaXBCb29rIEZvcmsgQ29kZSBTaWduaW5nMB4XDTI2MTExNjEzMjc0NloX
        DTM2MTExMzEzMjc0NlowJTEjMCEGA1UEAwwaQ2xpcEJvb2sgRm9yayBDb2RlIFNp
        Z25pbmcwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDQjyunOLBdXkd3
        30Y67hpWz4MnxOzk+288unxuPVcmFo8ubRjws9zjxgUKPppJnY1cYyHENzGTWwKs
        kQrbYsqpZYW82cxWXOkdyu3Toyy7Sp+5iakvQmPZLNUDz3Ny7FGEjZn5JBdDziFu
        FhDzZhOmdz6RbEgdeWrURmXGdtT3ak8U/nQGe84nTqHANRnzlA868msfgrustYGM
        RIGjLJ4Mcc3D/RvaUzf6SoTIjghrIMV4X/jaLf0x6wnAkl7L546EMZwKXMFx7MZU
        7L0vkSdGBdwrbiItQbRLa5JjQ+HvIA2ymGv2rxHjwpuG2RnGbyHfY7IksOcYxAv/
        GQhUhG9Swd21ZuY+mvUkG0P22ISElfttiU3R8cxqkME5nr8BVXJa/M8FlsbTwdd1
        GwJUStVDWC3dO6LpL3Xt4e2eyKcRJu1zBeSiWqHWi3QEpvk93qoNwfBXarBrXVIa
        Ogs6oHSc8O7HEf7GjkaONLrOXCXAA3RAo/7bk3PNqkWjpTKVDC8CAwEAAaM4MDYw
        DAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
        BQUHAwMwDQYJKoZIhvcNAQELBQADggGBADIqWR3PL6dqw1ipZo4JvZApN+0lUxvL
        wpZ0WY58KvtlLWICANhWbFFO+0fB7SQnopK7yajcLgC9uiTtfWvH99eCPhFiTtqo
        aQh89aYR47APf2xb1UcvZmoWz+B0+iW11e+3xKbSB/f3N3ADUvaRBGuYt1xLehAv
        53w+Hs5M0IvpNeF8T7niHWzz+2U/XnMJBHHpbwsPZQTABzg4fjVksgpiEaJQ3bFL
        EsZLoNH0u2ic3hw+Njmwt5TmL69k3TuN0vIzNDLy79nkolleidj2yByWodueJVWE
        4o5WU+eMdQ3nti+j8qEUcGS+EVgNihavi+SIVJJOF8kyhXMsW/UzXQBjXspMS6Pc
        aMro1BeuR4Z/ej/RykceUj0+o9ERJXARpZ2U0b/or8sw6k3R6CkFOoMT9UMCy2VG
        XmINm9f6XsTqXdgtdviaPz1w5z1iPljCraAg9L72UB2kcSEXh3wIvNFJ/YFLFxa/
        LzBuRzOn6LNyN8l1CkFi7YTelRpdGSP2pg==
        """

        @Test
        func supportFolderAndDirectoryIsolationInThrowawayBaseDirectory() throws {
            #expect(AppDirectories.usesIsolatedDebugStorage)
            #expect(AppDirectories.supportFolderName() == "ClipBook2-Debug")
            #expect(AppDirectories.supportFolderName(isDebugBuild: false) == "ClipBook2")
            #expect(AppDirectories.supportFolderName(isDebugBuild: true) == "ClipBook2-Debug")

            let fileManager = FileManager.default
            let baseDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("ClipBookAppDirectoriesTests-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: baseDirectory)
            }

            func expectDirectoryExists(at url: URL) {
                var isDirectory: ObjCBool = false
                #expect(fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory))
                #expect(isDirectory.boolValue)
            }

            let releaseBase = baseDirectory.appendingPathComponent("release", isDirectory: true)
            let releaseSupport = AppDirectories.applicationSupport(
                fileManager: fileManager,
                baseDirectory: releaseBase,
                isDebugBuild: false
            )
            #expect(
                releaseSupport.standardizedFileURL
                    == releaseBase.appendingPathComponent("ClipBook2", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: releaseSupport)
            #expect(!fileManager.fileExists(atPath: releaseBase.appendingPathComponent("ClipBook2-Debug").path))

            let releaseForkInSupport = AppDirectories.forkSupportDirectory(
                in: releaseSupport,
                fileManager: fileManager
            )
            #expect(
                releaseForkInSupport.standardizedFileURL
                    == releaseBase.appendingPathComponent("ClipBook2/Fork", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: releaseForkInSupport)

            let releaseDirectBase = baseDirectory.appendingPathComponent("release-direct", isDirectory: true)
            let releaseForkDirect = AppDirectories.forkSupportDirectory(
                fileManager: fileManager,
                baseDirectory: releaseDirectBase,
                isDebugBuild: false
            )
            #expect(
                releaseForkDirect.standardizedFileURL
                    == releaseDirectBase.appendingPathComponent("ClipBook2/Fork", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: releaseDirectBase.appendingPathComponent("ClipBook2", isDirectory: true))
            expectDirectoryExists(at: releaseForkDirect)

            let debugBase = baseDirectory.appendingPathComponent("debug", isDirectory: true)
            let debugSupport = AppDirectories.applicationSupport(
                fileManager: fileManager,
                baseDirectory: debugBase,
                isDebugBuild: true
            )
            #expect(
                debugSupport.standardizedFileURL
                    == debugBase.appendingPathComponent("ClipBook2-Debug", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: debugSupport)
            #expect(!fileManager.fileExists(atPath: debugBase.appendingPathComponent("ClipBook2").path))

            let debugForkInSupport = AppDirectories.forkSupportDirectory(
                in: debugSupport,
                fileManager: fileManager
            )
            #expect(
                debugForkInSupport.standardizedFileURL
                    == debugBase.appendingPathComponent("ClipBook2-Debug/Fork", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: debugForkInSupport)

            let debugDirectBase = baseDirectory.appendingPathComponent("debug-direct", isDirectory: true)
            let debugForkDirect = AppDirectories.forkSupportDirectory(
                fileManager: fileManager,
                baseDirectory: debugDirectBase,
                isDebugBuild: true
            )
            #expect(
                debugForkDirect.standardizedFileURL
                    == debugDirectBase.appendingPathComponent("ClipBook2-Debug/Fork", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: debugDirectBase.appendingPathComponent("ClipBook2-Debug", isDirectory: true))
            expectDirectoryExists(at: debugForkDirect)

            let defaultBase = baseDirectory.appendingPathComponent("default", isDirectory: true)
            let defaultSupport = AppDirectories.applicationSupport(
                fileManager: fileManager,
                baseDirectory: defaultBase
            )
            #expect(
                defaultSupport.standardizedFileURL
                    == defaultBase.appendingPathComponent("ClipBook2-Debug", isDirectory: true).standardizedFileURL
            )
            let defaultFork = AppDirectories.forkSupportDirectory(
                fileManager: fileManager,
                baseDirectory: defaultBase
            )
            #expect(
                defaultFork.standardizedFileURL
                    == defaultBase.appendingPathComponent("ClipBook2-Debug/Fork", isDirectory: true).standardizedFileURL
            )
            expectDirectoryExists(at: defaultFork)
        }

        @Test
        func certificateSignedReleaseEvaluationAcrossSigningDictionaries() throws {
            let derData = try #require(
                Data(base64Encoded: Self.testCertificateDERBase64, options: .ignoreUnknownCharacters)
            )
            let rawCertificate = SecCertificateCreateWithData(nil, derData as CFData)
            #expect(rawCertificate != nil)
            let certificate = try #require(rawCertificate)

            let idKey = kSecCodeInfoIdentifier as String
            let flagsKey = kSecCodeInfoFlags as String
            let certsKey = kSecCodeInfoCertificates as String
            let validID = "com.ikryanov.clipbook.v2"

            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: nil))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [:]))

            // Missing, empty, or non-String identifier fails closed.
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                flagsKey: UInt32(0x10000),
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: "",
                flagsKey: UInt32(0x10000),
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: 42,
                flagsKey: UInt32(0x10000),
                certsKey: [certificate]
            ]))

            // Ad-hoc (0x10002 / 0x0002) and linker-signed (0x20002 / 0x20000 / 0x30000) flags fail closed.
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x10002),
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: SecCodeSignatureFlags.adhoc.rawValue,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x20002),
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: SecCodeSignatureFlags.linkerSigned.rawValue,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x30000),
                certsKey: [certificate]
            ]))

            // Empty, missing, or wrong-type certificate chain fails closed.
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x10000),
                certsKey: [SecCertificate]()
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x10000)
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x10000),
                certsKey: ["not-a-certificate"]
            ]))

            // Missing, CFBoolean, non-integer, negative, or overflow flags fail closed.
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: kCFBooleanTrue as Any,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: kCFBooleanFalse as Any,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: NSNumber(value: true),
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: "0x10000",
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: -1,
                certsKey: [certificate]
            ]))
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: NSNumber(value: Int64(UInt32.max) + 1),
                certsKey: [certificate]
            ]))

            // Certificate-signed hardened runtime (0x10000) succeeds across UInt32, Int, and non-CFBoolean NSNumber.
            #expect(AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: UInt32(0x10000),
                certsKey: [certificate]
            ]))
            #expect(AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: Int(0x10000),
                certsKey: [certificate]
            ]))
            #expect(AppDirectories.isCertificateSignedRelease(signingInfo: [
                idKey: validID,
                flagsKey: NSDecimalNumber(value: 0x10000),
                certsKey: [certificate]
            ]))

            // Ad-hoc signed test host process is never treated as a certificate-signed release.
            #expect(!AppDirectories.isCertificateSignedRelease(signingInfo: AppDirectories.currentProcessSigningInfo()))
        }

        @Test
        func grdbDeserializesModuleTypesAndResolvesSymbolsViaBundleLoader() throws {
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE grdb_smoke (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO grdb_smoke (label) VALUES (?)", arguments: ["bundle-loader-ok"])
            }
            let storedLabel = try queue.read { db in
                try String.fetchOne(db, sql: "SELECT label FROM grdb_smoke WHERE id = 1")
            }
            #expect(storedLabel == "bundle-loader-ok")

            let version = try queue.read { db in
                try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? ""
            }
            #expect(!version.isEmpty)
            #expect(version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil)
        }
    }
}
