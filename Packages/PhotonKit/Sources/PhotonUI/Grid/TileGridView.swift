import AppKit
import PhotonCore
import PhotonIndex
import PhotonMedia
import os

/// Exists only to give `NSScrollView` a height and a scroller, and to take events. It has the same
/// coordinates as the layout, so tiles are found with no conversion. No tile sits at these coordinates,
/// which reach tens of millions of points.
final class GridDocumentView: NSView {
    weak var grid: TileGridView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        grid?.focusChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        grid?.focusChanged(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if grid?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) { grid?.handleMouseDown(event) }
    override func magnify(with event: NSEvent) { grid?.handleMagnify(event) }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.contextMenu(for: event) }
    override func selectAll(_ sender: Any?) { grid?.model.selectAll() }
}

/// Sits over the scroll view's clip view, fixed to the viewport, and holds the tile layers.
final class GridHostView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The photo grid: recycled `CALayer` tiles, the backend chosen in Spike 1.
///
/// Scrolling only moves one container layer, so tile frames change only on zoom, on a change of
/// layout, or when the base moves. Tiles sit relative to that base, which moves in coarse steps and
/// keeps layer coordinates small. Each frame's work is proportional to what's on screen.
@MainActor
final class TileGridView: NSView, BrowserContent {
    let model: BrowserModel
    let scrollView = NSScrollView()
    let document = GridDocumentView()
    let host = GridHostView()
    private let container = PlainLayer()
    /// The system-style ring around the current item.
    private let focusRing = PlainLayer()
    private let loader: ThumbnailLoader
    private let artwork = TileArtwork()
    private lazy var ticker = FrameTicker { [weak self] _ in self?.tick() ?? false }

    private(set) var tileLayout = TileLayout()
    private var result = BrowseResult.empty
    private var tiles: [Int: TileLayer] = [:]
    private var tilesByAsset: [Int64: TileLayer] = [:]
    private var freeTiles: [TileLayer] = []
    private var updateStamp = 0
    private var base: CGFloat = 0
    private var hasFocus = false

    // Frame state
    private var needsTileUpdate = false
    private var needsFocusPlacement = false
    private var needsThumbnailRequests = false
    private var isZooming = false
    private var zoomEndsAt: ContinuousClock.Instant?
    private var zoomAnchor: ViewAnchor?
    private var lastScrollTop: CGFloat = 0
    private var lastScrollTime = ContinuousClock.now
    private var isScrollingFast = false
    private var idleFrames = 0
    private var fullPassGeneration = 0

    /// Above this, tiles show their stored color, and nothing is decoded for tiles that won't stay.
    private static let fastScrollSpeed: CGFloat = 12_000
    private static let baseStep: CGFloat = 16_384
    /// Thumbnails assigned per frame, so that a backlog can't flood the main thread.
    private static let thumbnailBatch = 48
    /// How long after the last zoom step the gesture counts as over.
    private static let zoomSettleDelay: Duration = .milliseconds(120)
    nonisolated private static let signposter = OSSignposter(subsystem: "app.photon", category: "Grid")
    private static let transitionDuration: CFTimeInterval = 0.18

    /// Frame timings for the measuring harness. Nil unless it's running.
    var frameObserver: ((Double) -> Void)?

    init(model: BrowserModel) {
        self.model = model
        loader = model.library.loader
        super.init(frame: .zero)
        tileLayout = TileLayout(mode: model.layoutMode)

        addSubview(scrollView)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.autoresizingMask = [.width, .height]
        document.grid = self
        document.setAccessibilityIdentifier("photon.grid")
        document.setAccessibilityElement(true)
        document.setAccessibilityRole(.group)
        document.setAccessibilityLabel("Photos")

        scrollView.addSubview(host, positioned: .below, relativeTo: scrollView.verticalScroller)
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .never
        host.layer?.addSublayer(container)
        container.addSublayer(focusRing)
        focusRing.zPosition = 10
        focusRing.isHidden = true
        focusRing.cornerRadius = 3
        configureAccessibility()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    private var clip: NSClipView { scrollView.contentView }
    private var viewportTop: CGFloat { clip.bounds.origin.y }
    private var viewportHeight: CGFloat { clip.bounds.height }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        host.frame = clip.frame
        let width = clip.bounds.width
        guard width > 1 else { return }
        model.layoutWidth = width
        if width != tileLayout.width {
            let anchor = captureAnchor()
            if let anchor, tileLayout.mode == .aspect, tileLayout.count > 0 {
                let frame = tileLayout.frame(of: anchor.row)
                tileLayout.zoom(
                    width: width, tile: CGFloat(model.tileSize), anchor: anchor.row, anchorX: frame.midX,
                    coverage: viewportHeight * 2)
                zoomAnchor = anchor
                markZoomStep()
            } else {
                tileLayout.resize(width: width, tile: CGFloat(model.tileSize))
            }
            applyContentHeight()
            if let anchor { scrollAnchorIntoPlace(anchor) }
        }
        updateTiles(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker.invalidate()
        guard window != nil else { return }
        artwork.setScale(backingScale)
        startTicking()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        artwork.reset()
        recolor()
    }

    // MARK: Frames

    private func startTicking() {
        idleFrames = 0
        guard window != nil else { return }
        ticker.start(in: self)
    }

    /// Runs once per display frame, only while something needs it.
    func tick() -> Bool {
        guard !isHidden else { return false }
        let interval = Self.signposter.beginInterval("Frame")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            Self.signposter.endInterval("Frame", interval)
            frameObserver?(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        if let end = zoomEndsAt, ContinuousClock.now >= end {
            zoomEndsAt = nil
            finishZoom()
        }
        // Key repeats land here, so that several in one frame do one update.
        if needsTileUpdate {
            needsTileUpdate = false
            updateTiles(force: false)
        }
        if needsFocusPlacement {
            needsFocusPlacement = false
            placeFocusRing()
        }
        // Fast scrolling can stop with no further event, so the speed has to decay here.
        if isScrollingFast, ContinuousClock.now - lastScrollTime > .milliseconds(80) {
            isScrollingFast = false
            needsThumbnailRequests = true
        }
        if needsThumbnailRequests, !isScrollingFast {
            needsThumbnailRequests = false
            requestVisibleThumbnails()
        }
        drainThumbnails()

        let busy = zoomEndsAt != nil || isScrollingFast || loader.hasFinishedThumbnails || needsTileUpdate
        idleFrames = busy ? 0 : idleFrames + 1
        return idleFrames < 30
    }

    private func drainThumbnails() {
        let batch = loader.drain(limit: Self.thumbnailBatch)
        guard !batch.isEmpty else { return }
        let interval = Self.signposter.beginInterval("Assign thumbnails", "\(batch.count)")
        defer { Self.signposter.endInterval("Assign thumbnails", interval) }
        for (asset, thumbnail) in batch {
            guard let tile = tilesByAsset[asset.rawValue] else { continue }
            if let shown = tile.shownTier, shown >= thumbnail.tier { continue }
            show(thumbnail, on: tile)
        }
    }

    private func show(_ thumbnail: DecodedThumbnail, on tile: TileLayer) {
        tile.contents = thumbnail.surface
        tile.contentsGravity = .resizeAspectFill
        tile.shownTier = thumbnail.tier
    }

    // MARK: Scrolling

    @objc private func boundsChanged() {
        let now = ContinuousClock.now
        let top = viewportTop
        let elapsed = (now - lastScrollTime) / .seconds(1)
        if elapsed > 0 {
            let speed = abs(top - lastScrollTop) / CGFloat(elapsed)
            let wasFast = isScrollingFast
            isScrollingFast = speed > Self.fastScrollSpeed
            if wasFast, !isScrollingFast { needsThumbnailRequests = true }
        }
        lastScrollTop = top
        lastScrollTime = now
        updateTiles(force: false)
        if !isZooming, tileLayout.canSettle(viewportTop: top) { settlePhase() }
        startTicking()
    }

    /// Moves to a top, within the content.
    func scroll(toTop top: CGFloat) {
        let highest = max(0, tileLayout.contentHeight - viewportHeight)
        clip.setBoundsOrigin(CGPoint(x: 0, y: max(0, min(top, highest))))
        scrollView.reflectScrolledClipView(clip)
    }

    private func applyContentHeight() {
        let frame = CGRect(x: 0, y: 0, width: clip.bounds.width, height: max(tileLayout.contentHeight, viewportHeight))
        if document.frame != frame { document.frame = frame }
    }

    private func scrollAnchorIntoPlace(_ anchor: ViewAnchor) {
        scroll(toTop: tileLayout.frame(of: anchor.row).midY - anchor.screenY)
    }

    // MARK: Tiles

    /// Puts tiles on screen. Costs what's visible, because scrolling reuses tiles already placed.
    private func updateTiles(force: Bool) {
        guard result.count > 0 else {
            recycleAll()
            return
        }
        let interval = Self.signposter.beginInterval("Update tiles")
        defer { Self.signposter.endInterval("Update tiles", interval) }

        let top = viewportTop
        let height = viewportHeight
        host.frame = clip.frame
        let rebased = (top / Self.baseStep).rounded(.down) * Self.baseStep
        let baseMoved = rebased != base
        base = rebased
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.frame = CGRect(x: 0, y: -(top - base), width: host.bounds.width, height: host.bounds.height)

        if tileLayout.isLocal { tileLayout.extendLocal(toCover: Double(top - height), bottom: Double(top + height * 2)) }

        updateStamp += 1
        let stamp = updateStamp
        let moved = force || baseMoved
        let viewport = CGRect(x: 0, y: top, width: tileLayout.width, height: height)
        let wanted = wantedTier
        let requestsAllowed = !isScrollingFast
        tileLayout.forEach(in: viewport) { row, frame in
            if let tile = tiles[row] {
                tile.stamp = stamp
                if moved {
                    tile.frame = frame.offsetBy(dx: 0, dy: -base)
                    tile.placeBadge()
                }
            } else {
                let tile = freeTiles.popLast() ?? makeTile()
                tile.stamp = stamp
                tile.isHidden = false
                tile.frame = frame.offsetBy(dx: 0, dy: -base)
                configure(tile, row: row, wanted: wanted, requests: requestsAllowed)
                tiles[row] = tile
                tilesByAsset[tile.assetID] = tile
            }
        }
        for (row, tile) in tiles where tile.stamp != stamp {
            recycle(tile, row: row)
            tiles[row] = nil
        }
        placeFocusRing()
    }

    private func makeTile() -> TileLayer {
        let tile = TileLayer()
        tile.masksToBounds = true
        tile.contentsGravity = .resizeAspectFill
        tile.contentsScale = backingScale
        container.addSublayer(tile)
        return tile
    }

    private func recycle(_ tile: TileLayer, row: Int) {
        tile.isHidden = true
        tile.contents = nil
        tile.shownTier = nil
        tile.setBadge(nil, scale: 1)
        tilesByAsset[tile.assetID] = nil
        // The tile may never have asked, but cancelling costs little.
        loader.cancel(AssetID(rawValue: tile.assetID))
        freeTiles.append(tile)
    }

    private func recycleAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (row, tile) in tiles { recycle(tile, row: row) }
        tiles.removeAll(keepingCapacity: true)
        tilesByAsset.removeAll(keepingCapacity: true)
        focusRing.isHidden = true
        CATransaction.commit()
    }

    /// The stored size that suits this tile size, on this screen.
    private var wantedTier: ThumbnailTier {
        tileLayout.tile * backingScale <= CGFloat(ThumbnailSizes.small) * 1.25 ? .small : .large
    }

    private func configure(_ tile: TileLayer, row: Int, wanted: ThumbnailTier, requests: Bool) {
        let asset = result.assetIDs[row]
        tile.row = row
        tile.assetID = asset
        tile.isVideo = result.flags[row].contains(.video)
        tile.backgroundColor = backgroundColor(row: row)
        setSelected(tile, model.selection.isSelected(row))

        if tile.isVideo {
            // Video thumbnails need a frame from the file, which arrives with Milestone 6.
            tile.contentsGravity = .center
            tile.contents = artwork.videoPlaceholder(appearance: effectiveAppearance)
            tile.setBadge(artwork.durationBadge(seconds: Int(result.durations[row])), scale: backingScale)
            return
        }
        let assetID = AssetID(rawValue: asset)
        if let nearest = loader.cache.nearest(asset: assetID, wanted: wanted) { show(nearest, on: tile) }
        guard requests, tile.shownTier != wanted else { return }
        request(row: row, assetID: assetID, wanted: wanted, priority: .visible)
    }

    private func request(row: Int, assetID: AssetID, wanted: ThumbnailTier, priority: IOPriority) {
        loader.request(
            ThumbnailRequest(
                asset: assetID, instance: FileInstanceID(rawValue: result.instanceIDs[row]), wanted: wanted,
                priority: priority))
    }

    /// Tiles that came on screen while requests were held back, or need a larger size.
    private func requestVisibleThumbnails() {
        guard !isZooming else { return }
        let wanted = wantedTier
        for (row, tile) in tiles where !tile.isVideo && tile.shownTier != wanted {
            request(row: row, assetID: AssetID(rawValue: tile.assetID), wanted: wanted, priority: .visible)
        }
        requestAhead(wanted: wanted)
    }

    /// One screen past the viewport in the direction of travel, ready before it arrives.
    private func requestAhead(wanted: ThumbnailTier) {
        let top = viewportTop
        let height = viewportHeight
        let ahead = top >= lastAheadTop ? top + height : top - height
        lastAheadTop = top
        tileLayout.forEach(in: CGRect(x: 0, y: max(0, ahead), width: tileLayout.width, height: height)) { row, _ in
            guard tiles[row] == nil, !result.flags[row].contains(.video) else { return }
            let assetID = AssetID(rawValue: result.assetIDs[row])
            if loader.cache.nearest(asset: assetID, wanted: wanted) == nil {
                request(row: row, assetID: assetID, wanted: wanted, priority: .ahead)
            }
        }
    }
    private var lastAheadTop: CGFloat = 0

    private func backgroundColor(row: Int) -> CGColor {
        if result.flags[row].contains(.hasColor) {
            let color = result.colors[row]
            return CGColor(
                srgbRed: CGFloat(color >> 16 & 255) / 255, green: CGFloat(color >> 8 & 255) / 255,
                blue: CGFloat(color & 255) / 255, alpha: 1)
        }
        return placeholderColor
    }

    private var placeholderColor: CGColor {
        var color = CGColor(gray: 0.5, alpha: 0.2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.quaternaryLabelColor.cgColor
        }
        return color
    }

    private func setSelected(_ tile: TileLayer, _ selected: Bool) {
        tile.borderWidth = selected ? 3 : 0
        if selected { tile.borderColor = NSColor.selectedContentBackgroundColor.cgColor }
    }

    private func recolor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (row, tile) in tiles {
            tile.backgroundColor = backgroundColor(row: row)
            if tile.isVideo { tile.contents = artwork.videoPlaceholder(appearance: effectiveAppearance) }
            setSelected(tile, model.selection.isSelected(row))
        }
        applyFocusColor()
        CATransaction.commit()
    }

    // MARK: Focus

    func focusChanged(_ focused: Bool) {
        hasFocus = focused
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFocusColor()
        CATransaction.commit()
    }

    private func applyFocusColor() {
        focusRing.borderWidth = 3
        effectiveAppearance.performAsCurrentDrawingAppearance {
            focusRing.borderColor =
                (hasFocus ? NSColor.keyboardFocusIndicatorColor : NSColor.tertiaryLabelColor).cgColor
        }
    }

    private func placeFocusRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let row = model.selection.currentRow, row < result.count else {
            focusRing.isHidden = true
            return
        }
        focusRing.isHidden = false
        focusRing.frame = tileLayout.frame(of: row).offsetBy(dx: 0, dy: -base).insetBy(dx: -2, dy: -2)
    }

    // MARK: BrowserContent

    func captureAnchor() -> ViewAnchor? {
        guard result.count > 0 else { return nil }
        let top = viewportTop
        if let row = model.selection.currentRow, row < result.count {
            let frame = tileLayout.frame(of: row)
            if frame.maxY > top, frame.minY < top + viewportHeight {
                return ViewAnchor(row: row, screenY: frame.midY - top)
            }
        }
        let center = CGPoint(x: tileLayout.width / 2, y: top + viewportHeight / 2)
        return tileLayout.closest(to: center).map { ViewAnchor(row: $0, screenY: tileLayout.frame(of: $0).midY - top) }
    }

    func resultDidChange(_ result: BrowseResult, anchor: ViewAnchor?, rows: AspectRows?, prefix: [Double]) {
        self.result = result
        fullPassGeneration += 1
        // Tile objects stay, but they may now show other rows.
        recycleAll()
        tileLayout.setItems(result.aspects, prefix: prefix, rows: nil)
        tileLayout.resize(width: max(clip.bounds.width, 1), tile: CGFloat(model.tileSize))
        // The query's pass only counts if nothing has changed since it started.
        if let rows, tileLayout.width == model.layoutWidth { tileLayout.install(rows) }
        applyContentHeight()
        if tileLayout.isLocal, result.count > 0 {
            let row = anchor?.row ?? 0
            tileLayout.zoom(
                width: tileLayout.width, tile: tileLayout.tile, anchor: row, anchorX: tileLayout.width / 2,
                coverage: viewportHeight * 2)
            startFullPass(anchor: row)
            applyContentHeight()
        }
        if let anchor {
            scrollAnchorIntoPlace(anchor)
        } else {
            scroll(toTop: 0)
        }
        updateTiles(force: true)
        updateAccessibilityValue()
        startTicking()
    }

    func selectionDidChange() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (row, tile) in tiles { setSelected(tile, model.selection.isSelected(row)) }
        CATransaction.commit()
        needsFocusPlacement = true
        updateAccessibilityValue()
        startTicking()
    }

    func revealCurrent() {
        guard let row = model.selection.currentRow, row < result.count else { return }
        let frame = tileLayout.frame(of: row)
        let top = viewportTop
        if frame.minY < top {
            scroll(toTop: frame.minY - 4)
        } else if frame.maxY > top + viewportHeight {
            scroll(toTop: frame.maxY - viewportHeight + 4)
        }
    }

    func row(after move: BrowserMove, from row: Int) -> Int? {
        let count = result.count
        guard count > 0 else { return nil }
        switch move {
        case .left: return max(row - 1, 0)
        case .right: return min(row + 1, count - 1)
        case .up: return tileLayout.neighbor(of: row, rowDelta: -1)
        case .down: return tileLayout.neighbor(of: row, rowDelta: 1)
        case .home: return 0
        case .end: return count - 1
        case .pageUp, .pageDown:
            let frame = tileLayout.frame(of: row)
            let step = (move == .pageUp ? -1 : 1) * max(viewportHeight - tileLayout.tile, tileLayout.tile)
            let target = tileLayout.closest(to: CGPoint(x: frame.midX, y: frame.midY + step))
            // Past either end there's no tile at that height, so it goes to the end.
            if frame.midY + step < 0 { return 0 }
            if frame.midY + step >= tileLayout.contentHeight { return count - 1 }
            return target
        }
    }

    func focus() { window?.makeFirstResponder(document) }
    func thumbnailsReady() { startTicking() }

    func tileSizeDidChange() {
        guard result.count > 0 else {
            tileLayout.resize(width: tileLayout.width, tile: CGFloat(model.tileSize))
            return
        }
        beginProgrammaticZoom()
        zoom(to: CGFloat(model.tileSize))
    }

    func layoutModeDidChange() {
        let anchor = captureAnchor()
        tileLayout.setMode(model.layoutMode)
        tileLayout.resize(width: tileLayout.width, tile: CGFloat(model.tileSize))
        applyContentHeight()
        if tileLayout.isLocal, result.count > 0 {
            let row = anchor?.row ?? 0
            tileLayout.zoom(
                width: tileLayout.width, tile: tileLayout.tile, anchor: row, anchorX: tileLayout.width / 2,
                coverage: viewportHeight * 2)
            startFullPass(anchor: row)
        }
        recycleAll()
        applyContentHeight()
        if let anchor { scrollAnchorIntoPlace(anchor) }
        updateTiles(force: true)
    }

    // MARK: Zooming

    /// Keeps the current item or the middle of the view in place, for the slider and shortcuts.
    private func beginProgrammaticZoom() {
        guard zoomAnchor == nil else { return }
        zoomAnchor = captureAnchor()
    }

    /// Starts a pinch, anchored on the tile under the cursor.
    func beginZoom(at point: CGPoint) {
        let top = viewportTop
        let hit = tileLayout.index(at: point) ?? tileLayout.closest(to: point)
        zoomAnchor = hit.map { ViewAnchor(row: $0, screenY: tileLayout.frame(of: $0).midY - top) }
    }

    /// One step. The anchor stays where it is vertically, and sideways as far as rows allow.
    func zoom(to tile: CGFloat) {
        guard let anchor = zoomAnchor, result.count > 0 else { return }
        let interval = Self.signposter.beginInterval("Zoom step")
        defer { Self.signposter.endInterval("Zoom step", interval) }
        isZooming = true
        let version = tileLayout.structureVersion
        let anchorX = tileLayout.frame(of: anchor.row).midX
        tileLayout.zoom(
            width: tileLayout.width, tile: tile, anchor: anchor.row, anchorX: anchorX, coverage: viewportHeight * 2)
        let oldPositions = tileLayout.structureVersion != version ? screenPositions() : nil
        applyContentHeight()
        scrollAnchorIntoPlace(anchor)
        updateTiles(force: true)
        if let oldPositions { animateFrom(oldPositions) }
        markZoomStep()
    }

    private func markZoomStep() {
        zoomEndsAt = ContinuousClock.now + Self.zoomSettleDelay
        startTicking()
    }

    private func finishZoom() {
        isZooming = false
        if tileLayout.isLocal, let anchor = zoomAnchor { startFullPass(anchor: anchor.row) } else { zoomAnchor = nil }
        needsThumbnailRequests = true
    }

    /// The full pass, off the main thread, breaking rows at the same place so that nothing visibly moves.
    private func startFullPass(anchor row: Int) {
        fullPassGeneration += 1
        let generation = fullPassGeneration
        let (aspects, width, tile, spacing) = (tileLayout.aspects, tileLayout.width, tileLayout.tile, tileLayout.spacing)
        let start = tileLayout.rowStart(containing: row)
        Task.detached(priority: .userInitiated) { [weak self] in
            let interval = Self.signposter.beginInterval("Full pass")
            let rows = AspectRows.compute(aspects: aspects, width: width, target: tile, spacing: spacing, anchorStart: start)
            Self.signposter.endInterval("Full pass", interval)
            await self?.installFullPass(rows, generation: generation, row: row)
        }
    }

    private func installFullPass(_ rows: AspectRows, generation: Int, row: Int) {
        guard generation == fullPassGeneration, !isZooming else { return }
        let top = viewportTop
        let screenY = tileLayout.frame(of: row).midY - top
        tileLayout.install(rows)
        zoomAnchor = nil
        applyContentHeight()
        scrollAnchorIntoPlace(ViewAnchor(row: row, screenY: screenY))
        updateTiles(force: true)
    }

    private func settlePhase() {
        let old = screenPositions()
        let anchor = captureAnchor()
        tileLayout.settle()
        applyContentHeight()
        if let anchor { scrollAnchorIntoPlace(anchor) }
        updateTiles(force: true)
        animateFrom(old)
    }

    private func screenPositions() -> [Int: CGPoint] {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return [:] }
        let offset = container.frame.minY
        return tiles.mapValues { CGPoint(x: $0.position.x, y: $0.position.y + offset) }
    }

    /// The transition when rows break differently. Each tile slides from where it was, added on top of
    /// its model position, so that the frames of a continuing pinch carry on underneath.
    private func animateFrom(_ old: [Int: CGPoint]) {
        guard !old.isEmpty else { return }
        let offset = container.frame.minY
        let limit = max(viewportHeight, tileLayout.width)
        for (row, tile) in tiles {
            guard let before = old[row] else { continue }
            let dx = before.x - tile.position.x
            let dy = before.y - (tile.position.y + offset)
            // A tile crossing the whole window reads as noise, so it simply appears.
            guard dx != 0 || dy != 0, abs(dx) < limit, abs(dy) < limit else { continue }
            let animation = CABasicAnimation(keyPath: "position")
            animation.isAdditive = true
            animation.fromValue = NSValue(point: CGPoint(x: dx, y: dy))
            animation.toValue = NSValue(point: .zero)
            animation.duration = Self.transitionDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tile.add(animation, forKey: "reflow")
        }
    }

    // MARK: Input

    func handleKey(_ event: NSEvent) -> Bool {
        BrowserKeys.handle(event, model: model, typeToSelect: false)
    }

    func handleMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(document)
        let point = document.convert(event.locationInWindow, from: nil)
        guard let row = tileLayout.index(at: point) else {
            if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) { model.selectNone() }
            return
        }
        if event.modifierFlags.contains(.shift) {
            model.extendSelection(to: row)
        } else if event.modifierFlags.contains(.command) {
            model.toggle(row: row)
        } else {
            model.select(row: row)
        }
    }

    func handleMagnify(_ event: NSEvent) {
        if event.phase == .began || zoomAnchor == nil {
            beginZoom(at: document.convert(event.locationInWindow, from: nil))
        }
        let size = tileLayout.tile * (1 + event.magnification)
        model.setTileSizeFromGesture(min(max(size, TileMetrics.minimumTile), TileMetrics.maximumTile))
        zoom(to: CGFloat(model.tileSize))
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = document.convert(event.locationInWindow, from: nil)
        guard let row = tileLayout.index(at: point) else { return nil }
        if !model.selection.isSelected(row) { model.select(row: row) }
        return BrowserContextMenu.make(model: model)
    }

    // MARK: Measuring

    func zoomForMeasuring(to tile: CGFloat, anchor point: CGPoint) {
        if zoomAnchor == nil { beginZoom(at: CGPoint(x: point.x, y: point.y + viewportTop)) }
        zoom(to: tile)
    }

    var layoutTile: CGFloat { tileLayout.tile }
    var visibleTileCount: Int { tiles.count }
    var scrollTopForMeasuring: CGFloat { viewportTop }
}

// MARK: - Accessibility

extension TileGridView {
    fileprivate func configureAccessibility() {
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.list)
        host.setAccessibilityLabel("Photos")
        host.setAccessibilityIdentifier("photon.tiles")
    }

    /// Reads the position for VoiceOver, and gives UI tests something to check.
    fileprivate func updateAccessibilityValue() {
        let selected = model.selection.count
        let position = model.selection.currentRow.map { "Item \($0 + 1) of \(result.count)" } ?? "\(result.count) items"
        document.setAccessibilityValue("\(position), \(selected) selected")
        host.setAccessibilityChildren(accessibleTiles())
    }

    /// One element per visible tile: 20 lines in Spike 1, and under a millisecond to build.
    fileprivate func accessibleTiles() -> [NSAccessibilityElement] {
        let top = viewportTop
        return tiles.keys.sorted().map { row in
            let element = NSAccessibilityElement()
            let isVideo = result.flags[row].contains(.video)
            element.setAccessibilityRole(.image)
            let name = model.pages.row(row)?.path.name ?? (isVideo ? "Video" : "Photo")
            element.setAccessibilityLabel("\(name), \(row + 1) of \(result.count)")
            element.setAccessibilityParent(host)
            element.setAccessibilitySelected(model.selection.isSelected(row))
            let frame = tileLayout.frame(of: row).offsetBy(dx: 0, dy: -top)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(host.convert(frame, to: nil)))
            }
            return element
        }
    }
}
