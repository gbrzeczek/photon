import Foundation
import PhotonCore

/// Full rows, loaded in pages as they're needed, so that the list never asks for more than it shows.
@MainActor
final class RowPageCache {
    static let pageSize = 128
    private static let pageLimit = 48

    private let store: LibraryStore
    private var result = BrowseResult.empty
    private var pages: [Int: [BrowseRow]] = [:]
    private var order: [Int] = []
    private var loading = Set<Int>()
    private var generation = 0

    /// Called when a page arrives, with the rows it covers.
    var onLoaded: ((Range<Int>) -> Void)?

    init(store: LibraryStore) { self.store = store }

    func reset(_ result: BrowseResult) {
        self.result = result
        pages.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        loading.removeAll(keepingCapacity: true)
        generation += 1
    }

    /// The row, or nil while its page is on its way.
    func row(_ index: Int) -> BrowseRow? {
        guard index >= 0, index < result.count else { return nil }
        let page = index / Self.pageSize
        guard let rows = pages[page] else {
            load(page)
            return nil
        }
        let offset = index % Self.pageSize
        return offset < rows.count ? rows[offset] : nil
    }

    private func load(_ page: Int) {
        guard loading.insert(page).inserted else { return }
        let range = (page * Self.pageSize)..<min((page + 1) * Self.pageSize, result.count)
        let instances = Array(result.instanceIDs[range])
        let generation = generation
        let store = store
        Task {
            let rows = (try? await store.browseRows(instances: instances)) ?? []
            guard generation == self.generation else { return }
            self.loading.remove(page)
            self.pages[page] = rows
            self.order.append(page)
            if self.order.count > Self.pageLimit { self.pages[self.order.removeFirst()] = nil }
            self.onLoaded?(range)
        }
    }
}
