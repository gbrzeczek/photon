import CoreGraphics
import Foundation

/// Where a photo sits in the viewer, as pure arithmetic. Zoom is a multiple of the size that fits, so
/// 1 is the whole photo, and `center` is the point of the photo at the middle of the viewport, from 0
/// to 1 on each axis. Neither depends on which decoded size is showing, so a sharper image can land
/// without anything moving.
struct ViewerGeometry: Equatable {
    var viewport: CGSize
    /// The photo's pixels, upright.
    var imageSize: CGSize
    /// Device pixels per point.
    var backingScale: CGFloat
    var zoom: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Past this, more zoom only shows larger pixels.
    private static let pixelMagnification: CGFloat = 8
    private static let step: CGFloat = 1.5
    /// About 95% of a scroll's zoom is done in three of these.
    private static let scrollEaseTime: TimeInterval = 0.06

    /// Points per image pixel at zoom 1.
    private var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewport.width / imageSize.width, viewport.height / imageSize.height)
    }

    /// The zoom at which one image pixel is one device pixel.
    var actualSizeZoom: CGFloat {
        guard fitScale > 0 else { return 1 }
        return 1 / (backingScale * fitScale)
    }

    var maximumZoom: CGFloat { max(1, actualSizeZoom * Self.pixelMagnification) }
    var isZoomedIn: Bool { zoom > 1.001 }

    /// The photo's size on screen, in points.
    var displayedSize: CGSize {
        let scale = fitScale * zoom
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// The photo's rectangle in the viewport, in flipped coordinates.
    var frame: CGRect {
        let size = displayedSize
        return CGRect(
            x: viewport.width / 2 - center.x * size.width, y: viewport.height / 2 - center.y * size.height,
            width: size.width, height: size.height)
    }

    /// The long edge a decoded image needs for this zoom to stay sharp, in pixels.
    var pixelsNeeded: Int {
        let size = displayedSize
        return Int((max(size.width, size.height) * backingScale).rounded(.up))
    }

    /// Whether there's more of the photo to see in a direction, which is what the arrow keys ask.
    var canPanHorizontally: Bool { displayedSize.width > viewport.width + 0.5 }
    var canPanVertically: Bool { displayedSize.height > viewport.height + 0.5 }

    /// Keeps the photo over the viewport. An axis that fits stays centered.
    mutating func clampCenter() {
        let size = displayedSize
        center.x = Self.clamped(center.x, size: size.width, viewport: viewport.width)
        center.y = Self.clamped(center.y, size: size.height, viewport: viewport.height)
    }

    private static func clamped(_ value: CGFloat, size: CGFloat, viewport: CGFloat) -> CGFloat {
        guard size > viewport, size > 0 else { return 0.5 }
        let margin = viewport / 2 / size
        return min(max(value, margin), 1 - margin)
    }

    /// Moves the photo by a distance in points.
    mutating func pan(by delta: CGSize) {
        let size = displayedSize
        guard size.width > 0, size.height > 0 else { return }
        center.x -= delta.width / size.width
        center.y -= delta.height / size.height
        clampCenter()
    }

    /// A zoom this photo can reach.
    func clampedZoom(_ zoom: CGFloat) -> CGFloat { min(max(zoom, 1), maximumZoom) }

    /// Zooms, keeping the photo still under a point of the viewport.
    mutating func setZoom(_ next: CGFloat, keeping point: CGPoint? = nil) {
        let point = point ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let old = frame
        let target = clampedZoom(next)
        guard old.width > 0, old.height > 0 else {
            zoom = target
            return
        }
        let anchor = CGPoint(x: (point.x - old.minX) / old.width, y: (point.y - old.minY) / old.height)
        zoom = target
        let size = displayedSize
        center.x = anchor.x + (viewport.width / 2 - point.x) / size.width
        center.y = anchor.y + (viewport.height / 2 - point.y) / size.height
        clampCenter()
    }

    /// The next zoom for Command-Equals or Command-Minus. Fit and actual size are stops on the way.
    func steppedZoom(larger: Bool) -> CGFloat {
        let next = larger ? zoom * Self.step : zoom / Self.step
        let actual = actualSizeZoom
        if actual > 1.001 {
            if larger, zoom < actual - 0.001, next > actual { return actual }
            if !larger, zoom > actual + 0.001, next < actual { return actual }
        }
        return min(max(next, 1), maximumZoom)
    }

    /// How much a scroll zooms. A wheel's delta is in lines, and anything smoother in points, where
    /// about ten make one line. Multiplying keeps each notch the same step at any zoom.
    static func scrollZoomFactor(delta: CGFloat, isPrecise: Bool) -> CGFloat {
        pow(isPrecise ? 1.01 : 1.1, delta)
    }

    /// Where a scroll's zoom has got to after `elapsed` seconds. It closes a fixed share of the distance
    /// per unit of time, so a new notch on the way carries on without a jolt, and it's even across zoom
    /// levels because the distance is a ratio. Close enough to the target lands on it.
    static func easedZoom(from zoom: CGFloat, to target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard zoom > 0, target > 0 else { return target }
        let next = zoom * pow(target / zoom, 1 - exp(-elapsed / scrollEaseTime))
        return abs(next / target - 1) < 0.002 ? target : next
    }

    /// The longest step a slow frame can take, so that a hitch doesn't turn into a jump.
    static let longestEaseFrame: TimeInterval = 1.0 / 30

    /// What a double click does: to actual size, or back to the whole photo.
    var toggledZoom: CGFloat {
        if isZoomedIn { return 1 }
        return actualSizeZoom > 1.001 ? actualSizeZoom : min(maximumZoom, 2)
    }
}

extension ViewerGeometry {
    /// The long edge, in pixels, that fills `viewport` at zoom 1 for a photo of this aspect.
    static func fitEdge(aspect: CGFloat, viewport: CGSize, backingScale: CGFloat) -> Int {
        guard aspect > 0 else { return Int(max(viewport.width, viewport.height) * backingScale) }
        let width = min(viewport.width, viewport.height * aspect)
        let height = width / aspect
        return Int((max(width, height) * backingScale).rounded(.up))
    }
}

/// The rectangles of a transition between a square tile and the photo.
enum ViewerTransition {
    /// Where the whole photo sits when it fills `tile`, which is what a tile shows.
    static func filled(_ tile: CGRect, aspect: CGFloat) -> CGRect {
        guard aspect > 0, tile.height > 0 else { return tile }
        var size = tile.size
        if tile.width / tile.height > aspect {
            size.height = tile.width / aspect
        } else {
            size.width = tile.height * aspect
        }
        return CGRect(
            x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height)
    }
}
