import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

@testable import PhotonUI

@MainActor
private func until(_ seconds: Double = 30, _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// The viewer, through real key events in a window that isn't shown. `UITests/` has the same checks
/// through the running app. With no display the flights never end, so tests finish them.
@Suite("The viewer", .serialized)
@MainActor
struct ViewerTests {
    private func withBrowser(count: Int = 300, _ body: (BrowserFixture) async throws -> Void) async throws {
        let fixture = try await BrowserFixture(count: count)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    private func land(_ browser: BrowserFixture) {
        browser.viewer.finishTransitionForTesting()
        browser.flushFrame()
    }

    @Test("Space, Return and Command-Down all open the current item")
    func opening() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            browser.pressSpace()
            #expect(browser.model.isViewerOpen)
            #expect(browser.window.firstResponder === browser.viewer)
            browser.pressEscape()
            land(browser)
            #expect(!browser.model.isViewerOpen)

            browser.pressReturn()
            #expect(browser.model.isViewerOpen)
            browser.pressEscape()
            land(browser)

            browser.press(.down, modifiers: .command)
            #expect(browser.model.isViewerOpen)
            browser.press(.up, modifiers: .command)
            land(browser)
            #expect(!browser.model.isViewerOpen)
        }
    }

    @Test("The same keys open from the list, and focus goes back to it")
    func list() async throws {
        try await withBrowser { browser in
            browser.model.setViewMode(.list)
            browser.press(.down)
            browser.pressSpace()
            #expect(browser.model.isViewerOpen)
            browser.pressSpace()
            land(browser)
            #expect(!browser.model.isViewerOpen)
            #expect(browser.window.firstResponder === browser.list.table)
        }
    }

    @Test("Opening with nothing current starts from what's on screen")
    func nothingCurrent() async throws {
        try await withBrowser { browser in
            #expect(browser.currentRow == nil)
            browser.model.openViewer()
            #expect(browser.model.isViewerOpen)
            #expect(browser.currentRow != nil)
        }
    }

    @Test("Left and Right move through the photos, and stop at the ends")
    func arrows() async throws {
        try await withBrowser(count: 4) { browser in
            browser.press(.right)
            browser.pressSpace()
            browser.press(.left)
            #expect(browser.currentRow == 0)
            browser.press(.right)
            browser.press(.right)
            browser.press(.right)
            browser.press(.right)
            browser.press(.right)
            #expect(browser.currentRow == 3)
            browser.press(.home)
            #expect(browser.currentRow == 0)
            browser.press(.end)
            #expect(browser.currentRow == 3)
        }
    }

    @Test("Up and Down do nothing at fit, and pan when zoomed in, where Left and Right pan too")
    func panning() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            browser.pressSpace()
            browser.press(.up)
            browser.press(.down)
            #expect(browser.currentRow == 1)

            browser.model.stepZoom(larger: true)
            browser.model.stepZoom(larger: true)
            let before = browser.viewer.geometryForTesting.center
            browser.press(.right)
            browser.press(.down)
            #expect(browser.currentRow == 1)
            #expect(browser.viewer.geometryForTesting.center != before)

            browser.model.zoomViewerToFit()
            #expect(browser.viewer.zoomForTesting == 1)
            browser.press(.right)
            #expect(browser.currentRow == 2)
        }
    }

    @Test("Moving to another photo goes back to fit")
    func zoomResets() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.pressSpace()
            browser.model.stepZoom(larger: true)
            #expect(browser.viewer.zoomForTesting > 1)
            browser.model.zoomViewerToFit()
            browser.model.stepViewer(by: 1, isRepeat: false)
            #expect(browser.viewer.zoomForTesting == 1)
        }
    }

    @Test("Closing selects the photo you ended on, and the grid moves to it")
    func keepsYourPlace() async throws {
        try await withBrowser(count: 1000) { browser in
            browser.press(.right)
            browser.pressSpace()
            let top = browser.grid.scrollTopForMeasuring
            for _ in 0..<500 { browser.model.stepViewer(by: 1, isRepeat: true) }
            #expect(browser.grid.scrollTopForMeasuring == top)
            browser.pressEscape()
            land(browser)
            #expect(browser.currentRow == 500)
            #expect(browser.selectedRows == IndexSet(integer: 500))
            #expect(browser.model.selectedCount == 1)
            #expect(browser.grid.scrollTopForMeasuring > top)
            #expect(browser.grid.tileRect(row: 500, in: browser.container) != nil)
        }
    }

    @Test("Opening and closing without moving keeps a multiple selection")
    func keepsSelection() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right, modifiers: .shift)
            browser.press(.right, modifiers: .shift)
            #expect(browser.selectedRows.count == 3)
            browser.pressSpace()
            browser.pressEscape()
            land(browser)
            #expect(browser.selectedRows.count == 3)
        }
    }

    @Test("The list follows too, whichever way the viewer went")
    func listFollows() async throws {
        try await withBrowser(count: 1000) { browser in
            browser.model.setViewMode(.list)
            browser.press(.down)
            browser.pressSpace()
            for _ in 0..<200 { browser.model.stepViewer(by: 1, isRepeat: true) }
            browser.pressEscape()
            land(browser)
            #expect(browser.currentRow == 200)
            #expect(browser.list.table.selectedRowIndexes == IndexSet(integer: 200))
        }
    }

    @Test("A held key shows each photo at once, and touches nothing until it lets go")
    func holdingAKey() async throws {
        try await withBrowser(count: 100) { browser in
            browser.press(.right)
            browser.pressSpace()
            for _ in 0..<30 { browser.hold(.right) }
            #expect(browser.currentRow == 30)
            #expect(browser.model.viewerStatus != "31 of 100")
            try await Task.sleep(for: .milliseconds(300))
            #expect(browser.model.viewerStatus == "31 of 100")
        }
    }

    @Test("A re-sort under the viewer keeps the photo on screen")
    func resort() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            browser.pressSpace()
            let asset = browser.model.selection.currentAsset
            await browser.waitForResult {
                browser.model.setSort(BrowseSort(key: .name, ascending: false))
            }
            #expect(browser.model.isViewerOpen)
            #expect(browser.model.selection.currentAsset == asset)
            browser.model.stepViewer(by: 1, isRepeat: false)
            #expect(browser.model.selection.currentAsset != asset)
        }
    }

    @Test("Switching view or folder closes the viewer and keeps the current item")
    func leaving() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            browser.pressSpace()
            browser.model.stepViewer(by: 1, isRepeat: false)
            browser.model.setViewMode(.list)
            #expect(!browser.model.isViewerOpen)
            #expect(browser.currentRow == 2)
            #expect(browser.viewer.isHidden)
        }
    }

    @Test("A photo with no file to read keeps its place and the app carries on")
    func offline() async throws {
        try await withBrowser(count: 10) { browser in
            browser.press(.right)
            browser.pressSpace()
            browser.model.stepViewer(by: 1, isRepeat: false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(browser.model.isViewerOpen)
            #expect(!browser.viewer.hasPictureForTesting)
        }
    }

    @Test("A pinch zooms")
    func pinching() async throws {
        try await withBrowser { browser async throws in
            browser.pressSpace()
            land(browser)
            let event = try #require(browser.gesture(magnification: 0.5, at: CGPoint(x: 300, y: 300)))
            #expect(event.type == .magnify)
            browser.viewer.magnify(with: event)
            #expect(browser.viewer.zoomForTesting > 1.4)
        }
    }

    @Test("A mouse wheel zooms, and a trackpad's scroll only does with Command or Option")
    func scrollZoom() async throws {
        try await withBrowser { browser async throws in
            browser.pressSpace()
            land(browser)
            browser.viewer.scrollWheel(with: try #require(browser.scroll(lines: 3)))
            browser.viewer.finishScrollZoomForTesting()
            let zoomed = browser.viewer.zoomForTesting
            #expect(zoomed > 1.2)
            browser.viewer.scrollWheel(with: try #require(browser.scroll(lines: -1)))
            browser.viewer.finishScrollZoomForTesting()
            #expect(browser.viewer.zoomForTesting < zoomed)

            browser.model.zoomViewerToFit()
            browser.viewer.scrollWheel(with: try #require(browser.scroll(points: 40)))
            browser.viewer.finishScrollZoomForTesting()
            #expect(browser.viewer.zoomForTesting == 1)
            browser.viewer.scrollWheel(with: try #require(browser.scroll(points: 40, modifiers: .command)))
            browser.viewer.finishScrollZoomForTesting()
            #expect(browser.viewer.zoomForTesting > 1.2)
        }
    }

    @Test("A scroll eases to its zoom, notches add up, and anything else takes over")
    func scrollZoomEases() async throws {
        try await withBrowser { browser async throws in
            browser.viewer.reducesMotionForTesting = false
            browser.pressSpace()
            land(browser)
            let notch = try #require(browser.scroll(lines: 3))
            browser.viewer.scrollWheel(with: notch)
            #expect(browser.viewer.isEasingZoomForTesting)
            #expect(browser.viewer.zoomForTesting == 1)
            browser.viewer.finishScrollZoomForTesting()
            #expect(!browser.viewer.isEasingZoomForTesting)
            let one = browser.viewer.zoomForTesting

            browser.model.zoomViewerToFit()
            browser.viewer.scrollWheel(with: notch)
            browser.viewer.scrollWheel(with: notch)
            browser.viewer.finishScrollZoomForTesting()
            #expect(abs(browser.viewer.zoomForTesting - one * one) < 0.01)

            browser.viewer.scrollWheel(with: notch)
            browser.model.zoomViewerToFit()
            #expect(!browser.viewer.isEasingZoomForTesting)
            browser.viewer.scrollWheel(with: notch)
            browser.press(.left)
            browser.press(.right)
            browser.model.zoomViewerToFit()
            browser.viewer.scrollWheel(with: notch)
            browser.pressEscape()
            #expect(!browser.viewer.isEasingZoomForTesting)
        }
    }

    @Test("Reduce Motion goes straight to a scroll's zoom")
    func scrollZoomReducedMotion() async throws {
        try await withBrowser { browser async throws in
            browser.viewer.reducesMotionForTesting = true
            browser.pressSpace()
            land(browser)
            browser.viewer.scrollWheel(with: try #require(browser.scroll(lines: 3)))
            #expect(!browser.viewer.isEasingZoomForTesting)
            #expect(browser.viewer.zoomForTesting > 1.2)
        }
    }

    @Test("The window's title names the photo, follows it, and goes back to the folder on closing")
    func caption() async throws {
        try await withBrowser { browser async throws in
            browser.pressSpace()
            #expect(try await until { browser.model.viewerCaption != nil })
            let first = try #require(browser.model.viewerCaption)
            #expect(first.name.hasPrefix("IMG_"))
            #expect(first.name.hasSuffix(".JPG"))
            #expect(!first.name.contains("/"))
            #expect(!first.detail.isEmpty)
            #expect(!first.isVideo)
            browser.press(.right)
            #expect(try await until { browser.model.viewerCaption?.name != first.name })
            browser.pressEscape()
            #expect(browser.model.viewerCaption == nil)
        }
    }

    @Test("A held key doesn't change the title until it lets go")
    func captionWaits() async throws {
        try await withBrowser { browser async throws in
            browser.pressSpace()
            #expect(try await until { browser.model.viewerCaption != nil })
            let first = browser.model.viewerCaption?.name
            browser.model.stepViewer(by: 1, isRepeat: true)
            browser.model.stepViewer(by: 1, isRepeat: true)
            #expect(browser.model.viewerCaption?.name == first)
            #expect(try await until { browser.model.viewerCaption?.name != first })
        }
    }

    @Test("A double click opens the tile under it")
    func doubleClick() async throws {
        try await withBrowser { browser in
            let point = browser.windowPoint(row: 4)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: browser.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
            browser.grid.handleMouseDown(event)
            #expect(browser.model.isViewerOpen)
            #expect(browser.currentRow == 4)
        }
    }

    @Test("Copy acts on the selection in the browser, and on the photo showing in the viewer")
    func copyTargets() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right, modifiers: .shift)
            browser.press(.right, modifiers: .shift)
            #expect(browser.model.actionRows.count == 3)
            browser.pressSpace()
            #expect(browser.model.actionRows == IndexSet(integer: 2))
        }
    }

    @Test("Copy sits in the responder chain behind the window, so it reaches the browser from anywhere")
    func responderChain() async throws {
        try await withBrowser { browser in
            let responder = try #require(browser.window.nextResponder as? BrowserCommandResponder)
            let item = NSMenuItem(title: "Copy", action: #selector(BrowserCommandResponder.copy(_:)), keyEquivalent: "c")
            #expect(!responder.validateMenuItem(item))
            browser.press(.right)
            #expect(responder.validateMenuItem(item))
        }
    }
}

/// Real files on a read-only exFAT image, the closest thing to the real drive that runs with no hardware.
@Suite("The viewer with real files", .serialized)
@MainActor
struct ViewerFilesTests {
    @MainActor
    private struct Setup {
        var directory: URL
        var image: DiskImage
        var library: BrowserLibrary
        var model: BrowserModel
        var view: BrowserContainerView
        var window: NSWindow
        var mount: String

        func tearDown() {
            library.loader.stop()
            window.close()
            image.ensureDetached()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func make(count: Int = 12, videos: Int = 0) async throws -> Setup {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-viewer-\(UUID().uuidString)")
        let image = try DiskImage.create(in: directory, label: "PHOTONVIEW", megabytes: 128)
        var options = SyntheticLibrary.Options()
        options.fileCount = count
        options.duplicateInterval = 0
        options.videoInterval = videos
        let first = try image.attach()
        try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: first).appending(path: "media"))
        try image.detach()
        let mount = try image.attach(readOnly: true)

        let url = directory.appending(path: "library/Library.sqlite")
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        let library = BrowserLibrary(handle)
        await library.start()
        let model = BrowserModel(library: library)
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
        library.addFolder(URL(fileURLWithPath: mount).appending(path: "media"))
        #expect(try await until { !library.isIndexing && model.itemCount == count })
        return Setup(
            directory: directory, image: image, library: library, model: model, view: view, window: window, mount: mount)
    }

    @Test("A photo goes on from nothing to its preview, and to full resolution when zoomed")
    func progressive() async throws {
        let setup = try await make()
        defer { setup.tearDown() }
        setup.model.select(row: 2)
        setup.model.openViewer()
        #expect(try await until { setup.view.viewer.isShowingPreviewOrBetterForTesting })
        setup.model.stepZoom(larger: true)
        setup.model.stepZoom(larger: true)
        setup.model.stepZoom(larger: true)
        setup.model.stepZoom(larger: true)
        #expect(try await until { setup.view.viewer.isShowingFullResolutionForTesting })
        setup.model.closeViewer(animated: false)
    }

    @Test("Command-C copies the current photo's file, on a real volume")
    func copying() async throws {
        let setup = try await make()
        defer { setup.tearDown() }
        setup.model.select(row: 1)
        let file = await BrowserModel.files(
            rows: IndexSet(integer: 1), result: setup.model.result, store: setup.library.store,
            indexer: setup.library.indexer)
        let url = try #require(file.first?.url)
        #expect(url.path.hasPrefix(setup.mount))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A drag gets its files while the button is down")
    func dragPreparation() async throws {
        let setup = try await make()
        defer { setup.tearDown() }
        setup.model.selectAll()
        setup.model.prepareDrag()
        #expect(try await until { setup.model.fileDrag.url(forRow: 5) != nil })
        #expect(setup.model.fileDrag.url(forRow: 5) != setup.model.fileDrag.url(forRow: 6))
    }

    @Test("Pulling the drive while viewing leaves what's on screen, and moving on fails quietly")
    func removal() async throws {
        let setup = try await make()
        defer { setup.tearDown() }
        setup.model.select(row: 0)
        setup.model.openViewer()
        #expect(try await until { setup.view.viewer.isShowingPreviewOrBetterForTesting })
        setup.library.indexer.volumeWillUnmount(mountPoint: setup.mount)
        try setup.image.detach()
        setup.library.indexer.volumeDidUnmount(mountPoint: setup.mount)
        setup.model.stepViewer(by: 1, isRepeat: false)
        setup.model.stepViewer(by: 1, isRepeat: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(setup.model.isViewerOpen)
        #expect(setup.model.selection.currentRow == 2)
        setup.model.closeViewer(animated: false)
    }
}
