import AppKit
import ImageIO
import PhotonCore
import PhotonTestSupport
import Testing
import UniformTypeIdentifiers

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

    /// A 40 by 20 PNG, gray but for a red top-left corner.
    private func markedPNG() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // Core Graphics' origin is at the bottom left.
        context.fill(CGRect(x: 0, y: 10, width: 10, height: 10))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Which corner of `data` is red: 0 top left, then clockwise.
    private func redCorner(_ data: Data) throws -> (corner: Int?, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Rows in memory start at the top.
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            return pixels[index] > 200 && pixels[index + 1] < 60
        }
        let corners = [(2, 2), (width - 3, 2), (width - 3, height - 3), (2, height - 3)]
        return (corners.firstIndex { isRed($0.0, $0.1) }, width, height)
    }

    @Test("Image data follows a non-destructive rotation, clockwise")
    func rotatedEncoding() throws {
        let data = try markedPNG()
        #expect(try redCorner(data).corner == 0)
        for turns in 0...3 {
            let png = try #require(PasteboardImage.encode(data, as: .png, quarterTurns: turns))
            let found = try redCorner(png)
            #expect(found.corner == turns)
            #expect(turns % 2 == 0 ? (found.width, found.height) == (40, 20) : (found.width, found.height) == (20, 40))
        }
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
