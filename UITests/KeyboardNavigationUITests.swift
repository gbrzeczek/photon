import AppKit
import XCTest

/// The keyboard table from docs/PLAN.md, through the running app. Needs a logged-in session with the
/// screen unlocked, so it isn't part of CI. `PhotonUITests` in the package covers the same logic there.
///
/// Set `PHOTON_UITEST_LIBRARY` to a library made by `photon-index seed`, so that this never touches
/// the real one. The `xcodebuild` line is in AGENTS.md.
final class KeyboardNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let library = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PHOTON_UITEST_LIBRARY"], "Set PHOTON_UITEST_LIBRARY.")
        app = XCUIApplication()
        app.launchEnvironment["PHOTON_LIBRARY"] = library
        app.launch()
        // The library remembers its last view, and the test before this one may have ended in the list.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        tiles.click()
    }

    override func tearDown() {
        app.terminate()
    }

    private var grid: XCUIElement { app.descendants(matching: .any)["photon.grid"] }
    /// The viewport. `grid` is as tall as the whole library, so offsets into it land off screen.
    private var tiles: XCUIElement { app.descendants(matching: .any)["photon.tiles"] }
    private var status: XCUIElement { app.descendants(matching: .any)["photon.status"] }
    private var position: String { grid.value as? String ?? "" }
    private var viewer: XCUIElement { app.descendants(matching: .any)["photon.viewer"] }
    private var viewerValue: String { viewer.value as? String ?? "" }

    private func waitForViewer(open: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: open))
        let done = XCTNSPredicateExpectation(predicate: predicate, object: viewer)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed, file: file, line: line)
    }

    /// Selects the first item and opens it.
    private func openViewer() {
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        waitForViewer(open: true)
    }

    func testArrowKeysMoveInTheGrid() {
        let start = position
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotEqual(position, start)
        let afterRight = position
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertNotEqual(position, afterRight)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(position, afterRight)
    }

    func testShiftArrowExtendsTheSelection() {
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey(.rightArrow, modifierFlags: .shift)
        XCTAssertTrue(position.hasSuffix("3 selected"), position)
    }

    func testSelectAllAndNoneFromTheMenuShortcuts() {
        app.typeKey("a", modifierFlags: .command)
        XCTAssertFalse(position.hasSuffix(" 0 selected"), position)
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(position.hasSuffix(" 0 selected"), position)
    }

    func testDraggingSelectsARectangle() {
        app.typeKey("a", modifierFlags: [.command, .shift])
        let start = tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
        let end = tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
        // On the Mac this has to be `click`. `press` compiles, but no event reaches the app.
        start.click(forDuration: 0.1, thenDragTo: end)
        let expectation = expectation(
            for: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return !self.position.hasSuffix(" 0 selected") && !self.position.hasSuffix(" 1 selected")
            }, evaluatedWith: nil)
        wait(for: [expectation], timeout: 5)
    }

    func testSwitchingToTheListKeepsTheCurrentItem() {
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        let before = position
        app.typeKey("2", modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey("1", modifierFlags: .command)
        XCTAssertNotEqual(position, before)
        app.typeKey(.upArrow, modifierFlags: [])
    }

    func testTabMovesFocusToTheSidebarAndBack() {
        app.typeKey(.rightArrow, modifierFlags: [])
        let before = position
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: .shift)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotEqual(position, before)
    }

    // MARK: Viewer

    func testSpaceOpensAndClosesTheViewer() {
        openViewer()
        XCTAssertTrue(viewerValue.contains("zoom 100%"), viewerValue)
        app.typeKey(.space, modifierFlags: [])
        waitForViewer(open: false)
        XCTAssertTrue(position.hasSuffix("1 selected"), position)
    }

    func testReturnAndCommandDownOpenTheViewer() {
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.enter, modifierFlags: [])
        waitForViewer(open: true)
        app.typeKey(.escape, modifierFlags: [])
        waitForViewer(open: false)
        app.typeKey(.downArrow, modifierFlags: .command)
        waitForViewer(open: true)
        app.typeKey(.upArrow, modifierFlags: .command)
        waitForViewer(open: false)
    }

    func testArrowKeysMoveInTheViewerAndTheGridFollows() {
        openViewer()
        let start = viewerValue
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        let after = viewerValue
        XCTAssertNotEqual(after, start)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertNotEqual(viewerValue, after)
        let item = String(viewerValue.prefix { $0 != "," })
        app.typeKey(.escape, modifierFlags: [])
        waitForViewer(open: false)
        XCTAssertTrue(position.hasPrefix(item), "\(position) should start with \(item)")
    }

    @MainActor func testZoomingWithTheToolbarAndAScroll() {
        openViewer()
        app.toolbars.buttons["Zoom In"].click()
        XCTAssertFalse(viewerValue.contains("zoom 100%"), viewerValue)
        app.toolbars.buttons["Zoom Out"].click()
        XCTAssertTrue(viewerValue.contains("zoom 100%"), viewerValue)
        // From partway, so that the scroll has room to go either way. It eases, so its value comes later.
        app.toolbars.buttons["Zoom In"].click()
        app.toolbars.buttons["Zoom In"].click()
        let zoomed = viewerValue
        XCUIElement.perform(withKeyModifiers: .command) {
            viewer.scroll(byDeltaX: 0, deltaY: 20)
        }
        let changed = NSPredicate(format: "value != %@", zoomed)
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: viewer)], timeout: 3),
            .completed, viewerValue)
    }

    func testZoomingAndPanningFromTheKeyboard() {
        openViewer()
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("=", modifierFlags: .command)
        XCTAssertFalse(viewerValue.contains("zoom 100%"), viewerValue)
        let item = String(viewerValue.prefix { $0 != "," })
        // Zoomed in, the arrow keys pan, so the photo stays the same one.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(viewerValue.hasPrefix(item), viewerValue)
        app.typeKey("-", modifierFlags: .command)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(viewerValue.contains("zoom 100%"), viewerValue)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertFalse(viewerValue.hasPrefix(item + ","), viewerValue)
    }

    func testTheViewerKeepsTheCurrentItemFromTheList() {
        app.typeKey("2", modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        waitForViewer(open: true)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        waitForViewer(open: false)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(position.hasSuffix(" 1 selected"), position)
    }

    /// Replaces the clipboard, so that's restored afterward.
    func testCopyWorksInEveryMode() {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        defer {
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
        }
        func copied(file: StaticString = #filePath, line: UInt = #line) {
            let before = board.changeCount
            app.typeKey("c", modifierFlags: .command)
            let changed = expectation(
                for: NSPredicate { _, _ in board.changeCount != before }, evaluatedWith: nil)
            wait(for: [changed], timeout: 5)
        }
        app.typeKey(.rightArrow, modifierFlags: [])
        copied()
        app.typeKey("2", modifierFlags: .command)
        copied()
        app.typeKey(.space, modifierFlags: [])
        waitForViewer(open: true)
        copied()
    }
}
