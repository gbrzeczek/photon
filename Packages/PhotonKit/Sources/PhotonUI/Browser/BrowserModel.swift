import AppKit
import Foundation
import Observation
import PhotonCore
import PhotonMedia
import os

public enum BrowserViewMode: Int, Sendable, CaseIterable {
    case tiles = 0
    case list = 1
}

/// Moves of the current item, from the keyboard.
enum BrowserMove: Sendable, Equatable {
    case left, right, up, down, pageUp, pageDown, home, end
}

/// A row, and how far from the top of the viewport it is.
struct ViewAnchor: Equatable {
    var row: Int
    var screenY: CGFloat
}

/// What the grid and the list both do. One of them is showing at a time, and the other stays alive.
@MainActor
protocol BrowserContent: AnyObject {
    /// The tile to keep in place when the rows change.
    func captureAnchor() -> ViewAnchor?
    func resultDidChange(_ result: BrowseResult, anchor: ViewAnchor?, rows: AspectRows?, prefix: [Double])
    func selectionDidChange()
    /// Brings the current item on screen, without moving more than needed.
    func revealCurrent()
    /// Where a move lands from `row`.
    func row(after move: BrowserMove, from row: Int) -> Int?
    /// Takes keyboard focus.
    func focus()
    func tileSizeDidChange()
    func layoutModeDidChange()
    /// Finished thumbnails are waiting in the loader.
    func thumbnailsReady()
}

/// The state of one window's browser. Grid and list share this: one data source, one selection.
@MainActor
@Observable
public final class BrowserModel {
    public private(set) var scope: BrowseScope?
    public private(set) var sort = BrowseSort.default
    public private(set) var viewMode = BrowserViewMode.tiles
    public private(set) var tileSize = Double(TileMetrics.defaultTile)
    public private(set) var layoutMode = TileLayoutMode.square
    public private(set) var itemCount = 0
    public private(set) var selectedCount = 0
    public private(set) var isLoading = false

    @ObservationIgnored let library: BrowserLibrary
    @ObservationIgnored let selection = SelectionModel()
    @ObservationIgnored let pages: RowPageCache
    @ObservationIgnored private(set) var result = BrowseResult.empty
    @ObservationIgnored private var grid: (any BrowserContent)?
    @ObservationIgnored private var list: (any BrowserContent)?
    @ObservationIgnored private var showMode: ((BrowserViewMode) -> Void)?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastContentReload = ContinuousClock.now
    @ObservationIgnored private var pendingContentReload: Task<Void, Never>?
    @ObservationIgnored private var typedName = ""
    @ObservationIgnored private var typedAt = ContinuousClock.now
    /// Layout inputs the grid has now, so that the query task can do the full pass.
    @ObservationIgnored var layoutWidth: CGFloat = 1
    /// Called after each result lands, with its row count.
    @ObservationIgnored var onResult: ((Int) -> Void)?

    nonisolated private static let signposter = OSSignposter(subsystem: "app.photon", category: "Browser")
    /// How often the library may be queried again while indexing changes it.
    private static let contentReloadInterval: Duration = .seconds(2)

    public init(library: BrowserLibrary) {
        self.library = library
        pages = RowPageCache(store: library.store)
        library.onContentChanged = { [weak self] in self?.contentChanged() }
        library.loader.setFinishedHandler { [weak self] in
            DispatchQueue.main.async { self?.active?.thumbnailsReady() }
        }
    }

    private var active: (any BrowserContent)? { viewMode == .tiles ? grid : list }

    func attach(grid: any BrowserContent, list: any BrowserContent, showMode: @escaping (BrowserViewMode) -> Void) {
        self.grid = grid
        self.list = list
        self.showMode = showMode
        showMode(viewMode)
    }

    // MARK: Opening

    /// Reopens the folder used last, or the first one.
    public func restore() async {
        if let session = try? await library.store.latestSession() {
            apply(session)
        } else if let first = library.folders.first {
            open(BrowseScope(volume: first.volume, path: first.path))
        }
    }

    public func open(_ scope: BrowseScope) {
        guard scope != self.scope else { return }
        flushSession()
        Task {
            let session = try? await library.store.session(for: scope)
            guard let session else {
                self.scope = scope
                self.selection.reset()
                self.reload(keepPosition: false)
                return
            }
            self.apply(session)
        }
    }

    private func apply(_ session: BrowseSession) {
        scope = session.scope
        sort = session.sort
        viewMode = BrowserViewMode(rawValue: session.viewMode) ?? .tiles
        showMode?(viewMode)
        if let size = session.tileSize { tileSize = size }
        selection.reset()
        reload(keepPosition: false, restoring: session.anchor)
    }

    /// Goes to the enclosing folder, up to the root. Command-Up.
    public func openParent() {
        guard let scope, let parent = parentScope(of: scope) else { return }
        open(parent)
    }

    public var canOpenParent: Bool { scope.flatMap(parentScope) != nil }

    private func parentScope(of scope: BrowseScope) -> BrowseScope? {
        let root = library.folders.last { $0.isRoot && $0.volume == scope.volume && isWithin(scope.path, root: $0.path) }
        return root.flatMap { scope.parent(within: $0.path) }
    }

    private func isWithin(_ path: String, root: String) -> Bool {
        root.isEmpty || path == root || path.hasPrefix(root + "/")
    }

    // MARK: Queries

    /// Runs the query and the layout pass off the main thread, then installs them together, keeping
    /// the anchor where it is. Nothing main-thread here grows with the library.
    func reload(keepPosition: Bool, restoring anchorAsset: AssetID? = nil) {
        guard let scope else { return }
        generation += 1
        let generation = generation
        reloadTask?.cancel()
        isLoading = true

        let store = library.store
        let sort = sort
        let base = keepPosition ? result : BrowseResult.empty
        let baseRows = keepPosition ? selection.rows : IndexSet()
        let baseVersion = selection.version
        let mode = layoutMode
        let width = layoutWidth
        let tile = CGFloat(tileSize)

        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let interval = Self.signposter.beginInterval("Query")
            defer { Self.signposter.endInterval("Query", interval) }
            guard let result = try? await store.browse(scope, sort: sort), !Task.isCancelled else { return }
            let prefix = TileLayout.prefixSums(result.aspects)
            let rows: AspectRows? = mode == .aspect && width > 1
                ? AspectRows.compute(
                    aspects: result.aspects, width: width, target: tile, spacing: TileMetrics.spacing)
                : nil
            let map = base.count > 0 ? base.rowMap(to: result) : []
            let selected = SelectionModel.remapped(baseRows, map: map)
            let wanted = anchorAsset.flatMap { result.row(of: $0) }
            await self?.install(
                result, generation: generation, prefix: prefix, rows: rows, map: map, selected: selected,
                selectionVersion: baseVersion, wantedRow: wanted, keepPosition: keepPosition)
        }
    }

    private func install(
        _ next: BrowseResult, generation: Int, prefix: [Double], rows: AspectRows?, map: [Int32],
        selected: IndexSet, selectionVersion: Int, wantedRow: Int?, keepPosition: Bool
    ) {
        guard generation == self.generation else { return }
        let interval = Self.signposter.beginInterval("Install")
        defer { Self.signposter.endInterval("Install", interval) }

        // The current view position, captured last, in terms of the old rows.
        var anchor = keepPosition ? active?.captureAnchor() : nil
        if let row = anchor?.row { anchor?.row = Self.survivor(of: row, map: map) ?? 0 }

        var nextSelected = selected
        if selection.version != selectionVersion, !map.isEmpty {
            // The selection changed while the query ran. This is rare, and it's bounded by the selection.
            nextSelected = SelectionModel.remapped(selection.rows, map: map)
        }
        var current: Int?
        if let wantedRow {
            current = wantedRow
        } else if keepPosition, let row = selection.currentRow {
            current = Self.survivor(of: row, map: map)
        }
        if wantedRow != nil { nextSelected = current.map { IndexSet(integer: $0) } ?? IndexSet() }
        let asset = current.map { AssetID(rawValue: next.assetIDs[$0]) }
        if !keepPosition, let wantedRow { anchor = ViewAnchor(row: wantedRow, screenY: 120) }

        result = next
        itemCount = next.count
        pages.reset(next)
        selection.install(rows: nextSelected, current: current, asset: asset)
        selectedCount = nextSelected.count
        grid?.resultDidChange(next, anchor: anchor, rows: rows, prefix: prefix)
        list?.resultDidChange(next, anchor: anchor, rows: rows, prefix: prefix)
        isLoading = false
        onResult?(next.count)
    }

    /// The nearest row after a change of result, looking outward for one that still exists.
    /// Bounded, so that it stays cheap on the main thread.
    private static func survivor(of row: Int, map: [Int32]) -> Int? {
        guard row < map.count else { return nil }
        for distance in 0..<256 {
            if row + distance < map.count, map[row + distance] >= 0 { return Int(map[row + distance]) }
            if row - distance >= 0, map[row - distance] >= 0 { return Int(map[row - distance]) }
        }
        return nil
    }

    private func contentChanged() {
        guard scope != nil, pendingContentReload == nil else { return }
        let wait = Self.contentReloadInterval - (ContinuousClock.now - lastContentReload)
        pendingContentReload = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            pendingContentReload = nil
            lastContentReload = .now
            reload(keepPosition: true)
        }
    }

    // MARK: Changing the view

    public func setSort(_ next: BrowseSort) {
        guard next != sort else { return }
        sort = next
        reload(keepPosition: true)
        saveSessionSoon()
    }

    /// Picks a sort key, or flips the order if it's already in use.
    public func chooseSort(_ key: SortKey) {
        setSort(
            key == sort.key
                ? BrowseSort(key: key, ascending: !sort.ascending)
                : BrowseSort(key: key, ascending: key.defaultAscending))
    }

    public func setViewMode(_ mode: BrowserViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        // The view has to be showing before it can take focus.
        showMode?(mode)
        active?.revealCurrent()
        active?.focus()
        saveSessionSoon()
    }

    public func setLayoutMode(_ mode: TileLayoutMode) {
        guard mode != layoutMode else { return }
        layoutMode = mode
        grid?.layoutModeDidChange()
    }

    /// Records a size chosen by the slider, a pinch or a shortcut. The grid applies it.
    func setTileSize(_ size: CGFloat) {
        tileSize = Double(min(max(size, TileMetrics.minimumTile), TileMetrics.maximumTile))
        grid?.tileSizeDidChange()
        saveSessionSoon()
    }

    /// A pinch. The grid has already applied the size, step by step, so this only records it.
    func setTileSizeFromGesture(_ size: CGFloat) {
        tileSize = Double(size)
        saveSessionSoon()
    }

    /// A step for Command-Equals and Command-Minus.
    public func stepTileSize(larger: Bool) {
        setTileSize(CGFloat(tileSize) * (larger ? 1.25 : 0.8))
    }

    public func setTileSizeFromSlider(_ size: Double) { setTileSize(CGFloat(size)) }

    // MARK: Selection and movement

    func move(_ move: BrowserMove, extending: Bool) {
        guard result.count > 0 else { return }
        guard let from = selection.currentRow else {
            // Nothing to move from yet, so a move starts at whichever end it points to.
            select(row: move == .end ? result.count - 1 : 0)
            active?.revealCurrent()
            return
        }
        guard let target = active?.row(after: move, from: from) else { return }
        guard target != from || !extending else { return }
        let asset = AssetID(rawValue: result.assetIDs[target])
        if extending {
            selection.extend(to: target, asset: asset)
        } else {
            selection.select(target, asset: asset)
        }
        selectionChanged()
        active?.revealCurrent()
    }

    func select(row: Int) {
        guard row < result.count else { return }
        selection.select(row, asset: AssetID(rawValue: result.assetIDs[row]))
        selectionChanged()
    }

    func toggle(row: Int) {
        guard row < result.count else { return }
        selection.toggle(row, asset: AssetID(rawValue: result.assetIDs[row]))
        selectionChanged()
    }

    func extendSelection(to row: Int) {
        guard row < result.count else { return }
        selection.extend(to: row, asset: AssetID(rawValue: result.assetIDs[row]))
        selectionChanged()
    }

    func adoptSelection(rows: IndexSet, current: Int?) {
        let asset = current.map { AssetID(rawValue: result.assetIDs[$0]) }
        selection.adopt(rows: rows, current: current, asset: asset)
        selectionChanged()
    }

    public func selectAll() {
        selection.selectAll(count: result.count)
        selectionChanged()
    }

    public func selectNone() {
        selection.selectNone()
        selectionChanged()
    }

    private func selectionChanged() {
        selectedCount = selection.count
        grid?.selectionDidChange()
        list?.selectionDidChange()
        saveSessionSoon()
    }

    /// Jumps to a typed name, in the list. Letters typed within a second build up one name.
    func typeSelect(_ characters: String) {
        let now = ContinuousClock.now
        if now - typedAt > .seconds(1) { typedName = "" }
        typedAt = now
        typedName += characters
        guard let scope else { return }
        let prefix = typedName
        let store = library.store
        let result = result
        Task {
            let row = await Task.detached(priority: .userInitiated) { () -> Int? in
                guard let found = try? await store.instances(in: scope, namePrefix: prefix, limit: 64) else {
                    return nil
                }
                let wanted = Set(found)
                // The first by name, among those in this result. Duplicates may be missing from it.
                var rows: [Int64: Int] = [:]
                for (row, instance) in result.instanceIDs.enumerated() where wanted.contains(instance) {
                    rows[instance] = row
                }
                return found.lazy.compactMap { rows[$0] }.first
            }.value
            guard let row, result === self.result, prefix == self.typedName else { return }
            self.select(row: row)
            self.active?.revealCurrent()
        }
    }

    // MARK: Sessions

    private func saveSessionSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flushSession()
        }
    }

    /// Saves where the user is, anchored to an asset. Called on leaving a folder too.
    public func flushSession() {
        guard let scope else { return }
        let anchor = selection.currentAsset
            ?? active?.captureAnchor().flatMap { $0.row < result.count ? AssetID(rawValue: result.assetIDs[$0.row]) : nil }
        let session = BrowseSession(
            scope: scope, sort: sort, viewMode: viewMode.rawValue, tileSize: tileSize, anchor: anchor)
        let store = library.store
        Task { try? await store.saveSession(session) }
    }

    // MARK: Files

    /// Opens Finder at the current selection. Offline files can't be shown, so nothing happens.
    func showInFinder(rows: [Int]) {
        let instances = rows.prefix(32).map { result.instanceIDs[$0] }
        let store = library.store
        let indexer = library.indexer
        Task {
            let browseRows = (try? await store.browseRows(instances: instances)) ?? []
            let urls = browseRows.compactMap { row -> URL? in
                indexer.mountPoint(of: row.volumeID).map {
                    URL(fileURLWithPath: $0).appending(path: row.path.string, directoryHint: .notDirectory)
                }
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }
}
