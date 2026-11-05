import CoreGraphics
import Foundation

/// Pure tile layout shared by both backends. Square layout is O(1) per query.
/// Justified layout is greedy row breaking over every item, and `lastPassSeconds` records what
/// that costs, because AGENTS.md forbids per-frame work proportional to the library.
final class Geometry {
    enum Mode: String { case square, justified }

    let count: Int
    let aspects: [Float]
    let mode: Mode
    let spacing: CGFloat = 2
    private(set) var width: CGFloat = 1
    private(set) var tile: CGFloat = 160
    private(set) var lastPassSeconds = 0.0

    // Square
    private(set) var columns = 1
    private var pitch: CGFloat = 162

    // Justified, one entry per row
    private var rowStart: [Int32] = []
    private var rowHeight: [Float] = []
    private var rowY: [Double] = []

    init(count: Int, aspects: [Float], mode: Mode) {
        self.count = count
        self.aspects = aspects
        self.mode = mode
    }

    func update(width: CGFloat, tile: CGFloat) {
        guard width != self.width || tile != self.tile else { return }
        self.width = max(width, 1)
        self.tile = tile
        switch mode {
        case .square:
            columns = max(1, Int((self.width + spacing) / (tile + spacing)))
            pitch = tile + spacing
        case .justified:
            let start = DispatchTime.now().uptimeNanoseconds
            justify()
            lastPassSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
    }

    private func justify() {
        rowStart.removeAll(keepingCapacity: true)
        rowHeight.removeAll(keepingCapacity: true)
        rowY.removeAll(keepingCapacity: true)
        let target = Float(tile), w = Float(width), gap = Float(spacing)
        var y = 0.0, sum: Float = 0, start = 0
        aspects.withUnsafeBufferPointer { a in
            for i in 0..<count {
                sum += a[i]
                let n = Float(i - start + 1)
                if sum * target + gap * (n - 1) >= w {
                    let h = (w - gap * (n - 1)) / sum
                    rowStart.append(Int32(start)); rowHeight.append(h); rowY.append(y)
                    y += Double(h + gap)
                    start = i + 1
                    sum = 0
                }
            }
        }
        if start < count {
            rowStart.append(Int32(start)); rowHeight.append(target); rowY.append(y)
        }
    }

    var contentHeight: CGFloat {
        switch mode {
        case .square:
            return CGFloat((count + columns - 1) / columns) * pitch
        case .justified:
            guard let y = rowY.last, let h = rowHeight.last else { return 0 }
            return CGFloat(y) + CGFloat(h)
        }
    }

    private func row(atY y: CGFloat) -> Int {
        var low = 0, high = rowY.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowY[mid] <= Double(y) { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func row(containing index: Int) -> Int {
        var low = 0, high = rowStart.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(rowStart[mid]) <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func rowEnd(_ row: Int) -> Int { row + 1 < rowStart.count ? Int(rowStart[row + 1]) : count }

    func frame(of index: Int) -> CGRect {
        switch mode {
        case .square:
            return CGRect(x: CGFloat(index % columns) * pitch, y: CGFloat(index / columns) * pitch, width: tile, height: tile)
        case .justified:
            let r = row(containing: index)
            let h = CGFloat(rowHeight[r])
            var x: CGFloat = 0
            for i in Int(rowStart[r])..<index { x += CGFloat(aspects[i]) * h + spacing }
            return CGRect(x: x, y: CGFloat(rowY[r]), width: CGFloat(aspects[index]) * h, height: h)
        }
    }

    /// Visits tiles intersecting `rect`, in index order. Cost scales with the tiles visited.
    func forEach(in rect: CGRect, _ body: (Int, CGRect) -> Void) {
        switch mode {
        case .square:
            let first = max(0, Int(rect.minY / pitch)), last = Int(rect.maxY / pitch)
            for r in first...max(first, last) {
                for c in 0..<columns {
                    let i = r * columns + c
                    if i >= count { return }
                    body(i, CGRect(x: CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: tile, height: tile))
                }
            }
        case .justified:
            var r = row(atY: rect.minY)
            while r < rowStart.count, rowY[r] < Double(rect.maxY) {
                let h = CGFloat(rowHeight[r])
                var x: CGFloat = 0
                for i in Int(rowStart[r])..<rowEnd(r) {
                    let w = CGFloat(aspects[i]) * h
                    body(i, CGRect(x: x, y: CGFloat(rowY[r]), width: w, height: h))
                    x += w + spacing
                }
                r += 1
            }
        }
    }

    func index(at point: CGPoint) -> Int {
        var hit = 0
        forEach(in: CGRect(x: 0, y: point.y, width: width, height: 1)) { i, f in
            if f.minX <= point.x { hit = i }
        }
        return hit
    }

    /// Left and Right follow reading order. Up and Down keep the column, or in justified
    /// layouts pick the tile closest horizontally, as docs/PLAN.md specifies.
    func neighbor(of index: Int, dx: Int, dy: Int) -> Int {
        if dx != 0 { return min(max(index + dx, 0), count - 1) }
        switch mode {
        case .square:
            let n = index + dy * columns
            return (0..<count).contains(n) ? n : index
        case .justified:
            let r = row(containing: index) + dy
            guard rowStart.indices.contains(r) else { return index }
            let center = frame(of: index).midX
            let h = CGFloat(rowHeight[r])
            var x: CGFloat = 0, best = Int(rowStart[r]), bestGap = CGFloat.infinity
            for i in Int(rowStart[r])..<rowEnd(r) {
                let w = CGFloat(aspects[i]) * h
                let gap = abs(x + w / 2 - center)
                if gap < bestGap { best = i; bestGap = gap }
                x += w + spacing
            }
            return best
        }
    }
}
