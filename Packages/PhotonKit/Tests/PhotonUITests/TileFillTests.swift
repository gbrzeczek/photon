import AppKit
import Testing

@testable import PhotonUI

@Suite("Square tiles filling the width", .serialized)
@MainActor
struct TileFillTests {
    private func withBrowser(_ body: (BrowserFixture) async throws -> Void) async throws {
        let fixture = try await BrowserFixture(count: 300)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    /// Runs frames until the zoom is over. The window never shows, so there's no display link to do it.
    private func finishZoom(_ browser: BrowserFixture) async throws {
        for _ in 0..<200 where browser.grid.isZoomingForTesting {
            _ = browser.grid.tick()
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(!browser.grid.isZoomingForTesting)
    }

    private func expectFilled(_ browser: BrowserFixture) {
        let layout = browser.grid.tileLayout
        #expect(abs(layout.tile - layout.filledTile(for: layout.tile)) < 0.001)
        #expect(abs(layout.frame(of: layout.columns - 1 - layout.phase).maxX - layout.width) < 0.001)
    }

    @Test("A pinch shows the exact size, then eases to fill the width when it stops")
    func pinchEndsFilled() async throws {
        try await withBrowser { browser in
            let start = browser.grid.tileLayout.tile
            browser.grid.zoomForMeasuring(to: start * 1.1, anchor: CGPoint(x: 400, y: 300))
            #expect(browser.grid.tileLayout.tile == start * 1.1)
            try await finishZoom(browser)
            expectFilled(browser)
        }
    }

    @Test("A frame that stalls during the easing doesn't leave the grid unfilled")
    func stallDuringEasing() async throws {
        try await withBrowser { browser in
            browser.model.setTileSizeFromSlider(300)
            _ = browser.grid.tick()
            try await Task.sleep(for: .milliseconds(150))
            try await finishZoom(browser)
            expectFilled(browser)
        }
    }

    @Test("The slider changes the column count, and leaves the grid filled")
    func sliderEndsFilled() async throws {
        try await withBrowser { browser in
            let columns = browser.grid.tileLayout.columns
            browser.model.setTileSizeFromSlider(300)
            try await finishZoom(browser)
            #expect(browser.grid.tileLayout.columns < columns)
            expectFilled(browser)
            #expect(browser.model.tileSize == 300)
        }
    }

    @Test("A slider step within the same column count changes nothing")
    func sliderStepWithinColumns() async throws {
        try await withBrowser { browser in
            let tile = browser.grid.tileLayout.tile
            let columns = browser.grid.tileLayout.columns
            browser.model.setTileSizeFromSlider(browser.model.tileSize + 0.5)
            #expect(browser.grid.tileLayout.columns == columns)
            #expect(browser.grid.tileLayout.tile == tile)
            #expect(!browser.grid.isZoomingForTesting)
        }
    }

    @Test("Resizing the window keeps the grid filled")
    func windowResize() async throws {
        try await withBrowser { browser in
            browser.window.setContentSize(CGSize(width: 1234, height: 600))
            browser.window.contentView?.layoutSubtreeIfNeeded()
            #expect(browser.grid.tileLayout.width > 1000)
            expectFilled(browser)
        }
    }
}
