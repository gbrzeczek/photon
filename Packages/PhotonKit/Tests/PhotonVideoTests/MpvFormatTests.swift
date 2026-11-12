import AppKit
import CoreGraphics
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

@testable import PhotonVideo

/// The fallback's clips in a folder on the internal disk, indexed with FFmpeg's metadata, with
/// thumbnails made through the scheduler.
private final class FallbackFixture: Sendable {
    let directory: URL
    let media: URL
    let store: LibraryStore
    let indexer: LibraryIndexer
    let generator: ThumbnailGenerator

    init(clips: [FallbackClip] = FallbackClip.allCases) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "photon-mpv-\(UUID().uuidString)")
        media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for clip in clips { try clip.copy(to: media) }
        store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: StandardMetadataReader())
        self.indexer = indexer
        generator = ThumbnailGenerator(
            store: store, packs: ThumbnailPackStore(store: store), scheduler: { indexer.scheduler(for: $0) },
            video: StandardVideoThumbnailer())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

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

    func scheduler(_ volume: VolumeID, faults: IOFaultInjector? = nil) throws -> VolumeIOScheduler {
        VolumeIOScheduler(mountPoint: try #require(indexer.mountPoint(of: volume)), faults: faults)
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

/// The fallback's half of Milestone 6's format test set. Skipped when this checkout has no libmpv:
/// `scripts/mpv/build.sh` makes it.
@Suite("The fallback's format test set", .serialized, .enabled(if: MpvEngine.isAvailable, "No libmpv. Run scripts/mpv/build.sh"))
struct MpvFormatTests {
    @Test("The libmpv this checkout carries is Photon's LGPL build")
    func library() throws {
        let library = try #require(MpvLibrary.shared)
        #expect(library.clientAPIVersion >= MpvLibrary.minimumAPI)
    }

    @Test("Every container gets its duration, dimensions and date from FFmpeg, through the scheduler")
    func metadata() async throws {
        let fixture = try FallbackFixture()
        let volume = try await fixture.index()
        let instances = try await fixture.instances(volume)
        #expect(instances.count == FallbackClip.allCases.count)
        for clip in FallbackClip.playable {
            let instance = try #require(instances[clip.fileName], "\(clip)")
            let asset = try #require(try await fixture.store.asset(instance.assetID), "\(clip)")
            let duration = try #require(asset.metadata.durationSeconds, "\(clip)")
            #expect(abs(duration - clip.seconds) < 0.15, "\(clip): \(duration)")
            let width = try #require(asset.metadata.pixelWidth, "\(clip)")
            let height = try #require(asset.metadata.pixelHeight, "\(clip)")
            let expected = clip.displaySize
            #expect(abs(Double(width) / Double(height) - Double(expected.width) / Double(expected.height)) < 0.03,
                "\(clip): \(width)x\(height)")
        }
        let dated = try #require(instances[FallbackClip.h264MKV.fileName])
        let asset = try #require(try await fixture.store.asset(dated.assetID))
        #expect(asset.metadata.captureDate?.wallClockMilliseconds == 1_714_566_600_000)
    }

    @Test("Every format with a picture gets thumbnails, and sound alone fails without trouble")
    func thumbnails() async throws {
        let fixture = try FallbackFixture()
        let volume = try await fixture.index()
        let report = try await fixture.generator.runBackground(volume: volume)
        // `full` counts every full pass, including the one that failed.
        #expect(report.full == FallbackClip.allCases.count)
        #expect(report.failed == 1)
        #expect(try await fixture.store.thumbnailBacklog(volume: volume) == 0)
        #expect(fixture.indexer.scheduler(for: volume)?.statistics.openHandles == 0)

        let instances = try await fixture.instances(volume)
        for clip in FallbackClip.playable {
            let instance = try #require(instances[clip.fileName], "\(clip)")
            let stored = try fixture.store.thumbnailLocationsBlocking(assets: [instance.assetID])[instance.assetID] ?? []
            let small = try #require(stored.first { $0.tier == .small }, "\(clip)")
            let expected = clip.displaySize
            let scale = min(1, 320 / Double(max(expected.width, expected.height)))
            #expect(abs(small.width - Int(Double(expected.width) * scale)) <= 1, "\(clip): \(small.width)")
            #expect(abs(small.height - Int(Double(expected.height) * scale)) <= 1, "\(clip): \(small.height)")
        }
    }

    @Test("A poster frame has a picture in it, not black")
    func posterHasContent() async throws {
        let fixture = try FallbackFixture(clips: [.vp9WebM])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.vp9WebM.fileName])
        let image = try #require(
            try await MpvThumbnailer().poster(
                of: instance, scheduler: try fixture.scheduler(volume), priority: .visible, maxPixelSize: 320))
        #expect((image.width, image.height) == (320, 240))
        #expect(Self.brightness(image) > 0.15)
    }

    @Test("A read that fails for the drive's sake leaves the video pending, not failed")
    func driveFailure() async throws {
        let fixture = try FallbackFixture(clips: [.h264MKV])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.h264MKV.fileName])
        let failing = try fixture.scheduler(volume) { operation, _ in operation == .read ? .fail(code: EIO) : nil }
        await #expect(throws: VolumeIOError.self) {
            _ = try await MpvThumbnailer().poster(of: instance, scheduler: failing, priority: .visible, maxPixelSize: 320)
        }
        #expect(failing.statistics.openHandles == 0)
    }

    @Test("A file that changed since it was indexed isn't read as the old one")
    func changed() async throws {
        let fixture = try FallbackFixture(clips: [.mpeg4AVI])
        let volume = try await fixture.index()
        var instance = try #require(try await fixture.instances(volume)[FallbackClip.mpeg4AVI.fileName])
        instance.size += 1
        await #expect(throws: VideoReadError.fileChanged) {
            _ = try await MpvThumbnailer().poster(
                of: instance, scheduler: try fixture.scheduler(volume), priority: .visible, maxPixelSize: 320)
        }
    }

    @Test("Cancelling a thumbnail stops its reads at once")
    func cancels() async throws {
        let fixture = try FallbackFixture(clips: [.wmv2WMV])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.wmv2WMV.fileName])
        // Every read waits, so the thumbnail can't finish before it's cancelled.
        let stalling = try fixture.scheduler(volume) { operation, _ in operation == .read ? .stall(.seconds(1)) : nil }
        let task = Task {
            try await MpvThumbnailer().poster(of: instance, scheduler: stalling, priority: .visible, maxPixelSize: 320)
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(stalling.statistics.openHandles == 0)
    }

    @Test("Every format with a picture plays, seeks and gives scrub previews", arguments: FallbackClip.playable)
    @MainActor
    func plays(clip: FallbackClip) async throws {
        let fixture = try FallbackFixture(clips: [clip])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[clip.fileName])
        let scheduler = try fixture.scheduler(volume)
        // mpv is the engine for the format, or the one tried after AVFoundation says it can't decode it.
        let engine = try #require(VideoEngines.standard.candidates(for: clip.fileExtension).last)
        #expect(engine is MpvEngine)
        let playback = engine.makePlayback(for: VideoSource(instance, scheduler: scheduler))
        defer { playback.close() }
        // In a window, as in the viewer. Core Animation draws a layer only once it's in one.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        window.contentView = host
        playback.layer.frame = host.bounds
        host.layer?.addSublayer(playback.layer)

        #expect(await until { playback.status != .loading })
        #expect(playback.status == .ready)
        #expect(abs(playback.duration - clip.seconds) < 0.15)
        // The layer shows only once mpv has drawn a frame into it, so the viewer never flashes black.
        #expect(await until { playback.isShowingFrame })

        playback.isMuted = true
        playback.play(rate: 1)
        #expect(await until { playback.currentTime > min(0.3, clip.seconds / 3) })
        #expect(playback.rate == 1)
        playback.pause()
        #expect(await until { playback.rate == 0 })

        let target = clip.seconds * 0.6
        var landed: Bool?
        playback.seek(to: target, exact: true) { landed = $0 }
        #expect(await until { landed != nil })
        #expect(landed == true)
        #expect(await until { abs(playback.currentTime - target) < 0.05 }, "\(playback.currentTime) for \(target), duration \(playback.duration)")

        var preview: CGImage?
        playback.previewFrame(at: clip.seconds / 4, maxPixelSize: 160) { image, _ in preview = image }
        #expect(await until { preview != nil })
        #expect(preview.map { max($0.width, $0.height) } == 160)
        #expect(scheduler.statistics.bytesRead > 0)
    }

    @Test("Sound with no picture is unsupported, because mpv would play the sound and say nothing")
    @MainActor
    func audioOnly() async throws {
        let fixture = try FallbackFixture(clips: [.audioOnlyMKV])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.audioOnlyMKV.fileName])
        let playback = MpvEngine().makePlayback(for: VideoSource(instance, scheduler: try fixture.scheduler(volume)))
        defer { playback.close() }
        #expect(await until { playback.status != .loading })
        #expect(playback.status == .unsupported)
    }

    @Test("Playing to the end stops on the last frame, and playing again starts over")
    @MainActor
    func end() async throws {
        let fixture = try FallbackFixture(clips: [.vp8WebM])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.vp8WebM.fileName])
        let playback = MpvEngine().makePlayback(for: VideoSource(instance, scheduler: try fixture.scheduler(volume)))
        defer { playback.close() }
        #expect(await until { playback.status == .ready })
        playback.isMuted = true
        playback.seek(to: 1.7, exact: true)
        playback.play(rate: 2)
        #expect(await until { playback.rate == 0 })
        #expect(playback.currentTime > 1.8)
        playback.play(rate: 1)
        #expect(await until { playback.currentTime < 1 && playback.rate == 1 })
    }

    @Test("Closing a playback leaves no file open")
    @MainActor
    func closes() async throws {
        let fixture = try FallbackFixture(clips: [.h264MKV])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.h264MKV.fileName])
        let scheduler = try fixture.scheduler(volume)
        let playback = MpvEngine().makePlayback(for: VideoSource(instance, scheduler: scheduler))
        #expect(await until { playback.status == .ready })
        playback.isMuted = true
        playback.play(rate: 1)
        playback.close()
        #expect(await until { scheduler.statistics.openHandles == 0 })
    }

    @Test("A drive that fails during playback makes it unavailable, not unsupported")
    @MainActor
    func failsUnavailable() async throws {
        let fixture = try FallbackFixture(clips: [.h264MKV])
        let volume = try await fixture.index()
        let instance = try #require(try await fixture.instances(volume)[FallbackClip.h264MKV.fileName])
        let failing = try fixture.scheduler(volume) { operation, _ in operation == .open ? .fail(code: EIO) : nil }
        let playback = MpvEngine().makePlayback(for: VideoSource(instance, scheduler: failing))
        defer { playback.close() }
        #expect(await until { playback.status != .loading })
        #expect(playback.status == .unavailable)
    }

    @Test("mpv is told to keep to the one file it's given")
    func isolation() throws {
        let options = Dictionary(MpvCore.isolation, uniquingKeysWith: { first, _ in first })
        for (name, value) in [
            ("sub-auto", "no"), ("audio-file-auto", "no"), ("cover-art-auto", "no"), ("access-references", "no"),
            ("ordered-chapters", "no"), ("config", "no"),
        ] {
            #expect(options[name] == value, "\(name)")
        }
        // Every one of them is an option this build knows, so none is silently left out.
        let api = try #require(MpvLibrary.shared)
        for (name, value) in MpvCore.isolation {
            let handle = try #require(api.create())
            defer { api.terminateDestroy(handle) }
            #expect(api.setOptionString(handle, name, value) >= 0, "\(name)")
        }
    }

    /// Mean brightness from 0 to 1.
    private static func brightness(_ image: CGImage) -> Double {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
        }
        return sum / Double(width * height * 3 * 255)
    }
}
