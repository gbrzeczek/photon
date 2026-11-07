import CoreGraphics
import Foundation
import IOSurface
import ImageIO
import PhotonCore
import Synchronization

/// Finished pixels, ready to assign to `CALayer.contents` on the main thread. IOSurfaces cut main-thread
/// time during scrolling to about a quarter of what `CGImage` costs (Spike 1).
public final class DecodedThumbnail: @unchecked Sendable {
    public let surface: IOSurface
    public let tier: ThumbnailTier
    public let width: Int
    public let height: Int

    init(surface: IOSurface, tier: ThumbnailTier, width: Int, height: Int) {
        self.surface = surface
        self.tier = tier
        self.width = width
        self.height = height
    }

    var byteCount: Int { surface.allocationSize }

    /// For tests in other modules, which render thumbnails to check how they reach the screen.
    public static func decodeForTesting(_ data: Data) -> DecodedThumbnail? { decode(data, tier: .small) }

    /// Decodes JPEG bytes in full, here, so that the main thread only assigns the result.
    /// Pixels are Display P3, so that wide-gamut photos keep their color on a P3 screen.
    static func decode(_ data: Data, tier: ThumbnailTier) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let surface = SurfaceDrawing.displayP3Surface(of: image)
        else { return nil }
        let (width, height) = (image.width, image.height)
        return DecodedThumbnail(surface: surface, tier: tier, width: width, height: height)
    }
}

/// Decoded thumbnails in memory, bounded by bytes.
///
/// Two generations stand in for a full LRU: entries go into the young one, and when that's full the old
/// one is dropped and the young one takes its place. Each operation is constant time, with no list to
/// maintain on a path the main thread takes for every tile.
public final class ThumbnailMemoryCache: Sendable {
    public struct Key: Hashable, Sendable {
        var asset: Int64
        var tier: ThumbnailTier
    }

    private struct Generations {
        var young: [Key: DecodedThumbnail] = [:]
        var old: [Key: DecodedThumbnail] = [:]
        var youngBytes = 0
    }

    private let state = Mutex(Generations())
    private let generationBytes: Int

    /// - Parameter byteLimit: The most this can hold, across both generations.
    public init(byteLimit: Int = 500 << 20) { generationBytes = byteLimit / 2 }

    public func thumbnail(asset: AssetID, tier: ThumbnailTier) -> DecodedThumbnail? {
        let key = Key(asset: asset.rawValue, tier: tier)
        return state.withLock { state in
            if let found = state.young[key] { return found }
            guard let found = state.old.removeValue(forKey: key) else { return nil }
            state.young[key] = found
            state.youngBytes += found.byteCount
            return found
        }
    }

    /// The best thumbnail in memory for a wanted tier: that tier, else the closest other one.
    public func nearest(asset: AssetID, wanted: ThumbnailTier) -> DecodedThumbnail? {
        for tier in Self.fallbacks(for: wanted) {
            if let found = thumbnail(asset: asset, tier: tier) { return found }
        }
        return nil
    }

    static func fallbacks(for wanted: ThumbnailTier) -> [ThumbnailTier] {
        switch wanted {
        case .large: [.large, .small, .preview]
        case .small: [.small, .large, .preview]
        case .preview: [.preview, .small, .large]
        }
    }

    public func insert(_ thumbnail: DecodedThumbnail, asset: AssetID) {
        let key = Key(asset: asset.rawValue, tier: thumbnail.tier)
        // Released outside the lock: freeing thousands of surfaces isn't instant.
        let retired: [Key: DecodedThumbnail]? = state.withLock { state in
            state.young[key] = thumbnail
            state.youngBytes += thumbnail.byteCount
            guard state.youngBytes >= generationBytes else { return nil }
            let retired = state.old
            state.old = state.young
            state.young = [:]
            state.youngBytes = 0
            return retired
        }
        _ = retired
    }

    /// Forgets everything for an asset whose content changed.
    public func remove(asset: AssetID) {
        state.withLock { state in
            for tier in ThumbnailTier.allCases {
                let key = Key(asset: asset.rawValue, tier: tier)
                state.young[key] = nil
                state.old[key] = nil
            }
        }
    }

    public var byteCount: Int {
        state.withLock { state in
            state.young.values.reduce(0) { $0 + $1.byteCount } + state.old.values.reduce(0) { $0 + $1.byteCount }
        }
    }
}
