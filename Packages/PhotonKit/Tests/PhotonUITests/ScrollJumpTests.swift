import AppKit
import Foundation
import Testing

@testable import PhotonUI

/// The jump buttons over the grid and list, and Back after a jump.
@Suite("Scroll to top and bottom, and Back", .serialized)
@MainActor
struct ScrollJumpTests {
    private func withBrowser(count: Int = 2000, aspect: Bool = false, _ body: (BrowserFixture) async throws -> Void)
        async throws
    {
        let fixture = try await BrowserFixture(count: count, aspectLayout: aspect)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    private func bottomOfGrid(_ browser: BrowserFixture) -> CGFloat {
        browser.grid.scrollView.documentView!.frame.height - browser.grid.scrollView.contentView.bounds.height
    }

    @Test("The buttons scroll to either end and keep the selection, and Back returns once")
    func jumpAndBack() async throws {
        try await withBrowser { browser in
            browser.click(row: 3)
            browser.grid.scroll(toTop: 900)
            browser.flushFrame()
            #expect(browser.container.jumps.isJumpVisibleForTesting)
            let before = try #require(browser.grid.captureAnchor())
            let anchorAsset = browser.model.result.assetIDs[before.row]

            browser.model.scrollToEdge(bottom: true)
            browser.flushFrame()
            #expect(abs(browser.grid.scrollTopForMeasuring - bottomOfGrid(browser)) < 8)
            #expect(browser.currentRow == 3)
            #expect(browser.container.jumps.isBackVisibleForTesting)

            browser.model.goBack()
            browser.flushFrame()
            #expect(abs(browser.grid.scrollTopForMeasuring - 900) < 2)
            let after = try #require(browser.grid.captureAnchor())
            #expect(browser.model.result.assetIDs[after.row] == anchorAsset)
            #expect(!browser.model.canGoBack)
            #expect(!browser.container.jumps.isBackVisibleForTesting)

            browser.model.scrollToEdge(bottom: false)
            browser.flushFrame()
            #expect(browser.grid.scrollTopForMeasuring == 0)
        }
    }

    @Test("Back after End brings back the current item, and a new source forgets it")
    func backAfterEnd() async throws {
        try await withBrowser { browser in
            browser.click(row: 5)
            browser.press(.end)
            #expect(browser.currentRow == 1999)
            #expect(browser.model.canGoBack)
            browser.model.goBack()
            browser.flushFrame()
            #expect(browser.currentRow == 5)
            #expect(browser.grid.scrollTopForMeasuring == 0)

            browser.press(.end)
            #expect(browser.model.canGoBack)
            browser.model.setViewMode(.list)
            #expect(!browser.model.canGoBack)
        }
    }

    @Test("In an aspect-ratio layout the bottom button reaches the last tile")
    func aspectBottom() async throws {
        try await withBrowser(aspect: true) { browser in
            browser.model.scrollToEdge(bottom: true)
            for _ in 0..<5 { browser.flushFrame() }
            let last = browser.grid.tileLayout.frame(of: 1999)
            let clip = browser.grid.scrollView.contentView.bounds
            #expect(last.maxY <= clip.maxY + 1)
            #expect(last.minY >= clip.minY)
        }
    }

    @Test("A short view shows no jump buttons")
    func shortView() async throws {
        try await withBrowser(count: 20) { browser in
            browser.grid.scroll(toTop: 40)
            browser.flushFrame()
            #expect(!browser.container.jumps.isJumpVisibleForTesting)
        }
    }

    @Test("The list jumps too")
    func list() async throws {
        try await withBrowser { browser in
            browser.model.setViewMode(.list)
            browser.model.scrollToEdge(bottom: true)
            let clip = browser.list.scrollView.contentView.bounds
            #expect(clip.maxY >= browser.list.scrollView.documentView!.frame.height - 1)
            browser.model.goBack()
            #expect(browser.list.scrollView.contentView.bounds.minY < 1)
        }
    }
}
