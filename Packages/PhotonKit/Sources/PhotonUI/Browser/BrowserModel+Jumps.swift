import CoreGraphics
import PhotonCore

/// Where a jump left from: the tile that was on screen, where it was, and the current item. Held by
/// asset, so that it survives reloads and re-sorts.
struct BackPlace: Equatable {
    var anchor: AssetID
    var screenY: CGFloat
    var current: AssetID?
}

/// Scrolling to the top or bottom, and Back after a jump. Home and End move the current item there,
/// and the jump buttons only scroll. Either one can be undone once, by Back.
extension BrowserModel {
    /// The jump buttons over the grid and list.
    func scrollToEdge(bottom: Bool) {
        guard result.count > 0 else { return }
        rememberPlace()
        active?.scrollToEdge(bottom: bottom)
    }

    /// Notes where the view is now, before a jump.
    func rememberPlace() {
        guard let anchor = active?.captureAnchor(), anchor.row < result.count else { return }
        backPlace = BackPlace(
            anchor: AssetID(rawValue: result.assetIDs[anchor.row]), screenY: anchor.screenY,
            current: selection.currentAsset)
    }

    var canGoBack: Bool { backPlace != nil }

    /// Returns to where the last jump left from, once. Assets that have gone since are skipped: with no
    /// anchor left, nothing moves.
    func goBack() {
        guard let place = backPlace else { return }
        backPlace = nil
        // Once per click, never per frame, so a scan of the rows is fine.
        let ids = result.assetIDs
        guard let row = ids.firstIndex(of: place.anchor.rawValue) else { return }
        if let current = place.current, current != selection.currentAsset,
            let currentRow = ids.firstIndex(of: current.rawValue)
        {
            select(row: currentRow)
        }
        active?.scroll(to: ViewAnchor(row: row, screenY: place.screenY))
    }

    /// Back goes stale after a while, or once the view is scrolled by hand.
    func forgetPlace() { backPlace = nil }
}
