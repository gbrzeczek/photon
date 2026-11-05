import Foundation
import PhotonCore
import Testing

@testable import PhotonIndex

/// Blocks an I/O thread until released, so that tests can line jobs up behind it.
private final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open(_ count: Int = 1) { for _ in 0..<count { semaphore.signal() } }
}

private func fileName(_ name: String) -> RelativePath { RelativePath(directory: "", name: name) }

@Suite("Per-volume I/O scheduler")
struct VolumeIOSchedulerTests {
    @Test func readsTheRequestedBytes() async throws {
        let folder = try TemporaryFolder()
        let bytes = randomData(10_000)
        try folder.write("a.bin", bytes)
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)

        let slice = try await scheduler.withFile(fileName("a.bin"), priority: .visible) {
            try $0.read(offset: 100, length: 50)
        }
        #expect(slice == bytes.subdata(in: 100..<150))
    }

    @Test("Reads spanning several chunks come back whole")
    func readsAcrossChunks() async throws {
        let folder = try TemporaryFolder()
        let bytes = randomData(VolumeIOScheduler.chunkSize * 2 + 123)
        try folder.write("a.bin", bytes)
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let all = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { file in
            try file.read(offset: 0, length: Int(file.size))
        }
        #expect(all == bytes)
    }

    @Test("A read past the end stops at the end")
    func readClampsAtEndOfFile() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin", randomData(100))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let (tail, beyond) = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { file in
            (try file.read(offset: 90, length: 50), try file.read(offset: 500, length: 50))
        }
        #expect(tail.count == 10)
        #expect(beyond.isEmpty)
    }

    @Test("Nothing stays open when a job finishes, succeeds or throws")
    func handlesCloseAfterEveryJob() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        _ = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size }
        await #expect(throws: VolumeIOError.notFound) {
            _ = try await scheduler.withFile(fileName("missing"), priority: .visible) { $0.size }
        }
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            let _: Int = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { _ in throw Failure() }
        }
        #expect(scheduler.statistics.openHandles == 0)
        #expect(scheduler.statistics.filesOpened == 2)
    }

    @Test("Symlinks aren't followed")
    func refusesSymlinks() async throws {
        let folder = try TemporaryFolder()
        let target = try folder.write("real.bin")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link.bin"), withDestinationURL: target)
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        await #expect(throws: VolumeIOError.self) {
            _ = try await scheduler.withFile(fileName("link.bin"), priority: .visible) { $0.size }
        }
    }

    @Test("Any error on a volume that has gone reports the volume, not the file")
    func goneVolumeErrors() async throws {
        let folder = try TemporaryFolder()
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, isAvailable: { false })
        await #expect(throws: VolumeIOError.volumeUnavailable) {
            _ = try await scheduler.withFile(fileName("missing"), priority: .visible) { $0.size }
        }
        await #expect(throws: VolumeIOError.volumeUnavailable) {
            _ = try await scheduler.status(of: fileName("missing"), priority: .visible)
        }
        await #expect(throws: VolumeIOError.volumeUnavailable) {
            _ = try await scheduler.listDirectory("missing", priority: .visible)
        }
    }

    @Test("A status check reports a missing file as nil")
    func statusOfMissingFile() async throws {
        let folder = try TemporaryFolder()
        let bytes = randomData(321)
        try folder.write("a.bin", bytes)
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        #expect(try await scheduler.status(of: fileName("a.bin"), priority: .visible)?.size == 321)
        #expect(try await scheduler.status(of: fileName("nope"), priority: .visible) == nil)
    }

    @Test("Higher priorities run first, and each priority is first in, first out")
    func priorityOrder() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, concurrency: 1)
        let gate = Gate()
        let order = SharedList()
        let started = SharedFlag()

        let blocker = Task {
            try await scheduler.withFile(fileName("a.bin"), priority: .backgroundWork) { _ in
                started.set()
                gate.wait()
            }
        }
        #expect(try await eventually { started.isSet })

        let requests: [(String, IOPriority)] = [
            ("work-1", .backgroundWork), ("metadata", .backgroundMetadata), ("hash", .userHash),
            ("work-2", .backgroundWork), ("visible-1", .visible), ("ahead", .ahead), ("visible-2", .visible),
        ]
        var tasks: [Task<Void, any Error>] = []
        for (label, priority) in requests {
            tasks.append(
                Task {
                    try await scheduler.withFile(fileName("a.bin"), priority: priority) { _ in
                        order.append(label)
                    }
                })
            // Let each one reach the queue, so the test isn't at the mercy of task start order.
            try await Task.sleep(for: .milliseconds(20))
        }

        gate.open()
        try await blocker.value
        for task in tasks { try await task.value }
        #expect(
            order.values == ["visible-1", "visible-2", "ahead", "hash", "metadata", "work-1", "work-2"])
    }

    @Test("A volume never runs more than its concurrency")
    func concurrencyLimit() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, concurrency: 3)
        let meter = ConcurrencyMeter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<60 {
                group.addTask {
                    try await scheduler.withFile(fileName("a.bin"), priority: .backgroundWork) { _ in
                        meter.enter()
                        Thread.sleep(forTimeInterval: 0.002)
                        meter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(meter.peak == 3)
    }

    @Test("Cancelling a queued read fails it at once, without touching the disk")
    func cancelQueuedJob() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, concurrency: 1)
        let gate = Gate()
        let started = SharedFlag()
        let blocker = Task {
            try await scheduler.withFile(fileName("a.bin"), priority: .visible) { _ in
                started.set()
                gate.wait()
            }
        }
        #expect(try await eventually { started.isSet })

        let queued = Task { try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size } }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(scheduler.statistics.filesOpened == 1)

        gate.open()
        try await blocker.value
    }

    @Test("A task that's already cancelled never reaches the disk")
    func alreadyCancelled() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(scheduler.statistics.filesOpened == 0)
    }

    @Test("Cancelling a read in flight stops it at the next chunk")
    func cancelRunningRead() async throws {
        let folder = try TemporaryFolder()
        let size = VolumeIOScheduler.chunkSize * 8
        try folder.write("big.bin", randomData(size))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let started = SharedFlag()
        let gate = Gate()

        let task = Task {
            try await scheduler.withFile(fileName("big.bin"), priority: .visible) { file in
                _ = try file.read(offset: 0, length: VolumeIOScheduler.chunkSize)
                started.set()
                gate.wait()
                return try file.read(offset: 0, length: size)
            }
        }
        #expect(try await eventually { started.isSet })
        task.cancel()
        try await Task.sleep(for: .milliseconds(10))
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(scheduler.statistics.openHandles == 0)
        #expect(scheduler.statistics.bytesRead == Int64(VolumeIOScheduler.chunkSize))
    }

    @Test("Suspending fails queued and running work, and every handle closes")
    func suspendCancelsEverything() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin", randomData(VolumeIOScheduler.chunkSize))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path, concurrency: 1)
        let gate = Gate()
        let started = SharedFlag()

        let running = Task {
            try await scheduler.withFile(fileName("a.bin"), priority: .visible) { file in
                started.set()
                gate.wait()
                return try file.read(offset: 0, length: 16)
            }
        }
        #expect(try await eventually { started.isSet })
        let queued = Task { try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size } }
        try await Task.sleep(for: .milliseconds(20))

        scheduler.suspend()
        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await queued.value }
        gate.open()
        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await running.value }
        #expect(scheduler.statistics.openHandles == 0)
    }

    @Test("A suspended volume refuses work until it resumes, because willUnmount can be a false alarm")
    func resumeAfterFalseAlarm() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        scheduler.suspend()
        await #expect(throws: VolumeIOError.volumeUnavailable) {
            _ = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size }
        }
        scheduler.resume()
        #expect(try await scheduler.withFile(fileName("a.bin"), priority: .visible) { $0.size } == 7)
    }

    @Test("A slow volume doesn't hold up another volume's scheduler")
    func volumesAreIndependent() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.bin")
        let slow = VolumeIOScheduler(mountPoint: folder.path, concurrency: 1)
        let fast = VolumeIOScheduler(mountPoint: folder.path, concurrency: 1)
        let gate = Gate()
        let started = SharedFlag()
        let blocked = Task {
            try await slow.withFile(fileName("a.bin"), priority: .visible) { _ in
                started.set()
                gate.wait()
            }
        }
        #expect(try await eventually { started.isSet })
        #expect(try await fast.withFile(fileName("a.bin"), priority: .visible) { $0.size } == 7)
        gate.open()
        try await blocked.value
    }

    @Test("A file that changes during a job is noticed")
    func detectsChange() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("a.bin", randomData(100))
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let unchanged = try await scheduler.withFile(fileName("a.bin"), priority: .visible) { file in
            let before = try file.isUnchanged()
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([1, 2, 3]))
            try handle.close()
            return (before, try file.isUnchanged())
        }
        #expect(unchanged.0)
        #expect(!unchanged.1)
    }
}
