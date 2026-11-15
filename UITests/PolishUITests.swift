import AppKit
import XCTest

/// Milestone 7b through the running app: Settings from Command-Comma, the Help menu's windows, and the
/// welcome on an empty library. Needs an unlocked screen and `PHOTON_UITEST_LIBRARY`, like
/// `KeyboardNavigationUITests`. Nothing here changes the library, and settings live in a development
/// domain that each launch resets.
final class PolishUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PHOTON_NO_VIEWER_RESTORE"] = "1"
        app.launchEnvironment["PHOTON_RESET_SETTINGS"] = "1"
    }

    override func tearDown() {
        app.terminate()
    }

    private func launchWithLibrary() throws {
        let library = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PHOTON_UITEST_LIBRARY"], "Set PHOTON_UITEST_LIBRARY.")
        app.launchEnvironment["PHOTON_LIBRARY"] = library
        app.launch()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        tiles.click()
    }

    private var grid: XCUIElement { app.descendants(matching: .any)["photon.grid"] }
    private var tiles: XCUIElement { app.descendants(matching: .any)["photon.tiles"] }
    private var status: XCUIElement { app.descendants(matching: .any)["photon.status"] }

    private func wait(_ element: XCUIElement, exists: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: exists))
        let done = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
    }

    private func statusText() -> String { status.value as? String ?? status.label }

    func testCommandCommaOpensSettingsAndCommandWClosesIt() throws {
        try launchWithLibrary()
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.descendants(matching: .any)["photon.settings.previews"].firstMatch
        let found = wait(toggle, exists: true)
        if !found { print(app.debugDescription) }
        XCTAssertTrue(found)
        app.toolbars.buttons["Storage"].click()
        XCTAssertTrue(wait(app.descendants(matching: .any)["photon.settings.cacheUsed"], exists: true))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(wait(toggle, exists: false))
        // The keyboard is back with the grid.
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [.shift])
        XCTAssertTrue(statusText().contains("2 of"))
    }

    func testHelpMenuOpensShortcutsAndAcknowledgements() throws {
        try launchWithLibrary()
        let help = app.menuBars.menuBarItems["Help"]
        help.click()
        help.menuItems["Keyboard Shortcuts"].click()
        let shortcuts = app.descendants(matching: .any)["photon.shortcuts"]
        XCTAssertTrue(wait(shortcuts, exists: true))
        XCTAssertTrue(app.staticTexts["Move the current item"].exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(wait(shortcuts, exists: false))

        help.click()
        help.menuItems["Acknowledgements"].click()
        XCTAssertTrue(wait(app.windows["Acknowledgements"], exists: true))
        XCTAssertTrue(app.staticTexts["GRDB"].exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(wait(app.windows["Acknowledgements"], exists: false))
    }

    func testAnEmptyLibraryWelcomesAndReturnAddsAFolder() throws {
        // Outside the runner's container, which the app may not write to. The runner is sandboxed and can't
        // remove it, so a run leaves one small empty library in /tmp.
        let folder = URL(fileURLWithPath: "/tmp/photon-welcome-\(UUID().uuidString)")
        app.launchEnvironment["PHOTON_LIBRARY"] = folder.appending(path: "Library.sqlite").path
        app.launch()
        let add = app.buttons["photon.welcome.add"]
        let found = wait(add, exists: true, timeout: 10)
        if !found { print(app.debugDescription) }
        XCTAssertTrue(found)

        // Return is the welcome's default button, and opens the panel to choose a folder.
        app.typeKey(.return, modifierFlags: [])
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(wait(panel, exists: true))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(wait(panel, exists: false))
        XCTAssertTrue(add.exists)
    }
}
