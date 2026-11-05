import Foundation
import PhotonCore
import Testing

@testable import PhotonIndex

@Suite("Enumeration with getattrlistbulk")
struct DirectoryListerTests {
    private func list(_ folder: TemporaryFolder, _ directory: String = "") async throws -> [DirectoryEntry] {
        try await VolumeIOScheduler(mountPoint: folder.path).listDirectory(directory, priority: .visible)
    }

    @Test("Sizes and modified times match the file system")
    func matchesStat() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("a.jpg", randomData(4321))
        let date = Date(timeIntervalSince1970: 1_600_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        let entry = try #require(try await list(folder).first)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(entry.name == "a.jpg")
        #expect(entry.kind == .file)
        #expect(entry.size == 4321)
        #expect(
            entry.modifiedTime
                == FileTimestamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec))
    }

    @Test("Finds the same names as FileManager, across several buffers")
    func largeDirectory() async throws {
        let folder = try TemporaryFolder()
        // Long names, so that the listing can't fit in one 256 KB buffer.
        let names = (0..<4000).map { String(format: "%05d-", $0) + String(repeating: "x", count: 120) + ".jpg" }
        for name in names { try folder.write(name, Data()) }

        let listed = try await list(folder).map(\.name)
        let expected = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(listed.count == 4000)
        #expect(Set(listed) == Set(expected))
    }

    @Test("Names outside ASCII survive, in the form the file system reports")
    func unicodeNames() async throws {
        let folder = try TemporaryFolder()
        let names = ["Zdjęcie żółć.jpg", "Cafe\u{301}.jpg", "日本語.heic", "🌅.png", "name with spaces.mov"]
        for name in names { try folder.write(name, Data()) }

        let listed = try await list(folder).map(\.name)
        #expect(listed.count == names.count)
        let opened = try await VolumeIOScheduler(mountPoint: folder.path)
            .withFile(RelativePath(directory: "", name: listed[0]), priority: .visible) { $0.size }
        #expect(opened == 0)
    }

    @Test("Tells files, directories and symlinks apart")
    func kinds() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("file.jpg")
        try folder.write("dir/inner.jpg")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link.jpg"), withDestinationURL: file)

        let entries = try await list(folder)
        #expect(entries.first { $0.name == "file.jpg" }?.kind == .file)
        #expect(entries.first { $0.name == "dir" }?.kind == .directory)
        #expect(entries.first { $0.name == "link.jpg" }?.kind == .other)
    }

    @Test func emptyDirectory() async throws {
        let folder = try TemporaryFolder()
        #expect(try await list(folder).isEmpty)
    }

    @Test func missingDirectory() async throws {
        let folder = try TemporaryFolder()
        await #expect(throws: VolumeIOError.notFound) { _ = try await list(folder, "nowhere") }
    }

    @Test("A symlink to a directory isn't listed through")
    func refusesDirectorySymlink() async throws {
        let folder = try TemporaryFolder()
        try folder.write("real/a.jpg")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link"), withDestinationURL: folder.url.appending(path: "real"))
        await #expect(throws: (any Error).self) { _ = try await list(folder, "link") }
    }
}
