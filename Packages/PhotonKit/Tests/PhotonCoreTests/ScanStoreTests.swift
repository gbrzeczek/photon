import Foundation
import GRDB
import Testing

@testable import PhotonCore

@Suite("Rescans write only differences")
struct ScanStoreTests {
    private func writesDuring(_ library: TestLibrary, _ body: () async throws -> Void) async throws -> Int {
        // total_changes counts every row written on the writer connection.
        let before = try await library.store.pool.write { db in try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0 }
        try await body()
        let after = try await library.store.pool.write { db in try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0 }
        return after - before
    }

    @Test("An unchanged directory writes nothing")
    func unchangedDirectoryWritesNothing() async throws {
        let library = try await TestLibrary()
        let files = (0..<50).map { TestLibrary.file("\($0).jpg") }
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "D", files: files)

        var changes = DirectoryChanges()
        let writes = try await writesDuring(library) {
            changes = try await library.store.applyDirectory(volume: library.volume, directory: "D", files: files)
        }
        #expect(writes == 0)
        #expect(changes.unchanged == 50)
        #expect(changes.added == 0 && changes.modified == 0 && changes.removed == 0)
    }

    @Test("Size, modified time, additions and removals are each detected")
    func detectsEachKindOfChange() async throws {
        let library = try await TestLibrary()
        _ = try await library.store.applyDirectory(
            volume: library.volume, directory: "D",
            files: [
                TestLibrary.file("same.jpg"), TestLibrary.file("size.jpg"), TestLibrary.file("time.jpg"),
                TestLibrary.file("gone.jpg"),
            ])

        let changes = try await library.store.applyDirectory(
            volume: library.volume, directory: "D",
            files: [
                TestLibrary.file("same.jpg"), TestLibrary.file("size.jpg", size: 101),
                TestLibrary.file("time.jpg", modified: 1001), TestLibrary.file("new.jpg"),
            ])

        #expect(changes.unchanged == 1)
        #expect(changes.modified == 2)
        #expect(changes.added == 1)
        #expect(changes.removed == 1)
        let names = try await library.store.instances(volume: library.volume, directory: "D").map(\.path.name)
        #expect(names == ["new.jpg", "same.jpg", "size.jpg", "time.jpg"])
    }

    @Test("A change puts a finished file back to pending and clears its failures")
    func changeResetsState() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        try await library.store.recordIndexFailure(instance.id, message: "x", maxAttempts: 1)
        #expect(try await library.reload(instance).indexState == .failed)

        let changed = try await library.add("a.jpg", size: 101)
        #expect(changed.indexState == .pending)
        #expect(changed.indexAttempts == 0)
        #expect(changed.indexError == nil)
    }

    @Test("Pending files come in pages and in order")
    func pendingPages() async throws {
        let library = try await TestLibrary()
        _ = try await library.store.applyDirectory(
            volume: library.volume, directory: "D", files: (0..<5).map { TestLibrary.file("\($0).jpg") })

        let first = try await library.store.pendingInstances(volume: library.volume, after: nil, limit: 3)
        let second = try await library.store.pendingInstances(volume: library.volume, after: first.last?.id, limit: 3)
        #expect(first.count == 3)
        #expect(second.count == 2)
        #expect(Set((first + second).map(\.id)).count == 5)
    }

    @Test("A file stops being retried after the last attempt")
    func failuresGiveUp() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        try await library.store.recordIndexFailure(instance.id, message: "first", maxAttempts: 2)
        #expect(try await library.reload(instance).indexState == .pending)
        #expect(try await library.reload(instance).indexAttempts == 1)
        try await library.store.recordIndexFailure(instance.id, message: "second", maxAttempts: 2)
        let failed = try await library.reload(instance)
        #expect(failed.indexState == .failed)
        #expect(failed.indexError == "second")
        #expect(try await library.store.pendingInstances(volume: library.volume, after: nil, limit: 10).isEmpty)
    }

    @Test("Known directories stop at the subtree, not at a shared prefix")
    func knownDirectoriesStayInTheSubtree() async throws {
        let library = try await TestLibrary()
        for directory in ["A", "A/B", "A/B/C", "A/B0", "A/B C", "A/Bb", "Z", ""] {
            _ = try await library.store.applyDirectory(
                volume: library.volume, directory: directory, files: [TestLibrary.file("x.jpg")])
        }
        let under = try await library.store.knownDirectories(volume: library.volume, under: "A/B")
        #expect(Set(under) == ["A/B", "A/B/C"])
        let all = try await library.store.knownDirectories(volume: library.volume, under: "")
        #expect(all.count == 8)
    }

    @Test("Removing a directory counts its files and keeps favorites")
    func removeDirectory() async throws {
        let library = try await TestLibrary()
        let kept = try await library.addIndexed("a.jpg", directory: "Gone", hash: TestLibrary.hash(1))
        _ = try await library.addIndexed("b.jpg", directory: "Gone", hash: TestLibrary.hash(2))
        try await library.favorite(kept.assetID)

        let removed = try await library.store.removeDirectories(volume: library.volume, ["Gone"])

        #expect(removed == 2)
        #expect(try await library.store.assetCount() == 1)
        #expect(try await library.store.asset(kept.assetID)?.isFavorite == true)
    }

    @Test("Instances on one volume don't disturb another")
    func volumesAreSeparate() async throws {
        let library = try await TestLibrary()
        let other = try await library.store.insertVolume(uuid: "B", name: "B", capacity: nil, filesystem: nil)
        let instance = try await library.add("a.jpg", directory: "D", on: other.id)
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "D", files: [])
        #expect(try await library.store.instance(volume: other.id, path: instance.path) != nil)
    }
}

@Suite struct VolumeRowTests {
    @Test("Rows sharing a UUID come back most recently seen first")
    func clonesShareAUUID() async throws {
        let library = try await TestLibrary()
        let older = try await library.store.insertVolume(
            uuid: "SAME", name: "Old", capacity: nil, filesystem: nil, now: Date(timeIntervalSince1970: 100))
        let newer = try await library.store.insertVolume(
            uuid: "SAME", name: "New", capacity: nil, filesystem: nil, now: Date(timeIntervalSince1970: 200))
        #expect(try await library.store.volumes(uuid: "SAME").map(\.id) == [newer.id, older.id])

        try await library.store.markVolumeSeen(
            older.id, name: "Old", capacity: nil, filesystem: nil, now: Date(timeIntervalSince1970: 300))
        #expect(try await library.store.volumes(uuid: "SAME").first?.id == older.id)
    }

    @Test("Adding a root twice keeps one row")
    func rootsAreUnique() async throws {
        let library = try await TestLibrary()
        let first = try await library.store.addRoot(volume: library.volume, relativePath: "Photos")
        let second = try await library.store.addRoot(volume: library.volume, relativePath: "Photos")
        #expect(first.id == second.id)
        #expect(try await library.store.roots(volume: library.volume).count == 1)
    }

    @Test func summariesCountStates() async throws {
        let library = try await TestLibrary()
        let failed = try await library.add("failed.jpg", size: 10)
        try await library.store.recordIndexFailure(failed.id, message: "x", maxAttempts: 1)
        try await library.add("pending.jpg", size: 20)
        _ = try await library.addIndexed("done.jpg", hash: TestLibrary.hash(1))
        try await library.store.addRoot(volume: library.volume, relativePath: "")

        let summary = try #require(try await library.store.volumeSummaries().first)
        #expect(summary.fileCount == 3)
        #expect(summary.pendingCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.totalBytes == 130)
        #expect(summary.roots.count == 1)
    }
}
