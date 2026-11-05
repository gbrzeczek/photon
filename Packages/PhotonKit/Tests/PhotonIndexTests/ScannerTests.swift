import Foundation
import PhotonCore
import PhotonTestSupport
import Testing

@testable import PhotonIndex

@Suite("Enumeration stage")
struct ScannerTests {
    private struct Fixture {
        let folder: TemporaryFolder
        let storeFolder: TemporaryFolder
        let store: LibraryStore
        let volume: VolumeID
        var scanner: VolumeScanner {
            VolumeScanner(store: store, scheduler: VolumeIOScheduler(mountPoint: folder.path), volume: volume)
        }

        init() async throws {
            folder = try TemporaryFolder()
            storeFolder = try TemporaryFolder()
            store = try LibraryStore(url: storeFolder.url.appending(path: "Library.sqlite"))
            volume = try await store.insertVolume(uuid: "U", name: "N", capacity: nil, filesystem: nil).id
        }

        func names(in directory: String) async throws -> [String] {
            try await store.instances(volume: volume, directory: directory).map(\.path.name)
        }
    }

    @Test("Walks subfolders and records only media files")
    func walksTree() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("a.jpg")
        try fixture.folder.write("DCIM/100/b.MOV")
        try fixture.folder.write("DCIM/101/deep/c.heic")
        try fixture.folder.write("notes.txt")
        try fixture.folder.write("DCIM/100/b.THM")

        let report = try await fixture.scanner.scan(root: "")

        #expect(report.added == 3)
        #expect(report.directories == 5)
        #expect(try await fixture.names(in: "") == ["a.jpg"])
        #expect(try await fixture.names(in: "DCIM/100") == ["b.MOV"])
        #expect(try await fixture.names(in: "DCIM/101/deep") == ["c.heic"])
        #expect(try await fixture.store.assetCount() == 3)
    }

    @Test("Skips dot files, system folders, photo libraries and symlinks")
    func skipsIgnoredItems() async throws {
        let fixture = try await Fixture()
        let real = try fixture.folder.write("real.jpg")
        try fixture.folder.write("._real.jpg")
        try fixture.folder.write(".hidden.jpg")
        try fixture.folder.write(".Trashes/501/deleted.jpg")
        try fixture.folder.write(".Spotlight-V100/x.jpg")
        try fixture.folder.write("$RECYCLE.BIN/x.jpg")
        try fixture.folder.write("System Volume Information/x.jpg")
        try fixture.folder.write("Photos Library.photoslibrary/originals/x.jpg")
        try FileManager.default.createSymbolicLink(
            at: fixture.folder.url.appending(path: "link.jpg"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: fixture.folder.url.appending(path: "loop"), withDestinationURL: fixture.folder.url)

        let report = try await fixture.scanner.scan(root: "")
        #expect(report.added == 1)
        #expect(report.directories == 1)
    }

    @Test("A second scan of an unchanged tree finds nothing to do")
    func rescanIsQuiet() async throws {
        let fixture = try await Fixture()
        for index in 0..<20 { try fixture.folder.write("D/\(index % 3)/\(index).jpg") }
        _ = try await fixture.scanner.scan(root: "")
        let report = try await fixture.scanner.scan(root: "")
        #expect(report.unchanged == 20)
        #expect(report.added == 0 && report.modified == 0 && report.removed == 0)
    }

    @Test("A deleted folder is forgotten, with everything under it")
    func deletedFolder() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("keep/a.jpg")
        try fixture.folder.write("gone/b.jpg")
        try fixture.folder.write("gone/sub/c.jpg")
        _ = try await fixture.scanner.scan(root: "")

        try fixture.folder.remove("gone")
        let report = try await fixture.scanner.scan(root: "")

        #expect(report.removed == 2)
        #expect(try await fixture.names(in: "keep") == ["a.jpg"])
        #expect(try await fixture.names(in: "gone").isEmpty)
        #expect(try await fixture.store.assetCount() == 1)
    }

    @Test("Scanning one root leaves the rest of the volume alone")
    func rootsAreIndependent() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("Photos/a.jpg")
        try fixture.folder.write("Photos2/b.jpg")
        _ = try await fixture.scanner.scan(root: "Photos")
        _ = try await fixture.scanner.scan(root: "Photos2")

        try fixture.folder.remove("Photos2/b.jpg")
        let report = try await fixture.scanner.scan(root: "Photos")

        #expect(report.removed == 0)
        #expect(try await fixture.names(in: "Photos2") == ["b.jpg"])
    }

    @Test("A folder that can't be listed keeps its files, because a failing drive must not look empty")
    func unreadableFolderIsProtected() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("locked/a.jpg")
        try fixture.folder.write("locked/sub/b.jpg")
        try fixture.folder.write("open/c.jpg")
        _ = try await fixture.scanner.scan(root: "")

        let locked = fixture.folder.url.appending(path: "locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let report = try await fixture.scanner.scan(root: "")

        #expect(report.unreadableDirectories == 1)
        #expect(report.removed == 0)
        #expect(try await fixture.names(in: "locked/sub") == ["b.jpg"])
    }

    @Test("A volume that disappears isn't mistaken for deleted folders")
    func goneVolumeRemovesNothing() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("D/a.jpg")
        try fixture.folder.write("D/sub/b.jpg")
        try fixture.folder.write("E/c.jpg")
        _ = try await fixture.scanner.scan(root: "")

        // With a mount gone, every path gives ENOENT, exactly as if each folder had been deleted.
        try fixture.folder.remove("D")
        try fixture.folder.remove("E")
        let scheduler = VolumeIOScheduler(mountPoint: fixture.folder.path, isAvailable: { false })
        let scanner = VolumeScanner(store: fixture.store, scheduler: scheduler, volume: fixture.volume)

        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await scanner.scan(root: "") }
        #expect(try await fixture.names(in: "D") == ["a.jpg"])
        #expect(try await fixture.names(in: "D/sub") == ["b.jpg"])
    }

    @Test("A listing that comes back empty from a dying mount changes nothing")
    func emptyListingFromGoneVolume() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("a.jpg")
        _ = try await fixture.scanner.scan(root: "")
        try fixture.folder.remove("a.jpg")

        let scheduler = VolumeIOScheduler(mountPoint: fixture.folder.path, isAvailable: { false })
        let scanner = VolumeScanner(store: fixture.store, scheduler: scheduler, volume: fixture.volume)
        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await scanner.scan(root: "") }
        #expect(try await fixture.names(in: "") == ["a.jpg"])
    }

    @Test("A cancelled scan forgets nothing")
    func cancelledScanRemovesNothing() async throws {
        let fixture = try await Fixture()
        for index in 0..<30 { try fixture.folder.write("D\(index)/a.jpg") }
        _ = try await fixture.scanner.scan(root: "")
        for index in 0..<30 { try fixture.folder.remove("D\(index)") }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.scanner.scan(root: "")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await fixture.names(in: "D0") == ["a.jpg"])
    }

    @Test("A suspended volume stops the scan and forgets nothing")
    func suspendedScanRemovesNothing() async throws {
        let fixture = try await Fixture()
        try fixture.folder.write("D/a.jpg")
        _ = try await fixture.scanner.scan(root: "")
        try fixture.folder.remove("D")

        let scheduler = VolumeIOScheduler(mountPoint: fixture.folder.path)
        scheduler.suspend()
        let scanner = VolumeScanner(store: fixture.store, scheduler: scheduler, volume: fixture.volume)
        await #expect(throws: VolumeIOError.volumeUnavailable) { _ = try await scanner.scan(root: "") }
        #expect(try await fixture.names(in: "D") == ["a.jpg"])
    }
}
