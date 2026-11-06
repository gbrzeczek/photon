import CoreGraphics
import Foundation
import ImageIO
import PhotonCore
import PhotonMedia
import PhotonTestSupport
import UniformTypeIdentifiers

/// Writes a library with no real files, for measuring the grid: rows for a large folder tree, on a volume
/// that's never mounted, with thumbnails in real packs. Assets share a set of template thumbnails, so a
/// million items take seconds and little disk, and decoding costs what it does for real ones.
func runSeed() async throws {
    let count = option("--count").flatMap(Int.init) ?? 100_000
    let seed = option("--seed").flatMap(UInt64.init) ?? 1
    let store = try openStore()
    let packs = ThumbnailPackStore(store: store)
    let volume = try await store.insertVolume(
        uuid: "SYNTHETIC-\(seed)-\(UUID().uuidString)", name: "Synthetic", capacity: nil, filesystem: "none")
    let root = "Library"
    try await store.addRoot(volume: volume.id, relativePath: root)

    let aspects: [(width: Int, height: Int)] = [(2, 3), (3, 4), (1, 1), (4, 3), (3, 2), (16, 9)]
    var templates: [[ThumbnailLocation]] = []
    var colors: [UInt32] = []
    for index in 0..<(aspects.count * 16) {
        let aspect = aspects[index % aspects.count]
        var generator = SeededGenerator(seed: seed &+ UInt64(index))
        let thumbnails = ThumbnailTier.allCases.filter { $0 != .preview }.compactMap { tier -> EncodedThumbnail? in
            let edge = tier == .small ? ThumbnailSizes.small : ThumbnailSizes.large
            var copy = generator
            return template(aspect: aspect, longEdge: edge, tier: tier, generator: &copy)
        }
        templates.append(try await packs.append(thumbnails))
        colors.append(UInt32.random(in: 0...0xFF_FFFF, using: &generator))
    }

    var generator = SeededGenerator(seed: seed)
    let perFolder = 500
    var firstAsset: AssetID?
    for folder in stride(from: 0, to: count, by: perFolder) {
        let directory = "\(root)/\(2000 + folder / 50_000)/\(folder / perFolder)"
        let items = folder..<min(folder + perFolder, count)
        let files = items.map { index -> ScannedFile in
            let isVideo = index % 10 == 1
            return ScannedFile(
                name: String(format: isVideo ? "VID_%07d.MP4" : "IMG_%07d.JPG", index),
                kind: isVideo ? .video : .photo,
                size: Int64.random(in: 1_000_000...8_000_000, using: &generator),
                modifiedTime: FileTimestamp(seconds: 1_500_000_000 + index, nanoseconds: 0))
        }
        _ = try await store.applyDirectory(volume: volume.id, directory: directory, files: files)
        let instances = try await store.instances(volume: volume.id, directory: directory)

        var indexed: [IndexedFile] = []
        var records: [ThumbnailRecord] = []
        for instance in instances {
            let index = Int(instance.id.rawValue)
            let template = Int.random(in: 0..<templates.count, using: &generator)
            let aspect = aspects[template % aspects.count]
            let scale = 500
            var hash = Data(count: 32)
            withUnsafeBytes(of: UInt64(index).littleEndian) { hash.replaceSubrange(0..<8, with: $0) }
            withUnsafeBytes(of: seed.littleEndian) { hash.replaceSubrange(8..<16, with: $0) }
            let date = 1_400_000_000_000 + Int64.random(in: 0...315_000_000_000, using: &generator)
            let isVideo = instance.path.fileExtension == "MP4"
            indexed.append(
                IndexedFile(
                    instanceID: instance.id, size: instance.size, modifiedTime: instance.modifiedTime,
                    hash: ContentHash(bytes: hash)!,
                    metadata: MediaMetadata(
                        pixelWidth: aspect.width * scale, pixelHeight: aspect.height * scale,
                        captureDate: CaptureDate(wallClockMilliseconds: date),
                        durationSeconds: isVideo ? Double.random(in: 2...600, using: &generator) : nil)))
            if !isVideo {
                records.append(
                    ThumbnailRecord(
                        assetID: instance.assetID, instanceID: instance.id, size: instance.size,
                        modifiedTime: instance.modifiedTime, state: .complete, dominantColor: colors[template],
                        locations: templates[template]))
            }
            firstAsset = firstAsset ?? instance.assetID
        }
        _ = try await store.applyIndexed(indexed)
        try await store.recordThumbnails(records)
    }
    try await store.saveSession(
        BrowseSession(
            scope: BrowseScope(volume: volume.id, path: root), sort: .default, viewMode: 0, tileSize: 160, anchor: nil))
    print("\(count) items in \(count / perFolder + 1) folders")
}

/// Blobs of color, compressing about as a photo does.
private func template(
    aspect: (width: Int, height: Int), longEdge: Int, tier: ThumbnailTier, generator: inout SeededGenerator
) -> EncodedThumbnail? {
    let scale = Double(longEdge) / Double(max(aspect.width, aspect.height))
    let (width, height) = (Int(Double(aspect.width) * scale), Int(Double(aspect.height) * scale))
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(gray: .random(in: 0.2...0.8, using: &generator), alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let limit = CGFloat(longEdge)
    for _ in 0..<40 {
        context.setFillColor(
            red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
            blue: .random(in: 0...1, using: &generator), alpha: 0.7)
        context.fillEllipse(
            in: CGRect(
                x: .random(in: -limit / 4...limit, using: &generator),
                y: .random(in: -limit / 4...limit, using: &generator),
                width: .random(in: limit / 12...limit / 2, using: &generator),
                height: .random(in: limit / 12...limit / 2, using: &generator)))
    }
    guard let image = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return EncodedThumbnail(tier: tier, data: output as Data, width: width, height: height)
}
