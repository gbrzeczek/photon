import Foundation
import XCTest

/// Mount handling through the running app, on a disk image, with no real drive anywhere near it. A forced
/// detach stands in for a pulled cable: see docs/PLAN.md, Removable media checks.
///
/// Needs a logged-in session with the screen unlocked. Set `PHOTON_UITEST_REMOVABLE_LIBRARY` to a library
/// made by `photon-index scan` from an exFAT disk image whose volume is called `Demo Drive`, and run
/// `UITests/removable-media-helper.sh <image>` in another terminal, because this runner is sandboxed and
/// can't attach images. Keep both away from any real drive. With `PHOTON_LIBRARY` set the app can only
/// eject disk images.
final class RemovableMediaUITests: XCTestCase {
    private var app: XCUIApplication!
    private let volume = "Demo Drive"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let library = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PHOTON_UITEST_REMOVABLE_LIBRARY"],
            "Set PHOTON_UITEST_REMOVABLE_LIBRARY.")
        XCTAssertEqual(try image("attach"), "attached")
        app = XCUIApplication()
        app.launchEnvironment["PHOTON_LIBRARY"] = library
        app.launchEnvironment["PHOTON_NO_VIEWER_RESTORE"] = "1"
        app.launch()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        waitFor(offline, exists: false)
    }

    override func tearDownWithError() throws {
        app.terminate()
        try image("force")
    }

    private var grid: XCUIElement { app.descendants(matching: .any)["photon.grid"] }
    private var viewer: XCUIElement { app.descendants(matching: .any)["photon.viewer"] }
    private var offline: XCUIElement { app.staticTexts["\(volume) is offline"] }

    private func waitFor(_ element: XCUIElement, exists: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: exists))
        let done = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed, file: file, line: line)
    }

    /// Asks the helper, and waits for it to finish. Returns what it reports.
    @discardableResult
    private func image(_ command: String) throws -> String {
        let box = URL(fileURLWithPath: NSTemporaryDirectory())
        let request = box.appending(path: "photon-image-command")
        let state = box.appending(path: "photon-image-state")
        try? FileManager.default.removeItem(at: state)
        try Data(command.utf8).write(to: request)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: request.path), let reply = try? String(contentsOf: state, encoding: .utf8) {
                return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("removable-media-helper.sh isn't running.")
        return ""
    }

    func testForcedDetachKeepsTheViewerAndReconnects() throws {
        app.descendants(matching: .any)["photon.tiles"].click()
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        waitFor(viewer, exists: true)
        let place = viewer.value as? String

        XCTAssertEqual(try image("force"), "detached")
        waitFor(offline, exists: true)
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(viewer.value as? String, place)

        XCTAssertEqual(try image("attach"), "attached")
        waitFor(offline, exists: false)
        XCTAssertEqual(viewer.value as? String, place)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEjectFromTheMenuThenReconnect() throws {
        let item = app.menuBars.menuBarItems["File"].menuItems["Eject “\(volume)”"]
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        item.click()

        waitFor(offline, exists: true)
        XCTAssertEqual(try image("state"), "detached")
        XCTAssertTrue(grid.exists)

        XCTAssertEqual(try image("attach"), "attached")
        waitFor(offline, exists: false)
    }

    func testEjectFromTheKeyboard() throws {
        app.typeKey("e", modifierFlags: .command)
        waitFor(offline, exists: true)
    }
}
