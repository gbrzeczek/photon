import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import PhotonVideo
import Testing

/// Video on an exFAT disk image, through the same FSKit driver as the real drive. AVFoundation reads
/// through the volume's scheduler, so a forced detach must leave no handle open and fail calmly.
@Suite("Video on removable media", .serialized, .usesDiskImages, .timeLimit(.minutes(5)))
struct VideoRemovableMediaTests {
    private final class Fixture: Sendable {
        let directory: URL
        let store: LibraryStore
        let indexer: LibraryIndexer

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "photon-video-removable-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
            indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// An image holding real videos, attached read-only, as the drive is.
        func image(formats: [SyntheticVideo.Format]) async throws -> (DiskImage, String) {
            // Written on the internal disk and copied over, because the writer can hold its file for a
            // moment after it finishes, which keeps the image from detaching.
            let staging = directory.appending(path: "staging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var options = SyntheticVideo.Options()
            options.seconds = 3
            for (index, format) in formats.enumerated() {
                try await SyntheticVideo.write(
                    to: staging.appending(path: "clip-\(index).\(format.fileExtension)"), format: format,
                    options: options)
            }
            let image = try DiskImage.create(in: directory, label: "PHOTONVIDEO", megabytes: 64)
            do {
                let mount = try image.attach()
                for name in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
                    try FileManager.default.copyItem(
                        at: staging.appending(path: name), to: URL(fileURLWithPath: mount).appending(path: name))
                }
                try image.detach()
                return (image, try image.attach(readOnly: true))
            } catch {
                image.ensureDetached()
                throw error
            }
        }

        func instance(_ volume: VolumeID, named name: String) async throws -> FileInstance {
            let path = try await store.roots(volume: volume).first?.relativePath ?? ""
            let result = try await store.browse(
                BrowseScope(volume: volume, path: path), sort: BrowseSort(key: .name, ascending: true))
            let row = try #require(try await store.browseRows(instances: result.instanceIDs).first { $0.path.name == name })
            return try #require(try await store.thumbnailJob(asset: row.assetID, instance: row.instanceID)?.instance)
        }
    }

    @MainActor
    private func until(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("Videos get thumbnails from a read-only exFAT image, and the image stays unchanged")
    func thumbnails() async throws {
        let fixture = try Fixture()
        let (image, mount) = try await fixture.image(formats: [.h264MP4, .hevcMOV, .proRes422MOV])
        defer { image.ensureDetached() }
        let before = try Data(contentsOf: image.url)
        let volume = try #require(try await fixture.indexer.index(path: mount).volumeID)
        let indexer = fixture.indexer
        let generator = ThumbnailGenerator(
            store: fixture.store, packs: ThumbnailPackStore(store: fixture.store),
            scheduler: { indexer.scheduler(for: $0) }, video: AVFoundationThumbnailer())
        let report = try await generator.runBackground(volume: volume)
        #expect(report.full == 3)
        #expect(report.failed == 0)
        #expect(indexer.scheduler(for: volume)?.statistics.openHandles == 0)
        try image.detach()
        #expect(try Data(contentsOf: image.url) == before)
    }

    @Test("A forced detach during playback closes every handle, and the video plays again after a reattach")
    @MainActor
    func detachDuringPlayback() async throws {
        let fixture = try Fixture()
        let (image, mount) = try await fixture.image(formats: [.h264MP4])
        defer { image.ensureDetached() }
        let indexer = fixture.indexer
        let volume = try #require(try await indexer.index(path: mount).volumeID)
        let instance = try await fixture.instance(volume, named: "clip-0.mp4")
        let scheduler = try #require(indexer.scheduler(for: volume))

        let playback = AVFoundationEngine().makePlayback(for: VideoSource(instance, scheduler: scheduler))
        defer { playback.close() }
        #expect(await until { playback.status == .ready })
        playback.isMuted = true
        playback.play(rate: 1)

        indexer.volumeWillUnmount(mountPoint: mount)
        #expect(await until { scheduler.statistics.openHandles == 0 })
        try image.detach(force: true)
        indexer.volumeDidUnmount(mountPoint: mount)
        #expect(indexer.scheduler(for: volume) == nil)

        // What's buffered may still play, but anything new can't be read, and says why.
        let stale = AVFoundationEngine().makePlayback(for: VideoSource(instance, scheduler: scheduler))
        defer { stale.close() }
        #expect(await until { stale.status != .loading })
        #expect(stale.status == .unavailable)

        _ = try image.attach(readOnly: true)
        _ = try await indexer.connectKnownVolumes()
        let fresh = try #require(indexer.scheduler(for: volume))
        let again = AVFoundationEngine().makePlayback(for: VideoSource(instance, scheduler: fresh))
        defer { again.close() }
        #expect(await until { again.status == .ready })
        again.seek(to: 2, exact: true)
        #expect(await until { abs(again.currentTime - 2) < 0.05 })
    }
}
