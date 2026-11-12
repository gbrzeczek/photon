import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

/// Which folders are open in the sidebar's tree, kept in the library.
@Suite("Sidebar tree", .serialized)
@MainActor
struct SidebarTreeTests {
    @Test("Opening a folder opens the folders above it, and the tree is saved in the library")
    func revealAndSave() async throws {
        let browser = try await BrowserFixture(count: 10)
        defer { browser.tearDown() }
        let library = browser.library
        let root = browser.scope
        let sub = BrowseScope(volume: root.volume, path: root.path + "/Sub")

        library.revealInTree(sub)
        #expect(library.expandedFolders == [root])
        library.revealInTree(root)
        #expect(library.expandedFolders == [root])

        library.setFolder(sub, expanded: true)
        library.setFolder(root, expanded: false)
        #expect(library.expandedFolders == [sub])
        // Saved behind the change, so it's in the store once the write lands.
        var saved: Set<BrowseScope> = []
        for _ in 0..<100 {
            saved = try await library.store.expandedFolders()
            if saved == [sub] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved == [sub])
    }
}
