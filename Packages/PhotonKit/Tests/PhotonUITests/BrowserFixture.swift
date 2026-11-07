import AppKit
import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

/// A browser in a real window, over a library in a temporary folder, with no real files.
/// The window never shows, and the tests send it real key events.
@MainActor
final class BrowserFixture {
    let directory: URL
    let library: BrowserLibrary
    let model: BrowserModel
    let container: BrowserContainerView
    let window: NSWindow
    let scope: BrowseScope

    var grid: TileGridView { container.grid }
    var list: BrowserListView { container.list }

    init(
        count: Int = 300, aspectLayout: Bool = false, size: CGSize = CGSize(width: 1000, height: 600),
        names: ((Int) -> String)? = nil
    ) async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(path: "photon-ui-\(UUID().uuidString)")
        let url = directory.appending(path: "Library.sqlite")
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        library = BrowserLibrary(handle)
        let store = library.store
        let volume = try await store.insertVolume(uuid: "UI", name: "Test", capacity: nil, filesystem: nil)
        try await store.addRoot(volume: volume.id, relativePath: "Root")
        scope = BrowseScope(volume: volume.id, path: "Root")

        let files = (0..<count).map { index in
            ScannedFile(
                name: names?(index) ?? String(format: "IMG_%05d.JPG", index), kind: .photo, size: Int64(1000 + index),
                modifiedTime: FileTimestamp(nanoseconds: Int64(index) * 1_000_000_000))
        }
        _ = try await store.applyDirectory(volume: volume.id, directory: "Root/Sub", files: files)
        let instances = try await store.instances(volume: volume.id, directory: "Root/Sub")
        var indexed: [IndexedFile] = []
        for (position, instance) in instances.enumerated() {
            var hash = Data(count: 32)
            withUnsafeBytes(of: UInt64(position + 1)) { hash.replaceSubrange(0..<8, with: $0) }
            let wide = position % 3 != 0
            indexed.append(
                IndexedFile(
                    instanceID: instance.id, size: instance.size, modifiedTime: instance.modifiedTime,
                    hash: ContentHash(bytes: hash)!,
                    metadata: MediaMetadata(pixelWidth: wide ? 1500 : 1000, pixelHeight: 1000)))
        }
        _ = try await store.applyIndexed(indexed)

        await library.start()
        model = BrowserModel(library: library)
        if aspectLayout { model.setLayoutMode(.aspect) }
        container = BrowserContainerView(model: model)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutSubtreeIfNeeded()
        grid.needsLayout = true
        grid.layoutSubtreeIfNeeded()
        grid.focus()
        await open(scope)
    }

    func tearDown() {
        library.loader.stop()
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func open(_ scope: BrowseScope) async {
        await waitForResult { self.model.open(scope) }
    }

    /// Runs `action`, and waits for the query it starts to land.
    func waitForResult(_ action: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.onResult = { [weak model] _ in
                model?.onResult = nil
                continuation.resume()
            }
            action()
        }
    }

    /// Sends a key to whatever has focus, the way the window would.
    func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union(key.flags), timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)!
        window.firstResponder?.keyDown(with: event)
        flushFrame()
    }

    func type(_ text: String) {
        for character in text {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: 0)!
            window.firstResponder?.keyDown(with: event)
        }
    }

    /// A pinch at a point in the window, as the system sends one.
    func gesture(magnification: CGFloat, at point: CGPoint) -> NSEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let gesture: Int64 = 29
        let magnify: Int64 = 8
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: screen.x, y: height - screen.y)
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: gesture)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: magnify)
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        return NSEvent(cgEvent: event)
    }

    /// A mouse wheel, in lines.
    func scroll(lines: Int32) -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            .flatMap { NSEvent(cgEvent: $0) }
    }

    /// A trackpad's scroll, in points, in the middle of a gesture.
    func scroll(points: Int32, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0)
        else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)
    }

    /// What a display link would run. A test window has no display to drive one.
    func flushFrame() {
        _ = grid.tick()
        _ = list.tick()
    }

    func click(row: Int, modifiers: NSEvent.ModifierFlags = []) {
        let frame = grid.tileLayout.frame(of: row)
        let point = grid.document.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        grid.handleMouseDown(event)
        flushFrame()
    }

    /// Presses at the middle of `row` and holds. Returns where, in window coordinates.
    func press(row: Int, modifiers: NSEvent.ModifierFlags = []) -> CGPoint {
        let point = windowPoint(row: row)
        grid.handleMouseDown(mouseEvent(.leftMouseDown, at: point, modifiers: modifiers))
        flushFrame()
        return point
    }

    /// Presses at a point in the window, tile or not, and holds.
    func press(at point: CGPoint) {
        grid.handleMouseDown(mouseEvent(.leftMouseDown, at: point))
        flushFrame()
    }

    func drag(to point: CGPoint) {
        grid.handleMouseDragged(mouseEvent(.leftMouseDragged, at: point))
        flushFrame()
    }

    func release(at point: CGPoint) async {
        sendMouseUp(at: point)
        await waitForBand()
    }

    /// Lets go, and returns while the rows are still being worked out.
    func sendMouseUp(at point: CGPoint) {
        grid.handleMouseUp(mouseEvent(.leftMouseUp, at: point))
    }

    /// The rows are worked out off the main thread. Tests need no more than a few of these.
    func waitForBand() async {
        for _ in 0..<200 where grid.isTrackingBandForTesting {
            try? await Task.sleep(for: .milliseconds(5))
        }
        flushFrame()
    }

    func windowPoint(row: Int) -> CGPoint {
        let frame = grid.tileLayout.frame(of: row)
        return grid.document.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    var viewer: ViewerView { container.viewer }

    /// A plain key by its characters: Space, Return or Escape.
    func press(characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)!
        window.firstResponder?.keyDown(with: event)
        flushFrame()
    }

    func pressSpace() { press(characters: " ", code: 49) }
    func pressReturn() { press(characters: "\r", code: 36) }
    func pressEscape() { press(characters: "\u{1B}", code: 53) }

    /// Sends a held key's repeat, or a key with modifiers.
    func hold(_ key: Key) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: true, keyCode: key.code)!
        window.firstResponder?.keyDown(with: event)
    }

    var currentRow: Int? { model.selection.currentRow }
    var selectedRows: IndexSet { model.selection.rows }

    struct Key {
        var code: UInt16
        var scalar: Int
        var flags: NSEvent.ModifierFlags = [.function, .numericPad]
        var characters: String { String(UnicodeScalar(scalar)!) }

        static let left = Key(code: 123, scalar: NSLeftArrowFunctionKey)
        static let right = Key(code: 124, scalar: NSRightArrowFunctionKey)
        static let down = Key(code: 125, scalar: NSDownArrowFunctionKey)
        static let up = Key(code: 126, scalar: NSUpArrowFunctionKey)
        static let home = Key(code: 115, scalar: NSHomeFunctionKey, flags: [.function])
        static let end = Key(code: 119, scalar: NSEndFunctionKey, flags: [.function])
        static let pageUp = Key(code: 116, scalar: NSPageUpFunctionKey, flags: [.function])
        static let pageDown = Key(code: 121, scalar: NSPageDownFunctionKey, flags: [.function])
    }
}
