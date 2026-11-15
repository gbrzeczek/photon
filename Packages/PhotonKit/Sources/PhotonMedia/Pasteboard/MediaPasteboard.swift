import AppKit
import ImageIO
import PhotonCore
import PhotonIndex
import UniformTypeIdentifiers

/// One file on its way to the pasteboard.
public struct CopiedFile: Sendable, Equatable {
    /// Where the file is. Nil on an offline volume.
    public var url: URL?
    public var asset: AssetID
    public var instance: FileInstanceID
    public var isVideo: Bool
    /// Non-destructive rotation, in clockwise quarter turns. Image data is turned to match what shows.
    /// The file itself is the original, untouched.
    public var quarterTurns: Int

    public init(url: URL?, asset: AssetID, instance: FileInstanceID, isVideo: Bool, quarterTurns: Int = 0) {
        self.url = url
        self.asset = asset
        self.instance = instance
        self.isVideo = isVideo
        self.quarterTurns = quarterTurns
    }
}

/// Puts files on a pasteboard: file URLs, so that paste works in Finder, and image data made only when
/// something asks for it, for apps that take pixels. Videos carry file URLs only.
///
/// Writing is the slow part, at about 30 µs per file, so it runs on its own queue and Command-C returns
/// at once however many files there are. A large selection shows up on the pasteboard a moment later.
public final class MediaPasteboard: @unchecked Sendable {
    /// Makes the bytes for one file in one type. Runs off the main thread.
    public typealias ImageSource = @Sendable (CopiedFile, NSPasteboard.PasteboardType) async -> Data?

    /// The most files that also carry image data. Past this the point is to move files, and every
    /// promise has to be kept or dropped at quit.
    public static let imageDataLimit = 16
    /// AppKit calls for promised data on the main thread and waits for it there, so a read can only be
    /// waited for this long. It's enough for a sleeping drive to wake.
    public static let defaultProviderWait: DispatchTimeInterval = .seconds(4)
    /// What a paste can turn into pixels. Both are lazy, and apps pick one.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    private let pasteboard: NSPasteboard
    private let source: ImageSource
    private let providerWait: DispatchTimeInterval
    private let queue = DispatchQueue(label: "app.photon.pasteboard", qos: .userInitiated)
    private let lock = NSLock()
    private var providers: [ImageProvider] = []
    private var isQuitting = false

    public init(
        pasteboard: NSPasteboard = .general, providerWait: DispatchTimeInterval = defaultProviderWait,
        source: @escaping ImageSource
    ) {
        self.pasteboard = pasteboard
        self.providerWait = providerWait
        self.source = source
    }

    /// Promised data would be read and encoded for every file during quit, on the main thread. Keeping
    /// the file URLs and dropping the rest is the better trade.
    public func applicationWillQuit() {
        lock.withLock { isQuitting = true }
    }

    /// Empties the pasteboard at once, ahead of a `write` that may take a while. A paste in that gap
    /// finds nothing, which beats pasting what was copied before.
    public func clear() {
        queue.async { [pasteboard] in pasteboard.clearContents() }
    }

    /// Replaces the pasteboard's contents. Nothing here depends on the main thread, but the provider
    /// callbacks arrive there.
    public func write(_ files: [CopiedFile]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                writeNow(files)
                continuation.resume()
            }
        }
    }

    private func writeNow(_ files: [CopiedFile]) {
        var providers: [ImageProvider] = []
        let offersImages = files.count <= Self.imageDataLimit
        let items = files.compactMap { file -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            if let url = file.url { item.setString(url.absoluteString, forType: .fileURL) }
            guard offersImages, !file.isVideo else { return file.url == nil ? nil : item }
            let provider = ImageProvider(file: file, owner: self)
            item.setDataProvider(provider, forTypes: Self.imageTypes)
            providers.append(provider)
            return item
        }
        lock.withLock { self.providers = providers }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    fileprivate func provide(_ file: CopiedFile, type: NSPasteboard.PasteboardType, item: NSPasteboardItem) {
        guard !lock.withLock({ isQuitting }) else { return }
        // The read and the encoding run elsewhere, so that the main thread never touches a file. It
        // only waits, for a bounded time, because AppKit gives it no other way to answer.
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        let source = source
        let task = Task.detached(priority: .userInitiated) {
            box.data = await source(file, type)
            done.signal()
        }
        guard done.wait(timeout: .now() + providerWait) == .success else {
            task.cancel()
            return
        }
        if let data = box.data { item.setData(data, forType: type) }
    }
}

private final class DataBox: @unchecked Sendable {
    var data: Data?
}

/// One per file, because a data provider is told only which item it's answering for.
private final class ImageProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let file: CopiedFile
    private weak var owner: MediaPasteboard?

    init(file: CopiedFile, owner: MediaPasteboard) {
        self.file = file
        self.owner = owner
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        owner?.provide(file, type: type, item: item)
    }
}

/// Turns a photo's bytes into data for the pasteboard, off the main thread.
public enum PasteboardImage {
    private static let queue = DispatchQueue(
        label: "app.photon.pasteboard-image", qos: .userInitiated, attributes: .concurrent)

    /// Runs `body` where it may block or take a while, which isn't Swift's pool.
    public static func offPool(_ body: @escaping @Sendable () -> Data?) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Long edge of generated image data. Apps that take pixels rarely want more, and a whole 48 MP PNG
    /// takes seconds to encode while AppKit waits. Finder and anything else taking the file gets the
    /// original.
    public static let maximumEdge = 4096

    /// Encodes as `type`, upright and in the photo's own color space, then turned clockwise by
    /// `quarterTurns`. HDR is tone mapped to SDR, because a PNG or TIFF that other apps can read has
    /// nowhere to keep it.
    public static func encode(_ data: Data, as type: NSPasteboard.PasteboardType, quarterTurns: Int = 0) -> Data? {
        guard let identifier = UTType(type.rawValue)?.identifier else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(
                maximumEdge, PhotoDecoder.longEdge(of: source) ?? maximumEdge),
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
            let image = turned(upright, quarterTurns: quarterTurns)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// `image` turned clockwise, drawn into a new bitmap in its own color space.
    static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = (quarterTurns % 4 + 4) % 4
        guard turns != 0 else { return image }
        let (width, height) = turns % 2 == 1 ? (image.height, image.width) : (image.width, image.height)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let is16 = image.bitsPerComponent > 8
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: is16 ? 16 : 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | (is16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        else { return nil }
        // Core Graphics' y points up, so clockwise is a negative angle, about the new bitmap's center.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width),
                height: CGFloat(image.height)))
        return context.makeImage()
    }
}
