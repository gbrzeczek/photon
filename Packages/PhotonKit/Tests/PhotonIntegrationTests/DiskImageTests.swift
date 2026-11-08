import CryptoKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Synchronization
import Testing

/// Indexing on real exFAT volumes through FSKit, the same driver as the T7 Touch, with no real drive
/// anywhere near it. A forced detach shows what a process sees when a cable is pulled, though not a real
/// failure's delays. No physical pull is ever part of testing: see docs/PLAN.md, Removable media checks.
@Suite("exFAT disk images", .serialized, .timeLimit(.minutes(2)))
struct DiskImageTests {
    final class Fixture: Sendable {
        let directory: URL
        let store: LibraryStore
        let paths = PathRecorder()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "photon-images-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func image(name: String = "image", label: String, megabytes: Int = 64) throws -> DiskImage {
            try DiskImage.create(in: directory, name: name, label: label, megabytes: megabytes)
        }

        func indexer(configure: (inout IndexOptions) -> Void = { _ in }) -> LibraryIndexer {
            var options = IndexOptions()
            configure(&options)
            return LibraryIndexer(
                store: store, extractor: MediaMetadataReader(), options: options, observer: paths.record)
        }

        /// An indexer slow enough that a test can reliably act in the middle of its run.
        func slowIndexer(configure: (inout IndexOptions) -> Void = { _ in }) -> LibraryIndexer {
            var options = IndexOptions()
            options.batchSize = 16
            configure(&options)
            return LibraryIndexer(store: store, extractor: SlowExtractor(), options: options, observer: paths.record)
        }
    }

    /// Adds a few milliseconds per file, on the I/O thread, as a slower drive would.
    struct SlowExtractor: MetadataExtracting {
        func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
            Thread.sleep(forTimeInterval: 0.01)
            return try MediaMetadataReader().metadata(kind: kind, fileExtension: fileExtension, from: source)
        }
    }

    final class PathRecorder: Sendable {
        private let storage = Storage()
        let record: @Sendable (String) -> Void

        private final class Storage: Sendable { let paths = Mutex<Set<String>>([]) }

        init() {
            let storage = self.storage
            record = { path in
                if !path.hasSuffix("/") { _ = storage.paths.withLock { $0.insert(path) } }
            }
        }

        func take() -> Set<String> {
            storage.paths.withLock { paths in
                defer { paths.removeAll() }
                return paths
            }
        }
    }

    private func populate(_ mountPoint: String, count: Int, averageBytes: Int = 0, seed: UInt64 = 1) throws -> SyntheticLibrary.Manifest {
        var options = SyntheticLibrary.Options()
        options.fileCount = count
        options.averageBytes = averageBytes
        options.seed = seed
        options.filesPerFolder = 50
        return try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: mountPoint))
    }

    /// Every path on a volume, including hidden ones, with its size.
    private func inventory(_ mountPoint: String) -> [String: Int] {
        var result: [String: Int] = [:]
        let root = URL(fileURLWithPath: mountPoint)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [])
        while let url = walker?.nextObject() as? URL {
            result[url.path] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return result
    }

    private func sha256(_ url: URL) throws -> Data {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    @Test("The image really is exFAT through FSKit, like the T7 Touch")
    func imageMatchesTheDrive() throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONFS")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let volume = try MountedVolume.containing(path: mountPoint).volume
        #expect(volume.filesystem == "exfat")
        #expect(volume.location == .diskImage)
        #expect(!volume.isReadOnly)
        #expect(!volume.uuid.isEmpty)
    }

    @Test("Indexes a library, then rescans touch only what changed")
    func rescansTouchOnlyChanges() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONSCAN")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let manifest = try populate(mountPoint, count: 300, averageBytes: 40_000)
        let indexer = fixture.indexer()

        let first = try await indexer.index(path: mountPoint)
        #expect(first.outcome == .completed)
        #expect(first.isNewVolume)
        #expect(first.scan.added == 300)
        #expect(first.processed == 300)
        #expect(first.failed == 0)
        #expect(try await fixture.store.assetCount() == manifest.uniqueContent)
        _ = fixture.paths.take()

        let quiet = try await indexer.index(path: mountPoint)
        #expect(quiet.scan.unchanged == 300)
        #expect(quiet.processed == 0)
        #expect(fixture.paths.take().isEmpty)

        let base = URL(fileURLWithPath: mountPoint)
        let photos = manifest.files.filter { $0.hasSuffix(".JPG") && !$0.contains("COPY") }
        let (edited, deleted, moved) = (photos[3], photos[5], photos[7])
        let handle = try FileHandle(forWritingTo: base.appending(path: edited))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended".utf8))
        try handle.close()
        try FileManager.default.removeItem(at: base.appending(path: deleted))
        let movedTarget = "DCIM/MOVED/renamed.JPG"
        try FileManager.default.createDirectory(
            at: base.appending(path: "DCIM/MOVED"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: base.appending(path: moved), to: base.appending(path: movedTarget))
        try SyntheticMedia.jpeg()?.write(to: base.appending(path: "DCIM/new.JPG"))

        let changed = try await indexer.index(path: mountPoint)

        #expect(changed.scan.modified == 1)
        #expect(changed.scan.added == 2)
        #expect(changed.scan.removed == 2)
        #expect(changed.scan.unchanged == 297)
        #expect(fixture.paths.take() == [edited, movedTarget, "DCIM/new.JPG"])
    }

    @Test("Metadata from real files on exFAT reaches the library")
    func metadataReachesTheLibrary() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONMETA")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        var options = SyntheticMedia.ImageOptions()
        options.width = 200
        options.height = 100
        options.captureDate = "2024:06:15 13:45:30"
        try SyntheticMedia.jpeg(options)?.write(to: URL(fileURLWithPath: mountPoint + "/photo.JPG"))
        try SyntheticMedia.movie().write(to: URL(fileURLWithPath: mountPoint + "/video.MP4"))

        let report = try await fixture.indexer().index(path: mountPoint)

        let volume = try #require(report.volumeID)
        let photo = try #require(
            try await fixture.store.instance(volume: volume, path: RelativePath(directory: "", name: "photo.JPG")))
        let video = try #require(
            try await fixture.store.instance(volume: volume, path: RelativePath(directory: "", name: "video.MP4")))
        let photoAsset = try #require(try await fixture.store.asset(photo.assetID))
        let videoAsset = try #require(try await fixture.store.asset(video.assetID))
        #expect(photoAsset.kind == .photo)
        #expect(photoAsset.metadata.pixelWidth == 200)
        #expect(photoAsset.metadata.captureDate?.wallClockMilliseconds == 1_718_459_130_000)
        #expect(videoAsset.kind == .video)
        #expect(videoAsset.metadata.durationSeconds == 10)
    }

    @Test("Nothing is written to the volume: a writable mount keeps the same files")
    func writesNothingToAWritableVolume() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONWRITE")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 60)
        let before = inventory(mountPoint)

        let report = try await fixture.indexer().index(path: mountPoint)

        #expect(report.outcome == .completed)
        #expect(inventory(mountPoint) == before)
    }

    @Test("A read-only mount indexes fully, and the image stays identical to the byte")
    func readOnlyMount() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONRO")
        defer { image.ensureDetached() }
        let writable = try image.attach()
        let manifest = try populate(writable, count: 80)
        try image.detach()
        let before = try sha256(image.url)

        let mountPoint = try image.attach(readOnly: true)
        let volume = try MountedVolume.containing(path: mountPoint).volume
        #expect(volume.isReadOnly)

        let report = try await fixture.indexer().index(path: mountPoint)

        #expect(report.outcome == .completed)
        #expect(report.processed == manifest.files.count)
        #expect(report.failed == 0)
        try image.detach()
        #expect(try sha256(image.url) == before)
    }

    @Test("The library can't live on the volume being indexed")
    func refusesLibraryOnScannedVolume() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONLIB")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let store = try LibraryStore(url: URL(fileURLWithPath: mountPoint + "/lib/Library.sqlite"))
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        await #expect(throws: IndexingError.libraryOnScannedVolume) { _ = try await indexer.index(path: mountPoint) }
    }

    @Test("A remount at a different path is the same volume, and nothing is read again")
    func remountAtNewPath() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONMOVE")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 40)
        let indexer = fixture.indexer()
        let first = try await indexer.index(path: mountPoint)
        try image.detach()
        indexer.volumeDidUnmount(mountPoint: mountPoint)
        _ = fixture.paths.take()

        let other = try image.attach(mountPoint: fixture.directory.appending(path: "elsewhere"))
        #expect(other != mountPoint)
        let second = try await indexer.index(path: other)

        #expect(second.volumeID == first.volumeID)
        #expect(!second.isNewVolume)
        #expect(second.scan.unchanged == 40)
        #expect(second.processed == 0)
        #expect(fixture.paths.take().isEmpty)
    }

    @Test("A clone mounted alone is the same volume, and its files don't count as new")
    func cloneAlone() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONCLONE")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 30)
        let indexer = fixture.indexer()
        let first = try await indexer.index(path: mountPoint)
        try image.detach()
        indexer.volumeDidUnmount(mountPoint: mountPoint)

        let clone = try image.clone(to: fixture.directory.appending(path: "clone.dmg"))
        defer { clone.ensureDetached() }
        let cloneMount = try clone.attach()
        let second = try await indexer.index(path: cloneMount)
        #expect(second.volumeID == first.volumeID)
        #expect(second.processed == 0)
    }

    @Test("A clone mounted beside its original stays apart from it")
    func cloneTogether() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONTWIN")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 10)
        try image.detach()
        let clone = try image.clone(to: fixture.directory.appending(path: "twin.dmg"))
        defer { clone.ensureDetached() }

        let original = try image.attach()
        let twin = try clone.attach(mountPoint: fixture.directory.appending(path: "twin"))
        let first = try MountedVolume.containing(path: original).volume
        let second = try MountedVolume.containing(path: twin).volume
        #expect(first.uuid == second.uuid)
        #expect(first.bsdName != second.bsdName)

        let indexer = fixture.indexer()
        let report = try await indexer.index(path: original)
        let id = try #require(report.volumeID)
        await #expect(throws: IndexingError.duplicateVolume(id)) { _ = try await indexer.index(path: twin) }
        #expect(try await fixture.store.allVolumes().count == 1)
    }

    @Test("A clone that has diverged gets its own row, and shared content keeps one asset")
    func divergedClone() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONDIV")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let manifest = try populate(mountPoint, count: 20)
        let indexer = fixture.indexer()
        let first = try await indexer.index(path: mountPoint)
        try image.detach()
        indexer.volumeDidUnmount(mountPoint: mountPoint)

        let clone = try image.clone(to: fixture.directory.appending(path: "diverged.dmg"))
        defer { clone.ensureDetached() }
        let cloneMount = try clone.attach()
        // Rearranging every file means the sample no longer matches by path.
        let base = URL(fileURLWithPath: cloneMount)
        try FileManager.default.moveItem(at: base.appending(path: "DCIM"), to: base.appending(path: "Rearranged"))

        let second = try await indexer.index(path: cloneMount)

        #expect(second.isNewVolume)
        #expect(second.volumeID != first.volumeID)
        #expect(second.identity.merged == 20)
        #expect(try await fixture.store.assetCount() == manifest.uniqueContent)
    }

    @Test("Favorites follow their content to a new drive")
    func favoritesMoveToANewDrive() async throws {
        let fixture = try Fixture()
        let oldDrive = try fixture.image(name: "old", label: "PHOTONOLD")
        let newDrive = try fixture.image(name: "new", label: "PHOTONNEW")
        defer {
            oldDrive.ensureDetached()
            newDrive.ensureDetached()
        }
        let oldMount = try oldDrive.attach()
        let manifest = try populate(oldMount, count: 12, averageBytes: 100_000)
        let indexer = fixture.indexer()
        let report = try await indexer.index(path: oldMount)
        let volume = try #require(report.volumeID)
        let path = try #require(RelativePath(string: manifest.files[2]))
        let original = try #require(try await fixture.store.instance(volume: volume, path: path))

        let newMount = try newDrive.attach()
        let target = URL(fileURLWithPath: newMount + "/Archive/2024")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in manifest.files {
            let source = URL(fileURLWithPath: oldMount).appending(path: file)
            try FileManager.default.copyItem(at: source, to: target.appending(path: source.lastPathComponent))
        }
        let moved = try await indexer.index(path: newMount)

        #expect(moved.isNewVolume)
        #expect(moved.volumeID != report.volumeID)
        let newVolume = try #require(moved.volumeID)
        let copy = try #require(
            try await fixture.store.instance(
                volume: newVolume, path: RelativePath(directory: "Archive/2024", name: path.name)))
        #expect(copy.assetID == original.assetID)
    }

    @Test("Pulling the drive mid-read stops the run calmly, and the next mount finishes the job")
    func forcedDetach() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONPULL")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 600)
        try image.detach()
        let mounted = try image.attach()

        let store = fixture.store
        let indexer = fixture.slowIndexer()
        let run = Task { try await indexer.index(path: mounted) }
        #expect(
            try await waitFor {
                let summary = try await store.volumeSummaries().first
                return (summary?.fileCount ?? 0) == 600 && (summary?.pendingCount ?? 600) < 590
            })
        try image.detach(force: true)

        let report = try await run.value
        #expect(report.outcome == .volumeOffline)
        let summary = try #require(try await store.volumeSummaries().first)
        #expect(summary.failedCount == 0)
        #expect(summary.fileCount == 600)
        #expect(summary.pendingCount > 0)

        let remounted = try image.attach()
        let resumed = try await indexer.index(path: remounted)
        #expect(resumed.outcome == .completed)
        #expect(resumed.volumeID == report.volumeID)
        #expect(resumed.scan.added == 0)
        #expect(try await store.volumeSummaries().first?.pendingCount == 0)
        #expect(try await store.volumeSummaries().first?.failedCount == 0)
    }

    @Test("A rescan after the drive has gone forgets nothing, and doesn't invent a new volume")
    func rescanOfGoneDrive() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONGONE")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 20)
        let mount = try MountedVolume.containing(path: mountPoint).volume
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: mountPoint)
        let before = try await fixture.store.volumeSummaries()

        try image.detach(force: true)

        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await indexer.rescan(mount: mount) }
        #expect(try await fixture.store.volumeSummaries() == before)
    }

    @Test("On willUnmount every handle closes, so a normal eject succeeds during a run")
    func ejectDuringRun() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONEJECT")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        _ = try populate(mountPoint, count: 400)
        try image.detach()
        let mounted = try image.attach()

        let store = fixture.store
        let indexer = fixture.slowIndexer()
        let run = Task { try await indexer.index(path: mounted) }
        #expect(
            try await waitFor {
                let summary = try await store.volumeSummaries().first
                return (summary?.pendingCount ?? 0) > 0 && (summary?.pendingCount ?? 0) < 390
            })

        indexer.volumeWillUnmount(mountPoint: mounted)
        try await Task.sleep(for: .milliseconds(100))
        // With no force: this fails if anything is still open.
        try image.detach()
        indexer.volumeDidUnmount(mountPoint: mounted)

        let report = try await run.value
        #expect(report.outcome == .volumeOffline)
    }

    @Test("A refused unmount is a false alarm, and work carries on")
    func refusedUnmount() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONBUSY")
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let manifest = try populate(mountPoint, count: 300)
        try image.detach()
        let mounted = try image.attach()

        // Another app holds a file open, so the unmount below can't succeed.
        let holder = try FileHandle(forReadingFrom: URL(fileURLWithPath: mounted).appending(path: manifest.files[0]))
        defer { try? holder.close() }

        let store = fixture.store
        let indexer = fixture.slowIndexer { $0.unmountGracePeriod = .milliseconds(500) }
        let run = Task { try await indexer.index(path: mounted) }
        #expect(
            try await waitFor {
                let summary = try await store.volumeSummaries().first
                return (summary?.pendingCount ?? 0) > 0 && (summary?.pendingCount ?? 0) < 290
            })

        indexer.volumeWillUnmount(mountPoint: mounted)
        #expect(throws: (any Error).self) { try image.detach() }

        let report = try await run.value
        #expect(report.outcome == .completed)
        #expect(try await store.volumeSummaries().first?.pendingCount == 0)
    }

    private func waitFor(_ condition: @Sendable () async throws -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
