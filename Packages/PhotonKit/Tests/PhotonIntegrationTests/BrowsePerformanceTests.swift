import Foundation
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

/// The query behind opening a folder, on a synthetic 100k library. Limits are generous, so that a shared
/// CI machine doesn't fail them: these catch accidental quadratic behavior. Measured numbers are in
/// docs/PLAN.md, and the same scenarios run in the app through `PerformanceHarness`.
@Suite("Browsing performance", .serialized)
struct BrowsePerformanceTests {
    private func makeLibrary() async throws -> (LibraryStore, BrowseScope, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-browse-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appending(path: "Library.sqlite"))
        let volume = try await store.insertVolume(uuid: "PERF", name: "P", capacity: nil, filesystem: nil)
        for folder in 0..<100 {
            let files = (0..<1000).map { index in
                ScannedFile(
                    name: "IMG_\(folder * 1000 + index).JPG", kind: .photo, size: Int64(index),
                    modifiedTime: FileTimestamp(nanoseconds: Int64(folder * 1000 + index) * 7_919_000_000 % 999_983_000_000_000))
            }
            _ = try await store.applyDirectory(volume: volume.id, directory: "Root/\(folder)", files: files)
        }
        return (store, BrowseScope(volume: volume.id, path: "Root"), directory)
    }

    @Test("Every sort of 100k rows comes back quickly")
    func sorts() async throws {
        let (store, scope, directory) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ContinuousClock()
        for key in SortKey.allCases {
            let start = clock.now
            let result = try await store.browse(scope, sort: BrowseSort(key: key, ascending: true))
            let seconds = (clock.now - start) / .seconds(1)
            print("Browse 100k by \(key.rawValue): \(Int(seconds * 1000)) ms")
            #expect(result.count == 100_000)
            #expect(seconds < 2, "Sorting by \(key.rawValue) took \(seconds) s")
        }
    }

    @Test("Row maps for keeping the anchor are cheap off the main thread")
    func rowMaps() async throws {
        let (store, scope, directory) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let byDate = try await store.browse(scope, sort: .default)
        let byName = try await store.browse(scope, sort: BrowseSort(key: .name, ascending: true))
        let clock = ContinuousClock()
        let start = clock.now
        let map = byDate.rowMap(to: byName)
        #expect(map.count == 100_000)
        #expect((clock.now - start) / .seconds(1) < 1)
    }
}
