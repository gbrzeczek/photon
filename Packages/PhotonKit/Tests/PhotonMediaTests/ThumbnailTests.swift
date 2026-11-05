import CoreGraphics
import Foundation
import ImageIO
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

@testable import PhotonMedia

private func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

/// A library with real files on the internal disk, and the whole thumbnail pipeline around it.
private final class PipelineFixture: Sendable {
    let directory: URL
    let media: URL
    let store: LibraryStore
    let indexer: LibraryIndexer
    let packs: ThumbnailPackStore
    let generator: ThumbnailGenerator

    init(options: ThumbnailPackOptions = ThumbnailPackOptions()) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "photon-thumbs-\(UUID().uuidString)")
        media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        self.indexer = indexer
        packs = ThumbnailPackStore(store: store, options: options)
        generator = ThumbnailGenerator(store: store, packs: packs, scheduler: { indexer.scheduler(for: $0) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ name: String, width: Int = 1200, height: Int = 800, seed: UInt64 = 1, orientation: Int? = nil) throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = width
        options.height = height
        options.seed = seed
        options.orientation = orientation
        try #require(SyntheticMedia.jpeg(options)).write(to: media.appending(path: name))
    }

    func index() async throws -> VolumeID {
        try #require(try await indexer.index(path: media.path).volumeID)
    }

    func rows(_ volume: VolumeID) async throws -> [BrowseRow] {
        let path = try await store.roots(volume: volume).first?.relativePath ?? ""
        let result = try await store.browse(BrowseScope(volume: volume, path: path), sort: BrowseSort(key: .name, ascending: true))
        return try await store.browseRows(instances: result.instanceIDs)
    }
}

@Suite("Making thumbnails")
struct ThumbnailerTests {
    @Test("Both sizes come from one read, and neither goes above its limit")
    func twoSizes() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 2000
        options.height = 1000
        let data = try #require(SyntheticMedia.jpeg(options))
        let set = try #require(try Thumbnailer.fullThumbnails(from: DataByteSource(data)))
        let large = try #require(set.thumbnails.first { $0.tier == .large })
        let small = try #require(set.thumbnails.first { $0.tier == .small })
        #expect((large.width, large.height) == (800, 400))
        #expect((small.width, small.height) == (320, 160))
        #expect(pixelSize(small.data)?.0 == 320)
        #expect(set.dominantColor != nil)
    }

    @Test("A small original isn't scaled up, and gets one size")
    func smallOriginal() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 200
        options.height = 100
        let data = try #require(SyntheticMedia.jpeg(options))
        let set = try #require(try Thumbnailer.fullThumbnails(from: DataByteSource(data)))
        #expect(set.thumbnails.map(\.tier) == [.small])
        #expect(set.thumbnails[0].width == 200)
    }

    @Test("Orientation is applied, so a portrait photo comes out upright")
    func orientation() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 1000
        options.height = 500
        options.orientation = 6
        let data = try #require(SyntheticMedia.jpeg(options))
        let set = try #require(try Thumbnailer.fullThumbnails(from: DataByteSource(data)))
        let small = try #require(set.thumbnails.first { $0.tier == .small })
        #expect(small.height > small.width)
    }

    @Test("Bytes that aren't an image give nothing, not a crash")
    func garbage() throws {
        let garbage = DataByteSource(Data(repeating: 7, count: 4096))
        #expect(try Thumbnailer.fullThumbnails(from: garbage) == nil)
        #expect(try Thumbnailer.embeddedPreview(from: garbage) == nil)
    }

    @Test("A failing read is passed on, so a removed drive isn't taken for a bad file")
    func readErrorsThrow() {
        final class Failing: ByteSource {
            var size: Int64 { 1000 }
            func read(offset: Int64, length: Int) throws -> Data { throw VolumeIOError.volumeUnavailable }
        }
        #expect(throws: VolumeIOError.volumeUnavailable) { try Thumbnailer.fullThumbnails(from: Failing()) }
    }

    @Test("The dominant color is the picture's average")
    func dominantColor() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let color = try #require(Thumbnailer.dominantColor(of: image))
        #expect(color >> 16 > 0xF0)
        #expect(color & 0xFFFF < 0x1010)
    }

    @Test("Decoded pixels land in an IOSurface of the same size")
    func decode() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 64
        options.height = 32
        let data = try #require(SyntheticMedia.jpeg(options))
        let decoded = try #require(DecodedThumbnail.decode(data, tier: .small))
        #expect(decoded.surface.width == 64)
        #expect(decoded.surface.height == 32)
    }
}

@Suite("Thumbnail pipeline")
struct ThumbnailPipelineTests {
    @Test("Packs hold what was appended, at the offsets returned")
    func packRoundTrip() async throws {
        let fixture = try PipelineFixture()
        let one = EncodedThumbnail(tier: .small, data: Data(repeating: 1, count: 500), width: 1, height: 1)
        let two = EncodedThumbnail(tier: .small, data: Data(repeating: 2, count: 700), width: 1, height: 1)
        let locations = try await fixture.packs.append([one, two])
        #expect(locations[1].offset == 500)
        #expect(fixture.packs.readBlocking(locations[0]) == one.data)
        #expect(fixture.packs.readBlocking(locations[1]) == two.data)
    }

    @Test("A location past the end of a pack reads as missing")
    func shortRead() async throws {
        let fixture = try PipelineFixture()
        var location = try await fixture.packs.append([
            EncodedThumbnail(tier: .small, data: Data(count: 100), width: 1, height: 1)
        ])[0]
        location.offset = 10_000
        #expect(fixture.packs.readBlocking(location) == nil)
    }

    @Test("The background run makes every thumbnail, then has nothing left to read")
    func background() async throws {
        let fixture = try PipelineFixture()
        for index in 0..<6 { try fixture.write("photo\(index).jpg", seed: UInt64(index)) }
        let volume = try await fixture.index()

        let report = try await fixture.generator.runBackground(volume: volume)
        #expect(report.outcome == .completed)
        #expect(report.previews == 6)
        #expect(report.full == 6)
        #expect(report.failed == 0)
        #expect(try await fixture.store.thumbnailBacklog(volume: volume) == 0)

        let rows = try await fixture.rows(volume)
        let stored = try fixture.store.thumbnailLocationsBlocking(assets: rows.map(\.assetID))
        for row in rows {
            let tiers = Set(stored[row.assetID]?.map(\.tier) ?? [])
            #expect(tiers == [.small, .large])
            #expect(try await fixture.store.asset(row.assetID)?.dominantColor != nil)
        }

        let again = try await fixture.generator.runBackground(volume: volume)
        #expect(again.previews == 0)
        #expect(again.full == 0)
    }

    @Test("A file that can't be decoded fails once, and isn't retried")
    func failedDecode() async throws {
        let fixture = try PipelineFixture()
        try Data(repeating: 9, count: 2048).write(to: fixture.media.appending(path: "broken.jpg"))
        let volume = try await fixture.index()
        let report = try await fixture.generator.runBackground(volume: volume)
        #expect(report.failed == 1)
        let again = try await fixture.generator.runBackground(volume: volume)
        #expect(again.full == 0)
    }

    @Test("A file changed since it was indexed stays pending, and nothing wrong is stored")
    func changedFile() async throws {
        let fixture = try PipelineFixture()
        try fixture.write("photo.jpg")
        let volume = try await fixture.index()
        try fixture.write("photo.jpg", width: 900, height: 900, seed: 2)
        let report = try await fixture.generator.runBackground(volume: volume)
        #expect(report.full == 0)
        #expect(try await fixture.store.thumbnailBacklog(volume: volume) == 1)
    }

    @Test("A tile's request produces thumbnails, delivered through the bounded queue")
    func requestFromTile() async throws {
        let fixture = try PipelineFixture()
        try fixture.write("photo.jpg")
        let volume = try await fixture.index()
        let row = try #require(try await fixture.rows(volume).first)

        let loader = ThumbnailLoader(
            store: fixture.store, packs: fixture.packs, generator: fixture.generator, cache: ThumbnailMemoryCache())
        defer { loader.stop() }
        loader.request(
            ThumbnailRequest(asset: row.assetID, instance: row.instanceID, wanted: .large, priority: .visible))
        var tiers: [ThumbnailTier] = []
        for _ in 0..<500 where !tiers.contains(.large) {
            tiers += loader.drain(limit: 10).map(\.thumbnail.tier)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tiers.contains(.large))
        #expect(loader.cache.nearest(asset: row.assetID, wanted: .large)?.tier == .large)
    }

    @Test("Lost pack bytes are noticed, and the thumbnail is made again")
    func lostPack() async throws {
        let fixture = try PipelineFixture()
        try fixture.write("photo.jpg")
        let volume = try await fixture.index()
        _ = try await fixture.generator.runBackground(volume: volume)
        let row = try #require(try await fixture.rows(volume).first)

        let packDirectory = fixture.store.databaseURL.deletingLastPathComponent().appending(path: "Thumbnails")
        for file in try FileManager.default.contentsOfDirectory(at: packDirectory, includingPropertiesForKeys: nil) {
            try Data().write(to: file)
        }
        let loader = ThumbnailLoader(
            store: fixture.store, packs: fixture.packs, generator: fixture.generator, cache: ThumbnailMemoryCache())
        defer { loader.stop() }
        loader.request(
            ThumbnailRequest(asset: row.assetID, instance: row.instanceID, wanted: .small, priority: .visible))
        var backlog = 0
        for _ in 0..<500 {
            backlog = try await fixture.store.thumbnailBacklog(volume: volume)
            if backlog == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backlog == 1)
    }

    @Test("Offline volumes generate nothing and don't fail")
    func offline() async throws {
        let fixture = try PipelineFixture()
        try fixture.write("photo.jpg")
        let volume = try await fixture.index()
        let row = try #require(try await fixture.rows(volume).first)
        let offline = ThumbnailGenerator(store: fixture.store, packs: fixture.packs, scheduler: { _ in nil })
        try await offline.generate(asset: row.assetID, instance: row.instanceID, priority: .visible) {}
        let report = try await offline.runBackground(volume: volume)
        #expect(report.outcome == .volumeOffline)
    }

    @Test("Over the limit, large packs go first, favorites last, and small ones stay")
    func eviction() async throws {
        var options = ThumbnailPackOptions()
        options.packByteLimit = 1
        options.cacheByteLimit = 0
        let fixture = try PipelineFixture(options: options)
        try fixture.write("a.jpg", seed: 1)
        try fixture.write("b.jpg", seed: 2)
        let volume = try await fixture.index()
        _ = try await fixture.generator.runBackground(volume: volume)
        // Rolls both tiers on to a new pack, because the pack being written is never evicted.
        _ = try await fixture.packs.append([
            EncodedThumbnail(tier: .small, data: Data(count: 1), width: 1, height: 1),
            EncodedThumbnail(tier: .large, data: Data(count: 1), width: 1, height: 1),
        ])
        try await fixture.packs.enforceLimit()

        let rows = try await fixture.rows(volume)
        let stored = try fixture.store.thumbnailLocationsBlocking(assets: rows.map(\.assetID))
        for row in rows {
            #expect(stored[row.assetID]?.map(\.tier) == [.small])
        }
    }

    @Test("The memory cache stays within its limit, and returns the nearest size")
    func memoryCache() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 64
        options.height = 64
        let data = try #require(SyntheticMedia.jpeg(options))
        let one = try #require(DecodedThumbnail.decode(data, tier: .small))
        let cache = ThumbnailMemoryCache(byteLimit: one.byteCount * 10)
        for id in 0..<100 {
            let decoded = try #require(DecodedThumbnail.decode(data, tier: .small))
            cache.insert(decoded, asset: AssetID(rawValue: Int64(id)))
        }
        #expect(cache.byteCount <= one.byteCount * 10)
        #expect(cache.nearest(asset: AssetID(rawValue: 99), wanted: .large)?.tier == .small)
        #expect(cache.nearest(asset: AssetID(rawValue: 0), wanted: .small) == nil)
    }
}
