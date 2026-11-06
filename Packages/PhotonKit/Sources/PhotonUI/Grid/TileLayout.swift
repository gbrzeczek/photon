import CoreGraphics
import Foundation

public enum TileLayoutMode: Int, Sendable, CaseIterable {
    case square = 0
    case aspect = 1
}

public enum TileMetrics {
    public static let spacing: CGFloat = 2
    public static let minimumTile: CGFloat = 64
    public static let maximumTile: CGFloat = 400
    public static let defaultTile: CGFloat = 160
}

/// Rows of an aspect-ratio layout, in reading order.
struct AspectRows: Sendable {
    /// The first item of each row, ascending.
    var starts: [Int32] = []
    var heights: [Float] = []
    /// The top of each row. Double, because a large library runs to tens of millions of points.
    var tops: [Double] = []

    var count: Int { starts.count }

    /// How many items fit in a row starting at `start`, and the row's height.
    @inline(__always)
    static func rowForward(
        from start: Int, aspects: UnsafeBufferPointer<Float>, width: Float, target: Float, gap: Float
    ) -> (end: Int, height: Float, isFull: Bool) {
        var sum: Float = 0
        var index = start
        while index < aspects.count {
            sum += aspects[index]
            index += 1
            let items = Float(index - start)
            if sum * target + gap * (items - 1) >= width {
                return (index, (width - gap * (items - 1)) / sum, true)
            }
        }
        return (index, target, false)
    }

    /// The row ending just before `end`, built backward.
    @inline(__always)
    static func rowBackward(
        before end: Int, aspects: UnsafeBufferPointer<Float>, width: Float, target: Float, gap: Float
    ) -> (start: Int, height: Float, isFull: Bool) {
        var sum: Float = 0
        var index = end
        while index > 0 {
            index -= 1
            sum += aspects[index]
            let items = Float(end - index)
            if sum * target + gap * (items - 1) >= width {
                return (index, (width - gap * (items - 1)) / sum, true)
            }
        }
        return (0, target, false)
    }

    /// The full pass. Rows break forward from `anchorStart` and backward from it, so a pass that follows
    /// a zoom keeps the rows the zoom already showed. Proportional to the library, so it runs off the
    /// main thread: about a millisecond at 200k items.
    static func compute(
        aspects: [Float], width: CGFloat, target: CGFloat, spacing: CGFloat, anchorStart: Int = 0
    ) -> AspectRows {
        guard !aspects.isEmpty else { return AspectRows() }
        let (w, t, gap) = (Float(width), Float(target), Float(spacing))
        var before: [(start: Int32, height: Float)] = []
        var rows = AspectRows()
        aspects.withUnsafeBufferPointer { buffer in
            var end = anchorStart
            while end > 0 {
                let row = rowBackward(before: end, aspects: buffer, width: w, target: t, gap: gap)
                before.append((Int32(row.start), row.height))
                end = row.start
            }
            let estimatedRows = aspects.count / 4 + 1
            rows.starts.reserveCapacity(estimatedRows)
            rows.heights.reserveCapacity(estimatedRows)
            rows.tops.reserveCapacity(estimatedRows)
            var top = 0.0
            for row in before.reversed() {
                rows.starts.append(row.start)
                rows.heights.append(row.height)
                rows.tops.append(top)
                top += Double(row.height + gap)
            }
            var start = anchorStart
            while start < buffer.count {
                let row = rowForward(from: start, aspects: buffer, width: w, target: t, gap: gap)
                rows.starts.append(Int32(start))
                rows.heights.append(row.height)
                rows.tops.append(top)
                top += Double(row.height + gap)
                start = row.end
            }
        }
        return rows
    }
}

/// Where tiles go. Pure geometry, with no views, so that it can be tested without a window.
///
/// Queries cost what they return, never what the library holds. The one exception is the full pass
/// over an aspect-ratio layout, which `AspectRows.compute` does off the main thread. Until it lands,
/// the layout is *local*: rows are built outward from an anchor, only as far as they're looked at.
///
/// **Zooming.** When the column count changes, a tile's cell changes, and with no help the tile under
/// the cursor would jump across the window. So during a zoom, both layouts choose how rows break to keep
/// the anchor where it is. Square layouts use `phase`, which is blank cells before the first item.
/// Aspect-ratio layouts break rows around the anchor. Rows stay that way afterward, because the full
/// pass starts from the same row, and `settle` clears them once the top of the library is on screen.
///
/// **Filling the width.** Square tiles at rest fill the width exactly, so the size asked for only chooses
/// the column count, and the tile is whatever fits that many columns. Only a zoom in progress shows other
/// sizes, which leaves margins until the zoom ends and the grid eases to `filledTile(for:)`.
struct TileLayout {
    let spacing = TileMetrics.spacing
    private(set) var mode: TileLayoutMode
    private(set) var width: CGFloat = 1
    /// The size on screen. Square tiles at rest are bigger than the size asked for.
    private(set) var tile: CGFloat = TileMetrics.defaultTile

    private(set) var aspects: [Float] = []
    /// Sums of `aspects` every `prefixStride` items, for estimating positions in constant time.
    private var prefix: [Double] = [0]
    private static let prefixStride = 256

    // Square
    private(set) var columns = 1
    private(set) var phase = 0

    // Aspect
    private var full = AspectRows()
    private var fullIsValid = false
    private var fullAnchorStart = 0
    private var local = AspectRows()
    /// A running count of changes to how rows break, for the column-change transition.
    private(set) var structureVersion = 0

    init(mode: TileLayoutMode = .square) { self.mode = mode }

    var count: Int { aspects.count }
    var isLocal: Bool { mode == .aspect && !fullIsValid }
    private var pitch: CGFloat { tile + spacing }

    /// Left and right margins, so that a square grid stays centered during a zoom. Zero at rest, and
    /// negative for a moment when a zoom adds columns before its tiles have shrunk.
    private var margin: CGFloat {
        (width - (CGFloat(columns) * pitch - spacing)) / 2
    }

    private var rows: AspectRows { fullIsValid ? full : local }

    // MARK: Setup

    /// Swaps in new items. `rows` is the finished full pass, if there is one for this width and size.
    mutating func setItems(_ aspects: [Float], prefix: [Double], rows: AspectRows?) {
        self.aspects = aspects
        self.prefix = prefix
        phase = 0
        if let rows {
            full = rows
            fullIsValid = true
        } else {
            fullIsValid = false
            local = AspectRows()
        }
        structureVersion += 1
    }

    static func prefixSums(_ aspects: [Float]) -> [Double] {
        var sums: [Double] = []
        sums.reserveCapacity(aspects.count / prefixStride + 2)
        var sum = 0.0
        for (index, aspect) in aspects.enumerated() {
            if index % prefixStride == 0 { sums.append(sum) }
            sum += Double(aspect)
        }
        sums.append(sum)
        return sums
    }

    private func aspectSum(upTo index: Int) -> Double {
        guard index > 0, !aspects.isEmpty else { return 0 }
        let block = min(index / Self.prefixStride, prefix.count - 1)
        // Beyond the last sum, the mean is good enough for an estimate.
        return prefix[block] + Double(index - block * Self.prefixStride) * mean
    }

    private var mean: Double {
        aspects.isEmpty ? 1 : (prefix.last ?? 0) / Double(aspects.count)
    }

    mutating func setMode(_ mode: TileLayoutMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        phase = 0
        fullIsValid = false
        local = AspectRows()
        structureVersion += 1
    }

    /// Changes size or width with no anchor, as at first layout.
    mutating func resize(width: CGFloat, tile: CGFloat) {
        self.width = max(width, 1)
        let previous = columns
        columns = Self.columns(width: self.width, tile: tile, spacing: spacing)
        self.tile = mode == .square ? filledTile(columns: columns) : tile
        if mode == .square {
            if previous != columns {
                phase = 0
                structureVersion += 1
            }
        } else {
            fullIsValid = false
            local = AspectRows()
        }
    }

    /// Rounds up a hair, because a filled tile has to get its own column count back.
    private static func columns(width: CGFloat, tile: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (tile + spacing) + 1e-6))
    }

    private func filledTile(columns: Int) -> CGFloat {
        (width + spacing) / CGFloat(columns) - spacing
    }

    /// The column count that a square tile of `size` gives at this width.
    func columns(for size: CGFloat) -> Int {
        Self.columns(width: width, tile: size, spacing: spacing)
    }

    /// The square tile that fills the width, in the columns that `size` gives.
    func filledTile(for size: CGFloat) -> CGFloat {
        filledTile(columns: columns(for: size))
    }

    /// The size for Command-Equals and Command-Minus. Large tiles span many sizes per column count, so
    /// where the usual step would change nothing, this goes to the middle of the next count's sizes,
    /// which leaves room to resize the window before the count changes again.
    func steppedSize(from size: CGFloat, larger: Bool) -> CGFloat {
        let step = size * (larger ? 1.25 : 0.8)
        guard mode == .square, columns(for: step) == columns(for: size) else { return step }
        let next = columns(for: size) + (larger ? -1 : 1)
        guard next >= 1 else { return step }
        return (filledTile(columns: next) + filledTile(columns: next + 1)) / 2
    }

    // MARK: Zooming

    /// One step of a zoom. Keeps the anchor in its place on screen as well as rows allow.
    ///
    /// - Parameters:
    ///   - anchor: The item to keep in place.
    ///   - anchorX: Where its center is now, in layout coordinates.
    ///   - coverage: The vertical span the local layout should reach, around the anchor.
    ///   - columns: A square grid's column count, if it shouldn't follow from `tile`.
    mutating func zoom(
        width: CGFloat, tile: CGFloat, anchor: Int, anchorX: CGFloat, coverage: CGFloat, columns fixed: Int? = nil
    ) {
        guard count > 0 else { return resize(width: width, tile: tile) }
        self.width = max(width, 1)
        self.tile = tile
        switch mode {
        case .square:
            let previous = columns
            columns = fixed ?? self.columns(for: tile)
            guard previous != columns else { return }
            let column = max(0, min(columns - 1, Int((anchorX - margin) / pitch)))
            phase = ((column - anchor) % columns + columns) % columns
            structureVersion += 1
        case .aspect:
            buildLocal(anchor: anchor, anchorX: anchorX, coverage: coverage)
        }
    }

    /// Whether a zoom's shifted rows could be put back, which only matters where they show: blank
    /// cells or a short row at the very top.
    func canSettle(viewportTop: CGFloat) -> Bool {
        viewportTop < pitch && (mode == .square ? phase != 0 : fullIsValid && fullAnchorStart != 0)
    }

    /// Clears the blank cells from a zoom. Aspect-ratio rows need a full pass from the top instead.
    mutating func settle() {
        guard phase != 0 else { return }
        phase = 0
        structureVersion += 1
    }

    /// The first item of the row that holds `index`, which a full pass should start from.
    func rowStart(containing index: Int) -> Int {
        guard mode == .aspect, rows.count > 0, count > 0 else { return 0 }
        return Int(rows.starts[row(containing: index)])
    }

    /// Installs the full pass, which replaces the local rows.
    /// - Parameter anchorStart: The row it broke around.
    mutating func install(_ rows: AspectRows, anchorStart: Int = 0) {
        full = rows
        fullAnchorStart = anchorStart
        fullIsValid = true
        local = AspectRows()
    }

    private mutating func buildLocal(anchor: Int, anchorX: CGFloat, coverage: CGFloat) {
        let previousCount = local.count > 0 ? itemsInLocalRow(containing: anchor) : 0
        let wasFull = fullIsValid
        fullIsValid = false
        let (w, t, gap) = (Float(width), Float(tile), Float(spacing))
        let lookback = 48

        var fresh = AspectRows()
        aspects.withUnsafeBufferPointer { buffer in
            // The anchor's row: whichever break puts the anchor closest to where it is now.
            var bestStart = anchor
            var bestHeight = t
            var bestEnd = anchor + 1
            var bestGap = CGFloat.infinity
            var candidate = anchor
            let lowest = max(0, anchor - lookback)
            while candidate >= lowest {
                let row = AspectRows.rowForward(from: candidate, aspects: buffer, width: w, target: t, gap: gap)
                if row.end > anchor {
                    var x: Float = 0
                    for index in candidate..<anchor { x += buffer[index] * row.height + gap }
                    let center = CGFloat(x + buffer[anchor] * row.height / 2)
                    let distance = abs(center - anchorX)
                    if distance < bestGap {
                        (bestStart, bestHeight, bestEnd, bestGap) = (candidate, row.height, row.end, distance)
                    }
                }
                // Once the row can't reach the anchor, earlier starts can't either.
                else { break }
                candidate -= 1
            }

            let top = estimatedTop(of: bestStart)
            fresh.starts = [Int32(bestStart)]
            fresh.heights = [bestHeight]
            fresh.tops = [top]
            local = fresh
            _ = bestEnd
        }
        extendLocal(toCover: top(ofLocalAnchor: 0) - coverage, bottom: top(ofLocalAnchor: 0) + coverage)
        if wasFull || previousCount != itemsInLocalRow(containing: anchor) { structureVersion += 1 }
    }

    private func top(ofLocalAnchor index: Int) -> Double { local.tops.isEmpty ? 0 : local.tops[index] }

    private func itemsInLocalRow(containing index: Int) -> Int {
        guard local.count > 0 else { return 0 }
        let row = Self.rowIndex(in: local, containing: index)
        return rowEnd(row, in: local) - Int(local.starts[row])
    }

    /// Top of an item, estimated from areas: rows above hold this much aspect at about this height.
    private func estimatedTop(of index: Int) -> Double {
        let height = Double(tile + spacing)
        return aspectSum(upTo: index) * height * height / Double(width)
    }

    /// Grows local rows up to `top` and down to `bottom`. Costs the rows it adds.
    mutating func extendLocal(toCover top: Double, bottom: Double) {
        guard !fullIsValid, local.count > 0 else { return }
        let (w, t, gap) = (Float(width), Float(tile), Float(spacing))
        var rows = local
        aspects.withUnsafeBufferPointer { buffer in
            var before: [(start: Int32, height: Float)] = []
            var cursor = rows.tops[0]
            var firstStart = Int(rows.starts[0])
            while firstStart > 0, cursor > top {
                let row = AspectRows.rowBackward(before: firstStart, aspects: buffer, width: w, target: t, gap: gap)
                before.append((Int32(row.start), row.height))
                firstStart = row.start
                cursor -= Double(row.height + gap)
            }
            if !before.isEmpty {
                var starts: [Int32] = []
                var heights: [Float] = []
                var tops: [Double] = []
                var y = cursor
                for row in before.reversed() {
                    starts.append(row.start)
                    heights.append(row.height)
                    tops.append(y)
                    y += Double(row.height + gap)
                }
                rows.starts.insert(contentsOf: starts, at: 0)
                rows.heights.insert(contentsOf: heights, at: 0)
                rows.tops.insert(contentsOf: tops, at: 0)
            }
            var nextStart = rowEnd(rows.count - 1, in: rows)
            while nextStart < buffer.count, rows.tops[rows.count - 1] + Double(rows.heights[rows.count - 1]) < bottom {
                let row = AspectRows.rowForward(from: nextStart, aspects: buffer, width: w, target: t, gap: gap)
                let last = rows.count - 1
                rows.tops.append(rows.tops[last] + Double(rows.heights[last] + gap))
                rows.starts.append(Int32(nextStart))
                rows.heights.append(row.height)
                nextStart = row.end
            }
        }
        // The start of the library is the one position known exactly, so the estimate gives way to it.
        if rows.starts[0] == 0, rows.tops[0] != 0 {
            let shift = rows.tops[0]
            for index in rows.tops.indices { rows.tops[index] -= shift }
        }
        local = rows
    }

    // MARK: Queries

    var contentHeight: CGFloat {
        guard count > 0 else { return 0 }
        switch mode {
        case .square:
            return CGFloat((count + phase + columns - 1) / columns) * pitch - spacing
        case .aspect:
            if fullIsValid, let top = full.tops.last, let height = full.heights.last {
                return CGFloat(top) + CGFloat(height)
            }
            if local.count > 0, rowEnd(local.count - 1, in: local) == count {
                return CGFloat(local.tops[local.count - 1]) + CGFloat(local.heights[local.count - 1])
            }
            return CGFloat(estimatedTop(of: count))
        }
    }

    private func rowEnd(_ row: Int, in rows: AspectRows) -> Int {
        row + 1 < rows.count ? Int(rows.starts[row + 1]) : nextRowStart(after: row, in: rows)
    }

    /// The end of the last known row, which for a local layout has to be worked out.
    private func nextRowStart(after row: Int, in rows: AspectRows) -> Int {
        if fullIsValid { return count }
        return aspects.withUnsafeBufferPointer { buffer in
            AspectRows.rowForward(
                from: Int(rows.starts[row]), aspects: buffer, width: Float(width), target: Float(tile),
                gap: Float(spacing)
            ).end
        }
    }

    private func row(atY y: CGFloat) -> Int {
        let rows = rows
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if rows.tops[middle] <= Double(y) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func row(containing index: Int) -> Int { Self.rowIndex(in: rows, containing: index) }

    private static func rowIndex(in rows: AspectRows, containing index: Int) -> Int {
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Int(rows.starts[middle]) <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func frame(of index: Int) -> CGRect {
        switch mode {
        case .square:
            let cell = index + phase
            return CGRect(
                x: margin + CGFloat(cell % columns) * pitch, y: CGFloat(cell / columns) * pitch,
                width: tile, height: tile)
        case .aspect:
            guard rows.count > 0 else { return estimatedFrame(of: index) }
            let rows = rows
            let row = Self.rowIndex(in: rows, containing: index)
            guard index < rowEnd(row, in: rows) else { return estimatedFrame(of: index) }
            let height = CGFloat(rows.heights[row])
            var x: CGFloat = 0
            for item in Int(rows.starts[row])..<index { x += CGFloat(aspects[item]) * height + spacing }
            return CGRect(x: x, y: CGFloat(rows.tops[row]), width: CGFloat(aspects[index]) * height, height: height)
        }
    }

    private func estimatedFrame(of index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(estimatedTop(of: index)), width: tile, height: tile)
    }

    /// Visits tiles meeting `rect`, in order. The cost is the tiles visited.
    func forEach(in rect: CGRect, _ body: (Int, CGRect) -> Void) {
        guard count > 0 else { return }
        switch mode {
        case .square:
            let (left, topInset) = (margin, max(0, Int(rect.minY / pitch)))
            let last = Int(rect.maxY / pitch)
            for row in topInset...max(topInset, last) {
                for column in 0..<columns {
                    let item = row * columns + column - phase
                    if item < 0 { continue }
                    if item >= count { return }
                    body(
                        item,
                        CGRect(
                            x: left + CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: tile, height: tile))
                }
            }
        case .aspect:
            let rows = rows
            guard rows.count > 0 else { return }
            var row = row(atY: rect.minY)
            while row < rows.count, rows.tops[row] < Double(rect.maxY) {
                let height = CGFloat(rows.heights[row])
                var x: CGFloat = 0
                for item in Int(rows.starts[row])..<rowEnd(row, in: rows) {
                    let tileWidth = CGFloat(aspects[item]) * height
                    body(item, CGRect(x: x, y: CGFloat(rows.tops[row]), width: tileWidth, height: height))
                    x += tileWidth + spacing
                }
                row += 1
            }
        }
    }

    /// The tile at `point`, or nil over a gap or past the end.
    func index(at point: CGPoint) -> Int? {
        var hit: Int?
        forEach(in: CGRect(x: 0, y: point.y, width: width, height: 1)) { item, frame in
            if frame.contains(point) { hit = item }
        }
        return hit
    }

    /// The tile closest to `point`, for moving by a screen and for anchoring on empty space.
    func closest(to point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        var best: Int?
        var bestDistance = CGFloat.infinity
        let y = max(0, min(point.y, contentHeight - 1))
        forEach(in: CGRect(x: 0, y: y, width: width, height: 1)) { item, frame in
            let distance = abs(frame.midX - point.x)
            if distance < bestDistance {
                best = item
                bestDistance = distance
            }
        }
        return best
    }

    /// Up and Down keep the column, or in aspect-ratio layouts take the tile closest horizontally.
    func neighbor(of index: Int, rowDelta: Int) -> Int {
        switch mode {
        case .square:
            let next = index + rowDelta * columns
            return (0..<count).contains(next) ? next : index
        case .aspect:
            let rows = rows
            guard rows.count > 0 else { return index }
            let target = Self.rowIndex(in: rows, containing: index) + rowDelta
            guard rows.starts.indices.contains(target) else { return index }
            let center = frame(of: index).midX
            let height = CGFloat(rows.heights[target])
            var x: CGFloat = 0
            var best = Int(rows.starts[target])
            var bestGap = CGFloat.infinity
            for item in Int(rows.starts[target])..<rowEnd(target, in: rows) {
                let tileWidth = CGFloat(aspects[item]) * height
                let gap = abs(x + tileWidth / 2 - center)
                if gap < bestGap {
                    best = item
                    bestGap = gap
                }
                x += tileWidth + spacing
            }
            return best
        }
    }
}
