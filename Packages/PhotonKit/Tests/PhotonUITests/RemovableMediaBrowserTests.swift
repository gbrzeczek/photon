import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Synchronization
import Testing

@testable import PhotonUI

/// The browser through disconnecting and reconnecting, on exFAT images, with the system's real mount
/// events. A forced detach stands in for a pulled cable: see docs/PLAN.md, Removable media checks.
@Suite("Browsing across a disconnect", .serialized, .usesDiskImages, .timeLimit(.minutes(10)))
@MainActor
struct RemovableMediaBrowserTests {
    private func until(_ seconds: Double = 30, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @MainActor
    private final class Browser {
        let library: BrowserLibrary
        let model: BrowserModel
        let view: BrowserContainerView
        let window: NSWindow

        init(library: BrowserLibrary, model: BrowserModel, view: BrowserContainerView, window: NSWindow) {
            self.library = library
            self.model = model
            self.view = view
            self.window = window
        }

        func close() {
            library.loader.stop()
            window.close()
        }
    }

    private final class Setup {
        let directory: URL
        let image: DiskImage
        var mount: String

        init(directory: URL, image: DiskImage, mount: String) {
            self.directory = directory
            self.image = image
            self.mount = mount
        }

        var libraryURL: URL { directory.appending(path: "library/Library.sqlite") }

        func tearDown() {
            image.ensureDetached()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeImage(count: Int = 12, label: String, readOnly: Bool = true) throws -> Setup {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-disconnect-\(UUID().uuidString)")
        let image = try DiskImage.create(in: directory, label: label, megabytes: 128)
        var options = SyntheticLibrary.Options()
        options.fileCount = count
        options.duplicateInterval = 0
        options.videoInterval = 0
        let first = try image.attach()
        try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: first).appending(path: "media"))
        try image.detach()
        return Setup(directory: directory, image: image, mount: try image.attach(readOnly: readOnly))
    }

    private func openBrowser(_ setup: Setup, options: IndexOptions = BrowserLibrary.defaultOptions) async throws -> Browser {
        let url = setup.libraryURL
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        let library = BrowserLibrary(handle, options: options)
        let model = BrowserModel(library: library)
        let restored = await model.restoreLastSession()
        let view = BrowserContainerView(model: model)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        view.grid.needsLayout = true
        view.grid.layoutSubtreeIfNeeded()
        view.list.needsLayout = true
        view.list.layoutSubtreeIfNeeded()
        model.contentDidLayOut()
        await library.start()
        if restored { model.leaveVanishedFolder() } else { model.openFirstFolder() }
        return Browser(library: library, model: model, view: view, window: window)
    }

    private func addMedia(_ browser: Browser, _ setup: Setup, count: Int) async throws {
        browser.library.addFolder(URL(fileURLWithPath: setup.mount).appending(path: "media"))
        #expect(try await until { !browser.library.isIndexing && browser.model.itemCount == count })
    }

    @Test("Disconnecting keeps the place, the viewer and the picture, and reconnecting sharpens it again")
    func disconnectAndReconnect() async throws {
        let setup = try makeImage(label: "PHOTONCYCLE")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        #expect(browser.model.scopeAccess == .readOnly)
        browser.model.select(row: 3)
        browser.model.openViewer()
        #expect(try await until { browser.view.viewer.isShowingPreviewOrBetterForTesting })

        try setup.image.detach(force: true)

        // The system's own events bring this about. Nothing here calls the indexer.
        #expect(try await until { browser.library.onlineVolumes.isEmpty })
        #expect(browser.model.scopeAccess == .offline)
        #expect(browser.model.itemCount == 12)
        #expect(browser.model.isViewerOpen)
        #expect(browser.model.selection.currentRow == 3)

        // Past the neighbors, which are already in memory.
        browser.model.stepViewer(by: 5, isRepeat: false)
        #expect(browser.model.selection.currentRow == 8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!browser.view.viewer.isShowingPreviewOrBetterForTesting)
        #expect(browser.model.viewerStatus == "9 of 12")

        setup.mount = try setup.image.attach(readOnly: true)

        #expect(try await until { !browser.library.onlineVolumes.isEmpty })
        #expect(browser.model.scopeAccess == .readOnly)
        #expect(try await until { browser.view.viewer.isShowingPreviewOrBetterForTesting })
        #expect(browser.model.selection.currentRow == 8)
        #expect(browser.model.isViewerOpen)
        browser.model.closeViewer(animated: false)
    }

    @Test("What changed while the drive was away arrives on reconnect, and the place stays")
    func changesOnReconnect() async throws {
        let setup = try makeImage(label: "PHOTONNEWF", readOnly: false)
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        browser.model.select(row: 5)
        let asset = browser.model.selection.currentAsset

        try setup.image.detach()
        #expect(try await until { browser.library.onlineVolumes.isEmpty })

        // A scratch mount, away from the library's eyes, changes the image.
        let elsewhere = setup.directory.appending(path: "elsewhere")
        let scratch = try setup.image.attach(mountPoint: elsewhere)
        try SyntheticMedia.jpeg()?.write(to: URL(fileURLWithPath: scratch + "/media/arrived.JPG"))
        try setup.image.detach()

        setup.mount = try setup.image.attach()
        #expect(try await until { browser.model.itemCount == 13 })
        #expect(browser.model.selection.currentAsset == asset)
    }

    @Test("Eject takes the volume offline, and the browser carries on")
    func eject() async throws {
        let setup = try makeImage(label: "PHOTONEJCT")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        #expect(try await until { browser.model.canEjectVolume })
        browser.model.select(row: 2)

        browser.model.ejectVolume()

        #expect(try await until { browser.model.scopeAccess == .offline })
        #expect(try await until { !setup.image.isAttached })
        #expect(try await until { browser.model.notice?.contains("ejected") == true })
        #expect(!browser.model.canEjectVolume)
        #expect(browser.model.itemCount == 12)
        #expect(browser.model.selection.currentRow == 2)
    }

    @Test("An eject refused because another app is using the volume changes nothing, and says so")
    func refusedEject() async throws {
        let setup = try makeImage(label: "PHOTONBUSYE")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        let media = URL(fileURLWithPath: setup.mount).appending(path: "media")
        let held = try #require(
            FileManager.default.enumerator(atPath: media.path)?.compactMap { $0 as? String }.first { $0.hasSuffix(".JPG") })
        let holder = try FileHandle(forReadingFrom: media.appending(path: held))
        defer { try? holder.close() }

        browser.model.ejectVolume()

        #expect(try await until { browser.model.notice?.contains("couldn't be ejected") == true })
        #expect(setup.image.isAttached)
        #expect(try await until { browser.model.scopeAccess == .readOnly })
    }

    @Test("Eject isn't offered for a volume that isn't a disk image in a test run")
    func ejectStaysOnImages() async throws {
        let setup = try makeImage(label: "PHOTONSCOPE")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        #expect(try await until { browser.library.ejectableVolumes.count == 1 })
        for mount in MountedVolume.all() where mount.location != .diskImage {
            #expect(!VolumeEjector().canEject(mount))
        }
    }

    @Test("A launch with any development setting can only eject disk images")
    func launchScope() {
        #expect(LaunchSettings(environment: [:]).ejectScope == .anyExternalVolume)
        #expect(LaunchSettings(environment: ["PHOTON_LIBRARY": "/tmp/x"]).ejectScope == .diskImagesOnly)
        #expect(LaunchSettings(environment: ["PHOTON_WINDOW": "main"]).ejectScope == .diskImagesOnly)
        #expect(LaunchSettings(environment: ["PHOTON_PERF_OUT": "/tmp/x"]).ejectScope == .diskImagesOnly)
        #expect(LaunchSettings(environment: ["XCTestConfigurationFilePath": "x"]).ejectScope == .diskImagesOnly)
    }

    @Test("Offline, Show in Finder is disabled and Copy isn't")
    func offlineMenu() async throws {
        let setup = try makeImage(label: "PHOTONMENU")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        browser.model.select(row: 0)
        #expect(BrowserContextMenu.make(model: browser.model).item(withTitle: "Show in Finder")?.isEnabled == true)

        try setup.image.detach(force: true)
        #expect(try await until { browser.library.onlineVolumes.isEmpty })

        let menu = BrowserContextMenu.make(model: browser.model)
        #expect(menu.item(withTitle: "Show in Finder")?.isEnabled == false)
        #expect(menu.item(withTitle: "Copy")?.isEnabled == true)
    }

    @Test("Dragging offline files says why nothing happens, once")
    func offlineDrag() async throws {
        let drag = FileDragController()
        final class Box: Sendable { let count = Mutex(0) }
        let box = Box()
        drag.onOfflineDrag = { box.count.withLock { $0 += 1 } }
        let file = CopiedFile(url: nil, asset: AssetID(rawValue: 1), instance: FileInstanceID(rawValue: 1), isVideo: false)
        drag.prepare(rows: IndexSet(integer: 0)) { [file] }
        #expect(try await until { drag.url(forRow: 0) == nil && drag.hasFilesForTesting })
        let view = ViewerView(
            thumbnails: try await emptyLoader(), images: ViewerImageLoader(read: { _, _ in nil }))
        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let preview = FileDragController.Preview(row: 0, frame: .zero, contents: nil)
        #expect(!drag.begin(from: view, event: event, previews: [preview], formation: .none))
        #expect(!drag.begin(from: view, event: event, previews: [preview], formation: .none))
        #expect(box.count.withLock { $0 } == 1)
    }

    private func emptyLoader() async throws -> ThumbnailLoader {
        let url = FileManager.default.temporaryDirectory.appending(path: "photon-loader-\(UUID().uuidString)/L.sqlite")
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        return BrowserLibrary(handle).loader
    }

    @Test("A read that stalls says so in the status bar, and the app keeps working")
    func stalledRead() async throws {
        final class Stall: Sendable {
            let isOn = Mutex(false)
        }
        let stall = Stall()
        var options = BrowserLibrary.defaultOptions
        options.faults = { operation, _ in
            operation == .read && stall.isOn.withLock({ $0 }) ? .stall(.seconds(3)) : nil
        }
        let setup = try makeImage(label: "PHOTONSLOW")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup, options: options)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        // Thumbnails read the same files, and the wait is for the viewer's own read.
        #expect(try await until { browser.library.activity.isEmpty })
        stall.isOn.withLock { $0 = true }
        browser.model.select(row: 7)
        browser.model.openViewer()

        #expect(try await until(8) { browser.model.viewerStatus.contains("Waiting for") })
        browser.model.stepViewer(by: 1, isRepeat: false)
        #expect(browser.model.selection.currentRow == 8)
        stall.isOn.withLock { $0 = false }
        #expect(try await until(15) { browser.view.viewer.isShowingPreviewOrBetterForTesting })
        #expect(try await until { !browser.model.viewerStatus.contains("Waiting for") })
        browser.model.closeViewer(animated: false)
    }

    @Test("A clone beside its original gets a calm line, and goes when the clone does")
    func cloneNotice() async throws {
        let setup = try makeImage(label: "PHOTONTWINS")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)

        try setup.image.detach()
        #expect(try await until { browser.library.onlineVolumes.isEmpty })
        let clone = try setup.image.clone(to: setup.directory.appending(path: "twin.dmg"))
        defer { clone.ensureDetached() }
        setup.mount = try setup.image.attach(readOnly: true)
        #expect(try await until { !browser.library.onlineVolumes.isEmpty })

        _ = try clone.attach(readOnly: true, mountPoint: setup.directory.appending(path: "twin"))
        #expect(try await until { browser.library.volumeNotice?.contains("copy") == true })

        try clone.detach()
        #expect(try await until { browser.library.volumeNotice == nil })
        #expect(browser.library.onlineVolumes.count == 1)
    }

    // MARK: Session restore

    @Test("A session comes back after a restart with the drive disconnected")
    func restoreOffline() async throws {
        let setup = try makeImage(count: 200, label: "PHOTONREST")
        defer { setup.tearDown() }
        let first = try await openBrowser(setup)
        try await addMedia(first, setup, count: 200)
        first.model.setSort(BrowseSort(key: .name, ascending: false))
        first.model.setTileSizeFromSlider(90)
        first.model.setViewMode(.list)
        first.model.setViewMode(.tiles)
        first.model.select(row: 150)
        first.view.grid.revealCurrent()
        first.view.grid.layoutSubtreeIfNeeded()
        let current = first.model.selection.currentAsset
        first.model.openViewer()
        #expect(try await until { first.view.viewer.isShowingPreviewOrBetterForTesting })
        first.model.saveSessionBeforeQuit()
        first.close()

        try setup.image.detach(force: true)

        let second = try await openBrowser(setup)
        defer { second.close() }
        #expect(try await until { second.model.itemCount == 200 })
        #expect(second.model.scopeAccess == .offline)
        #expect(second.model.sort == BrowseSort(key: .name, ascending: false))
        #expect(second.model.tileSize == 90)
        #expect(second.model.selection.currentAsset == current)
        #expect(try await until { second.model.isViewerOpen })
        second.model.closeViewer(animated: false)
        second.view.grid.layoutSubtreeIfNeeded()
        let row = try #require(second.model.selection.currentRow)
        #expect(second.view.grid.tileRect(row: row, in: second.view) != nil)
    }

    @Test("Nothing selected stays nothing selected, wherever the view was")
    func restoreNoSelection() async throws {
        let setup = try makeImage(count: 40, label: "PHOTONNONE")
        defer { setup.tearDown() }
        let first = try await openBrowser(setup)
        try await addMedia(first, setup, count: 40)
        first.model.saveSessionBeforeQuit()
        first.close()

        let second = try await openBrowser(setup)
        defer { second.close() }
        #expect(try await until { second.model.itemCount == 40 })
        #expect(second.model.selection.currentRow == nil)
        #expect(second.model.selectedCount == 0)
    }

    @Test("Your place on screen comes back even when the current item is far from it")
    func restoreScrolledAway() async throws {
        let setup = try makeImage(count: 200, label: "PHOTONSCRL")
        defer { setup.tearDown() }
        let first = try await openBrowser(setup)
        try await addMedia(first, setup, count: 200)
        first.model.select(row: 0)
        first.view.grid.scroll(toTop: first.view.grid.tileLayout.frame(of: 190).minY)
        first.view.grid.layoutSubtreeIfNeeded()
        let anchor = try #require(first.view.grid.captureAnchor())
        #expect(anchor.row > 100)
        let seen = first.model.result.assetIDs[anchor.row]
        let current = first.model.selection.currentAsset
        first.model.saveSessionBeforeQuit()
        first.close()

        let second = try await openBrowser(setup)
        defer { second.close() }
        #expect(try await until { second.model.itemCount == 200 })
        second.view.grid.layoutSubtreeIfNeeded()
        #expect(second.model.selection.currentAsset == current)
        let row = try #require(second.model.result.row(of: AssetID(rawValue: seen)))
        #expect(second.view.grid.tileRect(row: row, in: second.view) != nil)
        #expect(second.view.grid.tileRect(row: 0, in: second.view) == nil)
    }

    @Test("A saved folder that has gone from the library leaves for one that hasn't")
    func vanishedFolder() async throws {
        let setup = try makeImage(label: "PHOTONVANI")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        let scope = try #require(browser.model.scope)
        let gone = BrowseScope(volume: scope.volume, path: "media/gone")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            browser.model.onResult = { _ in
                browser.model.onResult = nil
                done.resume()
            }
            browser.model.open(gone)
        }
        #expect(browser.model.itemCount == 0)

        browser.model.leaveVanishedFolder()

        #expect(try await until { browser.model.itemCount == 12 })
        #expect(browser.model.scope == scope)
    }

    @Test("An offline folder stays where it is")
    func offlineFolderStays() async throws {
        let setup = try makeImage(label: "PHOTONSTAY")
        defer { setup.tearDown() }
        let browser = try await openBrowser(setup)
        defer { browser.close() }
        try await addMedia(browser, setup, count: 12)
        let scope = browser.model.scope
        try setup.image.detach(force: true)
        #expect(try await until { browser.library.onlineVolumes.isEmpty })
        browser.model.leaveVanishedFolder()
        #expect(browser.model.scope == scope)
    }
}
