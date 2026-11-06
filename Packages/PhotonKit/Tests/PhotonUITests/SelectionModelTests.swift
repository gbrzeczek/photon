import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

@Suite("Selection")
@MainActor
struct SelectionModelTests {
    private func asset(_ value: Int) -> AssetID { AssetID(rawValue: Int64(value)) }

    @Test("Selecting replaces, and the current item is an asset")
    func select() {
        let selection = SelectionModel()
        selection.select(3, asset: asset(30))
        selection.select(5, asset: asset(50))
        #expect(selection.rows == IndexSet(integer: 5))
        #expect(selection.currentAsset == asset(50))
    }

    @Test("Extending grows from where it started, and can shrink back")
    func extend() {
        let selection = SelectionModel()
        selection.select(5, asset: asset(5))
        selection.extend(to: 8, asset: asset(8))
        #expect(selection.rows == IndexSet(integersIn: 5...8))
        selection.extend(to: 6, asset: asset(6))
        #expect(selection.rows == IndexSet(integersIn: 5...6))
        selection.extend(to: 3, asset: asset(3))
        #expect(selection.rows == IndexSet(integersIn: 3...5))
    }

    @Test("Toggling keeps the rest, and extending after it keeps that too")
    func toggle() {
        let selection = SelectionModel()
        selection.select(1, asset: asset(1))
        selection.toggle(5, asset: asset(5))
        #expect(selection.rows == IndexSet([1, 5]))
        selection.extend(to: 7, asset: asset(7))
        #expect(selection.rows == IndexSet([1, 5, 6, 7]))
    }

    @Test("Selecting everything in a million rows is one range")
    func selectAllIsCheap() {
        let selection = SelectionModel()
        selection.selectAll(count: 1_000_000)
        #expect(selection.count == 1_000_000)
        #expect(selection.rows.rangeView.count == 1)
    }

    @Test("Selected rows follow their assets to a new order")
    func remap() {
        #expect(SelectionModel.remapped(IndexSet([0, 2]), map: [5, 3, 1]) == IndexSet([5, 1]))
        #expect(SelectionModel.remapped(IndexSet([0, 2]), map: [5, 3, -1]) == IndexSet(integer: 5))
        #expect(SelectionModel.remapped(IndexSet(integersIn: 0..<3), map: [2, 1, 0]) == IndexSet(integersIn: 0..<3))
    }
}
