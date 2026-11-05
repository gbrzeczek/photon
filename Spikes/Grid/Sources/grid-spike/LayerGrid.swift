import AppKit

/// Option B: recycled CALayers in a host view fixed to the viewport. The document view exists
/// only to give NSScrollView its height and scroller, so nothing here depends on layers sitting
/// at document coordinates of tens of millions of points.
final class EmptyDocument: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class HostView: NSView {
    var tilesForAccessibility: (@MainActor () -> [NSAccessibilityElement])?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Photos" }
    override func accessibilityChildren() -> [Any]? { tilesForAccessibility?() }
}

@MainActor final class LayerGrid: NSObject, GridBackend {
    let state: GridState
    let scrollView = NSScrollView()
    let document = EmptyDocument()
    let host = HostView()
    let container = CALayer()
    let marker = CALayer()
    var keyView: NSView { document }

    private var tiles: [Int: CALayer] = [:]
    private var free: [CALayer] = []
    private var seen = Set<Int>()
    /// Keeps layer coordinates small. Tiles sit relative to this, and it moves in coarse steps.
    private var base: CGFloat = 0
    private let baseStep: CGFloat = 16384

    init(state: GridState) {
        self.state = state
        super.init()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        document.onKey = { [unowned state] in state.handle($0) }
        scrollView.addSubview(host, positioned: .below, relativeTo: scrollView.verticalScroller)
        host.wantsLayer = true
        host.tilesForAccessibility = { [unowned self] in self.accessibleTiles() }
        host.layer!.addSublayer(container)
        container.addSublayer(marker)
        marker.borderWidth = 3
        marker.borderColor = NSColor.controlAccentColor.cgColor
        marker.zPosition = 1
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func reload() { relayout() }

    func relayout() {
        document.frame = CGRect(x: 0, y: 0, width: state.geometry.width, height: state.geometry.contentHeight)
        update(force: true)
    }

    private func update(force: Bool = false) {
        host.frame = scrollView.contentView.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let origin = scrollView.contentView.bounds.origin.y
        let rebased = (origin / baseStep).rounded(.down) * baseStep
        let moved = rebased != base
        base = rebased
        container.frame = CGRect(x: 0, y: -(origin - base), width: host.bounds.width, height: host.bounds.height)

        // Scrolling only moves the container, so frames change only on zoom or rebase.
        let viewport = CGRect(x: 0, y: origin, width: state.geometry.width, height: host.bounds.height)
        seen.removeAll(keepingCapacity: true)
        state.geometry.forEach(in: viewport) { index, frame in
            seen.insert(index)
            let local = frame.offsetBy(dx: 0, dy: -base)
            if let tile = tiles[index] {
                if force || moved { tile.frame = local }
            } else {
                let tile = free.popLast() ?? makeTile()
                tile.isHidden = false
                tile.frame = local
                tile.backgroundColor = state.color(index)
                tile.contents = state.image(index)
                tiles[index] = tile
                state.want(index)
            }
        }
        for (index, tile) in tiles where !seen.contains(index) {
            tile.isHidden = true
            tile.contents = nil
            free.append(tile)
            tiles[index] = nil
            state.decoder.cancel(index)
        }
        placeMarker()
    }

    private func makeTile() -> CALayer {
        let tile = CALayer()
        tile.contentsGravity = .resizeAspectFill
        tile.masksToBounds = true
        container.addSublayer(tile)
        return tile
    }

    private func placeMarker() {
        marker.frame = state.geometry.frame(of: state.current).offsetBy(dx: 0, dy: -base)
    }

    func deliver(_ index: Int, image: AnyObject) {
        guard let tile = tiles[index] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.contents = image
        CATransaction.commit()
    }

    func currentChanged(from old: Int, to new: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeMarker()
        CATransaction.commit()
    }

    var visibleTileCount: Int { tiles.count }

    /// The hand-built accessibility this option needs. NSCollectionView gets this from its item views.
    func accessibleTiles() -> [NSAccessibilityElement] {
        tiles.keys.sorted().map { index in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.image)
            element.setAccessibilityLabel("Photo \(index + 1) of \(state.count)")
            element.setAccessibilityParent(host)
            let frame = state.geometry.frame(of: index).offsetBy(dx: 0, dy: -scrollView.contentView.bounds.origin.y)
            if let window = host.window {
                element.setAccessibilityFrame(window.convertToScreen(host.convert(frame, to: nil)))
            }
            return element
        }
    }
}
