import Darwin
import Foundation
import PhotonCore
import Synchronization

public struct ThumbnailPackOptions: Sendable {
    /// A pack is the unit of eviction, so this is how much goes in one step.
    public var packByteLimit: Int64 = 256 << 20
    /// The total to keep. Small thumbnails stay whatever this says, and only large ones are evicted.
    public var cacheByteLimit: Int64 = 20 << 30
    public init() {}
}

public enum ThumbnailPackError: Error, Equatable, Sendable {
    case writeFailed(Int32)
}

/// Append-only pack files on the internal disk, with offsets in the database.
///
/// Bytes are written before their rows, so a crash can only leave unused bytes behind. Those, and
/// thumbnails replaced later, stay until their pack is evicted. Packs are cheap to throw away, because
/// everything in them can be made again while the drive is connected.
public final class ThumbnailPackStore: Sendable {
    private let store: LibraryStore
    private let directory: URL
    private let options: ThumbnailPackOptions
    private let writer: PackWriter
    private let handles = Mutex<[Int64: PackHandle]>([:])
    private let usedPacks = Mutex<Set<Int64>>([])

    /// Packs live beside the library, which is always on the internal disk.
    public init(store: LibraryStore, options: ThumbnailPackOptions = ThumbnailPackOptions()) {
        self.store = store
        self.options = options
        directory = store.databaseURL.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
        writer = PackWriter(store: store, directory: directory, limit: options.packByteLimit)
    }

    static func fileURL(in directory: URL, pack: Int64) -> URL {
        directory.appending(path: "\(pack).pack", directoryHint: .notDirectory)
    }

    /// Writes thumbnails, and returns where each one went, in the same order.
    public func append(_ thumbnails: [EncodedThumbnail]) async throws -> [ThumbnailLocation] {
        try await writer.append(thumbnails)
    }

    /// Reads one thumbnail. Blocks, for the decoding threads. Returns nil when its bytes are missing,
    /// so that the caller can make it again.
    public func readBlocking(_ location: ThumbnailLocation) -> Data? {
        usedPacks.withLock { _ = $0.insert(location.packID) }
        guard let handle = handle(for: location.packID) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: location.length, alignment: 16)
        let count = pread(handle.descriptor, buffer, location.length, off_t(location.offset))
        guard count == location.length else {
            buffer.deallocate()
            return nil
        }
        return Data(bytesNoCopy: buffer, count: count, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    private func handle(for pack: Int64) -> PackHandle? {
        if let existing = handles.withLock({ $0[pack] }) { return existing }
        let path = Self.fileURL(in: directory, pack: pack).path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = PackHandle(descriptor: descriptor)
        return handles.withLock { handles in
            if let raced = handles[pack] { return raced }
            handles[pack] = handle
            return handle
        }
    }

    // MARK: Eviction

    /// Deletes packs nothing refers to, then evicts large packs until the cache fits its limit: the
    /// least recently used first, and those holding favorites last. Small packs are never evicted.
    public func enforceLimit() async throws {
        let used = Array(usedPacks.withLock { used in
            defer { used.removeAll() }
            return used
        })
        try await store.markThumbnailPacksUsed(used)

        let open = await writer.openPacks()
        for pack in try await store.emptyThumbnailPacks(keeping: open) { try await remove(pack) }

        let packs = try await store.thumbnailPacks()
        var total = packs.reduce(0) { $0 + $1.byteCount }
        guard total > options.cacheByteLimit else { return }
        let candidates = packs
            .filter { $0.tier == .large && !open.contains($0.id) }
            .sorted {
                let (left, right) = ($0.favoriteCount > 0, $1.favoriteCount > 0)
                return left != right ? !left : $0.lastUsedAt < $1.lastUsedAt
            }
        for pack in candidates where total > options.cacheByteLimit {
            try await remove(pack.id)
            total -= pack.byteCount
        }
    }

    private func remove(_ pack: Int64) async throws {
        try await store.deleteThumbnailPack(pack)
        // A read in progress keeps its own reference, so its descriptor stays valid until it's done.
        _ = handles.withLock { $0.removeValue(forKey: pack) }
        try? FileManager.default.removeItem(at: Self.fileURL(in: directory, pack: pack))
    }
}

/// Keeps a pack's descriptor open while anything still uses it.
private final class PackHandle: Sendable {
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
}

/// One open pack per tier, and a single writer.
private actor PackWriter {
    private struct OpenPack {
        let id: Int64
        let descriptor: Int32
        var size: Int64
    }

    private let store: LibraryStore
    private let directory: URL
    private let limit: Int64
    private var open: [ThumbnailTier: OpenPack] = [:]

    init(store: LibraryStore, directory: URL, limit: Int64) {
        self.store = store
        self.directory = directory
        self.limit = limit
    }

    deinit {
        for pack in open.values { close(pack.descriptor) }
    }

    func openPacks() -> Set<Int64> { Set(open.values.map(\.id)) }

    func append(_ thumbnails: [EncodedThumbnail]) async throws -> [ThumbnailLocation] {
        var locations: [ThumbnailLocation] = []
        locations.reserveCapacity(thumbnails.count)
        for thumbnail in thumbnails {
            var pack = try await pack(for: thumbnail.tier)
            let offset = pack.size
            try write(thumbnail.data, to: pack.descriptor, at: offset)
            pack.size += Int64(thumbnail.data.count)
            open[thumbnail.tier] = pack
            locations.append(
                ThumbnailLocation(
                    tier: thumbnail.tier, packID: pack.id, offset: offset, length: thumbnail.data.count,
                    width: thumbnail.width, height: thumbnail.height))
        }
        for tier in Set(thumbnails.map(\.tier)) {
            if let pack = open[tier] { try await store.setThumbnailPackSize(pack.id, byteCount: pack.size) }
        }
        return locations
    }

    private func pack(for tier: ThumbnailTier) async throws -> OpenPack {
        if let pack = open[tier] {
            guard pack.size >= limit else { return pack }
            close(pack.descriptor)
            open[tier] = nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = try await store.insertThumbnailPack(tier: tier)
        let path = ThumbnailPackStore.fileURL(in: directory, pack: id).path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw ThumbnailPackError.writeFailed(errno) }
        return OpenPack(id: id, descriptor: descriptor, size: 0)
    }

    private func write(_ data: Data, to descriptor: Int32, at offset: Int64) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var written = 0
            while written < bytes.count {
                let count = pwrite(
                    descriptor, bytes.baseAddress! + written, bytes.count - written, off_t(offset) + off_t(written))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ThumbnailPackError.writeFailed(errno)
                }
                written += count
            }
        }
    }
}
