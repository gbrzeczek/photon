import AppKit
import XCTest

/// Copy and drag with real files, into Finder. Needs a library of 24 files on the internal disk, more
/// than a drag has dragging items, in
/// `PHOTON_UITEST_FILES_LIBRARY`, an empty folder in `PHOTON_UITEST_DROP_FOLDER`, and that folder open
/// in a Finder window on the right of the main display. A seeded library has no files to move.
final class FileTransferUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dropFolder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let library = try XCTUnwrap(
            environment["PHOTON_UITEST_FILES_LIBRARY"], "Set PHOTON_UITEST_FILES_LIBRARY.")
        dropFolder = URL(fileURLWithPath: try XCTUnwrap(environment["PHOTON_UITEST_DROP_FOLDER"]))
        app = XCUIApplication()
        app.launchEnvironment["PHOTON_LIBRARY"] = library
        app.launchEnvironment["PHOTON_NO_VIEWER_RESTORE"] = "1"
        app.launchEnvironment["PHOTON_WINDOW"] = "left"
        app.launch()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(tiles.waitForExistence(timeout: 10))
    }

    override func tearDown() {
        app.terminate()
    }

    private var tiles: XCUIElement { app.descendants(matching: .any)["photon.tiles"] }

    private func dropped() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dropFolder.path).filter { !$0.hasPrefix(".") }) ?? []
    }

    func testCopyOffersFilesAndLazyPixels() throws {
        let board = NSPasteboard.general
        app.typeKey(.rightArrow, modifierFlags: [])
        let before = board.changeCount
        app.typeKey("c", modifierFlags: .command)
        let changed = expectation(for: NSPredicate { _, _ in board.changeCount != before }, evaluatedWith: nil)
        wait(for: [changed], timeout: 5)
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), urls[0].path)
        let png = try XCTUnwrap(board.data(forType: .png), "The app made no PNG.")
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(board.data(forType: .tiff))))
    }

    func testDraggingAnUnselectedTileCopiesItIntoFinder() throws {
        app.typeKey("a", modifierFlags: [.command, .shift])
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let window = finder.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let start = tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.click(forDuration: 0.5, thenDragTo: end)
        let landed = expectation(for: NSPredicate { [weak self] _, _ in self?.dropped().count == 1 }, evaluatedWith: nil)
        wait(for: [landed], timeout: 15)
    }

    func testDraggingSelectedTilesCopiesThemIntoFinder() throws {
        app.typeKey("a", modifierFlags: .command)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let window = finder.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        XCTAssertFalse(app.windows.firstMatch.frame.intersects(window.frame), "Finder must be to the right: \(app.windows.firstMatch.frame) \(window.frame)")
        let start = tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.click(forDuration: 0.5, thenDragTo: end)
        let landed = expectation(for: NSPredicate { [weak self] _, _ in self?.dropped().count == 24 }, evaluatedWith: nil)
        wait(for: [landed], timeout: 15)
    }
}
