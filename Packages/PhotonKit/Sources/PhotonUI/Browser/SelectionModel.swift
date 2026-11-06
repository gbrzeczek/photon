import Foundation
import PhotonCore

/// What's selected in the current result, shared by grid and list.
///
/// The current item is an asset, so it survives re-sorts and view changes. Selected rows are ranges over
/// the current result rather than a set of assets, so selecting 100k items costs one range, and
/// holding Shift-Page Down stays cheap. When the order changes, `remapped` carries them across.
@MainActor
final class SelectionModel {
    private(set) var rows = IndexSet()
    private(set) var currentAsset: AssetID?
    /// The row of `currentAsset` in the current result.
    private(set) var currentRow: Int?
    /// A running count, so that work begun on a snapshot can tell if it has gone stale.
    private(set) var version = 0

    /// Where a Shift extension starts, and what was selected before it.
    private var extensionAnchor: Int?
    private var extensionBase = IndexSet()

    var count: Int { rows.count }

    func isSelected(_ row: Int) -> Bool { rows.contains(row) }

    /// Moves to a row, replacing the selection.
    func select(_ row: Int, asset: AssetID) {
        rows = IndexSet(integer: row)
        setCurrent(row, asset: asset)
        extensionAnchor = row
        extensionBase = IndexSet()
    }

    /// Adds or removes a row, as Command-click does.
    func toggle(_ row: Int, asset: AssetID) {
        if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        setCurrent(row, asset: asset)
        extensionAnchor = row
        extensionBase = rows
    }

    /// Selects from the extension's start to `row`, keeping what was selected before it began.
    func extend(to row: Int, asset: AssetID) {
        let anchor = extensionAnchor ?? currentRow ?? row
        extensionAnchor = anchor
        var next = extensionBase
        next.insert(integersIn: min(anchor, row)..<(max(anchor, row) + 1))
        rows = next
        setCurrent(row, asset: asset)
    }

    func selectAll(count: Int) {
        rows = count > 0 ? IndexSet(integersIn: 0..<count) : IndexSet()
        version += 1
    }

    func selectNone() {
        rows = IndexSet()
        extensionAnchor = currentRow
        extensionBase = IndexSet()
        version += 1
    }

    /// Takes on the table view's selection after a click in the list.
    func adopt(rows: IndexSet, current: Int?, asset: AssetID?) {
        self.rows = rows
        currentRow = current
        currentAsset = asset
        if let current {
            extensionAnchor = current
            extensionBase = IndexSet()
        }
        version += 1
    }

    private func setCurrent(_ row: Int, asset: AssetID) {
        currentRow = row
        currentAsset = asset
        version += 1
    }

    /// Forgets everything, as when opening another folder.
    func reset() {
        rows = IndexSet()
        currentAsset = nil
        currentRow = nil
        extensionAnchor = nil
        extensionBase = IndexSet()
        version += 1
    }

    /// Selected rows after a change of result. Runs off the main thread: it's proportional to the selection.
    nonisolated static func remapped(_ rows: IndexSet, map: [Int32]) -> IndexSet {
        var next = IndexSet()
        if rows.count == map.count, !map.contains(-1) {
            // Everything stays selected, so the result is one range. This is Select All during indexing.
            return map.isEmpty ? next : IndexSet(integersIn: 0..<map.count)
        }
        for row in rows where row < map.count && map[row] >= 0 { next.insert(Int(map[row])) }
        return next
    }

    /// Applies a new result. `rows` came from `remapped`, and `current` is the new row of the current item.
    func install(rows: IndexSet, current: Int?, asset: AssetID?) {
        self.rows = rows
        currentRow = current
        currentAsset = asset
        extensionAnchor = current
        extensionBase = IndexSet()
        version += 1
    }
}
