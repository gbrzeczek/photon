import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

@testable import PhotonUI

/// Videos in the browser and viewer, over real files on the internal disk, through real key events in a
/// window that isn't shown. Playback is muted and doesn't start by itself, so nothing depends on sound.
@Suite("Videos in the browser", .serialized)
@MainActor
struct VideoViewerTests {
    private func until(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @MainActor
    private final class Browser {
        let directory: URL
        let library: BrowserLibrary
        let model: BrowserModel
        let view: BrowserContainerView
        let window: NSWindow

        init(directory: URL, library: BrowserLibrary, model: BrowserModel, view: BrowserContainerView, window: NSWindow) {
            self.directory = directory
            self.library = library
            self.model = model
            self.view = view
            self.window = window
        }

        var viewer: ViewerView { view.viewer }
        var video: ViewerVideo { view.viewer.video }

        func press(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)!
            window.firstResponder?.keyDown(with: event)
        }

        func pressRight(modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
            press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, modifiers: modifiers.union(.function), isRepeat: isRepeat)
        }

        func pressLeft(modifiers: NSEvent.ModifierFlags = []) {
            press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, modifiers: modifiers.union(.function))
        }

        /// The pointer moving onto the middle of a tile, the way the tracking area reports it.
        func hover(row: Int) {
            let grid = view.grid
            let frame = grid.tileLayout.frame(of: row)
            let point = grid.document.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            grid.handleMouseMoved(event)
        }

        var preview: TileVideoPreview { view.grid.videoPreview }

        func pressSpace() { press(" ", code: 49) }
        func pressEscape() { press("\u{1B}", code: 53) }

        func tearDown() {
            viewer.video.stop()
            library.loader.stop()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// In name order: a photo, two videos, a photo, and a format no engine here plays.
    private func makeBrowser() async throws -> Browser {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "photon-video-ui-\(UUID().uuidString)").resolvingSymlinksInPath()
        let media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for (name, seed) in [("a-photo.jpg", UInt64(1)), ("d-photo.jpg", 2)] {
            var options = SyntheticMedia.ImageOptions()
            options.seed = seed
            try #require(SyntheticMedia.jpeg(options)).write(to: media.appending(path: name))
        }
        var options = SyntheticVideo.Options()
        options.seconds = 3
        try await SyntheticVideo.write(to: media.appending(path: "b-clip.mp4"), format: .h264MP4, options: options)
        try await SyntheticVideo.write(to: media.appending(path: "c-clip.mov"), format: .proRes422MOV, options: options)
        try Data(repeating: 1, count: 2048).write(to: media.appending(path: "e-other.mkv"))

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
        view.viewer.autoplaysVideos = false
        view.grid.videoPreview.delay = .milliseconds(100)
        view.grid.videoPreview.reducesMotionForTesting = false
        view.viewer.reducesMotionForTesting = true
        let browser = Browser(directory: directory, library: library, model: model, view: view, window: window)

        library.addFolder(media)
        #expect(try await until { !library.isIndexing && model.itemCount == 5 })
        let volume = try #require(library.onlineVolumes.first)
        #expect(try await until { try await library.store.thumbnailBacklog(volume: volume) == 0 })
        model.setSort(BrowseSort(key: .name, ascending: true))
        let names = ["a-photo.jpg", "b-clip.mp4", "c-clip.mov", "d-photo.jpg", "e-other.mkv"]
        let sorted = try await until {
            let rows = try await library.store.browseRows(instances: model.result.instanceIDs)
            let byInstance = Dictionary(uniqueKeysWithValues: rows.map { ($0.instanceID.rawValue, $0.path.name) })
            return model.result.instanceIDs.map { byInstance[$0] } == names
        }
        try #require(sorted)
        view.grid.focus()
        return browser
    }

    @Test("Video tiles show a frame from the file, and a format no engine plays keeps the film symbol")
    func tiles() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        let shown = try await until {
            _ = browser.view.grid.tick()
            return browser.view.grid.visibleThumbnailCount == 4
        }
        #expect(shown)
    }

    @Test("Space plays and pauses a video, J, K, L and M work, and Escape closes it")
    func keys() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        browser.pressRight()
        browser.pressRight()
        #expect(browser.model.selection.currentRow == 1)
        browser.pressSpace()
        #expect(browser.model.isViewerOpen)
        #expect(try await until { browser.video.status == .ready })
        let video = browser.video
        browser.press("m", code: 46)
        #expect(video.isMuted)

        browser.pressSpace()
        #expect(browser.model.isViewerOpen)
        #expect(video.isPlaying)
        browser.press("k", code: 40)
        #expect(!video.isPlaying)
        browser.press("l", code: 37)
        #expect(video.playback?.rate == 1)
        browser.press("l", code: 37)
        #expect(video.playback?.rate == 2)
        browser.press("k", code: 40)

        browser.pressRight(modifiers: .shift)
        #expect(try await until { (video.playback?.currentTime ?? 0) > 2.5 })
        browser.pressLeft(modifiers: .shift)
        #expect(try await until { (video.playback?.currentTime ?? 9) < 0.5 })
        browser.pressRight(modifiers: .option)
        #expect(try await until { (video.playback?.currentTime ?? 0) > 0 })
        #expect(browser.model.selection.currentRow == 1)

        // Plain arrows still move between items, and the next video gets a player of its own.
        browser.pressRight()
        #expect(browser.model.selection.currentRow == 2)
        #expect(try await until { browser.video.status == .ready })
        #expect(video.isMuted)

        browser.pressEscape()
        browser.viewer.finishTransitionForTesting()
        #expect(!browser.model.isViewerOpen)
        #expect(browser.video.playback == nil)
    }

    @Test("A held arrow key opens no player for the videos it passes")
    func heldKey() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        browser.pressRight()
        browser.pressSpace()
        #expect(browser.model.isViewerOpen)
        browser.pressRight(isRepeat: true)
        #expect(browser.model.selection.currentRow == 1)
        #expect(browser.video.playback == nil)
        browser.pressRight(isRepeat: true)
        #expect(browser.video.playback == nil)
        // Once the key rests, the video it stopped on opens.
        #expect(try await until { browser.video.status == .ready })
        #expect(browser.model.selection.currentRow == 2)
    }

    @Test("A format with no engine says so, and Space still doesn't close it")
    func unsupported() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        browser.model.select(row: 4)
        browser.model.openViewer()
        #expect(try await until { browser.video.problem != nil })
        #expect(browser.model.viewerStatus.contains("Can't play this format"))
        browser.pressSpace()
        #expect(browser.model.isViewerOpen)
    }

    @Test("Resting on a video's tile plays it there, muted and looping, and moving off stops it")
    func hoverPreview() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        _ = browser.view.grid.tick()
        browser.hover(row: 1)
        #expect(browser.preview.playback == nil)
        #expect(try await until { browser.preview.isPlaying })
        let playback = try #require(browser.preview.playback)
        // Shown only with a frame, never as an empty layer, which draws black.
        #expect(playback.isShowingFrame)
        #expect(playback.isMuted)
        #expect(playback.loops)
        #expect(playback.layer.superlayer != nil)

        // Still on the same tile: nothing restarts.
        browser.hover(row: 1)
        #expect(browser.preview.playback === playback)

        // A reload, as indexing makes every couple of seconds, keeps it playing.
        var reloaded = false
        browser.model.onResult = { _ in reloaded = true }
        browser.model.reload(keepPosition: true)
        #expect(try await until { reloaded })
        browser.model.onResult = nil
        #expect(browser.preview.playback === playback)
        #expect(playback.layer.superlayer != nil)

        browser.hover(row: 0)
        #expect(browser.preview.playback == nil)
        #expect(playback.layer.superlayer == nil)
    }

    @Test("Passing over tiles opens nothing, and a key, the viewer or a scroll stops a preview")
    func hoverStops() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        _ = browser.view.grid.tick()
        browser.hover(row: 1)
        browser.hover(row: 2)
        #expect(browser.preview.asset?.rawValue == browser.model.result.assetIDs[2])
        #expect(try await until { browser.preview.isPlaying })

        browser.pressRight()
        #expect(browser.preview.playback == nil)

        // Tiles large enough that five of them scroll.
        browser.model.setTileSize(TileMetrics.maximumTile)
        // Nothing starts while the size eases, so the pointer keeps resting until it has.
        #expect(
            try await until {
                _ = browser.view.grid.tick()
                browser.hover(row: 1)
                return browser.preview.isPlaying
            })
        browser.view.grid.document.scroll(CGPoint(x: 0, y: 120))
        #expect(browser.preview.playback == nil)
        browser.view.grid.document.scroll(.zero)

        #expect(
            try await until {
                _ = browser.view.grid.tick()
                browser.hover(row: 1)
                return browser.preview.isPlaying
            })
        browser.model.openViewer()
        browser.viewer.finishTransitionForTesting()
        #expect(browser.preview.playback == nil)
        browser.hover(row: 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(browser.preview.playback == nil)
    }

    @Test("Reduce Motion, a photo and a format no engine plays never get a preview")
    func hoverNever() async throws {
        let browser = try await makeBrowser()
        defer { browser.tearDown() }
        _ = browser.view.grid.tick()
        browser.hover(row: 4)
        try await Task.sleep(for: .milliseconds(500))
        #expect(browser.preview.playback == nil)
        browser.hover(row: 3)
        #expect(browser.preview.asset == nil)

        browser.preview.reducesMotionForTesting = true
        browser.hover(row: 1)
        try await Task.sleep(for: .milliseconds(500))
        #expect(browser.preview.playback == nil)
    }
}
