import CoreGraphics
import Testing

@testable import PhotonUI

@Suite("Tile layout")
struct TileLayoutTests {
    private func square(count: Int, width: CGFloat = 1000, tile: CGFloat = 100) -> TileLayout {
        var layout = TileLayout(mode: .square)
        let aspects = [Float](repeating: 1, count: count)
        layout.setItems(aspects, prefix: TileLayout.prefixSums(aspects), rows: nil)
        layout.resize(width: width, tile: tile)
        return layout
    }

    private func aspectLayout(_ aspects: [Float], width: CGFloat = 1000, tile: CGFloat = 100) -> TileLayout {
        var layout = TileLayout(mode: .aspect)
        layout.setItems(aspects, prefix: TileLayout.prefixSums(aspects), rows: nil)
        layout.resize(width: width, tile: tile)
        layout.install(AspectRows.compute(aspects: aspects, width: width, target: tile, spacing: layout.spacing))
        return layout
    }

    private func randomAspects(_ count: Int) -> [Float] {
        let choices: [Float] = [0.667, 0.75, 1, 1.333, 1.5, 1.778]
        var value = 12345
        return (0..<count).map { _ in
            value = (value &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            return choices[value % choices.count]
        }
    }

    @Test("Square tiles fill rows in order, centered in the width")
    func squareFrames() {
        let layout = square(count: 100, width: 1000, tile: 100)
        #expect(layout.columns == 9)
        let first = layout.frame(of: 0)
        let last = layout.frame(of: 8)
        #expect(abs(first.minX - (1000 - last.maxX)) < 0.001)
        #expect(layout.frame(of: 9).minY == first.maxY + layout.spacing)
    }

    @Test("At rest, square tiles fill the width exactly, whatever size was asked for")
    func squareFillsWidth() {
        for width in stride(from: CGFloat(300), through: 3000, by: 37.5) {
            for tile in stride(from: CGFloat(64), through: 400, by: 7) {
                let layout = square(count: 1000, width: width, tile: tile)
                let last = layout.frame(of: layout.columns - 1)
                #expect(abs(layout.frame(of: 0).minX) < 0.001)
                #expect(abs(last.maxX - width) < 0.001)
                #expect(layout.tile >= tile || layout.columns == 1)
            }
        }
    }

    @Test("A filled tile gets its own column count back")
    func filledTileIsStable() {
        for width in stride(from: CGFloat(300), through: 3000, by: 11.3) {
            let layout = square(count: 1000, width: width, tile: 100)
            #expect(layout.columns(for: layout.tile) == layout.columns)
            #expect(layout.filledTile(for: layout.tile) == layout.tile)
        }
    }

    @Test("A zoom shows the exact size, with margins, until it fills the width again")
    func zoomKeepsExactSize() {
        var layout = square(count: 1000, width: 1000, tile: 100)
        layout.zoom(width: 1000, tile: 104, anchor: 10, anchorX: 300, coverage: 1000)
        #expect(layout.tile == 104)
        #expect(layout.frame(of: 0).minX > 0)
        let filled = layout.filledTile(for: layout.tile)
        layout.zoom(width: 1000, tile: filled, anchor: 10, anchorX: 300, coverage: 1000)
        #expect(abs(layout.frame(of: layout.columns - 1).maxX - 1000) < 0.001 || layout.phase != 0)
        #expect(abs(layout.frame(of: 0).minX) < filled + 3)
    }

    @Test("A zoom can reflow to its final column count before its tiles have changed size")
    func zoomWithFixedColumns() {
        var layout = square(count: 1000, width: 1000, tile: 100)
        let start = layout.structureVersion
        layout.zoom(width: 1000, tile: layout.tile, anchor: 10, anchorX: 300, coverage: 1000, columns: 10)
        #expect(layout.columns == 10)
        #expect(layout.structureVersion == start + 1)
        var visited = 0
        layout.forEach(in: CGRect(x: 0, y: 0, width: 1000, height: 200)) { _, _ in visited += 1 }
        #expect(visited > 0)
    }

    @Test("Every shortcut step changes the column count, until the size limits")
    func stepsChangeColumns() {
        var size: CGFloat = 200
        var layout = square(count: 1000, width: 1272, tile: size)
        var previous = layout.columns
        while true {
            size = min(layout.steppedSize(from: size, larger: true), TileMetrics.maximumTile)
            layout.resize(width: 1272, tile: size)
            if size == TileMetrics.maximumTile || layout.columns == previous { break }
            #expect(layout.columns < previous)
            previous = layout.columns
        }
        #expect(layout.columns == 3)
        while size > TileMetrics.minimumTile {
            size = max(layout.steppedSize(from: size, larger: false), TileMetrics.minimumTile)
            let before = layout.columns
            layout.resize(width: 1272, tile: size)
            #expect(layout.columns > before || size == TileMetrics.minimumTile)
        }
    }

    @Test("A step leaves room to narrow the window before the column count changes")
    func stepsLeaveRoom() {
        var layout = square(count: 1000, width: 1272, tile: 360)
        let size = layout.steppedSize(from: 360, larger: false)
        layout.resize(width: 1272, tile: size)
        let columns = layout.columns
        layout.resize(width: 1262, tile: size)
        #expect(layout.columns == columns)
    }

    @Test("forEach visits only what meets the rectangle, in order")
    func forEachIsBounded() {
        let layout = square(count: 1_000_000)
        var visited: [Int] = []
        layout.forEach(in: CGRect(x: 0, y: 1_020_000, width: 1000, height: 300)) { index, _ in visited.append(index) }
        #expect(visited.count <= 9 * 5)
        #expect(visited == visited.sorted())
    }

    @Test("Hit testing finds tiles and rejects gaps and the end of the library")
    func hitTesting() {
        let layout = square(count: 10)
        let frame = layout.frame(of: 3)
        #expect(layout.index(at: CGPoint(x: frame.midX, y: frame.midY)) == 3)
        #expect(layout.index(at: CGPoint(x: frame.maxX + 1, y: frame.midY)) == nil)
        #expect(layout.index(at: CGPoint(x: 500, y: 5000)) == nil)
    }

    @Test("Up and Down keep the column, and stay put at the edges")
    func squareNeighbors() {
        let layout = square(count: 100)
        #expect(layout.neighbor(of: 12, rowDelta: 1) == 21)
        #expect(layout.neighbor(of: 12, rowDelta: -1) == 3)
        #expect(layout.neighbor(of: 3, rowDelta: -1) == 3)
        #expect(layout.neighbor(of: 95, rowDelta: 1) == 95)
    }

    @Test("Aspect rows fill the width exactly, except the last")
    func aspectRowsFill() {
        let aspects = randomAspects(2000)
        let layout = aspectLayout(aspects)
        var lastInRow: [CGFloat: CGRect] = [:]
        layout.forEach(in: CGRect(x: 0, y: 0, width: 1000, height: 2000)) { _, frame in
            lastInRow[frame.minY] = frame
        }
        #expect(lastInRow.count > 3)
        for frame in lastInRow.values { #expect(abs(frame.maxX - 1000) < 0.1) }
    }

    @Test("Every item lands in exactly one aspect row, in order")
    func aspectRowsCoverAll() {
        let aspects = randomAspects(5000)
        let layout = aspectLayout(aspects)
        var visited: [Int] = []
        layout.forEach(in: CGRect(x: 0, y: 0, width: 1000, height: layout.contentHeight + 1)) { index, _ in
            visited.append(index)
        }
        #expect(visited == Array(0..<5000))
    }

    @Test("Up in aspect rows picks the closest tile horizontally")
    func aspectNeighbor() {
        let layout = aspectLayout(randomAspects(500))
        let start = layout.index(at: CGPoint(x: 500, y: 300))!
        let up = layout.neighbor(of: start, rowDelta: -1)
        let candidates = (0..<500).filter { layout.frame(of: $0).minY == layout.frame(of: up).minY }
        let best = candidates.min { abs(layout.frame(of: $0).midX - 500) < abs(layout.frame(of: $1).midX - 500) }
        let center = layout.frame(of: start).midX
        #expect(abs(layout.frame(of: up).midX - center) <= abs(layout.frame(of: best!).midX - center) + 0.001)
    }

    // MARK: Zooming

    @Test("In square layouts, the anchor stays within one column through every column change")
    func squareZoomKeepsColumn() {
        var layout = square(count: 100_000)
        let anchor = 53_217
        var tile: CGFloat = 100
        while tile < 400 {
            let before = layout.frame(of: anchor)
            tile += 3
            layout.zoom(width: 1000, tile: tile, anchor: anchor, anchorX: before.midX, coverage: 2000)
            let after = layout.frame(of: anchor)
            // A jump used to reach most of the window. Now it's at most a pitch, plus centering.
            #expect(abs(after.midX - before.midX) <= tile + 2 + 1)
        }
    }

    @Test("A column change raises the structure version, and a plain size change doesn't")
    func structureVersion() {
        var layout = square(count: 1000)
        let start = layout.structureVersion
        layout.zoom(width: 1000, tile: 100.5, anchor: 10, anchorX: 300, coverage: 1000)
        #expect(layout.structureVersion == start)
        layout.zoom(width: 1000, tile: 113, anchor: 10, anchorX: 300, coverage: 1000)
        #expect(layout.structureVersion == start + 1)
        #expect(layout.columns == 8)
    }

    @Test("Blank cells keep items in order and cost no items, and settling clears them")
    func phaseKeepsItems() {
        var layout = square(count: 50)
        layout.zoom(width: 1000, tile: 150, anchor: 20, anchorX: 900, coverage: 1000)
        #expect(layout.phase != 0)
        var visited: [Int] = []
        layout.forEach(in: CGRect(x: 0, y: 0, width: 1000, height: layout.contentHeight + 1)) { index, _ in
            visited.append(index)
        }
        #expect(visited == Array(0..<50))
        #expect(layout.canSettle(viewportTop: 0))
        #expect(!layout.canSettle(viewportTop: 5000))
        layout.settle()
        #expect(layout.phase == 0)
    }

    @Test("An aspect zoom stays local, and the full pass keeps the rows it showed")
    func aspectZoomThenFullPass() {
        let aspects = randomAspects(200_000)
        var layout = aspectLayout(aspects)
        let anchor = 100_000
        var x = layout.frame(of: anchor).midX
        for step in 1...40 {
            layout.zoom(width: 1000, tile: 100 + CGFloat(step) * 4, anchor: anchor, anchorX: x, coverage: 1800)
            x = layout.frame(of: anchor).midX
        }
        #expect(layout.isLocal)
        let frame = layout.frame(of: anchor)
        let start = layout.rowStart(containing: anchor)
        var neighbors: [Int: CGRect] = [:]
        for index in (anchor - 30)...(anchor + 30) { neighbors[index] = layout.frame(of: index) }

        let rows = AspectRows.compute(
            aspects: aspects, width: 1000, target: layout.tile, spacing: layout.spacing, anchorStart: start)
        layout.install(rows)
        #expect(!layout.isLocal)
        let installed = layout.frame(of: anchor)
        #expect(abs(installed.minX - frame.minX) < 0.01)
        #expect(abs(installed.height - frame.height) < 0.01)
        // Rows nearby are the same rows, shifted by one amount.
        let shift = installed.minY - frame.minY
        for (index, before) in neighbors {
            let after = layout.frame(of: index)
            #expect(abs(after.minX - before.minX) < 0.01)
            #expect(abs(after.minY - before.minY - shift) < 0.5)
        }
    }

    @Test("The anchor stays near where it was through an aspect zoom")
    func aspectZoomKeepsX() {
        let aspects = randomAspects(50_000)
        var layout = aspectLayout(aspects)
        let anchor = 25_000
        var x = layout.frame(of: anchor).midX
        var tile: CGFloat = 100
        while tile < 300 {
            tile += 2
            layout.zoom(width: 1000, tile: tile, anchor: anchor, anchorX: x, coverage: 1800)
            let next = layout.frame(of: anchor).midX
            #expect(abs(next - x) < 1000 * 0.75, "jumped from \(x) to \(next) at \(tile)")
            x = next
        }
    }

    @Test("A local layout reaching the first item starts at zero, not at the estimate")
    func localReachesTop() {
        let aspects = randomAspects(300)
        var layout = aspectLayout(aspects)
        layout.zoom(width: 1000, tile: 180, anchor: 2, anchorX: 300, coverage: 2000)
        #expect(layout.frame(of: 0).minY == 0)
    }

    @Test("Estimated height is close to the true height")
    func estimate() {
        let aspects = randomAspects(100_000)
        var layout = aspectLayout(aspects)
        let exact = layout.contentHeight
        layout.zoom(width: 1000, tile: 100, anchor: 50_000, anchorX: 500, coverage: 1800)
        #expect(abs(layout.contentHeight - exact) / exact < 0.15)
    }
}
