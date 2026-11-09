import Foundation
import Testing

@testable import PhotonCore

@Suite("Browsing queries")
struct BrowseTests {
    private func scope(_ library: TestLibrary, _ path: String = "") -> BrowseScope {
        BrowseScope(volume: library.volume, path: path)
    }

    private func names(_ result: BrowseResult, _ library: TestLibrary) async throws -> [String] {
        try await library.store.browseRows(instances: result.instanceIDs).map(\.path.name)
    }

    private func metadata(ms: Int64, width: Int = 400, height: Int = 300, orientation: Int? = nil) -> MediaMetadata {
        MediaMetadata(
            pixelWidth: width, pixelHeight: height, orientation: orientation,
            captureDate: CaptureDate(wallClockMilliseconds: ms))
    }

    @Test("A folder includes its subfolders, and nothing that only shares its prefix")
    func recursiveScope() async throws {
        let library = try await TestLibrary()
        try await library.add("a.jpg", directory: "Photos")
        try await library.add("b.jpg", directory: "Photos/2024")
        try await library.add("c.jpg", directory: "Photos2")
        try await library.add("d.jpg", directory: "Other")
        let result = try await library.store.browse(scope(library, "Photos"), sort: BrowseSort(key: .name, ascending: true))
        #expect(try await names(result, library) == ["a.jpg", "b.jpg"])
        let all = try await library.store.browse(scope(library), sort: .default)
        #expect(all.count == 4)
    }

    @Test("Names sort in natural order, ignoring case")
    func naturalNames() async throws {
        let library = try await TestLibrary()
        for name in ["IMG_10.jpg", "img_9.JPG", "IMG_100.jpg", "IMG_0002.jpg", "Żaba.jpg", "zebra.jpg", "a.jpg"] {
            try await library.add(name)
        }
        let result = try await library.store.browse(scope(library), sort: BrowseSort(key: .name, ascending: true))
        #expect(
            try await names(result, library)
                == ["a.jpg", "IMG_0002.jpg", "img_9.JPG", "IMG_10.jpg", "IMG_100.jpg", "Żaba.jpg", "zebra.jpg"])
        let reversed = try await library.store.browse(scope(library), sort: BrowseSort(key: .name, ascending: false))
        #expect(try await names(reversed, library).first == "zebra.jpg")
    }

    @Test("Dates use the capture date, and fall back to the file's date")
    func dateSort() async throws {
        let library = try await TestLibrary()
        let early = try await library.addIndexed(
            "early.jpg", hash: TestLibrary.hash(1), metadata: metadata(ms: 1_000))
        _ = early
        try await library.add("undated.jpg", modified: 2_000_000_000)  // 2,000 ms
        try await library.addIndexed("late.jpg", hash: TestLibrary.hash(2), metadata: metadata(ms: 3_000))
        let result = try await library.store.browse(scope(library), sort: BrowseSort(key: .date, ascending: true))
        #expect(try await names(result, library) == ["early.jpg", "undated.jpg", "late.jpg"])
    }

    @Test("Sizes and types sort, and files without a duration go last both ways")
    func otherSorts() async throws {
        let library = try await TestLibrary()
        try await library.add("big.png", size: 900)
        try await library.add("small.jpg", size: 10)
        let bySize = try await library.store.browse(scope(library), sort: BrowseSort(key: .size, ascending: false))
        #expect(try await names(bySize, library) == ["big.png", "small.jpg"])
        let byType = try await library.store.browse(scope(library), sort: BrowseSort(key: .type, ascending: true))
        #expect(try await names(byType, library) == ["small.jpg", "big.png"])

        let timed = try await library.addIndexed(
            "clip.jpg", hash: TestLibrary.hash(3), metadata: MediaMetadata(durationSeconds: 5))
        _ = timed
        for ascending in [true, false] {
            let result = try await library.store.browse(scope(library), sort: BrowseSort(key: .duration, ascending: ascending))
            #expect(try await names(result, library).first == "clip.jpg")
        }
    }

    @Test("Exact duplicates show as one row")
    func duplicatesCollapse() async throws {
        let library = try await TestLibrary()
        try await library.addIndexed("one.jpg", directory: "A", hash: TestLibrary.hash(4))
        try await library.addIndexed("two.jpg", directory: "B", hash: TestLibrary.hash(4))
        let result = try await library.store.browse(scope(library), sort: .default)
        #expect(result.count == 1)
    }

    @Test("Aspect ratios allow for orientation and rotation, and extremes are limited")
    func aspects() {
        let a = BrowseColumns.aspect(width: 400, height: 200, orientation: nil, rotation: 0, isVideo: false)
        #expect(a == 2)
        #expect(BrowseColumns.aspect(width: 400, height: 200, orientation: 6, rotation: 0, isVideo: false) == 0.5)
        #expect(BrowseColumns.aspect(width: 400, height: 200, orientation: nil, rotation: 1, isVideo: false) == 0.5)
        #expect(BrowseColumns.aspect(width: 400, height: 200, orientation: 6, rotation: 1, isVideo: false) == 2)
        #expect(BrowseColumns.aspect(width: 10000, height: 100, orientation: nil, rotation: 0, isVideo: false) == 4)
        #expect(BrowseColumns.aspect(width: nil, height: nil, orientation: nil, rotation: 0, isVideo: true) > 1.7)
    }

    @Test("Rows map from one result to the next")
    func rowMap() {
        func result(_ ids: [Int64]) -> BrowseResult {
            BrowseResult(
                assetIDs: ids, instanceIDs: ids, aspects: ids.map { _ in 1 }, colors: ids.map { _ in 0 },
                flags: ids.map { _ in [] }, durations: ids.map { _ in 0 })
        }
        #expect(result([1, 2, 3]).rowMap(to: result([3, 1])) == [1, -1, 0])
    }

    @Test("Paged rows come back in the order asked for")
    func pagedRows() async throws {
        let library = try await TestLibrary()
        let a = try await library.add("a.jpg")
        let b = try await library.add("b.jpg")
        let rows = try await library.store.browseRows(instances: [b.id.rawValue, a.id.rawValue])
        #expect(rows.map(\.path.name) == ["b.jpg", "a.jpg"])
    }

    @Test("A typed name finds matches, and wildcards mean themselves")
    func typedName() async throws {
        let library = try await TestLibrary()
        try await library.add("Beach.jpg")
        try await library.add("b_d.jpg")
        try await library.add("bad.jpg")
        let store = library.store
        let found = try await store.instances(in: scope(library), namePrefix: "be", limit: 5)
        #expect(found.count == 1)
        #expect(try await store.instances(in: scope(library), namePrefix: "b_", limit: 5).count == 1)
    }

    @Test("Folders include every level of the tree under a root")
    func folderTree() async throws {
        let library = try await TestLibrary()
        try await library.store.addRoot(volume: library.volume, relativePath: "Photos")
        try await library.add("a.jpg", directory: "Photos/2024/Trip")
        let folders = try await library.store.folders()
        #expect(folders.map(\.path) == ["Photos", "Photos/2024", "Photos/2024/Trip"])
        #expect(folders.map(\.isRoot) == [true, false, false])
    }

    @Test("A session keeps a folder's view state, and survives its anchor asset")
    func sessions() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let session = BrowseSession(
            scope: scope(library, "DCIM"), sort: BrowseSort(key: .name, ascending: true), viewMode: 1,
            tileSize: 200, anchor: instance.assetID)
        try await library.store.saveSession(session)
        #expect(try await library.store.session(for: session.source) == session)
        #expect(try await library.store.latestSession() == session)

        var updated = session
        updated.viewMode = 0
        updated.anchor = AssetID(rawValue: 9999)  // No such asset, such as one merged away.
        try await library.store.saveSession(updated)
        let stored = try await library.store.session(for: session.source)
        #expect(stored?.viewMode == 0)
        #expect(stored?.anchor == nil)
    }

    @Test("A session keeps what's on screen and the current item apart, and whether the viewer was open")
    func sessionPlace() async throws {
        let library = try await TestLibrary()
        let first = try await library.add("a.jpg")
        let second = try await library.add("b.jpg")
        let session = BrowseSession(
            scope: scope(library, "DCIM"), sort: BrowseSort(key: .name, ascending: true), viewMode: 0,
            tileSize: nil, anchor: first.assetID, anchorPosition: 0.4, current: second.assetID, isViewerOpen: true)
        try await library.store.saveSession(session)
        #expect(try await library.store.latestSession() == session)

        var updated = session
        updated.current = AssetID(rawValue: 9999)
        try await library.store.saveSession(updated)
        #expect(try await library.store.latestSession()?.current == nil)
    }

    @Test("Going up stops at the root")
    func parentScope() {
        let volume = VolumeID(rawValue: 1)
        let scope = BrowseScope(volume: volume, path: "Photos/2024/Trip")
        #expect(scope.parent(within: "Photos") == BrowseScope(volume: volume, path: "Photos/2024"))
        #expect(BrowseScope(volume: volume, path: "Photos").parent(within: "Photos") == nil)
        #expect(BrowseScope(volume: volume, path: "Photos").parent(within: "") == BrowseScope(volume: volume, path: ""))
    }
}

@Suite("Thumbnail records")
struct ThumbnailRecordTests {
    private func record(
        _ instance: FileInstance, state: ThumbnailState = .complete, pack: Int64, tiers: [ThumbnailTier] = [.small]
    ) -> ThumbnailRecord {
        ThumbnailRecord(
            assetID: instance.assetID, instanceID: instance.id, size: instance.size,
            modifiedTime: instance.modifiedTime, state: state, dominantColor: 0x102030,
            locations: tiers.map {
                ThumbnailLocation(tier: $0, packID: pack, offset: 0, length: 10, width: 4, height: 3)
            })
    }

    @Test("A complete thumbnail replaces the preview, and sets the color")
    func completeReplacesPreview() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let pack = try await library.store.insertThumbnailPack(tier: .small)
        try await library.store.recordThumbnails([record(instance, state: .preview, pack: pack, tiers: [.preview])])
        try await library.store.recordThumbnails([record(instance, pack: pack, tiers: [.small, .large])])
        let stored = try library.store.thumbnailLocationsBlocking(assets: [instance.assetID])[instance.assetID]
        #expect(Set(stored?.map(\.tier) ?? []) == [.small, .large])
        #expect(try await library.asset(instance).dominantColor == 0x102030)
    }

    @Test("A result for a file that has changed since it was read is dropped")
    func staleResultDropped() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let pack = try await library.store.insertThumbnailPack(tier: .small)
        var stale = record(instance, pack: pack)
        stale.size += 1
        #expect(try await library.store.recordThumbnails([stale]).isEmpty)
        #expect(try library.store.thumbnailLocationsBlocking(assets: [instance.assetID]).isEmpty)
    }

    @Test("Edited content clears thumbnails, because they show the old picture")
    func rehashClears() async throws {
        let library = try await TestLibrary()
        let instance = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        let pack = try await library.store.insertThumbnailPack(tier: .small)
        try await library.store.recordThumbnails([record(instance, pack: pack)])

        // The same picture, edited in place: it keeps its asset and takes a new hash.
        let edited = try await library.add("a.jpg", size: 200)
        try await library.index(edited, hash: TestLibrary.hash(2), metadata: photoA)
        #expect(try library.store.thumbnailLocationsBlocking(assets: [instance.assetID]).isEmpty)
        #expect(try await library.asset(instance).dominantColor == nil)
    }

    @Test("Merging a provisional asset keeps thumbnails already made")
    func mergeMoves() async throws {
        let library = try await TestLibrary()
        let existing = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        let provisional = try await library.add("b.jpg")
        let pack = try await library.store.insertThumbnailPack(tier: .small)
        try await library.store.recordThumbnails([record(provisional, pack: pack)])
        try await library.index(provisional, hash: TestLibrary.hash(1))
        let stored = try library.store.thumbnailLocationsBlocking(assets: [existing.assetID])
        #expect(stored[existing.assetID]?.count == 1)
    }

    @Test("Pending work skips videos, unhashed files and finished assets")
    func pending() async throws {
        let library = try await TestLibrary()
        let done = try await library.addIndexed("done.jpg", hash: TestLibrary.hash(1))
        let waiting = try await library.addIndexed("waiting.jpg", hash: TestLibrary.hash(2))
        try await library.add("unhashed.jpg")
        let pack = try await library.store.insertThumbnailPack(tier: .small)
        try await library.store.recordThumbnails([record(done, pack: pack)])
        let jobs = try await library.store.pendingThumbnails(volume: library.volume, state: .none, after: nil, limit: 10)
        #expect(jobs.map(\.assetID) == [waiting.assetID])
    }

    @Test("Deleting a pack removes its rows, and the asset can start again")
    func packDeletion() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let pack = try await library.store.insertThumbnailPack(tier: .large)
        try await library.store.recordThumbnails([record(instance, pack: pack, tiers: [.large])])
        #expect(try await library.store.emptyThumbnailPacks(keeping: []).isEmpty)
        try await library.store.deleteThumbnailPack(pack)
        #expect(try library.store.thumbnailLocationsBlocking(assets: [instance.assetID]).isEmpty)
    }
}
