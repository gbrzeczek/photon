import AppKit

/// What both backends implement. The grid state talks to them only through this.
@MainActor protocol GridBackend: AnyObject {
    var scrollView: NSScrollView { get }
    /// The view that should receive key events.
    var keyView: NSView { get }
    func reload()
    /// Tile size or width changed, so every visible tile needs a new frame.
    func relayout()
    func deliver(_ index: Int, image: AnyObject)
    func currentChanged(from old: Int, to new: Int)
    /// Tiles currently on screen, for the screenshot sanity check.
    var visibleTileCount: Int { get }
}

/// Library, selection and thumbnails, shared by both backends.
@MainActor final class GridState {
    let count: Int
    let geometry: Geometry
    let colors: [CGColor]
    let decoder: ThumbDecoder
    weak var backend: GridBackend?

    var current = 0
    var skipDecoding = false

    private var cache: [Int: AnyObject] = [:]
    private var order: [Int] = []
    private var cursor = 0
    private let capacity = 1500
    private(set) var delivered = 0

    init(count: Int, mode: Geometry.Mode, format: ThumbFormat) {
        self.count = count
        decoder = ThumbDecoder(workers: 4, format: format)
        var rng = SystemRandomNumberGenerator()
        // Compact arrays, as the real query result will be. No per-item objects.
        let choices: [Float] = [0.667, 0.75, 1, 1.333, 1.5, 1.778]
        geometry = Geometry(count: count, aspects: (0..<count).map { _ in choices.randomElement(using: &rng)! }, mode: mode)
        colors = (0..<256).map { i in
            CGColor(srgbRed: CGFloat(i % 7) / 7, green: CGFloat(i % 11) / 11, blue: CGFloat(i % 13) / 13, alpha: 1)
        }
    }

    func color(_ index: Int) -> CGColor { colors[index & 255] }

    func image(_ index: Int) -> AnyObject? { cache[index] }

    func want(_ index: Int) {
        if cache[index] == nil, !skipDecoding { decoder.request(index) }
    }

    /// Called once per frame, so decoded images can't flood the main thread.
    func drainDecoded(limit: Int = 48) {
        for (index, image) in decoder.drain(limit: limit) {
            if order.count < capacity {
                order.append(index)
            } else {
                cache[order[cursor]] = nil
                order[cursor] = index
                cursor = (cursor + 1) % capacity
            }
            cache[index] = image
            backend?.deliver(index, image: image)
            delivered += 1
        }
    }

    var viewportHeight: CGFloat { backend?.scrollView.contentView.bounds.height ?? 0 }
    var offset: CGFloat { backend?.scrollView.contentView.bounds.origin.y ?? 0 }

    func scroll(to y: CGFloat) {
        guard let scroll = backend?.scrollView else { return }
        let top = max(0, min(y, geometry.contentHeight - viewportHeight))
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func move(dx: Int, dy: Int) {
        let old = current
        current = geometry.neighbor(of: old, dx: dx, dy: dy)
        let frame = geometry.frame(of: current)
        if frame.minY < offset {
            scroll(to: frame.minY)
        } else if frame.maxY > offset + viewportHeight {
            scroll(to: frame.maxY - viewportHeight)
        }
        backend?.currentChanged(from: old, to: current)
    }

    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: move(dx: -1, dy: 0)
        case 124: move(dx: 1, dy: 0)
        case 125: move(dx: 0, dy: 1)
        case 126: move(dx: 0, dy: -1)
        default: return false
        }
        return true
    }

    /// Continuous zoom. The tile under `point` (viewport coordinates) keeps its vertical position.
    /// Returns how far that tile's center ended up from where it was, in points.
    @discardableResult
    func zoom(to tile: CGFloat, anchoredAt point: CGPoint) -> (x: CGFloat, y: CGFloat) {
        let top = offset
        let index = geometry.index(at: CGPoint(x: point.x, y: point.y + top))
        let before = geometry.frame(of: index)
        let beforeOnScreen = before.midY - top
        geometry.update(width: geometry.width, tile: tile)
        let after = geometry.frame(of: index)
        backend?.relayout()
        scroll(to: after.midY - beforeOnScreen)
        return (after.midX - before.midX, (after.midY - offset) - beforeOnScreen)
    }
}
