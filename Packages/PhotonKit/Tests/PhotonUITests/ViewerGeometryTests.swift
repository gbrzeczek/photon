import CoreGraphics
import Testing

@testable import PhotonUI

@Suite("Viewer geometry")
struct ViewerGeometryTests {
    private func geometry(width: CGFloat = 6000, height: CGFloat = 4000) -> ViewerGeometry {
        ViewerGeometry(
            viewport: CGSize(width: 1000, height: 800), imageSize: CGSize(width: width, height: height), backingScale: 2)
    }

    @Test("At zoom 1 the whole photo fits, centered")
    func fit() {
        let frame = geometry().frame
        #expect(abs(frame.midY - 400) < 0.01)
        #expect(abs(frame.width - 1000) < 0.01)
        #expect(abs(frame.midX - 500) < 0.01)
        #expect(!geometry().canPanHorizontally)
    }

    @Test("Actual size puts one image pixel on one device pixel")
    func actualSize() {
        var geometry = geometry()
        geometry.setZoom(geometry.actualSizeZoom)
        #expect(abs(geometry.displayedSize.width - 3000) < 0.01)
        #expect(geometry.pixelsNeeded == 6000)
    }

    @Test("Zooming keeps the point under the cursor still")
    func anchored() {
        var geometry = geometry()
        geometry.setZoom(2)
        let point = CGPoint(x: 300, y: 250)
        let before = geometry.frame
        let relative = CGPoint(x: (point.x - before.minX) / before.width, y: (point.y - before.minY) / before.height)
        geometry.setZoom(3, keeping: point)
        let after = geometry.frame
        #expect(abs(after.minX + relative.x * after.width - point.x) < 0.01)
        #expect(abs(after.minY + relative.y * after.height - point.y) < 0.01)
    }

    @Test("Panning stops at the edges, and an axis that fits stays centered")
    func panning() {
        var geometry = geometry()
        geometry.setZoom(1.1)
        geometry.pan(by: CGSize(width: -100_000, height: -100_000))
        let frame = geometry.frame
        #expect(abs(frame.maxX - 1000) < 0.01)
        #expect(!geometry.canPanVertically)
        #expect(abs(frame.midY - 400) < 0.01)
    }

    @Test("A step stops at actual size, and at fit")
    func steps() {
        var geometry = geometry()
        var zooms: [CGFloat] = []
        for _ in 0..<12 {
            geometry.setZoom(geometry.steppedZoom(larger: true))
            zooms.append(geometry.zoom)
        }
        #expect(zooms.contains { abs($0 - geometry.actualSizeZoom) < 0.0001 })
        #expect(abs(zooms.last! - geometry.maximumZoom) < 0.0001)
        for _ in 0..<12 { geometry.setZoom(geometry.steppedZoom(larger: false)) }
        #expect(geometry.zoom == 1)
        #expect(!geometry.isZoomedIn)
    }

    @Test("A photo smaller than the screen still zooms, and a double click toggles")
    func toggle() {
        var small = geometry(width: 300, height: 200)
        #expect(small.maximumZoom >= 1)
        small.setZoom(small.toggledZoom)
        #expect(small.zoom >= 1)
        var large = geometry()
        large.setZoom(large.toggledZoom)
        #expect(abs(large.zoom - large.actualSizeZoom) < 0.0001)
        large.setZoom(large.toggledZoom)
        #expect(large.zoom == 1)
    }

    @Test("A wider screen keeps fit and the center where they were when the size changes")
    func viewportChange() {
        var geometry = geometry()
        geometry.setZoom(3)
        geometry.center = CGPoint(x: 0.6, y: 0.4)
        geometry.viewport = CGSize(width: 1400, height: 800)
        geometry.clampCenter()
        #expect(abs(geometry.center.x - 0.6) < 0.0001)
    }

    @Test("A preview is the size that fills the viewer, not the screen", arguments: [
        (CGFloat(1.5), 2000),  // Limited by the width.
        (CGFloat(0.75), 1600),  // Limited by the height.
        (CGFloat(3), 2000),
    ])
    func fitEdge(aspect: CGFloat, expected: Int) {
        let edge = ViewerGeometry.fitEdge(aspect: aspect, viewport: CGSize(width: 1000, height: 800), backingScale: 2)
        #expect(edge == expected)
    }

    @Test("Scrolling zooms by the same factor at any zoom, and the two kinds of delta roughly agree")
    func scrollFactor() {
        #expect(ViewerGeometry.scrollZoomFactor(delta: 0, isPrecise: false) == 1)
        let notch = ViewerGeometry.scrollZoomFactor(delta: 1, isPrecise: false)
        let back = ViewerGeometry.scrollZoomFactor(delta: -1, isPrecise: false)
        #expect(abs(notch * back - 1) < 0.0001)
        #expect(abs(ViewerGeometry.scrollZoomFactor(delta: 10, isPrecise: true) - notch) < 0.02)
    }

    @Test("A scroll's zoom eases without overshooting, lands exactly, and frame rate doesn't change it")
    func scrollEasing() {
        var zoom: CGFloat = 1
        var frames = 0
        while zoom != 3, frames < 600 {
            let next = ViewerGeometry.easedZoom(from: zoom, to: 3, elapsed: 1.0 / 120)
            #expect(next > zoom)
            #expect(next <= 3)
            zoom = next
            frames += 1
        }
        #expect(zoom == 3)
        #expect(frames < 60)

        var fast: CGFloat = 1
        for _ in 0..<4 { fast = ViewerGeometry.easedZoom(from: fast, to: 3, elapsed: 1.0 / 120) }
        let slow = ViewerGeometry.easedZoom(
            from: ViewerGeometry.easedZoom(from: 1, to: 3, elapsed: 1.0 / 60), to: 3, elapsed: 1.0 / 60)
        #expect(abs(fast - slow) < 0.0001)
        #expect(ViewerGeometry.easedZoom(from: 2, to: 1, elapsed: 1.0 / 120) < 2)
    }

    @Test("A photo fills a square tile from the middle, as tiles show it")
    func filled() {
        let tile = CGRect(x: 100, y: 200, width: 150, height: 150)
        let wide = ViewerTransition.filled(tile, aspect: 2)
        #expect(wide.height == 150)
        #expect(wide.width == 300)
        #expect(wide.midX == tile.midX)
        let tall = ViewerTransition.filled(tile, aspect: 0.5)
        #expect(tall.width == 150)
        #expect(tall.height == 300)
        #expect(tall.midY == tile.midY)
    }
}
