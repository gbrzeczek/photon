import Foundation
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

@testable import PhotonMedia

@Suite("Synthetic library generator")
struct SyntheticLibraryTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "photon-synthetic-\(UUID().uuidString)")
    }

    @Test("The same seed gives the same library, byte for byte")
    func deterministic() throws {
        var options = SyntheticLibrary.Options()
        options.fileCount = 30
        options.averageBytes = 8192
        let (first, second) = (folder(), folder())
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let manifest = try SyntheticLibrary(options: options).generate(at: first)
        _ = try SyntheticLibrary(options: options).generate(at: second)
        for path in manifest.files {
            #expect(try Data(contentsOf: first.appending(path: path)) == Data(contentsOf: second.appending(path: path)))
        }
    }

    @Test("Its files parse as what they claim to be")
    func filesParse() throws {
        var options = SyntheticLibrary.Options()
        options.fileCount = 40
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try SyntheticLibrary(options: options).generate(at: root)

        #expect(manifest.files.count == 40)
        #expect(manifest.videos > 0)
        #expect(manifest.duplicates > 0)
        #expect(manifest.photos + manifest.videos == 40)
        let reader = MediaMetadataReader()
        for path in manifest.files {
            let parsed = try #require(RelativePath(string: path))
            let kind = try #require(MediaKind(fileExtension: parsed.fileExtension))
            let data = try Data(contentsOf: root.appending(path: path))
            let metadata = try reader.metadata(kind: kind, fileExtension: parsed.fileExtension, from: DataByteSource(data))
            #expect(metadata?.pixelWidth != nil, "\(path)")
        }
    }

    @Test("Files are unique, apart from the intended duplicates")
    func uniqueContent() throws {
        var options = SyntheticLibrary.Options()
        options.fileCount = 60
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try SyntheticLibrary(options: options).generate(at: root)
        let contents = try Set(manifest.files.map { try Data(contentsOf: root.appending(path: $0)) })
        #expect(contents.count == manifest.uniqueContent)
    }
}
