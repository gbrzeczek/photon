import Foundation
import PhotonCore
import PhotonTestSupport
import Synchronization
import Testing

@testable import PhotonIndex

import AppKit

private enum NSNotificationNames {
    static let willUnmount = NSWorkspace.willUnmountNotification
    static let didUnmount = NSWorkspace.didUnmountNotification
    static let didMount = NSWorkspace.didMountNotification
}

/// The pipeline on a folder on the internal disk. `PhotonIntegrationTests` covers real exFAT volumes.
@Suite("Background indexing")
struct LibraryIndexerTests {
    private final class Fixture: Sendable {
        let folder: TemporaryFolder
        let storeFolder: TemporaryFolder
        let store: LibraryStore
        let log = PathLog()

        init() throws {
            folder = try TemporaryFolder()
            storeFolder = try TemporaryFolder()
            store = try LibraryStore(url: storeFolder.url.appending(path: "Library.sqlite"))
        }

        func indexer(
            extractor: any MetadataExtracting = StubExtractor(), configure: (inout IndexOptions) -> Void = { _ in }
        ) -> LibraryIndexer {
            var options = IndexOptions()
            configure(&options)
            return LibraryIndexer(store: store, extractor: extractor, options: options, observer: log.observe)
        }

        /// The prefix that scanned paths carry, because the temporary folder isn't a volume root.
        var prefix: String { MountedVolume.relative(folder.path, to: "/System/Volumes/Data") + "/" }

        func relative(_ paths: Set<String>) -> Set<String> {
            Set(paths.map { String($0.dropFirst(prefix.count)) })
        }
    }

    private func populate(_ fixture: Fixture, count: Int) throws {
        for index in 0..<count {
            try fixture.folder.write(String(format: "D%d/%03d.jpg", index % 4, index), randomData(4096, seed: UInt64(index)))
        }
    }

    @Test("A first run reads every file once and finishes every stage")
    func firstRun() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 50)
        let report = try await fixture.indexer().index(path: fixture.folder.path)

        #expect(report.outcome == .completed)
        #expect(report.scan.added == 50)
        #expect(report.processed == 50)
        #expect(report.identity.hashed == 50)
        #expect(report.io.filesOpened == 50)
        #expect(report.io.openHandles == 0)
        #expect(fixture.log.takeFiles().count == 50)
        let volume = try #require(report.volumeID)
        #expect(try await fixture.store.pendingInstances(volume: volume, after: nil, limit: 1).isEmpty)
    }

    @Test("A rescan of an unchanged library opens no files at all")
    func unchangedRescan() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 50)
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: fixture.folder.path)
        _ = fixture.log.takeFiles()
        let before = try await fixture.store.assetCount()

        let report = try await indexer.index(path: fixture.folder.path)

        #expect(report.scan.unchanged == 50)
        #expect(report.processed == 0)
        #expect(fixture.log.takeFiles().isEmpty)
        #expect(try await fixture.store.assetCount() == before)
    }

    @Test("A rescan reads exactly the files that changed")
    func rescanTouchesOnlyChanges() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 40)
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: fixture.folder.path)
        _ = fixture.log.takeFiles()

        try fixture.folder.write("D0/000.jpg", randomData(5000, seed: 900))
        try fixture.folder.write("D1/new.jpg", randomData(4096, seed: 901))
        try fixture.folder.remove("D2/002.jpg")
        try fixture.folder.move("D3/003.jpg", to: "Moved/renamed.jpg")

        let report = try await indexer.index(path: fixture.folder.path)

        #expect(report.scan.modified == 1)
        #expect(report.scan.added == 2)
        #expect(report.scan.removed == 2)
        #expect(report.scan.unchanged == 37)
        #expect(report.processed == 3)
        let touched = fixture.relative(fixture.log.takeFiles())
        #expect(touched == ["D0/000.jpg", "D1/new.jpg", "Moved/renamed.jpg"])
    }

    @Test("Touching a file reads it again, and nothing else")
    func touchedFile() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 10)
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: fixture.folder.path)
        _ = fixture.log.takeFiles()

        let url = fixture.folder.url.appending(path: "D0/000.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let report = try await indexer.index(path: fixture.folder.path)
        #expect(report.scan.modified == 1)
        #expect(fixture.relative(fixture.log.takeFiles()) == ["D0/000.jpg"])
    }

    @Test("Stopping partway loses nothing, and the next run does only what's left")
    func resumesAfterCancel() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 200)
        let run = Task {
            try await fixture.indexer { $0.batchSize = 10 }.index(path: fixture.folder.path)
        }
        // Cancel once the first batches have landed.
        #expect(
            try await eventually {
                let summary = try await fixture.store.volumeSummaries().first
                return (summary?.fileCount ?? 0) == 200 && (summary?.pendingCount ?? 200) < 190
            })
        run.cancel()
        let first = try await run.value
        #expect(first.outcome == .cancelled || first.outcome == .completed)
        let done = fixture.log.takeFiles()
        let summary = try #require(try await fixture.store.volumeSummaries().first)

        let second = try await fixture.indexer().index(path: fixture.folder.path)

        #expect(second.outcome == .completed)
        #expect(second.scan.added == 0)
        #expect(second.processed == summary.pendingCount)
        // Files recorded in the first run weren't read again.
        let again = fixture.log.takeFiles()
        #expect(again.count == summary.pendingCount)
        let finished = 200 - summary.pendingCount
        #expect(done.count >= finished)
        #expect(try await fixture.store.volumeSummaries().first?.pendingCount == 0)
    }

    @Test("Files found by a scan that was interrupted still get processed next time")
    func pendingSurvivesRuns() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 5)
        let volumeRow = try await fixture.indexer().index(path: fixture.folder.path).volumeID
        let volume = try #require(volumeRow)
        // Simulates a crash after enumeration: new rows exist, and nothing has read them.
        _ = try await fixture.store.applyDirectory(
            volume: volume, directory: fixture.prefix + "D1",
            files: [ScannedFile(name: "001.jpg", kind: .photo, size: 1, modifiedTime: FileTimestamp(nanoseconds: 1))])

        let report = try await fixture.indexer().index(path: fixture.folder.path)
        #expect(report.scan.modified == 1)
        #expect(report.processed == 1)
    }

    @Test("A file that can't be read is retried, then set aside, and the rest of the run carries on")
    func unreadableFile() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 6)
        let bad = fixture.folder.url.appending(path: "D0/000.jpg").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad) }

        let indexer = fixture.indexer { $0.maxAttempts = 2 }
        let first = try await indexer.index(path: fixture.folder.path)
        #expect(first.outcome == .completed)
        #expect(first.failed == 1)
        #expect(first.processed == 5)
        #expect(try await fixture.store.volumeSummaries().first?.pendingCount == 1)

        let second = try await indexer.index(path: fixture.folder.path)
        #expect(second.failed == 1)
        let summary = try #require(try await fixture.store.volumeSummaries().first)
        #expect(summary.pendingCount == 0)
        #expect(summary.failedCount == 1)

        // Set aside: later runs leave it alone.
        let third = try await indexer.index(path: fixture.folder.path)
        #expect(third.failed == 0)
    }

    @Test("A file that vanishes after enumeration is left for the next rescan, and isn't a failure")
    func vanishedFile() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 3)
        let extractor = VanishingExtractor(folder: fixture.folder)
        let indexer = fixture.indexer(extractor: extractor)
        let report = try await indexer.index(path: fixture.folder.path)
        #expect(report.outcome == .completed)
        #expect(report.failed == 0)
    }

    @Test("A file that changes while it's being read isn't recorded")
    func fileChangedDuringRead() async throws {
        let fixture = try Fixture()
        try fixture.folder.write("a.jpg", randomData(1000))
        try fixture.folder.write("steady.jpg", randomData(2000, seed: 2))
        try fixture.folder.write("steady2.jpg", randomData(2000, seed: 3))
        let extractor = ChangingExtractor(
            url: fixture.folder.url.appending(path: "a.jpg"), changes: { $0 == 1000 })
        let report = try await fixture.indexer(extractor: extractor).index(path: fixture.folder.path)
        #expect(report.processed == 2)
        #expect(report.failed == 0)
        #expect(try await fixture.store.volumeSummaries().first?.pendingCount == 1)

        // The next run sees the new size and reads it properly.
        let next = try await fixture.indexer().index(path: fixture.folder.path)
        #expect(next.scan.modified == 1)
        #expect(next.processed == 1)
    }

    @Test("Duplicates in a library end up as one asset")
    func duplicatesMerge() async throws {
        let fixture = try Fixture()
        let bytes = randomData(4096)
        try fixture.folder.write("a/one.jpg", bytes)
        try fixture.folder.write("b/two.jpg", bytes)
        try fixture.folder.write("c/three.jpg", bytes)
        let report = try await fixture.indexer().index(path: fixture.folder.path)
        #expect(report.identity.hashed + report.identity.merged == 3)
        #expect(report.identity.merged == 2)
        #expect(try await fixture.store.assetCount() == 1)
    }

    @Test("A willUnmount stops the run at once, and it picks up again if the unmount never happens")
    func falseAlarmResumes() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 400)
        let indexer = fixture.indexer {
            $0.batchSize = 8
            $0.unmountGracePeriod = .milliseconds(100)
        }
        let run = Task { try await indexer.index(path: fixture.folder.path) }
        #expect(
            try await eventually {
                let summary = try await fixture.store.volumeSummaries().first
                return (summary?.fileCount ?? 0) == 400 && (summary?.pendingCount ?? 400) < 400
            })
        let mountPoint = try #require(indexer.onlineVolumes().keys.first)
        indexer.volumeWillUnmount(mountPoint: mountPoint)

        let report = try await run.value
        #expect(report.outcome == .completed)
        #expect(try await fixture.store.volumeSummaries().first?.pendingCount == 0)
    }

    @Test("Two runs can't overlap on one volume")
    func oneRunAtATime() async throws {
        let fixture = try Fixture()
        try populate(fixture, count: 300)
        let indexer = fixture.indexer()
        let first = Task { try await indexer.index(path: fixture.folder.path) }
        #expect(try await eventually { !indexer.onlineVolumes().isEmpty })
        await #expect(throws: IndexingError.alreadyIndexing) {
            _ = try await indexer.index(path: fixture.folder.path)
        }
        _ = try await first.value
    }

    @Test("Each root is added once, and rescanning covers all of them")
    func rootsPersist() async throws {
        let fixture = try Fixture()
        try fixture.folder.write("Photos/a.jpg")
        try fixture.folder.write("Videos/b.mov")
        let indexer = fixture.indexer()
        _ = try await indexer.index(path: fixture.folder.url.appending(path: "Photos").path)
        _ = try await indexer.index(path: fixture.folder.url.appending(path: "Videos").path)

        let mount = try MountedVolume.containing(path: fixture.folder.path).volume
        try fixture.folder.write("Photos/new.jpg", randomData(10))
        let report = try await indexer.rescan(mount: mount)
        #expect(report.scan.added == 1)
        #expect(report.scan.unchanged == 2)
        #expect(try await fixture.store.volumeSummaries().first?.roots.count == 2)
    }

    @Test("A volume event for an unknown mount does nothing")
    func unknownMount() throws {
        let fixture = try Fixture()
        let indexer = fixture.indexer()
        indexer.volumeWillUnmount(mountPoint: "/Volumes/Nothing")
        indexer.volumeDidUnmount(mountPoint: "/Volumes/Nothing")
        #expect(indexer.onlineVolumes().isEmpty)
    }
}

/// Deletes the file before reading, as another app might.
private struct VanishingExtractor: MetadataExtracting {
    let folder: TemporaryFolder
    func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        // The descriptor stays valid, so this stands for a delete between enumeration and open.
        throw VolumeIOError.notFound
    }
}

/// Appends to the file during the read, as a camera import might.
private struct ChangingExtractor: MetadataExtracting {
    let url: URL
    let changes: @Sendable (Int64) -> Bool
    func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        // Sources don't know their path, so `changes` picks the file by size. It must match only that
        // file: appending while reading another one races with this file's own read.
        let name = url.path
        guard changes(source.size), Self.claim(name) else { return nil }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        return nil
    }

    private static let claimed = Mutex<Set<String>>([])
    private static func claim(_ name: String) -> Bool { claimed.withLock { $0.insert(name).inserted } }
}

@Suite("Volume events")
struct VolumeEventMonitorTests {
    @Test("Unmount notifications reach the handlers with their path")
    func deliversEvents() {
        let center = NotificationCenter()
        let events = Mutex<[String]>([])
        let monitor = VolumeEventMonitor(
            center: center,
            willUnmount: { path in events.withLock { $0.append("will " + path) } },
            didUnmount: { path in events.withLock { $0.append("did " + path) } },
            didMount: { path in events.withLock { $0.append("mount " + path) } })
        let info = ["NSDevicePath": "/Volumes/X"]
        center.post(name: NSNotificationNames.willUnmount, object: nil, userInfo: info)
        center.post(name: NSNotificationNames.didUnmount, object: nil, userInfo: info)
        center.post(name: NSNotificationNames.didMount, object: nil, userInfo: info)
        #expect(events.withLock { $0 } == ["will /Volumes/X", "did /Volumes/X", "mount /Volumes/X"])
        withExtendedLifetime(monitor) {}
    }
}
