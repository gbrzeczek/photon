import AppKit
import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

/// Real key events, sent to a real window's first responder. They run everywhere, with no display.
/// `UITests/` has the same checks through the running app.
@Suite("Keyboard navigation", .serialized)
@MainActor
struct KeyboardNavigationTests {
    private func withBrowser(
        count: Int = 300, aspect: Bool = false, _ body: (BrowserFixture) async throws -> Void
    ) async throws {
        let fixture = try await BrowserFixture(count: count, aspectLayout: aspect)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    @Test("The first arrow key selects the first item, then Right and Left follow reading order")
    func leftRight() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            #expect(browser.currentRow == 0)
            browser.press(.right)
            browser.press(.right)
            #expect(browser.currentRow == 2)
            browser.press(.left)
            #expect(browser.currentRow == 1)
            #expect(browser.selectedRows == IndexSet(integer: 1))
        }
    }

    @Test("Right wraps across rows")
    func wraps() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            let columns = browser.grid.tileLayout.columns
            for _ in 0..<columns { browser.press(.right) }
            #expect(browser.currentRow == columns)
            let frame = browser.grid.tileLayout.frame(of: columns)
            #expect(frame.minY > browser.grid.tileLayout.frame(of: 0).minY)
        }
    }

    @Test("Up and Down keep the column")
    func upDown() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            let columns = browser.grid.tileLayout.columns
            browser.press(.down)
            #expect(browser.currentRow == 1 + columns)
            browser.press(.up)
            #expect(browser.currentRow == 1)
            browser.press(.up)
            #expect(browser.currentRow == 1)
        }
    }

    @Test("The current item always stays on screen")
    func staysOnScreen() async throws {
        try await withBrowser(count: 2000) { browser in
            browser.press(.right)
            for _ in 0..<40 { browser.press(.down) }
            let row = try #require(browser.currentRow)
            let frame = browser.grid.tileLayout.frame(of: row)
            let top = browser.grid.scrollTopForMeasuring
            #expect(frame.minY >= top)
            #expect(frame.maxY <= top + browser.grid.scrollView.contentView.bounds.height)
        }
    }

    @Test("Shift-arrows extend the selection and shrink it again")
    func shiftExtends() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right, modifiers: .shift)
            browser.press(.right, modifiers: .shift)
            #expect(browser.selectedRows == IndexSet(integersIn: 0...2))
            browser.press(.left, modifiers: .shift)
            #expect(browser.selectedRows == IndexSet(integersIn: 0...1))
            #expect(browser.currentRow == 1)
        }
    }

    @Test("Home, End and paging")
    func homeEndPage() async throws {
        try await withBrowser(count: 2000) { browser in
            browser.press(.end)
            #expect(browser.currentRow == 1999)
            browser.press(.pageUp)
            let row = try #require(browser.currentRow)
            #expect(row < 1999)
            browser.press(.pageDown)
            browser.press(.home)
            #expect(browser.currentRow == 0)
            #expect(browser.grid.scrollTopForMeasuring == 0)
        }
    }

    @Test("Select All and Select None")
    func selectAll() async throws {
        try await withBrowser { browser in
            browser.grid.document.selectAll(nil)
            #expect(browser.model.selectedCount == 300)
            browser.model.selectNone()
            #expect(browser.model.selectedCount == 0)
        }
    }

    @Test("Command-Up goes to the parent, and stops at the root")
    func parent() async throws {
        try await withBrowser { browser in
            await browser.waitForResult { browser.model.open(BrowseScope(volume: browser.scope.volume, path: "Root/Sub")) }
            #expect(browser.model.scope?.path == "Root/Sub")
            await browser.waitForResult { browser.press(.up, modifiers: .command) }
            #expect(browser.model.scope?.path == "Root")
            browser.press(.up, modifiers: .command)
            #expect(browser.model.scope?.path == "Root")
        }
    }

    @Test("Clicks select, Command-click toggles and Shift-click extends")
    func mouse() async throws {
        try await withBrowser { browser in
            browser.click(row: 2)
            #expect(browser.selectedRows == IndexSet(integer: 2))
            browser.click(row: 5, modifiers: .command)
            #expect(browser.selectedRows == IndexSet([2, 5]))
            browser.click(row: 7, modifiers: .shift)
            #expect(browser.selectedRows == IndexSet([2, 5, 6, 7]))
            #expect(browser.currentRow == 7)
        }
    }

    @Test("Moving in an aspect-ratio layout lands on a real tile on the next row")
    func aspectMoves() async throws {
        try await withBrowser(count: 800, aspect: true) { browser in
            try await Task.sleep(for: .milliseconds(100))
            browser.press(.right)
            browser.press(.down)
            let row = try #require(browser.currentRow)
            #expect(row > 0)
            let layout = browser.grid.tileLayout
            #expect(layout.frame(of: row).minY > layout.frame(of: 0).minY)
        }
    }

    // MARK: List

    @Test("In the list, Up and Down move, Left and Right don't, and Shift extends")
    func listKeys() async throws {
        try await withBrowser { browser in
            browser.model.setViewMode(.list)
            browser.flushFrame()
            #expect(browser.window.firstResponder === browser.list.table)
            browser.press(.down)
            #expect(browser.currentRow == 0)
            browser.press(.down)
            browser.press(.down)
            #expect(browser.currentRow == 2)
            browser.press(.right)
            #expect(browser.currentRow == 2)
            browser.press(.down, modifiers: .shift)
            #expect(browser.selectedRows == IndexSet(integersIn: 2...3))
            #expect(browser.list.table.selectedRowIndexes == IndexSet(integersIn: 2...3))
        }
    }

    @Test("The list keeps the current row on screen")
    func listStaysOnScreen() async throws {
        try await withBrowser(count: 2000) { browser in
            browser.model.setViewMode(.list)
            browser.press(.end)
            browser.flushFrame()
            let table = browser.list.table
            #expect(table.visibleRect.intersects(table.rect(ofRow: 1999)))
        }
    }

    @Test("Grid and list share the current item and the selection")
    func sharedState() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            browser.press(.right, modifiers: .shift)
            browser.model.setViewMode(.list)
            browser.flushFrame()
            #expect(browser.list.table.selectedRowIndexes == IndexSet(integersIn: 1...2))
            browser.press(.down)
            browser.model.setViewMode(.tiles)
            browser.flushFrame()
            #expect(browser.currentRow == 3)
            #expect(browser.window.firstResponder === browser.grid.document)
        }
    }

    @Test("Typing a name jumps to it in the list")
    func typeToSelect() async throws {
        try await withBrowser { browser in
            browser.model.setViewMode(.list)
            await browser.model.setSortAndWait(BrowseSort(key: .name, ascending: true), browser)
            browser.type("img_0004")
            var row: Int?
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(10))
                row = browser.currentRow
                if row != nil { break }
            }
            let rows = try await browser.library.store.browseRows(
                instances: [browser.model.result.instanceIDs[try #require(row)]])
            #expect(rows.first?.path.name.hasPrefix("IMG_0004") == true)
        }
    }
}

extension BrowserModel {
    func setSortAndWait(_ sort: BrowseSort, _ browser: BrowserFixture) async {
        await browser.waitForResult { self.setSort(sort) }
    }
}

@Suite("Browsing", .serialized)
@MainActor
struct BrowsingTests {
    @Test("A re-sort keeps the current asset, and its place on screen")
    func resortKeepsAnchor() async throws {
        let browser = try await BrowserFixture(count: 3000)
        defer { browser.tearDown() }
        browser.grid.scroll(toTop: 5000)
        let visibleRow = try #require(browser.grid.captureAnchor()).row
        browser.model.select(row: visibleRow)
        let asset = browser.model.selection.currentAsset
        let before = try #require(browser.grid.captureAnchor())

        await browser.model.setSortAndWait(BrowseSort(key: .date, ascending: true), browser)
        let row = try #require(browser.currentRow)
        #expect(browser.model.selection.currentAsset == asset)
        #expect(row != visibleRow)
        let after = try #require(browser.grid.captureAnchor())
        #expect(after.row == row)
        #expect(abs(after.screenY - before.screenY) < 1)
    }

    @Test("A selection follows its assets through a re-sort")
    func resortKeepsSelection() async throws {
        let browser = try await BrowserFixture(count: 100)
        defer { browser.tearDown() }
        browser.click(row: 2)
        browser.click(row: 5, modifiers: .command)
        let assets = Set(browser.selectedRows.map { browser.model.result.assetIDs[$0] })
        await browser.model.setSortAndWait(BrowseSort(key: .date, ascending: true), browser)
        #expect(Set(browser.selectedRows.map { browser.model.result.assetIDs[$0] }) == assets)
    }

    @Test("New rows arriving during indexing keep the view where it is")
    func indexingKeepsPlace() async throws {
        let browser = try await BrowserFixture(count: 1000)
        defer { browser.tearDown() }
        browser.grid.scroll(toTop: 3000)
        let before = try #require(browser.grid.captureAnchor())
        let asset = browser.model.result.assetIDs[before.row]
        _ = try await browser.library.store.applyDirectory(
            volume: browser.scope.volume, directory: "Root/New",
            files: (0..<50).map {
                ScannedFile(
                    name: "NEW\($0).JPG", kind: .photo, size: 1,
                    modifiedTime: FileTimestamp(nanoseconds: 9_000_000_000_000_000_000))
            })
        await browser.waitForResult { browser.model.reload(keepPosition: true) }
        #expect(browser.model.itemCount == 1050)
        // New rows change which tile is nearest the middle, so this follows the asset itself.
        let row = try #require(browser.model.result.assetIDs.firstIndex(of: asset))
        let frame = browser.grid.tileLayout.frame(of: row)
        #expect(abs(frame.midY - browser.grid.scrollTopForMeasuring - before.screenY) < 1)
    }

    @Test("A session restores the sort, view and anchor")
    func sessionRestore() async throws {
        let browser = try await BrowserFixture(count: 500)
        defer { browser.tearDown() }
        browser.grid.scroll(toTop: 4000)
        let row = try #require(browser.grid.captureAnchor()).row
        browser.model.select(row: row)
        let asset = try #require(browser.model.selection.currentAsset)
        let session = BrowseSession(
            scope: browser.scope, sort: .default, viewMode: 0, tileSize: 200, anchor: asset)
        try await browser.library.store.saveSession(session)

        let next = BrowserModel(library: browser.library)
        let view = BrowserContainerView(model: next)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        view.grid.needsLayout = true
        view.grid.layoutSubtreeIfNeeded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            next.onResult = { _ in continuation.resume() }
            Task { await next.restore() }
        }
        #expect(next.selection.currentAsset == asset)
        #expect(next.tileSize == 200)
        let anchor = try #require(view.grid.captureAnchor())
        #expect(anchor.row == next.selection.currentRow)
    }

    @Test("A pinch keeps the tile under the cursor vertically, to within half a device pixel")
    func zoomAnchor() async throws {
        let browser = try await BrowserFixture(count: 10_000)
        defer { browser.tearDown() }
        browser.grid.scroll(toTop: 20_000)
        let top = browser.grid.scrollTopForMeasuring
        let layout = browser.grid.tileLayout
        let row = try #require(layout.closest(to: CGPoint(x: 500, y: top + 300)))
        let before = layout.frame(of: row).midY - top
        let point = CGPoint(x: layout.frame(of: row).midX, y: before)
        // The clip view snaps to device pixels, and this test window is at 1x.
        let limit = 0.5 / browser.window.backingScaleFactor + 0.01
        browser.grid.zoomForMeasuring(to: 160, anchor: point)
        for size in stride(from: CGFloat(160), through: 300, by: 3) {
            browser.grid.zoomForMeasuring(to: size, anchor: point)
            let now = browser.grid.tileLayout.frame(of: row).midY - browser.grid.scrollTopForMeasuring
            #expect(abs(now - before) <= limit)
        }
    }

    @Test("Grid tiles are recycled, so their number follows the viewport and not the library")
    func tilesAreBounded() async throws {
        let browser = try await BrowserFixture(count: 20_000)
        defer { browser.tearDown() }
        browser.grid.scroll(toTop: 100_000)
        #expect(browser.grid.visibleTileCount > 0)
        #expect(browser.grid.visibleTileCount < 100)
    }
}
