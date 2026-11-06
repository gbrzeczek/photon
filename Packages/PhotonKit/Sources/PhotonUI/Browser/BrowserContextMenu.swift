import AppKit

/// The context menu grid and list share.
@MainActor
enum BrowserContextMenu {
    static func make(model: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        let rows = Array(model.selection.rows.prefix(32))
        let target = MenuTarget(model: model, rows: rows)
        let show = NSMenuItem(title: "Show in Finder", action: #selector(MenuTarget.showInFinder), keyEquivalent: "")
        show.target = target
        // The menu doesn't retain targets, so an item carries its own.
        show.representedObject = target
        menu.addItem(show)
        return menu
    }

    private final class MenuTarget: NSObject {
        let model: BrowserModel
        let rows: [Int]

        init(model: BrowserModel, rows: [Int]) {
            self.model = model
            self.rows = rows
        }

        @MainActor @objc func showInFinder() { model.showInFinder(rows: rows) }
    }
}
