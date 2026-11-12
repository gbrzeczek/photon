import AppKit
import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

/// Favorites, albums, search, stacks and the inspector, through real key events in a window that isn't
/// shown. `UITests/` checks Command-I and Command-F, which go through the menus, in the running app.
@Suite("Organization in the browser", .serialized)
@MainActor
struct OrganizationBrowserTests {
    private func withBrowser(count: Int = 60, _ body: (BrowserFixture) async throws -> Void) async throws {
        let fixture = try await BrowserFixture(count: count)
        defer { fixture.tearDown() }
        try await body(fixture)
    }

    private func favorites(_ browser: BrowserFixture) -> IndexSet {
        IndexSet(browser.model.result.flags.indices.filter { browser.model.result.flags[$0].contains(.favorite) })
    }

    @Test("Period toggles the current item's favorite in the grid")
    func periodInGrid() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.press(.right)
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser) == IndexSet(integer: 1))
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser).isEmpty)
        }
    }

    @Test("Period favorites the whole selection in the list, then a second press clears it")
    func periodInList() async throws {
        try await withBrowser { browser in
            browser.model.setViewMode(.list)
            browser.press(.down)
            browser.press(.down, modifiers: .shift)
            browser.press(.down, modifiers: .shift)
            #expect(browser.selectedRows == IndexSet(0...2))
            await browser.waitForResult { browser.model.toggleFavorite() }
            browser.model.select(row: 1)
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser) == IndexSet([0, 2]))
            browser.model.selectAll()
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser).count == browser.model.itemCount)
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser).isEmpty)
        }
    }

    @Test("Period in the viewer favorites the photo showing, and the viewer stays open")
    func periodInViewer() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.model.openViewer()
            browser.model.stepViewer(by: 3, isRepeat: false)
            #expect(browser.window.firstResponder === browser.container.viewer)
            await browser.waitForResult { browser.press(.period) }
            #expect(favorites(browser) == IndexSet(integer: 3))
            #expect(browser.model.isViewerOpen)
            #expect(browser.currentRow == 3)
        }
    }

    @Test("Unfavoriting in Favorites hands the current item to a neighbor")
    func unfavoriteInFavorites() async throws {
        try await withBrowser { browser in
            browser.model.selectAll()
            await browser.waitForResult { browser.model.toggleFavorite() }
            await browser.waitForResult { browser.model.open(.favorites) }
            #expect(browser.model.itemCount == 60)
            browser.model.select(row: 10)
            let removed = browser.model.result.assetIDs[10]
            await browser.waitForResult { browser.press(.period) }
            #expect(browser.model.itemCount == 59)
            #expect(!browser.model.result.assetIDs.contains(removed))
            #expect(browser.currentRow == 10)
        }
    }

    @Test("Delete removes from a manual album, and does nothing in a folder")
    func deleteInAlbum() async throws {
        try await withBrowser { browser in
            browser.model.selectAll()
            let assets = browser.model.actionAssets
            let album = try await browser.library.createAlbum(named: "Album")
            try await browser.library.store.addAssets(Array(assets.prefix(5)), to: album)

            browser.model.select(row: 0)
            browser.press(.delete)
            try await Task.sleep(for: .milliseconds(100))
            #expect(browser.model.itemCount == 60)

            await browser.waitForResult { browser.model.open(.album(album)) }
            #expect(browser.model.itemCount == 5)
            browser.press(.right)
            await browser.waitForResult { browser.press(.delete) }
            #expect(browser.model.itemCount == 4)
            #expect(try await browser.library.store.assetCount() == 60)
        }
    }

    @Test("Search filters what's showing, keeps the selection's place, and clears with another source")
    func search() async throws {
        try await withBrowser { browser in
            await browser.waitForResult { browser.model.setSearch("IMG_0001") }
            // IMG_00010 to IMG_00019. The underscore is literal, not LIKE's wildcard.
            #expect(browser.model.itemCount == 10)
            await browser.waitForResult { browser.model.setSearch("") }
            #expect(browser.model.itemCount == 60)
            await browser.waitForResult { browser.model.setSearch("nothing-matches") }
            #expect(browser.model.itemCount == 0)
            await browser.waitForResult { browser.model.open(.allItems) }
            #expect(browser.model.search.isEmpty)
            #expect(browser.model.itemCount == 60)
        }
    }

    @Test("Stacks collapse to their cover, and Expand Stacks shows every member")
    func stacks() async throws {
        try await withBrowser(count: 0) { browser in
            let store = browser.library.store
            let volume = browser.scope.volume
            let files = ["A.JPG", "A.CR3", "B.JPG", "C.HEIC"].map {
                ScannedFile(name: $0, kind: .photo, size: 10, modifiedTime: FileTimestamp(nanoseconds: 1))
            }
            _ = try await store.applyDirectory(volume: volume, directory: "Root/Pairs", files: files)
            var indexed: [IndexedFile] = []
            for (offset, instance) in try await store.instances(volume: volume, directory: "Root/Pairs").enumerated() {
                indexed.append(
                    IndexedFile(
                        instanceID: instance.id, size: instance.size, modifiedTime: instance.modifiedTime,
                        hash: ContentHash(bytes: Data(repeating: UInt8(offset + 1), count: 32))!, metadata: nil))
            }
            _ = try await store.applyIndexed(indexed)
            try await store.pairStacks(volume: volume)
            await browser.waitForResult { browser.model.open(.allItems) }
            #expect(browser.model.itemCount == 3)
            #expect(browser.model.result.flags.filter { $0.contains(.rawPair) }.count == 1)
            await browser.waitForResult { browser.model.setExpandsStacks(true) }
            #expect(browser.model.itemCount == 4)
        }
    }

    @Test("The inspector follows the current item once it rests, and shows its file and tags")
    func inspector() async throws {
        try await withBrowser { browser in
            browser.press(.right)
            browser.model.toggleInspector()
            #expect(browser.model.isInspectorShown)
            let first = AssetID(rawValue: browser.model.result.assetIDs[0])
            #expect(browser.model.inspectedAsset == first)
            browser.press(.right)
            browser.press(.right)
            // Waits for a held key to rest, like the status bar.
            #expect(browser.model.inspectedAsset == first)
            let third = AssetID(rawValue: browser.model.result.assetIDs[2])
            // Then follows once it rests. A slow machine may take longer than the rest delay.
            for _ in 0..<250 where browser.model.inspectedAsset != third {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(browser.model.inspectedAsset == third)

            await browser.waitForResult { browser.model.addTag(named: "Kept", to: [third]) }
            let details = try #require(try await browser.library.store.details(of: third))
            #expect(details.tags.map(\.name) == ["Kept"])
            #expect(details.locations.first?.path.directory == "Root/Sub")
            #expect(browser.library.tags.map(\.name) == ["Kept"])
            browser.model.toggleInspector()
            #expect(!browser.model.isInspectorShown)
        }
    }

    @Test("Albums and tags reopen with their sessions, and a deleted one falls back to a folder")
    func sessions() async throws {
        try await withBrowser { browser in
            let album = try await browser.library.createAlbum(named: "Trip")
            await browser.waitForResult { browser.model.open(.album(album)) }
            browser.model.flushSession()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await browser.library.store.latestSession()?.source == .album(album))
            await browser.waitForResult { browser.model.deleteAlbum(album) }
            #expect(browser.model.source?.folder != nil)
            // The album list refreshes after the delete's own write, which can land after the folder's
            // result on a slow machine.
            var isGone = false
            for _ in 0..<250 {
                isGone = browser.library.albums.isEmpty
                if isGone { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(isGone)
        }
    }
}
