import AVFoundation
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

@testable import PhotonVideo

/// A folder of real videos on the internal disk, indexed, with thumbnails made through the scheduler.
private final class VideoFixture: Sendable {
    let directory: URL
    let media: URL
    let store: LibraryStore
    let indexer: LibraryIndexer
    let generator: ThumbnailGenerator

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "photon-video-\(UUID().uuidString)")
        media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        self.indexer = indexer
        generator = ThumbnailGenerator(
            store: store, packs: ThumbnailPackStore(store: store), scheduler: { indexer.scheduler(for: $0) },
            video: AVFoundationThumbnailer())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ name: String, format: SyntheticVideo.Format, options: SyntheticVideo.Options = .init()) async throws {
        try await SyntheticVideo.write(to: media.appending(path: name), format: format, options: options)
    }

    func index() async throws -> VolumeID {
        try #require(try await indexer.index(path: media.path).volumeID)
    }

    func instances(_ volume: VolumeID) async throws -> [String: FileInstance] {
        let path = try await store.roots(volume: volume).first?.relativePath ?? ""
        let result = try await store.browse(
            BrowseScope(volume: volume, path: path), sort: BrowseSort(key: .name, ascending: true))
        let rows = try await store.browseRows(instances: result.instanceIDs)
        var found: [String: FileInstance] = [:]
        for row in rows {
            found[row.path.name] = try await store.thumbnailJob(asset: row.assetID, instance: row.instanceID)?.instance
        }
        return found
    }

    /// A scheduler of its own over the volume, for injecting failures. Paths are relative to its root.
    func scheduler(_ volume: VolumeID, faults: IOFaultInjector? = nil) throws -> VolumeIOScheduler {
        VolumeIOScheduler(mountPoint: try #require(indexer.mountPoint(of: volume)), faults: faults)
    }

    func source(_ instance: FileInstance, scheduler: VolumeIOScheduler) -> VideoSource {
        VideoSource(instance, scheduler: scheduler)
    }
}

/// Waits for a condition that the main thread's run loop brings about.
@MainActor
private func until(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

@Suite("The video format test set", .serialized)
struct VideoFormatTests {
    @Test("Every format AVFoundation writes gets thumbnails, read through the scheduler")
    func thumbnails() async throws {
        let fixture = try VideoFixture()
        for (index, format) in SyntheticVideo.Format.avFoundationSet.enumerated() {
            try await fixture.write("clip-\(index).\(format.fileExtension)", format: format)
        }
        let volume = try await fixture.index()
        let report = try await fixture.generator.runBackground(volume: volume)
        #expect(report.failed == 0)
        #expect(report.full == SyntheticVideo.Format.avFoundationSet.count)
        #expect(try await fixture.store.thumbnailBacklog(volume: volume) == 0)

        for (name, instance) in try await fixture.instances(volume) {
            let stored = try fixture.store.thumbnailLocationsBlocking(assets: [instance.assetID])[instance.assetID] ?? []
            let small = try #require(stored.first { $0.tier == .small }, "\(name)")
            #expect((small.width, small.height) == (320, 180), "\(name)")
        }
    }

    @Test("A video held upright has an upright thumbnail")
    func rotated() async throws {
        let fixture = try VideoFixture()
        var options = SyntheticVideo.Options()
        options.quarterTurns = 1
        try await fixture.write("upright.mov", format: .h264MOV, options: options)
        let volume = try await fixture.index()
        _ = try await fixture.generator.runBackground(volume: volume)
        let instance = try #require(try await fixture.instances(volume)["upright.mov"])
        let stored = try fixture.store.thumbnailLocationsBlocking(assets: [instance.assetID])[instance.assetID] ?? []
        let small = try #require(stored.first)
        #expect(small.height > small.width)
    }

    @Test("A format with no engine, and a file that can't be decoded, fail without trouble")
    func undecodable() async throws {
        let fixture = try VideoFixture()
        try Data(repeating: 7, count: 4096).write(to: fixture.media.appending(path: "other.mkv"))
        try SyntheticMedia.movie().write(to: fixture.media.appending(path: "empty.mp4"))
        let volume = try await fixture.index()
        let report = try await fixture.generator.runBackground(volume: volume)
        #expect(report.failed == 2)
        #expect(try await fixture.store.thumbnailBacklog(volume: volume) == 0)
    }

    @Test("A read that fails for the drive's sake leaves the video pending, not failed")
    func driveFailure() async throws {
        let fixture = try VideoFixture()
        try await fixture.write("clip.mp4", format: .h264MP4)
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)["clip.mp4"])
        let failing = try fixture.scheduler(volume) { operation, _ in operation == .read ? .fail(code: EIO) : nil }
        await #expect(throws: VolumeIOError.self) {
            _ = try await AVFoundationThumbnailer().poster(
                of: instance, scheduler: failing, priority: .visible, maxPixelSize: 320)
        }
        #expect(failing.statistics.openHandles == 0)
    }

    @Test("A file that changed since it was indexed isn't read as the old one")
    func changed() async throws {
        let fixture = try VideoFixture()
        try await fixture.write("clip.mp4", format: .h264MP4)
        let volume = try await fixture.index()
        var instance = try #require(try await fixture.instances(volume)["clip.mp4"])
        instance.size += 1
        await #expect(throws: VideoReadError.fileChanged) {
            _ = try await AVFoundationThumbnailer().poster(
                of: instance, scheduler: try fixture.scheduler(volume), priority: .visible, maxPixelSize: 320)
        }
    }

    @Test("Every format in the set plays, seeks and gives scrub previews", arguments: SyntheticVideo.Format.avFoundationSet)
    @MainActor
    func plays(format: SyntheticVideo.Format) async throws {
        let fixture = try VideoFixture()
        try await fixture.write("clip.\(format.fileExtension)", format: format)
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)["clip.\(format.fileExtension)"])
        let scheduler = try fixture.scheduler(volume)
        let engine = try #require(VideoEngines.standard.engine(for: format.fileExtension))
        let playback = engine.makePlayback(for: fixture.source(instance, scheduler: scheduler))
        defer { playback.close() }

        #expect(await until { playback.status != .loading })
        #expect(playback.status == .ready)
        #expect(abs(playback.duration - 2) < 0.1)

        playback.isMuted = true
        playback.play(rate: 1)
        #expect(await until { playback.currentTime > 0.3 })
        playback.pause()
        playback.seek(to: 1.5, exact: true)
        #expect(await until { abs(playback.currentTime - 1.5) < 0.05 })

        var preview: CGImage?
        playback.previewFrame(at: 0.5, maxPixelSize: 160) { image, _ in preview = image }
        #expect(await until { preview != nil })
        #expect(preview.map { max($0.width, $0.height) } == 160)
        #expect(scheduler.statistics.bytesRead > 0)
    }

    @Test("Closing a playback leaves no file open")
    @MainActor
    func closes() async throws {
        let fixture = try VideoFixture()
        try await fixture.write("clip.mov", format: .proRes422MOV)
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)["clip.mov"])
        let scheduler = try fixture.scheduler(volume)
        let playback = AVFoundationEngine().makePlayback(for: fixture.source(instance, scheduler: scheduler))
        #expect(await until { playback.status == .ready })
        playback.play(rate: 1)
        playback.close()
        #expect(await until { scheduler.statistics.openHandles == 0 })
    }

    @Test("A drive that fails during playback makes it unavailable, not unsupported")
    @MainActor
    func failsUnavailable() async throws {
        let fixture = try VideoFixture()
        try await fixture.write("clip.mp4", format: .h264MP4)
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)["clip.mp4"])
        let failing = try fixture.scheduler(volume) { operation, _ in operation == .open ? .fail(code: EIO) : nil }
        let playback = AVFoundationEngine().makePlayback(for: fixture.source(instance, scheduler: failing))
        defer { playback.close() }
        #expect(await until { playback.status != .loading })
        #expect(playback.status == .unavailable)
    }
}
