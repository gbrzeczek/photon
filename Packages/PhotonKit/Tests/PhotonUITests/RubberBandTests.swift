import AppKit
import Foundation
import Testing

@testable import PhotonUI

@Suite("Rubber band selection", .serialized)
@MainActor
struct RubberBandTests {
    private func withBrowser(
        count: Int = 300, aspect: Bool = false, _ body: (BrowserFixture) async throws -> Void
    ) async throws {
        let fixture = try await BrowserFixture(count: count, aspectLayout: aspect)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    @Test("Dragging from a tile selects the rectangle it crosses, not the rows between")
    func rectangle() async throws {
        try await withBrowser { browser in
            let columns = browser.grid.tileLayout.columns
            #expect(columns >= 3)
            // Two columns by two rows, starting one column in.
            _ = browser.press(row: 1)
            browser.drag(to: browser.windowPoint(row: columns + 2))
            #expect(browser.grid.isShowingBandForTesting)
            await browser.release(at: browser.windowPoint(row: columns + 2))
            var expected = IndexSet()
            expected.insert(integersIn: 1...2)
            expected.insert(integersIn: (columns + 1)...(columns + 2))
            #expect(browser.selectedRows == expected)
            #expect(browser.currentRow == columns + 2)
            #expect(!browser.grid.isShowingBandForTesting)
        }
    }

    @Test("Tiles show the band as it moves, and backing off clears them again")
    func live() async throws {
        try await withBrowser { browser in
            let columns = browser.grid.tileLayout.columns
            _ = browser.press(row: 0)
            browser.drag(to: browser.windowPoint(row: columns + 1))
            #expect(browser.grid.showsSelectedForTesting(row: columns + 1) == true)
            browser.drag(to: browser.windowPoint(row: 1))
            #expect(browser.grid.showsSelectedForTesting(row: columns + 1) == false)
            #expect(browser.grid.showsSelectedForTesting(row: 1) == true)
            await browser.release(at: browser.windowPoint(row: 1))
            #expect(browser.selectedRows == IndexSet(integersIn: 0...1))
        }
    }

    @Test("A small wobble during a click stays a click")
    func threshold() async throws {
        try await withBrowser { browser in
            let start = browser.press(row: 5)
            browser.drag(to: CGPoint(x: start.x + 2, y: start.y + 1))
            #expect(!browser.grid.isShowingBandForTesting)
            await browser.release(at: CGPoint(x: start.x + 2, y: start.y + 1))
            #expect(browser.selectedRows == IndexSet(integer: 5))
        }
    }

    @Test("Dragging from a selected tile leaves the selection alone")
    func selectedTileIsKeptForFileDrags() async throws {
        try await withBrowser { browser in
            browser.click(row: 5)
            browser.click(row: 6, modifiers: .command)
            _ = browser.press(row: 5)
            browser.drag(to: browser.windowPoint(row: 20))
            #expect(!browser.grid.isShowingBandForTesting)
            await browser.release(at: browser.windowPoint(row: 20))
            #expect(browser.selectedRows == IndexSet(integersIn: 5...6))
        }
    }

    @Test("A plain click on one of several selected tiles narrows to it when the button comes up")
    func clickNarrows() async throws {
        try await withBrowser { browser in
            browser.click(row: 5)
            browser.click(row: 6, modifiers: .command)
            let point = browser.press(row: 5)
            #expect(browser.selectedRows == IndexSet(integersIn: 5...6))
            await browser.release(at: point)
            #expect(browser.selectedRows == IndexSet(integer: 5))
        }
    }

    @Test("Command keeps what was already selected")
    func extending() async throws {
        try await withBrowser { browser in
            let columns = browser.grid.tileLayout.columns
            browser.click(row: 0)
            _ = browser.press(row: columns * 2, modifiers: .command)
            browser.drag(to: browser.windowPoint(row: columns * 2 + 1))
            await browser.release(at: browser.windowPoint(row: columns * 2 + 1))
            var expected = IndexSet(integer: 0)
            expected.insert(integersIn: (columns * 2)...(columns * 2 + 1))
            #expect(browser.selectedRows == expected)
        }
    }

    @Test("Holding the pointer past the bottom scrolls, and the selection carries on off screen")
    func autoscroll() async throws {
        try await withBrowser(count: 2000) { browser in
            let columns = browser.grid.tileLayout.columns
            _ = browser.press(row: 0)
            // Below the window. In window coordinates, up is positive.
            let below = CGPoint(x: browser.windowPoint(row: columns - 1).x, y: -100)
            browser.drag(to: below)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(10))
                browser.flushFrame()
            }
            let top = browser.grid.scrollTopForMeasuring
            #expect(top > 0)
            await browser.release(at: below)
            #expect(browser.selectedRows.contains(0))
            let row = try #require(browser.currentRow)
            // The last selected row is whatever is at the pointer, past everything that started on screen.
            #expect(browser.grid.tileLayout.frame(of: row).maxY > top)
            #expect(browser.selectedRows.count >= columns * 2)
        }
    }

    @Test("A band in an aspect-ratio layout selects what it touches")
    func aspect() async throws {
        try await withBrowser(aspect: true) { browser in
            let layout = browser.grid.tileLayout
            _ = browser.press(row: 0)
            let next = layout.frame(of: 1)
            let end = browser.grid.document.convert(CGPoint(x: next.midX, y: next.midY), to: nil)
            browser.drag(to: end)
            await browser.release(at: end)
            #expect(browser.selectedRows == IndexSet(integersIn: 0...1))
        }
    }

    @Test("A key press while the rows are being worked out wins")
    func keyWins() async throws {
        try await withBrowser { browser in
            _ = browser.press(row: 0)
            let end = browser.windowPoint(row: 3)
            browser.drag(to: end)
            browser.sendMouseUp(at: end)
            browser.press(.right)
            await browser.waitForBand()
            let current = try #require(browser.currentRow)
            #expect(browser.selectedRows == IndexSet(integer: current))
        }
    }

    @Test("Scroll speed grows with distance past the edge, and has a limit")
    func speed() {
        #expect(RubberBand.scrollSpeed(pointerY: 100, viewportHeight: 500) == 0)
        #expect(RubberBand.scrollSpeed(pointerY: -10, viewportHeight: 500) < 0)
        #expect(RubberBand.scrollSpeed(pointerY: 510, viewportHeight: 500) > 0)
        #expect(
            RubberBand.scrollSpeed(pointerY: 600, viewportHeight: 500)
                > RubberBand.scrollSpeed(pointerY: 510, viewportHeight: 500))
        #expect(RubberBand.scrollSpeed(pointerY: 100_000, viewportHeight: 500) == RubberBand.fastestScroll)
    }
}
