import Foundation
import PhotonCore
import PhotonIndex
import Synchronization
import os

/// One tile's request for pixels.
public struct ThumbnailRequest: Sendable, Hashable {
    public var asset: AssetID
    public var instance: FileInstanceID
    public var wanted: ThumbnailTier
    public var priority: IOPriority
    /// Whether a missing size should be made from the original. The viewer reads the original anyway,
    /// so for it this would be a second read of the same file.
    public var generatesMissing: Bool

    public init(
        asset: AssetID, instance: FileInstanceID, wanted: ThumbnailTier, priority: IOPriority,
        generatesMissing: Bool = true
    ) {
        self.asset = asset
        self.instance = instance
        self.wanted = wanted
        self.priority = priority
        self.generatesMissing = generatesMissing
    }
}

/// Gets thumbnails from packs to tiles, off the main thread.
///
/// The newest requests run first, as a scrolling grid wants, and requests for tiles that have gone are
/// skipped. Finished thumbnails queue up, and the main thread takes a bounded batch per frame, so that
/// a backlog can't flood it. A tile that lacks a size starts the generator for it.
public final class ThumbnailLoader: @unchecked Sendable {
    private let store: LibraryStore
    private let packs: ThumbnailPackStore
    private let generator: ThumbnailGenerator
    public let cache: ThumbnailMemoryCache

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var stack: [ThumbnailRequest] = []
    private var wanted: [AssetID: ThumbnailRequest] = [:]
    private var finished: [(asset: AssetID, thumbnail: DecodedThumbnail)] = []
    private var generating: [AssetID: Task<Void, Never>] = [:]
    private var stopped = false
    private var onFinished: (@Sendable () -> Void)?

    private static let batchSize = 8
    private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: "Thumbnails")

    public init(
        store: LibraryStore, packs: ThumbnailPackStore, generator: ThumbnailGenerator, cache: ThumbnailMemoryCache,
        workers: Int = 4
    ) {
        self.store = store
        self.packs = packs
        self.generator = generator
        self.cache = cache
        for index in 0..<workers {
            let thread = Thread { [weak self] in self?.work() }
            thread.name = "Thumbnail decode \(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Called from a decoding thread whenever `drain` has something new, or the queue has emptied.
    public func setFinishedHandler(_ handler: @escaping @Sendable () -> Void) {
        condition.lock()
        onFinished = handler
        condition.unlock()
    }

    /// Stops the decoding threads. For tests and teardown.
    public func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    /// Asks for an asset. Safe on the main thread: it only queues.
    public func request(_ request: ThumbnailRequest) {
        condition.lock()
        defer { condition.unlock() }
        // An existing request for the same size is still in the stack.
        if let existing = wanted[request.asset], existing.wanted >= request.wanted { return }
        wanted[request.asset] = request
        stack.append(request)
        condition.signal()
    }

    /// A tile went away. Queued work is skipped, and a read in progress stops at its next chunk.
    public func cancel(_ asset: AssetID) {
        condition.lock()
        wanted[asset] = nil
        let task = generating.removeValue(forKey: asset)
        condition.unlock()
        task?.cancel()
    }

    /// A bounded batch of finished thumbnails. Call once per frame.
    public func drain(limit: Int) -> [(asset: AssetID, thumbnail: DecodedThumbnail)] {
        condition.lock()
        defer { condition.unlock() }
        let count = min(limit, finished.count)
        let batch = Array(finished.prefix(count))
        finished.removeFirst(count)
        return batch
    }

    public var hasFinishedThumbnails: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !finished.isEmpty
    }

    /// The bytes of the largest stored thumbnail, which is all an offline photo has. Blocks on the
    /// database and the packs, so never call it on the main thread, or from Swift's cooperative pool.
    public func storedThumbnailBlocking(asset: AssetID) -> Data? {
        let locations = (try? store.thumbnailLocationsBlocking(assets: [asset])[asset]) ?? []
        return locations.max { $0.tier < $1.tier }.flatMap { packs.readBlocking($0) }
    }

    // MARK: Workers

    private func work() {
        while true {
            let batch = nextBatch()
            guard let batch else { return }
            autoreleasepool { load(batch) }
        }
    }

    private func nextBatch() -> [ThumbnailRequest]? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty, !stopped { condition.wait() }
        if stopped { return nil }
        var batch: [ThumbnailRequest] = []
        while batch.count < Self.batchSize, let request = stack.popLast() {
            // Skips requests that were cancelled, or replaced by one for a larger size.
            if wanted[request.asset] == request { batch.append(request) }
        }
        return batch
    }

    private func load(_ batch: [ThumbnailRequest]) {
        guard !batch.isEmpty else { return }
        let interval = Self.signposter.beginInterval("Load batch", "\(batch.count)")
        defer { Self.signposter.endInterval("Load batch", interval) }
        let locations = (try? store.thumbnailLocationsBlocking(assets: batch.map(\.asset))) ?? [:]
        for request in batch {
            guard isWanted(request) else { continue }
            let stored = locations[request.asset] ?? []
            var bestTier: ThumbnailTier?
            for tier in ThumbnailMemoryCache.fallbacks(for: request.wanted) {
                guard let location = stored.first(where: { $0.tier == tier }) else { continue }
                if let found = cache.thumbnail(asset: request.asset, tier: tier) {
                    deliver(found, for: request)
                } else if let data = packs.readBlocking(location),
                    let decoded = DecodedThumbnail.decode(data, tier: tier)
                {
                    cache.insert(decoded, asset: request.asset)
                    deliver(decoded, for: request)
                } else {
                    // The bytes are gone, or damaged. Forget the row, so that it gets made again.
                    let store = store
                    Task.detached { try? await store.dropThumbnail(asset: request.asset, tier: tier) }
                    continue
                }
                bestTier = tier
                break
            }
            if bestTier.map({ $0 >= request.wanted }) == true || !request.generatesMissing {
                finish(request)
            } else {
                // Originals too small for this size never get it. The generator knows, and stops at once.
                startGenerating(request)
            }
        }
    }

    private func isWanted(_ request: ThumbnailRequest) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return wanted[request.asset] == request
    }

    private func deliver(_ thumbnail: DecodedThumbnail, for request: ThumbnailRequest) {
        condition.lock()
        finished.append((request.asset, thumbnail))
        let handler = onFinished
        condition.unlock()
        handler?()
    }

    private func finish(_ request: ThumbnailRequest) {
        condition.lock()
        if wanted[request.asset] == request { wanted[request.asset] = nil }
        condition.unlock()
    }

    private func startGenerating(_ request: ThumbnailRequest) {
        condition.lock()
        defer { condition.unlock() }
        guard generating[request.asset] == nil, wanted[request.asset] == request else { return }
        generating[request.asset] = Task.detached(priority: .userInitiated) { [self] in
            try? await generator.generate(
                asset: request.asset, instance: request.instance, priority: request.priority
            ) { [self] in reload(request) }
            generationEnded(request)
        }
    }

    /// New bytes are in a pack, so the tile can have them. Bypasses `generating`, which is still set.
    private func reload(_ request: ThumbnailRequest) {
        guard let locations = try? store.thumbnailLocationsBlocking(assets: [request.asset])[request.asset]
        else { return }
        for tier in ThumbnailMemoryCache.fallbacks(for: request.wanted) {
            guard let location = locations.first(where: { $0.tier == tier }), let data = packs.readBlocking(location),
                let decoded = DecodedThumbnail.decode(data, tier: tier)
            else { continue }
            cache.insert(decoded, asset: request.asset)
            deliver(decoded, for: request)
            return
        }
    }

    private func generationEnded(_ request: ThumbnailRequest) {
        condition.lock()
        generating[request.asset] = nil
        if wanted[request.asset] == request { wanted[request.asset] = nil }
        condition.unlock()
    }
}
