import AppKit
import SwiftUI

/// Holds the grid and the list. Neither is torn down when the other shows, so the grid keeps its tiles.
final class BrowserContainerView: NSView {
    let grid: TileGridView
    let list: BrowserListView

    init(model: BrowserModel) {
        grid = TileGridView(model: model)
        list = BrowserListView(model: model)
        super.init(frame: .zero)
        grid.autoresizingMask = [.width, .height]
        list.autoresizingMask = [.width, .height]
        addSubview(grid)
        addSubview(list)
        model.attach(grid: grid, list: list) { [weak self] in self?.show($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    func show(_ mode: BrowserViewMode) {
        grid.isHidden = mode != .tiles
        list.isHidden = mode != .list
    }
}

struct BrowserContentRepresentable: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> BrowserContainerView {
        let view = BrowserContainerView(model: model)
        DispatchQueue.main.async { [weak view] in
            view?.grid.focus()
        }
        PerformanceHarness.attachIfRequested(to: view, model: model)
        DevelopmentHooks.scheduleSnapshot(of: view)
        return view
    }

    func updateNSView(_ view: BrowserContainerView, context: Context) {}
}
