import Foundation
import PhotonCore
import PhotonIndex
import os

/// One photo the viewer might show.
public struct ViewerItem: Sendable, Hashable {
    public var asset: AssetID
    public var instance: FileInstanceID
    /// The long edge of its preview, which is what fills the viewer exactly. Any larger and the screen
    /// would have to scale it back down, which costs sharpness as well as memory.
    public var previewEdge: Int

    public init(asset: AssetID, instance: FileInstanceID, previewEdge: Int) {
        self.asset = asset
        self.instance = instance
        self.previewEdge = previewEdge
    }
}

/// What has been decoded for one photo so far.
public struct ViewerImages: Sendable {
    public var preview: ViewerImage?
    public var full: ViewerImage?
}

/// The last two steps of progressive loading: a preview that fills the viewer, then the original's own
/// pixels. The first step, the stored thumbnail, comes from `ThumbnailLoader`.
///
/// Work follows `focus`, which names the photo on screen and its neighbors. Anything else is cancelled,
/// which stops a read at its next chunk. One read serves both decodes, and a neighbor's bytes stay in
/// memory, so that going on to it doesn't read the file again.
@MainActor
public final class ViewerImageLoader {
    public typealias Read = @Sendable (FileInstanceID, IOPriority) async throws -> Data?
    public typealias Decode = @Sendable (Data, Int?) -> ViewerImage?

    private struct Goal: Equatable {
        var priority: IOPriority
        var wantsFull: Bool
    }

    private struct Entry: Sendable {
        var item: ViewerItem
        var images = ViewerImages()
        var bytes: Data?
        var task: Task<Void, Never>?
        var goal: Goal?
        /// Which run owns `task`. A cancelled run can still be finishing when the next one starts.
        var run = 0
        /// There's nothing to read, or it can't be decoded. The thumbnail is all there is for now.
        var unavailable = false
        var lastUse = 0
    }

    private let read: Read
    private let decode: Decode
    private var entries: [AssetID: Entry] = [:]
    private var useCount = 0

    /// Decoding runs here rather than on Swift's pool, because a large photo holds a thread for a while.
    nonisolated private static let queue = DispatchQueue(
        label: "app.photon.viewer-decode", qos: .userInitiated, attributes: .concurrent)
    nonisolated private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: "Viewer")
    /// Photos kept decoded, counting the one on screen and its neighbors, so that going back is instant.
    private static let keptEntries = 7
    /// Originals kept in memory for the current photo and its neighbors.
    private static let bytesLimit = 300 << 20

    /// Called when `images(for:)` has something new for an asset.
    public var onImage: ((AssetID) -> Void)?

    public init(read: @escaping Read, decode: @escaping Decode = { PhotoDecoder.decode($0, maximumEdge: $1) }) {
        self.read = read
        self.decode = decode
    }

    public func images(for asset: AssetID) -> ViewerImages { entries[asset]?.images ?? ViewerImages() }

    /// Whether anything is still on its way for an asset.
    public func isLoading(_ asset: AssetID) -> Bool { entries[asset]?.task != nil }

    /// Says what's needed now, and cancels what isn't. Safe to call often: it only starts what's missing.
    ///
    /// - Parameters:
    ///   - current: The photo on screen, or nil to stop everything.
    ///   - neighbors: Photos worth having ready, nearest first. They stop at the preview.
    ///   - wantsFull: Whether the current photo should go on to full resolution.
    public func focus(current: ViewerItem?, neighbors: [ViewerItem], wantsFull: Bool) {
        var wanted: [(item: ViewerItem, goal: Goal)] = []
        if let current { wanted.append((current, Goal(priority: .visible, wantsFull: wantsFull))) }
        for neighbor in neighbors where neighbor.asset != current?.asset {
            wanted.append((neighbor, Goal(priority: .ahead, wantsFull: false)))
        }
        let keep = Set(wanted.map(\.item.asset))

        for asset in Array(entries.keys) where !keep.contains(asset) {
            entries[asset]?.task?.cancel()
            entries[asset]?.task = nil
            entries[asset]?.goal = nil
            Self.releaseLater(entries[asset]?.images.full)
            entries[asset]?.images.full = nil
        }
        // Most urgent first, because a neighbor's bytes may be trimmed to make room for these.
        for (item, _) in wanted.reversed() {
            useCount += 1
            entries[item.asset, default: Entry(item: item)].lastUse = useCount
            entries[item.asset]?.item = item
        }
        for (item, goal) in wanted { ensure(item, goal: goal) }
        trim(keeping: keep)
    }

    /// A volume came back, so what couldn't be read may be readable now. The next `focus` tries again.
    public func retryUnavailable() {
        for asset in entries.keys { entries[asset]?.unavailable = false }
    }

    /// Lets go of everything, as when the viewer closes.
    public func reset() {
        for entry in entries.values { entry.task?.cancel() }
        Self.releaseLater(entries)
        entries.removeAll()
    }

    /// Lets go of large surfaces and buffers away from the main thread, where freeing one can take
    /// milliseconds. The delay outlasts the commit that takes a surface off the screen.
    public nonisolated static func releaseLater(_ object: some Sendable) {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { _ = object }
    }

    private func needsNewPreview(_ entry: Entry) -> Bool {
        guard let preview = entry.images.preview else { return true }
        return preview.longEdge < entry.item.previewEdge && !preview.isFullResolution
    }

    private func needsWork(_ entry: Entry, goal: Goal) -> Bool {
        guard !entry.unavailable else { return false }
        if needsNewPreview(entry) { return true }
        guard let preview = entry.images.preview else { return true }
        return goal.wantsFull && !preview.isFullResolution && entry.images.full == nil
    }

    private func ensure(_ item: ViewerItem, goal: Goal) {
        guard let entry = entries[item.asset], needsWork(entry, goal: goal) else { return }
        if entry.task != nil {
            guard entry.goal != goal else { return }
            entry.task?.cancel()
        }
        let run = entry.run + 1
        entries[item.asset]?.run = run
        entries[item.asset]?.goal = goal
        entries[item.asset]?.task = Task { [weak self] in await self?.run(item, goal: goal, run: run) }
    }

    private func run(_ item: ViewerItem, goal: Goal, run: Int) async {
        let asset = item.asset
        defer { taskEnded(asset, run: run) }

        var bytes = entries[asset]?.bytes
        if bytes == nil {
            let interval = Self.signposter.beginInterval("Read original")
            let result = await readResult(item.instance, priority: goal.priority)
            Self.signposter.endInterval("Read original", interval)
            switch result {
            case .cancelled: return
            case .nothing:
                entries[asset]?.unavailable = true
                return
            case .bytes(let data):
                bytes = data
                entries[asset]?.bytes = data
            }
        }
        guard let bytes else { return }

        if let entry = entries[asset], needsNewPreview(entry) {
            guard !Task.isCancelled else { return }
            let interval = Self.signposter.beginInterval("Decode preview")
            let preview = await decoded(bytes, edge: item.previewEdge)
            Self.signposter.endInterval("Decode preview", interval)
            guard let preview else {
                entries[asset]?.unavailable = true
                return
            }
            // Kept even if this task was cancelled, because the work is done and it may be wanted again.
            guard entries[asset] != nil else { return }
            Self.releaseLater(entries[asset]?.images.preview)
            entries[asset]?.images.preview = preview
            onImage?(asset)
        }

        guard goal.wantsFull, !Task.isCancelled, entries[asset]?.images.preview?.isFullResolution == false,
            entries[asset]?.images.full == nil
        else { return }
        let interval = Self.signposter.beginInterval("Decode full")
        let full = await decoded(bytes, edge: nil)
        Self.signposter.endInterval("Decode full", interval)
        guard let full, entries[asset]?.run == run, !Task.isCancelled else { return }
        entries[asset]?.images.full = full
        onImage?(asset)
    }

    private enum ReadResult {
        case bytes(Data)
        case nothing
        case cancelled
    }

    private func readResult(_ instance: FileInstanceID, priority: IOPriority) async -> ReadResult {
        do {
            return try await read(instance, priority).map(ReadResult.bytes) ?? .nothing
        } catch {
            return .cancelled
        }
    }

    private func decoded(_ bytes: Data, edge: Int?) async -> ViewerImage? {
        let decode = decode
        return await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: autoreleasepool { decode(bytes, edge) }) }
        }
    }

    private func taskEnded(_ asset: AssetID, run: Int) {
        guard entries[asset]?.run == run else { return }
        entries[asset]?.task = nil
        entries[asset]?.goal = nil
    }

    private func trim(keeping keep: Set<AssetID>) {
        let oldestFirst = entries.values.sorted { $0.lastUse < $1.lastUse }
        var surplus = entries.count - Self.keptEntries
        for entry in oldestFirst where surplus > 0 && !keep.contains(entry.item.asset) {
            entries[entry.item.asset] = nil
            Self.releaseLater(entry.images)
            Self.releaseLater(entry.bytes)
            surplus -= 1
        }
        var bytes = entries.values.reduce(0) { $0 + ($1.bytes?.count ?? 0) }
        for entry in oldestFirst where bytes > Self.bytesLimit {
            guard let count = entries[entry.item.asset]?.bytes?.count else { continue }
            Self.releaseLater(entries[entry.item.asset]?.bytes)
            entries[entry.item.asset]?.bytes = nil
            bytes -= count
        }
    }
}
