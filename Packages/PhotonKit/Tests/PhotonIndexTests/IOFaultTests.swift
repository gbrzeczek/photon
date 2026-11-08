import Darwin
import Foundation
import PhotonCore
import Synchronization
import Testing

@testable import PhotonIndex

private func fileName(_ name: String) -> RelativePath { RelativePath(directory: "", name: name) }

/// Failures a disk image can't produce: a forced detach fails every read at once, while a real drive can
/// stall, or fail reads while its mount still looks healthy. See docs/PLAN.md, Removable media checks.
@Suite("Injected I/O failures", .timeLimit(.minutes(2)))
struct IOFaultTests {
    /// Turns faults on and off during a run.
    final class Switch: Sendable {
        private let state = Mutex<(@Sendable (IOOperation, String) -> IOFault?)?>(nil)
        func set(_ rule: (@Sendable (IOOperation, String) -> IOFault?)?) { state.withLock { $0 = rule } }
        var injector: IOFaultInjector { { operation, path in self.state.withLock { $0 }?(operation, path) } }
    }

    private final class Fixture: Sendable {
        let folder: TemporaryFolder
        let storeFolder: TemporaryFolder
        let store: LibraryStore
        let faults = Switch()

        init() throws {
            folder = try TemporaryFolder()
            storeFolder = try TemporaryFolder()
            store = try LibraryStoreFixture.make(in: storeFolder)
        }

        func indexer() -> LibraryIndexer {
            var options = IndexOptions()
            options.batchSize = 8
            options.faults = faults.injector
            return LibraryIndexer(store: store, extractor: StubExtractor(), options: options)
        }

        func write(_ count: Int) throws {
            for index in 0..<count { try folder.write("f\(index).jpg", randomData(100 + index, seed: UInt64(index))) }
        }
    }

    @Test("Device errors are told from errors about one file")
    func classifiesErrors() {
        #expect(VolumeIOError.system(operation: "read", code: EIO).isDeviceFailure)
        #expect(VolumeIOError.system(operation: "read", code: ENXIO).isDeviceFailure)
        #expect(!VolumeIOError.system(operation: "open", code: EACCES).isDeviceFailure)
        #expect(!VolumeIOError.notFound.isDeviceFailure)
        #expect(!VolumeIOError.volumeUnavailable.isDeviceFailure)
    }

    @Test("A read that fails while the mount looks healthy reports the device, not the volume")
    func readError() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin", randomData(1000))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, faults: { operation, _ in
            operation == .read ? .fail(code: EIO) : nil
        })
        await #expect(throws: VolumeIOError.system(operation: "injected", code: EIO)) {
            _ = try await scheduler.withFile(fileName("a.bin"), priority: .visible) {
                try $0.read(offset: 0, length: 100)
            }
        }
        #expect(scheduler.statistics.openHandles == 0)
    }

    @Test("Suspending returns at once with a read stuck, and the handle closes when the read lets go")
    func stuckRead() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin", randomData(1000))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, faults: { operation, _ in
            operation == .read ? .stall(.milliseconds(600)) : nil
        })
        let read = Task {
            try await scheduler.withFile(fileName("a.bin"), priority: .visible) { try $0.read(offset: 0, length: 100) }
        }
        #expect(try await eventually { scheduler.statistics.openHandles == 1 })

        let clock = ContinuousClock()
        let start = clock.now
        scheduler.suspend()
        #expect(clock.now - start < .milliseconds(50))
        // A stuck read can't be interrupted, so a short wait reports that rather than hanging.
        #expect(await scheduler.waitUntilIdle(timeout: .milliseconds(50)) == false)

        #expect(await scheduler.waitUntilIdle(timeout: .seconds(5)))
        #expect(scheduler.statistics.openHandles == 0)
        _ = try? await read.value
    }

    @Test("A job that finds the mount gone says so once")
    func lostOnce() async throws {
        let folder = try TemporaryFolder()
        let gone = SharedFlag()
        let calls = SharedList()
        let scheduler = VolumeIOScheduler(
            mountPoint: folder.path, isAvailable: { !gone.isSet }, onLost: { calls.append("lost") })
        gone.set()
        for _ in 0..<3 {
            await #expect(throws: VolumeIOError.volumeUnavailable) {
                _ = try await scheduler.listDirectory("", priority: .visible)
            }
        }
        #expect(calls.values == ["lost"])
    }

    @Test("Every read failing and the root not listing stops the run, and blames no file")
    func dyingDrive() async throws {
        let fixture = try Fixture()
        try fixture.write(40)
        let indexer = fixture.indexer()
        // Enumeration succeeds, then the drive starts failing, as one does partway through a run.
        fixture.faults.set { operation, path in
            switch operation {
            case .open, .read: .fail(code: EIO)
            case .list: path.isEmpty ? .fail(code: EIO) : nil
            case .status: nil
            }
        }

        let report = try await indexer.index(path: fixture.folder.path)

        #expect(report.outcome == .volumeFailing)
        #expect(report.failed == 0)
        let summary = try #require(try await fixture.store.volumeSummaries().first)
        #expect(summary.failedCount == 0)
        #expect(summary.pendingCount == 40)

        fixture.faults.set(nil)
        let next = try await indexer.index(path: fixture.folder.path)
        #expect(next.outcome == .completed)
        #expect(next.processed == 40)
        #expect(try await fixture.store.volumeSummaries().first?.pendingCount == 0)
    }

    @Test("One unreadable file costs that file, and the run carries on")
    func oneBadFile() async throws {
        let fixture = try Fixture()
        try fixture.write(20)
        let indexer = fixture.indexer()
        fixture.faults.set { operation, path in
            operation == .read && path.hasSuffix("f3.jpg") ? .fail(code: EIO) : nil
        }

        let report = try await indexer.index(path: fixture.folder.path)

        #expect(report.outcome == .completed)
        #expect(report.failed == 1)
        #expect(report.processed == 19)
    }

    @Test("A batch of bad files on a drive that still lists its root counts against the files")
    func healthyDriveBadFiles() async throws {
        let fixture = try Fixture()
        try fixture.write(4)
        let indexer = fixture.indexer()
        fixture.faults.set { operation, _ in operation == .read ? .fail(code: EIO) : nil }

        let report = try await indexer.index(path: fixture.folder.path)

        #expect(report.outcome == .completed)
        #expect(report.failed == 4)
    }

    @Test("Tools refuse a writable external drive, and the app's options don't")
    func policy() async throws {
        let fixture = try Fixture()
        let (real, _) = try MountedVolume.containing(path: fixture.folder.path)
        var writableExternal = real
        writableExternal.location = .external
        writableExternal.isReadOnly = false

        let tool = LibraryIndexer(store: fixture.store, extractor: StubExtractor())
        await #expect(throws: IndexingError.self) { _ = try await tool.connect(mount: writableExternal) }

        var options = IndexOptions()
        options.requiresReadOnlyExternal = false
        let app = LibraryIndexer(store: fixture.store, extractor: StubExtractor(), options: options)
        do {
            _ = try await app.connect(mount: writableExternal)
        } catch let error as IndexingError {
            // The test's library lives on this same volume, and that rule still holds.
            #expect(error == .libraryOnScannedVolume)
        }
    }
}
