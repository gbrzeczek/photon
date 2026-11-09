import AppKit
import XCTest

/// Milestone 5's shortcuts through the running app: Period, Command-I and Command-F. Needs an unlocked
/// screen, like `KeyboardNavigationUITests`, and the same `PHOTON_UITEST_LIBRARY`.
///
/// These change favorites in that library, so point it at a seeded copy, never the real one.
final class OrganizationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let library = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PHOTON_UITEST_LIBRARY"], "Set PHOTON_UITEST_LIBRARY.")
        app = XCUIApplication()
        app.launchEnvironment["PHOTON_LIBRARY"] = library
        app.launchEnvironment["PHOTON_NO_VIEWER_RESTORE"] = "1"
        app.launch()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        tiles.click()
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
    }

    override func tearDown() {
        app.terminate()
    }

    private var grid: XCUIElement { app.descendants(matching: .any)["photon.grid"] }
    private var tiles: XCUIElement { app.descendants(matching: .any)["photon.tiles"] }
    private var status: XCUIElement { app.descendants(matching: .any)["photon.status"] }
    private var inspector: XCUIElement { app.descendants(matching: .any)["photon.inspector"] }
    private var favoriteButton: XCUIElement { app.toolbars.buttons["Favorite"] }
    private var unfavoriteButton: XCUIElement { app.toolbars.buttons["Unfavorite"] }
    private var searchField: XCUIElement { app.searchFields.firstMatch }

    private func wait(_ element: XCUIElement, exists: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: exists))
        let done = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
    }

    func testPeriodTogglesTheFavorite() {
        // Whatever the library had, the first press makes this one a favorite and the second clears it.
        if unfavoriteButton.exists {
            app.typeKey(".", modifierFlags: [])
            XCTAssertTrue(wait(favoriteButton, exists: true))
        }
        app.typeKey(".", modifierFlags: [])
        XCTAssertTrue(wait(unfavoriteButton, exists: true))
        app.typeKey(".", modifierFlags: [])
        XCTAssertTrue(wait(favoriteButton, exists: true))
    }

    func testPeriodWorksInTheViewer() {
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(wait(app.descendants(matching: .any)["photon.viewer"], exists: true))
        let wasFavorite = unfavoriteButton.exists
        app.typeKey(".", modifierFlags: [])
        XCTAssertTrue(wait(wasFavorite ? favoriteButton : unfavoriteButton, exists: true))
        app.typeKey(".", modifierFlags: [])
        XCTAssertTrue(wait(wasFavorite ? unfavoriteButton : favoriteButton, exists: true))
        XCTAssertTrue(app.descendants(matching: .any)["photon.viewer"].exists)
    }

    func testCommandIShowsAndHidesTheInspector() {
        let shown = inspector.exists
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(wait(inspector, exists: !shown))
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(wait(inspector, exists: shown))
    }

    func testCommandFSearchesAndPeriodStillTypes() {
        let before = status.label
        app.typeKey("f", modifierFlags: .command)
        // A period in the search field is text, not the favorite command.
        app.typeText("IMG_00001.")
        XCTAssertTrue(wait(favoriteButton, exists: true) || wait(unfavoriteButton, exists: true))
        XCTAssertEqual(searchField.value as? String, "IMG_00001.")
        let filtered = NSPredicate(format: "label != %@", before)
        let changed = XCTNSPredicateExpectation(predicate: filtered, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        app.typeKey(.escape, modifierFlags: [])
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", before), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }
}
