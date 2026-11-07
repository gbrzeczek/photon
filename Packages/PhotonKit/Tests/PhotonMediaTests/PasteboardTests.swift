import AppKit
import ImageIO
import PhotonCore
import PhotonTestSupport
import Testing

@testable import PhotonMedia

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(AssetID, NSPasteboard.PasteboardType)] = []
    func add(_ asset: AssetID, _ type: NSPasteboard.PasteboardType) { lock.withLock { seen.append((asset, type)) } }
    var count: Int { lock.withLock { seen.count } }
}

@Suite("The pasteboard", .serialized)
@MainActor
struct PasteboardTests {
    private func file(_ value: Int64, video: Bool = false, online: Bool = true) -> CopiedFile {
        CopiedFile(
            url: online ? URL(fileURLWithPath: "/Volumes/Test/IMG \(value).JPG") : nil, asset: AssetID(rawValue: value),
            instance: FileInstanceID(rawValue: value), isVideo: video)
    }

    private func make(
        _ requests: Requests = Requests()
    ) -> (NSPasteboard, MediaPasteboard) {
        let board = NSPasteboard.withUniqueName()
        let photo = SyntheticMedia.jpeg()!
        let writer = MediaPasteboard(pasteboard: board) { file, type in
            requests.add(file.asset, type)
            return PasteboardImage.encode(photo, as: type)
        }
        return (board, writer)
    }

    @Test("Files land as URLs in order, so that paste works in Finder")
    func urls() async throws {
        let (board, writer) = make()
        defer { board.releaseGlobally() }
        await writer.write([file(1), file(2), file(3)])
        let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.lastPathComponent) == ["IMG 1.JPG", "IMG 2.JPG", "IMG 3.JPG"])
    }

    @Test("Image data isn't made until something asks, and then only in the type it asks for")
    func lazily() async throws {
        let requests = Requests()
        let (board, writer) = make(requests)
        defer { board.releaseGlobally() }
        await writer.write([file(1)])
        #expect(requests.count == 0)
        #expect(board.types?.contains(.png) == true)
        #expect(board.types?.contains(.tiff) == true)
        let png = try #require(board.data(forType: .png))
        #expect(requests.count == 1)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
    }

    @Test("Videos carry file URLs only")
    func videos() async throws {
        let (board, writer) = make()
        defer { board.releaseGlobally() }
        await writer.write([file(1, video: true)])
        #expect(board.types?.contains(.fileURL) == true)
        #expect(board.types?.contains(.png) == false)
        #expect(board.types?.contains(.tiff) == false)
    }

    @Test("A large selection carries file URLs only")
    func largeSelection() async throws {
        let (board, writer) = make()
        defer { board.releaseGlobally() }
        await writer.write((1...Int64(MediaPasteboard.imageDataLimit + 1)).map { file($0) })
        #expect(board.pasteboardItems?.count == MediaPasteboard.imageDataLimit + 1)
        #expect(board.types?.contains(.png) == false)
    }

    @Test("An offline photo has no URL but can still paste as pixels, and an offline video gives nothing")
    func offline() async throws {
        let (board, writer) = make()
        defer { board.releaseGlobally() }
        await writer.write([file(1, online: false), file(2, video: true, online: false)])
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.types?.contains(.fileURL) == false)
        #expect(board.data(forType: .png) != nil)
    }

    @Test("While quitting, promises are dropped rather than made")
    func quitting() async throws {
        let requests = Requests()
        let (board, writer) = make(requests)
        defer { board.releaseGlobally() }
        await writer.write([file(1)])
        writer.applicationWillQuit()
        #expect(board.data(forType: .png) == nil)
        #expect(requests.count == 0)
        #expect(board.string(forType: .fileURL) != nil)
    }

    @Test("A slow source gives up in time, and the file URL stays")
    func slowSource() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = MediaPasteboard(pasteboard: board, providerWait: .milliseconds(50)) { _, _ in
            try? await Task.sleep(for: .seconds(20))
            return Data([1])
        }
        await writer.write([file(1)])
        let start = ContinuousClock.now
        #expect(board.data(forType: .png) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(board.string(forType: .fileURL) != nil)
    }

    @Test("Encoded data is upright, and no larger than the limit")
    func encoding() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 600
        options.height = 300
        options.orientation = 6
        let data = try #require(SyntheticMedia.jpeg(options))
        let png = try #require(PasteboardImage.encode(data, as: .png))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 300)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 600)
    }

    @Test("An HDR photo is tone mapped for the pasteboard")
    func hdr() throws {
        let data = try #require(SyntheticMedia.hdrGainMap())
        let tiff = try #require(PasteboardImage.encode(data, as: .tiff))
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.bitsPerComponent == 8)
    }
}
