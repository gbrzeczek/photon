import CoreGraphics
import Foundation

/// A drag that selects the tiles it crosses, in document coordinates.
///
/// Tiles on screen ask `covers`, which costs one tile, so a band over the whole library still costs only
/// what's visible on each frame. The rows themselves are worked out once, off the main thread, when the
/// drag ends.
struct RubberBand: Sendable {
    /// How far the pointer travels before a press becomes a drag.
    static let startDistance: CGFloat = 4
    /// Stays below the grid's fast scroll speed, so that thumbnails keep arriving during a drag.
    static let fastestScroll: CGFloat = 6000
    private static let scrollPerPointPastEdge: CGFloat = 16

    let origin: CGPoint
    /// What stays selected whatever the band crosses. Empty unless Command or Shift is held.
    let base: IndexSet
    private(set) var rect: CGRect

    init(origin: CGPoint, base: IndexSet) {
        self.origin = origin
        self.base = base
        rect = CGRect(origin: origin, size: .zero)
    }

    mutating func drag(to point: CGPoint) {
        rect = CGRect(
            x: min(origin.x, point.x), y: min(origin.y, point.y),
            width: abs(point.x - origin.x), height: abs(point.y - origin.y))
    }

    func covers(_ row: Int, in layout: TileLayout) -> Bool {
        base.contains(row) || layout.frame(of: row).intersects(rect)
    }

    /// Everything the band selects. The cost is the tiles it covers, so this doesn't run on the main thread.
    func rows(in layout: TileLayout) -> IndexSet {
        let rect = rect
        var rows = base
        var run: Range<Int>?
        layout.forEach(in: rect) { item, frame in
            guard frame.intersects(rect) else { return }
            if let current = run, current.upperBound == item {
                run = current.lowerBound..<(item + 1)
            } else {
                if let current = run { rows.insert(integersIn: current) }
                run = item..<(item + 1)
            }
        }
        if let run { rows.insert(integersIn: run) }
        return rows
    }

    /// Points per second to scroll with the pointer `y` from the top of a viewport `height` tall.
    /// Further past the edge is faster, and inside the viewport nothing moves.
    static func scrollSpeed(pointerY y: CGFloat, viewportHeight height: CGFloat) -> CGFloat {
        let past = y < 0 ? y : max(0, y - height)
        return min(max(past * scrollPerPointPastEdge, -fastestScroll), fastestScroll)
    }
}
