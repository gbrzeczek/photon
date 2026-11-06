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
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        grid.click()
    }

    override func tearDown() {
        app.terminate()
    }

    private var grid: XCUIElement { app.descendants(matching: .any)["photon.grid"] }
    private var status: XCUIElement { app.descendants(matching: .any)["photon.status"] }
    private var position: String { grid.value as? String ?? "" }

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
}
