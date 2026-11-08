import AppKit
import CryptoKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Synchronization
import Testing

/// Mount handling on exFAT disk images, through the same FSKit driver as the real drive. These stand in
/// for a physical check, which isn't done, by the user's decision: see docs/PLAN.md, Removable media checks.
///
/// Eject here acts on images this test created, through the same code as the app's command.
@Suite("Removable media on disk images", .serialized, .timeLimit(.minutes(2)))
struct RemovableMediaTests {
    final class Fixture: Sendable {
        let directory: URL
        let store: LibraryStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "photon-removable-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func image(name: String = "image", label: String, count: Int) throws -> DiskImage {
            let image = try DiskImage.create(in: directory, name: name, label: label, megabytes: 64)
            let mount = try image.attach()
            var options = SyntheticLibrary.Options()
            options.fileCount = count
            options.duplicateInterval = 0
            options.filesPerFolder = 50
            _ = try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: mount))
            try image.detach()
            return image
        }

        func indexer(configure: (inout IndexOptions) -> Void = { _ in }) -> LibraryIndexer {
            var options = IndexOptions()
            configure(&options)
            return LibraryIndexer(store: store, extractor: MediaMetadataReader(), options: options)
        }
    }

    /// Slow enough that a test can act in the middle of a run.
    struct SlowExtractor: MetadataExtracting {
        func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
            Thread.sleep(forTimeInterval: 0.01)
            return try MediaMetadataReader().metadata(kind: kind, fileExtension: fileExtension, from: source)
        }
    }

    final class Counter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    private func waitFor(seconds: Int = 30, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while clock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func sha256(_ url: URL) throws -> Data {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    @Test("A forced detach and a reattach bring the same volume back, reading no file")
    func reconnect() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONBACK", count: 30)
        defer { image.ensureDetached() }
        let opened = Counter()
        let mountPoint = try image.attach(readOnly: true)
        let indexer = LibraryIndexer(
            store: fixture.store, extractor: MediaMetadataReader(),
            observer: { path in if !path.hasSuffix("/") { opened.add() } })
        let report = try await indexer.index(path: mountPoint)
        let volume = try #require(report.volumeID)
        #expect(indexer.access(to: volume) == .readOnly)

        try image.detach(force: true)
        indexer.volumeDidUnmount(mountPoint: mountPoint)
        #expect(try await waitFor { indexer.access(to: volume) == .offline })
        #expect(indexer.scheduler(for: volume) == nil)
        // Offline is a normal state, so nothing about the library changed.
        #expect(try await fixture.store.volumeSummaries().first?.fileCount == 30)

        let before = opened.count
        let remounted = try image.attach(readOnly: true)
        let connected = try await indexer.connectKnownVolumes()

        #expect(connected.connections.map(\.volume) == [volume])
        #expect(connected.connections.first?.isNew == true)
        #expect(indexer.access(to: volume) == .readOnly)
        let rescan = try await indexer.rescan(mount: try #require(connected.connections.first?.mount))
        #expect(rescan.scan.unchanged == 30)
        #expect(rescan.processed == 0)
        #expect(opened.count == before)
        #expect(indexer.mountPoint(of: volume) == remounted)

        let again = try await indexer.connectKnownVolumes()
        #expect(again.connections.first?.isNew == false)
    }

    @Test("Files that changed while the drive was away are found by the rescan")
    func changesWhileAway() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONAWAY", count: 20)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: mountPoint)
        try image.detach(force: true)
        indexer.volumeDidUnmount(mountPoint: mountPoint)

        // Changed elsewhere, as another computer might.
        let elsewhere = try image.attach()
        try SyntheticMedia.jpeg()?.write(to: URL(fileURLWithPath: elsewhere + "/new.JPG"))
        try image.detach()

        _ = try image.attach()
        let mount = try #require(try await indexer.connectKnownVolumes().connections.first?.mount)
        let rescan = try await indexer.rescan(mount: mount)
        #expect(rescan.scan.added == 1)
        #expect(rescan.scan.unchanged == 20)
    }

    @Test("A mount lost with no notification is found by the next read, and the library hears about it")
    func lostWithoutNotification() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONLOST", count: 10)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let indexer = fixture.indexer()
        let changes = Counter()
        indexer.setChangeHandler { changes.add() }
        let report = try await indexer.index(path: mountPoint)
        let volume = try #require(report.volumeID)
        let scheduler = try #require(indexer.scheduler(for: volume))

        try image.detach(force: true)
        await #expect(throws: VolumeIOError.volumeUnavailable) {
            _ = try await scheduler.listDirectory("", priority: .visible)
        }

        #expect(indexer.access(to: volume) == .offline)
        #expect(indexer.onlineVolumes().isEmpty)
        #expect(changes.count > 0)
    }

    @Test("The system's own events arrive for a disk image, forced detach included")
    func realNotifications() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONNOTE", count: 2)
        defer { image.ensureDetached() }
        final class Box: Sendable { let events = Mutex<Set<String>>([]) }
        let box = Box()
        let monitor = VolumeEventMonitor(
            center: NSWorkspace.shared.notificationCenter,
            willUnmount: { _ in box.events.withLock { _ = $0.insert("will") } },
            didUnmount: { _ in box.events.withLock { _ = $0.insert("did") } },
            didMount: { _ in box.events.withLock { _ = $0.insert("mount") } })
        _ = try image.attach()
        #expect(try await waitFor(seconds: 10) { box.events.withLock { $0.contains("mount") } })
        try image.detach(force: true)
        #expect(try await waitFor(seconds: 10) { box.events.withLock { $0.isSuperset(of: ["will", "did"]) } })
        withExtendedLifetime(monitor) {}
    }

    @Test("Ejecting a disk image during a run closes everything, and the image detaches")
    func ejectDuringRun() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONOUT", count: 300)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let store = fixture.store
        var options = IndexOptions()
        options.batchSize = 16
        let indexer = LibraryIndexer(store: store, extractor: SlowExtractor(), options: options)
        let run = Task { try await indexer.index(path: mountPoint) }
        #expect(
            try await waitFor {
                let summary = try await store.volumeSummaries().first
                return (summary?.pendingCount ?? 0) > 0 && (summary?.pendingCount ?? 0) < 290
            })
        let volume = try #require(try await store.volumeSummaries().first?.volume.id)

        try await indexer.eject(volume, using: VolumeEjector())

        #expect(!image.isAttached)
        #expect(indexer.access(to: volume) == .offline)
        let report = try await run.value
        #expect(report.outcome == .volumeOffline)
        #expect(try await store.volumeSummaries().first?.failedCount == 0)

        _ = try image.attach()
        let mount = try #require(try await indexer.connectKnownVolumes().connections.first?.mount)
        #expect(try await indexer.rescan(mount: mount).outcome == .completed)
        #expect(try await store.volumeSummaries().first?.pendingCount == 0)
    }

    @Test("An eject another app refuses leaves everything as it was, and work resumes")
    func refusedEject() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONHOLD", count: 10)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let indexer = fixture.indexer()
        let volume = try #require(try await indexer.index(path: mountPoint).volumeID)
        let held = try #require(FileManager.default.enumerator(atPath: mountPoint)?.compactMap { $0 as? String }
            .first { $0.hasSuffix(".JPG") })
        let holder = try FileHandle(forReadingFrom: URL(fileURLWithPath: mountPoint).appending(path: held))
        defer { try? holder.close() }

        await #expect(throws: EjectError.self) { try await indexer.eject(volume, using: VolumeEjector()) }

        #expect(image.isAttached)
        #expect(indexer.access(to: volume) == .writable)
        #expect(indexer.scheduler(for: volume) != nil)
    }

    @Test("Eject stays away from anything that isn't this run's disk image")
    func ejectScope() throws {
        let ejector = VolumeEjector()
        for mount in MountedVolume.all() where mount.location != .diskImage {
            #expect(!ejector.canEject(mount))
        }
    }

    @Test("A clone beside its original is reported, and stays out of the library")
    func cloneReported() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONPAIR", count: 5)
        defer { image.ensureDetached() }
        let clone = try image.clone(to: fixture.directory.appending(path: "pair.dmg"))
        defer { clone.ensureDetached() }
        let mountPoint = try image.attach()
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: mountPoint)
        _ = try clone.attach(mountPoint: fixture.directory.appending(path: "pair"))

        let report = try await indexer.connectKnownVolumes()

        #expect(report.connections.count == 1)
        // exFAT's serial comes from the clock, so an image from another suite can share this UUID.
        #expect(report.duplicateNames.contains("PHOTONPAIR"))
        #expect(try await fixture.store.allVolumes().count == 1)
    }

    @Test("A renamed volume is found again at its new path")
    func renamed() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONOLDNM", count: 5)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach()
        let indexer = fixture.indexer()
        let volume = try #require(try await indexer.index(path: mountPoint).volumeID)

        // Runs on this test's own image, and the mount point comes from attaching it just now.
        let rename = Process()
        rename.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        rename.arguments = ["rename", mountPoint, "PHOTONNEWNM"]
        rename.standardOutput = Pipe()
        rename.standardError = Pipe()
        try rename.run()
        rename.waitUntilExit()
        try #require(rename.terminationStatus == 0)

        indexer.volumeDidRename(from: mountPoint)
        let report = try await indexer.connectKnownVolumes()
        #expect(report.connections.first?.volume == volume)
        #expect(report.connections.first?.mount.name == "PHOTONNEWNM")
        #expect(try await fixture.store.allVolumes().first?.name == "PHOTONNEWNM")
    }

    @Test("Thumbnails stop calmly at a forced detach, marking nothing as failed, and finish after a reattach")
    func thumbnailsAcrossDetach() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONTHMB", count: 120)
        defer { image.ensureDetached() }
        let mountPoint = try image.attach(readOnly: true)
        let store = fixture.store
        // A delay per read, or a fast disk finishes before the detach lands.
        final class Delay: Sendable { let isOn = Mutex(false) }
        let delay = Delay()
        let indexer = fixture.indexer {
            $0.faults = { operation, _ in
                operation == .read && delay.isOn.withLock({ $0 }) ? .stall(.milliseconds(30)) : nil
            }
        }
        let volume = try #require(try await indexer.index(path: mountPoint).volumeID)
        delay.isOn.withLock { $0 = true }
        let packs = ThumbnailPackStore(store: store)
        let generator = ThumbnailGenerator(store: store, packs: packs, scheduler: { indexer.scheduler(for: $0) })

        let progress = Counter()
        let run = Task { try await generator.runBackground(volume: volume, batchSize: 8) { _ in progress.add() } }
        #expect(try await waitFor { progress.count > 0 })
        try image.detach(force: true)
        indexer.volumeDidUnmount(mountPoint: mountPoint)
        let first = try await run.value

        #expect(first.outcome == .volumeOffline)
        #expect(first.failed == 0)
        let remaining = try await store.thumbnailBacklog(volume: volume)

        delay.isOn.withLock { $0 = false }
        _ = try image.attach(readOnly: true)
        _ = try await indexer.connectKnownVolumes()
        let second = try await generator.runBackground(volume: volume)
        #expect(second.outcome == .completed)
        #expect(second.failed == 0)
        #expect(remaining > 0)
        #expect(try await store.thumbnailBacklog(volume: volume) == 0)
    }

    @Test("Indexing a writable volume changes no byte that mounting it alone doesn't")
    func writableVolumeStaysIdentical() async throws {
        let fixture = try Fixture()
        let image = try fixture.image(label: "PHOTONSAME", count: 40)
        defer { image.ensureDetached() }
        // Each mount may stamp the volume by itself, so the control is a mount with no Photon in it.
        _ = try image.attach()
        try image.detach()
        let control = try sha256(image.url)
        _ = try image.attach()
        try image.detach()
        try #require(try sha256(image.url) == control, "Mounting alone changes this image, so this test can't tell.")

        let mountPoint = try image.attach()
        var options = IndexOptions()
        options.requiresReadOnlyExternal = false
        let indexer = LibraryIndexer(store: fixture.store, extractor: MediaMetadataReader(), options: options)
        let report = try await indexer.index(path: mountPoint)
        #expect(report.processed == 40)
        let volume = try #require(report.volumeID)
        let packs = ThumbnailPackStore(store: fixture.store)
        let generator = ThumbnailGenerator(store: fixture.store, packs: packs, scheduler: { indexer.scheduler(for: $0) })
        _ = try await generator.runBackground(volume: volume)
        try image.detach()

        #expect(try sha256(image.url) == control)
    }
}
