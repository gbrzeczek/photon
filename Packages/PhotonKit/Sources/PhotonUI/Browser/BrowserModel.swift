import AppKit
import Foundation
import Observation
import PhotonCore
import PhotonIndex
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

/// Where a saved session asks a new result to land.
struct RestoredPlace: Sendable {
    var anchor: AssetID?
    var anchorPosition: Double?
    var current: AssetID?
    /// Filled in once the rows are known.
    var anchorRow: Int?
    var currentRow: Int?
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
    /// Scrolls to the first or last row, leaving the selection as it is.
    func scrollToEdge(bottom: Bool)
    /// Puts a row back where an anchor says it was.
    func scroll(to anchor: ViewAnchor)
    /// Where a move lands from `row`.
    func row(after move: BrowserMove, from row: Int) -> Int?
    /// Takes keyboard focus.
    func focus()
    /// How tall the view is, for placing a restored anchor.
    var anchorViewportHeight: CGFloat { get }
    /// Asks again for what's on screen, because a volume came back.
    func retryThumbnails()
    func tileSizeDidChange()
    /// The size one step on from `size`.
    func steppedTileSize(from size: CGFloat, larger: Bool) -> CGFloat
    func layoutModeDidChange()
    /// Finished thumbnails are waiting in the loader.
    func thumbnailsReady()
    /// Where a row is showing, in `view`'s coordinates. Nil if it isn't on screen.
    func tileRect(row: Int, in view: NSView) -> CGRect?
    /// Hides a tile while its photo flies to or from it. Nil shows it again.
    func hideTile(row: Int?)
}

/// The state of one window's browser. Grid and list share this: one data source, one selection.
@MainActor
@Observable
public final class BrowserModel {
    /// What's showing: a folder, an album, a tag, or the library's own rows.
    public private(set) var source: BrowseSource?
    /// The folder showing, if the source is one.
    public var scope: BrowseScope? { source?.folder }
    /// The search field's words, which filter the source. Cleared when the source changes.
    public internal(set) var search = ""
    /// Every member of a stack as its own tile, instead of the cover alone.
    public internal(set) var expandsStacks = false
    /// The inspector column at the trailing edge.
    public var isInspectorShown = false
    /// The asset the inspector describes: the photo in the viewer, or else the current item.
    /// Waits for a held key, like the status bar.
    public internal(set) var inspectedAsset: AssetID?
    /// Bumped when organization data changes, so that the inspector reads it again.
    public internal(set) var organizationVersion = 0
    /// The smart album sheet, for a new album or one to edit.
    var smartAlbumRequest: SmartAlbumRequest?
    /// Asks the search field to take focus. Bumped by Command-F.
    public internal(set) var searchFocusRequest = 0
    public private(set) var sort = BrowseSort.default
    public private(set) var viewMode = BrowserViewMode.tiles
    public private(set) var tileSize = Double(TileMetrics.defaultTile)
    public private(set) var layoutMode = TileLayoutMode.square
    public private(set) var itemCount = 0
    public private(set) var selectedCount = 0
    public private(set) var isLoading = false
    /// The viewer is over the grid and list. Read by the shell and the menus, so it changes rarely.
    public internal(set) var isViewerOpen = false
    /// What the status bar says while the viewer is open. Waits for a held key, like the disk does.
    public internal(set) var viewerStatus = ""
    /// The name and date of the photo in the viewer, for the window's title. Waits for a held key too.
    public internal(set) var viewerCaption: ViewerCaption?
    /// Something worth a line in the status bar, such as what a copy left out.
    public internal(set) var notice: String?

    @ObservationIgnored let library: BrowserLibrary
    @ObservationIgnored let selection = SelectionModel()
    @ObservationIgnored let pages: RowPageCache
    @ObservationIgnored private(set) var result = BrowseResult.empty
    @ObservationIgnored private var grid: (any BrowserContent)?
    @ObservationIgnored weak var viewer: ViewerView?
    @ObservationIgnored var copyTask: Task<Void, Never>?
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var captionTask: Task<Void, Never>?
    @ObservationIgnored var inspectTask: Task<Void, Never>?
    @ObservationIgnored let fileDrag = FileDragController()
    @ObservationIgnored private var list: (any BrowserContent)?
    @ObservationIgnored private var showMode: ((BrowserViewMode) -> Void)?
    @ObservationIgnored private var hasLaidOutContent = false
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The restored session had the viewer open, so it opens again once its result lands.
    @ObservationIgnored private var opensViewerOnResult = false
    @ObservationIgnored private var lastContentReload = ContinuousClock.now
    @ObservationIgnored private var pendingContentReload: Task<Void, Never>?
    @ObservationIgnored private var typedName = ""
    @ObservationIgnored private var typedAt = ContinuousClock.now
    /// Layout inputs the grid has now, so that the query task can do the full pass.
    @ObservationIgnored var layoutWidth: CGFloat = 1
    /// Called after each result lands, with its row count.
    @ObservationIgnored var onResult: ((Int) -> Void)?
    /// Where a jump left from, for Back. See BrowserModel+Jumps.
    @ObservationIgnored var backPlace: BackPlace? {
        didSet { if backPlace != oldValue { onBackPlaceChange?(backPlace != nil) } }
    }
    @ObservationIgnored var onBackPlaceChange: ((Bool) -> Void)?

    nonisolated private static let signposter = OSSignposter(subsystem: "app.photon", category: "Browser")
    /// How often the library may be queried again while indexing changes it.
    private static let contentReloadInterval: Duration = .seconds(2)

    public init(library: BrowserLibrary) {
        self.library = library
        pages = RowPageCache(store: library.store)
        library.onContentChanged = { [weak self] in self?.contentChanged() }
        library.onVolumesChanged = { [weak self] in self?.volumesChanged() }
        library.onNotice = { [weak self] in self?.setNotice($0) }
        library.loader.setFinishedHandler { [weak self] in
            DispatchQueue.main.async {
                self?.active?.thumbnailsReady()
                self?.viewer?.thumbnailsReady()
            }
        }
    }

    var active: (any BrowserContent)? { viewMode == .tiles ? grid : list }

    func attach(grid: any BrowserContent, list: any BrowserContent, showMode: @escaping (BrowserViewMode) -> Void) {
        self.grid = grid
        self.list = list
        self.showMode = showMode
        showMode(viewMode)
    }

    /// Grid and list have their real size, so a result can land.
    func contentDidLayOut() {
        hasLaidOutContent = true
        let install = pendingInstall
        pendingInstall = nil
        install?()
    }

    // MARK: Opening

    /// Takes on a session and starts its query. Launch does this before building the window, so that the
    /// window is right the first time, and launch costs the longer of the query and the window, not both.
    /// Returns false if there's no session.
    func restore(_ session: BrowseSession?, opensViewer: Bool = true) -> Bool {
        guard let session else { return false }
        opensViewerOnResult = opensViewer && session.isViewerOpen
        apply(session)
        return true
    }

    /// Reopens the folder used last. Returns false if there's no saved session.
    public func restoreLastSession(opensViewer: Bool = true) async -> Bool {
        restore(try? await library.store.latestSession(), opensViewer: opensViewer)
    }

    /// The saved folder may have gone while the app was closed, and an empty view isn't a useful place
    /// to come back to. An offline folder is still in the library, so it stays.
    public func leaveVanishedFolder() {
        guard let source, !library.folders.isEmpty else { return }
        if !library.contains(source) { openFirstFolder() }
    }

    public func openFirstFolder() {
        if let first = library.folders.first { open(BrowseScope(volume: first.volume, path: first.path)) }
    }

    public func open(_ scope: BrowseScope) { open(.folder(scope)) }

    public func open(_ source: BrowseSource) {
        guard source != self.source else { return }
        closeViewer(animated: false)
        flushSession()
        backPlace = nil
        Task {
            let session = try? await library.store.session(for: source)
            guard let session else {
                self.source = source
                self.search = ""
                self.selection.reset()
                self.reload(keepPosition: false)
                return
            }
            self.apply(session)
        }
    }

    private func apply(_ session: BrowseSession) {
        closeViewer(animated: false)
        source = session.source
        search = ""
        sort = session.sort
        viewMode = BrowserViewMode(rawValue: session.viewMode) ?? .tiles
        showMode?(viewMode)
        if let size = session.tileSize { tileSize = size }
        selection.reset()
        reload(
            keepPosition: false,
            restoring: RestoredPlace(
                anchor: session.anchor, anchorPosition: session.anchorPosition, current: session.current))
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
    func reload(keepPosition: Bool, restoring place: RestoredPlace? = nil) {
        guard let source else { return }
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
        let options = BrowseOptions(
            search: search, expandsStacks: expandsStacks, preferredVolumes: library.onlineVolumes)

        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let interval = Self.signposter.beginInterval("Query")
            defer { Self.signposter.endInterval("Query", interval) }
            guard let result = try? await store.browse(source, sort: sort, options: options), !Task.isCancelled
            else { return }
            let prefix = TileLayout.prefixSums(result.aspects)
            let rows: AspectRows? = mode == .aspect && width > 1
                ? AspectRows.compute(
                    aspects: result.aspects, width: width, target: tile, spacing: TileMetrics.spacing)
                : nil
            let map = base.count > 0 ? base.rowMap(to: result) : []
            let selected = SelectionModel.remapped(baseRows, map: map)
            var found = place
            found?.anchorRow = place?.anchor.flatMap { result.row(of: $0) }
            found?.currentRow = place?.current.flatMap { result.row(of: $0) }
            await self?.install(
                result, generation: generation, prefix: prefix, rows: rows, map: map, selected: selected,
                selectionVersion: baseVersion, place: found, keepPosition: keepPosition)
        }
    }

    private func install(
        _ next: BrowseResult, generation: Int, prefix: [Double], rows: AspectRows?, map: [Int32],
        selected: IndexSet, selectionVersion: Int, place: RestoredPlace?, keepPosition: Bool
    ) {
        guard generation == self.generation else { return }
        guard hasLaidOutContent else {
            // A restored session's query can finish before the window exists, and scrolling to the anchor
            // needs the view's real size.
            pendingInstall = { [weak self] in
                self?.install(
                    next, generation: generation, prefix: prefix, rows: rows, map: map, selected: selected,
                    selectionVersion: selectionVersion, place: place, keepPosition: keepPosition)
            }
            return
        }
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
        if let row = place?.currentRow {
            current = row
            nextSelected = IndexSet(integer: row)
        } else if keepPosition, let row = selection.currentRow {
            current = Self.survivor(of: row, map: map)
        }
        let asset = current.map { AssetID(rawValue: next.assetIDs[$0]) }
        if !keepPosition, let row = place?.anchorRow ?? place?.currentRow {
            let height = active?.anchorViewportHeight ?? 0
            anchor = ViewAnchor(row: row, screenY: CGFloat(place?.anchorPosition ?? 0.25) * height)
        }

        result = next
        itemCount = next.count
        pages.reset(next)
        selection.install(rows: nextSelected, current: current, asset: asset)
        selectedCount = nextSelected.count
        grid?.resultDidChange(next, anchor: anchor, rows: rows, prefix: prefix)
        list?.resultDidChange(next, anchor: anchor, rows: rows, prefix: prefix)
        isLoading = false
        if isViewerOpen {
            if next.count == 0 { closeViewer(animated: false) } else { viewer?.resultDidChange() }
        }
        if opensViewerOnResult {
            opensViewerOnResult = false
            // After this pass, once the tile it flies from is on screen.
            if current != nil { DispatchQueue.main.async { [weak self] in self?.openViewer() } }
        }
        if !isViewerOpen { inspect(asset) }
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
        guard source != nil else {
            // The first folder just arrived, so there's something to show.
            openFirstFolder()
            return
        }
        guard pendingContentReload == nil else { return }
        let wait = Self.contentReloadInterval - (ContinuousClock.now - lastContentReload)
        pendingContentReload = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            pendingContentReload = nil
            lastContentReload = .now
            reload(keepPosition: true)
        }
    }

    /// The rows are the same, but what can be read isn't. A volume coming back should fill in what
    /// couldn't be read, without moving anything.
    private func volumesChanged() {
        guard let source else {
            openFirstFolder()
            return
        }
        // A source spanning volumes prefers files on online ones, so its rows may now come from another.
        if source.folder == nil { reload(keepPosition: true) }
        active?.retryThumbnails()
        viewer?.volumesDidChange()
    }

    /// What can be done with the files showing now.
    public var scopeAccess: VolumeAccess {
        guard let source else { return .offline }
        guard let scope = source.folder else {
            // Rows come from many volumes, and each prefers one that's online.
            return library.onlineVolumes.isEmpty ? .offline : .readOnly
        }
        return library.volumeAccess[scope.volume] ?? .offline
    }

    /// The name of the volume showing now.
    public var volumeName: String? { scope.map { library.name(of: $0.volume) } }

    public var canEjectVolume: Bool { scope.map { library.ejectableVolumes.contains($0.volume) } ?? false }

    /// The Eject command: the volume holding the folder showing now.
    public func ejectVolume() {
        if let scope { library.eject(scope.volume) }
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
        closeViewer(animated: false)
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
        setTileSize(grid?.steppedTileSize(from: CGFloat(tileSize), larger: larger) ?? CGFloat(tileSize))
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
        if move == .home || move == .end, target != from { rememberPlace() }
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

    func selectionChanged() {
        selectedCount = selection.count
        grid?.selectionDidChange()
        list?.selectionDidChange()
        saveSessionSoon()
        inspect(selection.currentAsset)
    }

    /// Jumps to a typed name, in the list. Letters typed within a second build up one name.
    func typeSelect(_ characters: String) {
        let now = ContinuousClock.now
        if now - typedAt > .seconds(1) { typedName = "" }
        typedAt = now
        typedName += characters
        guard let source else { return }
        let prefix = typedName
        let store = library.store
        let result = result
        Task {
            let row = await Task.detached(priority: .userInitiated) { () -> Int? in
                guard let found = try? await store.instances(in: source, namePrefix: prefix, limit: 64) else {
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

    func saveSessionSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flushSession()
        }
    }

    /// Saves where the user is, anchored to an asset. Called on leaving a folder too.
    public func flushSession() {
        guard let session = currentSession() else { return }
        let store = library.store
        Task { try? await store.saveSession(session) }
    }

    /// Waits for the save, because the process won't outlive this call. The library is on the internal
    /// disk, so this is a few milliseconds, and the limit is for a stuck writer during indexing.
    public func saveSessionBeforeQuit() {
        saveTask?.cancel()
        guard let session = currentSession() else { return }
        let store = library.store
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            try? await store.saveSession(session)
            done.signal()
        }
        _ = done.wait(timeout: .now() + .milliseconds(500))
    }

    private func currentSession() -> BrowseSession? {
        guard let source else { return nil }
        // What's on screen and what's current can be far apart, and both are part of your place.
        let seen = active?.captureAnchor()
        let anchor = seen.flatMap { $0.row < result.count ? AssetID(rawValue: result.assetIDs[$0.row]) : nil }
        let height = active?.anchorViewportHeight ?? 0
        return BrowseSession(
            source: source, sort: sort, viewMode: viewMode.rawValue, tileSize: tileSize,
            anchor: anchor ?? selection.currentAsset,
            anchorPosition: seen.flatMap { height > 0 ? min(max(Double($0.screenY / height), 0), 1) : nil },
            current: selection.currentAsset, isViewerOpen: isViewerOpen)
    }

    // MARK: Files

    /// Opens Finder at the current selection. The menu item is disabled offline.
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
