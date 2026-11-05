import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing
import os

/// Budgets on a synthetic library. Limits are generous, so that a shared CI machine doesn't fail them:
/// these catch accidental quadratic behavior, and real numbers are in docs/PLAN.md.
@Suite("Indexing performance", .serialized)
struct PerformanceTests {
    @Test("Rescanning an unchanged library is cheap: enumeration only")
    func rescanCost() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = SyntheticLibrary.Options()
        options.fileCount = 5000
        let manifest = try SyntheticLibrary(options: options).generate(at: directory.appending(path: "media"))
        let store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())

        let first = try await indexer.index(path: directory.appending(path: "media").path)
        #expect(first.processed == 5000)

        let second = try await indexer.index(path: directory.appending(path: "media").path)
        #expect(second.processed == 0)
        #expect(second.scan.unchanged == manifest.files.count)
        #expect(second.io.filesOpened == 0)
        #expect(second.io.bytesRead == 0)
        #expect(second.scanSeconds < 5, "An unchanged rescan of 5,000 files took \(second.scanSeconds) s")
    }
}
