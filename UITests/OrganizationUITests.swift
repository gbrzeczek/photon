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

    private var rotateRight: XCUIElement { app.menuBars.menuBarItems["Image"].menuItems["Rotate Right"] }
    private var rotation: XCUIElement { app.descendants(matching: .any)["photon.inspector.rotation"] }

    /// Moves to a photo, since videos don't turn, shows the inspector, and turns the photo back upright
    /// if an earlier run left it turned.
    private func landOnUprightPhoto() {
        for _ in 0..<20 where !rotateRight.isEnabled {
            app.typeKey(.rightArrow, modifierFlags: [])
        }
        XCTAssertTrue(rotateRight.isEnabled, "No photo to turn near the start of the library")
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(wait(inspector, exists: true))
        for _ in 0..<4 where wait(rotation, exists: true, timeout: 1) {
            app.typeKey("r", modifierFlags: [.command, .option])
        }
        XCTAssertTrue(wait(rotation, exists: false))
    }

    func testCommandRTurnsAndCommandOptionRTurnsBack() {
        landOnUprightPhoto()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(wait(rotation, exists: true))
        XCTAssertTrue((rotation.value as? String ?? rotation.label).contains("right"))
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(wait(rotation, exists: false))
    }

    func testRotationWorksInTheViewer() {
        landOnUprightPhoto()
        app.typeKey(.space, modifierFlags: [])
        let viewer = app.descendants(matching: .any)["photon.viewer"]
        XCTAssertTrue(wait(viewer, exists: true))
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(wait(rotation, exists: true))
        XCTAssertTrue((rotation.value as? String ?? rotation.label).contains("left"))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(wait(rotation, exists: false))
        XCTAssertTrue(viewer.exists)
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

    /// What the status bar says. A SwiftUI text gives it as its value on macOS, not its label.
    private var statusText: String {
        let value = status.value as? String ?? ""
        return value.isEmpty ? status.label : value
    }

    private func waitForStatus(timeout: TimeInterval = 5, _ condition: @escaping (String) -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition(self.statusText) }
        let done = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
    }

    /// How many items the status says the source has: "2,000" from "2,000 items" or "1 of 2,000 selected",
    /// written as the locale writes it.
    private func total(_ status: String) -> String? {
        let words = status.split(separator: " ")
        guard words.count >= 2, ["items", "item", "selected"].contains(words.last!) else { return nil }
        return String(words[words.count - 2])
    }

    func testCommandFSearchesAndPeriodStillTypes() {
        XCTAssertTrue(waitForStatus { self.total($0) != nil }, "The status says \"\(statusText)\"")
        let all = total(statusText)
        app.typeKey("f", modifierFlags: .command)
        // A period in the search field is text, not the favorite command. The name is one that
        // `photon-index seed` writes, and only a few files have it.
        let name = "IMG_0000001."
        app.typeText(name)
        XCTAssertTrue(wait(favoriteButton, exists: true) || wait(unfavoriteButton, exists: true))
        XCTAssertEqual(searchField.value as? String, name)
        XCTAssertTrue(
            waitForStatus { self.total($0) != nil && self.total($0) != all },
            "The status says \"\(statusText)\" after searching, from \(all ?? "nothing")")
        // Clearing shows everything again. A selection the search hid stays cleared, as in Finder.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForStatus { self.total($0) == all },
            "The status says \"\(statusText)\" after clearing, not \(all ?? "nothing") items")
    }
}
