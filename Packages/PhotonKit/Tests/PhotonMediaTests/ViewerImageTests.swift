import CoreGraphics
import Foundation
import IOSurface
import ImageIO
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

@testable import PhotonMedia

@Suite("Decoding for the viewer")
struct PhotoDecoderTests {
    private func jpeg(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        var options = SyntheticMedia.ImageOptions()
        options.width = width
        options.height = height
        options.orientation = orientation
        return try #require(SyntheticMedia.jpeg(options))
    }

    @Test("A preview fits the long edge asked for, and says how large the original is")
    func preview() throws {
        let image = try #require(PhotoDecoder.decode(try jpeg(width: 2000, height: 1000), maximumEdge: 500))
        #expect((image.width, image.height) == (500, 250))
        #expect(image.originalLongEdge == 2000)
        #expect(!image.isFullResolution)
        #expect(!image.isHDR)
    }

    @Test("No limit gives the original's pixels, and a limit past them doesn't enlarge")
    func full() throws {
        let data = try jpeg(width: 900, height: 600)
        let full = try #require(PhotoDecoder.decode(data, maximumEdge: nil))
        #expect((full.width, full.height) == (900, 600))
        #expect(full.isFullResolution)
        let wide = try #require(PhotoDecoder.decode(data, maximumEdge: 4000))
        #expect((wide.width, wide.height) == (900, 600))
        #expect(wide.isFullResolution)
    }

    @Test("Orientation is applied, so a turned photo comes out upright")
    func orientation() throws {
        let image = try #require(PhotoDecoder.decode(try jpeg(width: 800, height: 400, orientation: 6), maximumEdge: nil))
        #expect((image.width, image.height) == (400, 800))
    }

    @Test("A gain map decodes past SDR white, into a surface tagged with its headroom")
    func gainMap() throws {
        let data = try #require(SyntheticMedia.hdrGainMap())
        let image = try #require(PhotoDecoder.decode(data, maximumEdge: nil))
        #expect(image.isHDR)
        #expect(image.headroom > 2)
        #expect(image.surface.pixelFormat == 0x5247_6841)
        #expect(image.surface.attachment(forKey: kIOSurfaceContentHeadroom as String) != nil)
        image.surface.lock(options: .readOnly, seed: nil)
        defer { image.surface.unlock(options: .readOnly, seed: nil) }
        let pixels = image.surface.baseAddress.assumingMemoryBound(to: Float16.self)
        #expect(pixels[(image.width - 2) * 4] > 2)
    }

    @Test("A gain map in a JPEG works as well, at preview size")
    func gainMapPreview() throws {
        let data = try #require(SyntheticMedia.hdrGainMap(type: .jpeg))
        let image = try #require(PhotoDecoder.decode(data, maximumEdge: 100))
        #expect(image.isHDR)
        #expect(image.width == 100)
    }

    @Test("An SDR photo stays in 8 bits, untagged")
    func sdrSurface() throws {
        let image = try #require(PhotoDecoder.decode(try jpeg(width: 64, height: 48), maximumEdge: nil))
        #expect(image.surface.pixelFormat == 0x4247_5241)
        #expect(image.surface.attachment(forKey: kIOSurfaceContentHeadroom as String) == nil)
    }

    @Test("Bytes that aren't an image give nothing, and don't crash")
    func garbage() {
        #expect(PhotoDecoder.decode(Data(repeating: 7, count: 4096), maximumEdge: 100) == nil)
        #expect(PhotoDecoder.decode(Data(), maximumEdge: 100) == nil)
    }

    @Test("Decoding is limited by the texture size and by the pixels", arguments: [
        (30_000, 2_000, 16_384),  // A panorama, limited by the texture.
        (20_000, 15_000, 12_649),  // 300 MP, limited by pixels.
        (6_000, 4_000, 6_000),
    ])
    func limits(width: Int, height: Int, expected: Int) {
        #expect(PhotoDecoder.edgeLimit(width: width, height: height) == expected)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [FileInstanceID] = []
    private var decodes: [Int?] = []
    private var priorities: [FileInstanceID: IOPriority] = [:]

    func read(_ instance: FileInstanceID, _ priority: IOPriority) {
        lock.withLock {
            reads.append(instance)
            priorities[instance] = priority
        }
    }
    func decode(_ edge: Int?) { lock.withLock { decodes.append(edge) } }
    var readCount: Int { lock.withLock { reads.count } }
    var readInstances: [FileInstanceID] { lock.withLock { reads } }
    var decodeEdges: [Int?] { lock.withLock { decodes } }
    func priority(of instance: FileInstanceID) -> IOPriority? { lock.withLock { priorities[instance] } }
}

@Suite("Loading progressively", .serialized)
@MainActor
struct ViewerImageLoaderTests {
    private func item(_ value: Int64, edge: Int = 200) -> ViewerItem {
        ViewerItem(asset: AssetID(rawValue: value), instance: FileInstanceID(rawValue: value), previewEdge: edge)
    }

    private let image: Data = {
        var options = SyntheticMedia.ImageOptions()
        options.width = 800
        options.height = 400
        return SyntheticMedia.jpeg(options)!
    }()

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func loader(
        _ calls: Calls, readDelay: Duration = .zero, unavailable: Set<Int64> = []
    ) -> ViewerImageLoader {
        let data = image
        return ViewerImageLoader(
            read: { instance, priority in
                calls.read(instance, priority)
                if readDelay > .zero { try await Task.sleep(for: readDelay) }
                return unavailable.contains(instance.rawValue) ? nil : data
            },
            decode: { data, edge in
                calls.decode(edge)
                return PhotoDecoder.decode(data, maximumEdge: edge)
            })
    }

    @Test("The current photo goes to a preview, then full resolution, from one read")
    func progressive() async {
        let calls = Calls()
        let images = loader(calls)
        var landed: [AssetID] = []
        images.onImage = { landed.append($0) }
        images.focus(current: item(1), neighbors: [], wantsFull: true)
        #expect(await until { images.images(for: item(1).asset).full != nil })
        #expect(images.images(for: item(1).asset).preview?.width == 200)
        #expect(images.images(for: item(1).asset).full?.width == 800)
        #expect(calls.readCount == 1)
        #expect(calls.decodeEdges == [200, nil])
        #expect(landed == [item(1).asset, item(1).asset])
        #expect(await until { !images.isLoading(item(1).asset) })
    }

    @Test("A photo no larger than the screen stops at the preview, which is already full")
    func smallPhoto() async {
        let calls = Calls()
        let images = loader(calls)
        images.focus(current: item(1, edge: 4000), neighbors: [], wantsFull: true)
        #expect(await until { images.images(for: item(1).asset).preview != nil && !images.isLoading(item(1).asset) })
        #expect(images.images(for: item(1).asset).preview?.isFullResolution == true)
        #expect(images.images(for: item(1).asset).full == nil)
        #expect(calls.decodeEdges == [4000])
    }

    @Test("Neighbors stop at the preview, and read at the lower priority")
    func neighbors() async {
        let calls = Calls()
        let images = loader(calls)
        images.focus(current: item(1), neighbors: [item(2), item(3)], wantsFull: true)
        #expect(await until { images.images(for: item(1).asset).full != nil })
        #expect(await until { images.images(for: item(3).asset).preview != nil })
        #expect(images.images(for: item(2).asset).full == nil)
        #expect(calls.priority(of: item(1).instance) == .visible)
        #expect(calls.priority(of: item(3).instance) == .ahead)
    }

    @Test("Moving on to a neighbor needs no second read")
    func neighborBecomesCurrent() async {
        let calls = Calls()
        let images = loader(calls)
        images.focus(current: item(1), neighbors: [item(2)], wantsFull: false)
        #expect(await until { images.images(for: item(2).asset).preview != nil })
        #expect(calls.readCount == 2)
        images.focus(current: item(2), neighbors: [item(1)], wantsFull: true)
        #expect(await until { images.images(for: item(2).asset).full != nil })
        #expect(calls.readCount == 2)
    }

    @Test("A photo left behind has its read cancelled, and its full image released")
    func cancelling() async {
        let calls = Calls()
        let images = loader(calls, readDelay: .seconds(30))
        images.focus(current: item(1), neighbors: [], wantsFull: false)
        #expect(await until { calls.readCount == 1 })
        images.focus(current: item(2), neighbors: [], wantsFull: false)
        #expect(await until { !images.isLoading(item(1).asset) })
        #expect(calls.decodeEdges.isEmpty)
        images.focus(current: nil, neighbors: [], wantsFull: false)
        #expect(await until { !images.isLoading(item(2).asset) })
    }

    @Test("Going back to a photo finds its preview still there, with no read")
    func goingBack() async {
        let calls = Calls()
        let images = loader(calls)
        images.focus(current: item(1), neighbors: [], wantsFull: true)
        #expect(await until { images.images(for: item(1).asset).full != nil })
        images.focus(current: item(2), neighbors: [], wantsFull: false)
        #expect(await until { images.images(for: item(2).asset).preview != nil })
        #expect(images.images(for: item(1).asset).full == nil)
        #expect(images.images(for: item(1).asset).preview != nil)
        let reads = calls.readCount
        images.focus(current: item(1), neighbors: [], wantsFull: false)
        #expect(calls.readCount == reads)
    }

    @Test("An offline or changed file leaves the thumbnail in place and isn't tried again")
    func nothingToRead() async {
        let calls = Calls()
        let images = loader(calls, unavailable: [1])
        images.focus(current: item(1), neighbors: [], wantsFull: true)
        #expect(await until { calls.readCount == 1 && !images.isLoading(item(1).asset) })
        #expect(images.images(for: item(1).asset).preview == nil)
        images.focus(current: item(1), neighbors: [], wantsFull: true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(calls.readCount == 1)
    }

    @Test("A larger viewer gets a larger preview, from the bytes it already has")
    func resized() async {
        let calls = Calls()
        let images = loader(calls)
        images.focus(current: item(1, edge: 200), neighbors: [], wantsFull: false)
        #expect(await until { images.images(for: item(1).asset).preview?.width == 200 })
        images.focus(current: item(1, edge: 400), neighbors: [], wantsFull: false)
        #expect(await until { images.images(for: item(1).asset).preview?.width == 400 })
        #expect(calls.readCount == 1)
    }

    @Test("Memory stays bounded however many photos go past")
    func bounded() async {
        let calls = Calls()
        let images = loader(calls)
        for index in 1...30 {
            images.focus(current: item(Int64(index), edge: 100), neighbors: [], wantsFull: false)
            #expect(await until { images.images(for: item(Int64(index)).asset).preview != nil })
        }
        let kept = (1...30).filter { images.images(for: item(Int64($0)).asset).preview != nil }
        #expect(kept.count <= 7)
        #expect(kept.contains(30))
    }
}

@Suite("Reading originals")
struct OriginalReaderTests {
    private func makeFixture() async throws -> (URL, LibraryStore, LibraryIndexer, VolumeID, OriginalReader, BrowseRow) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-read-\(UUID().uuidString)")
        let media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try #require(SyntheticMedia.jpeg()).write(to: media.appending(path: "a.jpg"))
        let store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        let volume = try #require(try await indexer.index(path: media.path).volumeID)
        let path = try await store.roots(volume: volume).first?.relativePath ?? ""
        let result = try await store.browse(BrowseScope(volume: volume, path: path), sort: .default)
        let row = try #require(try await store.browseRows(instances: result.instanceIDs).first)
        return (directory, store, indexer, volume, OriginalReader(store: store, scheduler: { indexer.scheduler(for: $0) }), row)
    }

    @Test("A file comes back whole, through the scheduler")
    func reading() async throws {
        let (directory, _, indexer, volume, reader, row) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try #require(indexer.scheduler(for: volume)).statistics
        let data = try await reader.read(row.instanceID, priority: .visible)
        #expect(data?.count == Int(row.size))
        let after = try #require(indexer.scheduler(for: volume)).statistics
        #expect(after.filesOpened == before.filesOpened + 1)
        #expect(after.openHandles == 0)
    }

    @Test("A file that changed since it was indexed gives nothing")
    func changed() async throws {
        let (directory, _, indexer, volume, reader, row) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mount = try #require(indexer.mountPoint(of: volume))
        let file = URL(fileURLWithPath: mount).appending(path: row.path.string)
        try Data(repeating: 1, count: 10).write(to: file)
        #expect(try await reader.read(row.instanceID, priority: .visible) == nil)
    }

    @Test("A missing file gives nothing, and an offline volume reads nothing at all")
    func missing() async throws {
        let (directory, store, indexer, volume, reader, row) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mount = try #require(indexer.mountPoint(of: volume))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: mount).appending(path: row.path.string))
        #expect(try await reader.read(row.instanceID, priority: .visible) == nil)
        let offline = OriginalReader(store: store, scheduler: { _ in nil })
        #expect(try await offline.read(row.instanceID, priority: .visible) == nil)
    }
}
