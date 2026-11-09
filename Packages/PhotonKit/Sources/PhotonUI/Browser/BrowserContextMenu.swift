import AppKit
import PhotonCore

/// The context menu grid, list and viewer share.
@MainActor
enum BrowserContextMenu {
    static func make(model: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rows = model.isViewerOpen ? model.viewerRow.map { [$0] } ?? [] : Array(model.selection.rows.prefix(32))
        let target = MenuTarget(model: model, rows: rows)
        // The menu doesn't retain targets, so each item carries its own.
        func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = enabled
            return item
        }
        let hasItems = model.hasActionItems

        menu.addItem(item("Copy", #selector(MenuTarget.copyFiles)))
        menu.addItem(item("Show in Finder", #selector(MenuTarget.showInFinder), enabled: model.scopeAccess != .offline))
        menu.addItem(.separator())

        let favorite = item(
            model.actionItemsAreFavorites ? "Unfavorite" : "Favorite", #selector(MenuTarget.toggleFavorite),
            enabled: hasItems)
        favorite.keyEquivalent = "."
        favorite.keyEquivalentModifierMask = []
        menu.addItem(favorite)

        let albums = NSMenu()
        for album in model.library.albums where !album.isSmart {
            let entry = item(album.name, #selector(MenuTarget.addToAlbum(_:)))
            entry.tag = Int(album.id.rawValue)
            albums.addItem(entry)
        }
        if !albums.items.isEmpty { albums.addItem(.separator()) }
        albums.addItem(item("New Album…", #selector(MenuTarget.newAlbum)))
        let addToAlbum = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        addToAlbum.submenu = albums
        addToAlbum.isEnabled = hasItems
        menu.addItem(addToAlbum)

        if let album = model.currentManualAlbum {
            let remove = item("Remove from “\(album.name)”", #selector(MenuTarget.removeFromAlbum), enabled: hasItems)
            remove.keyEquivalent = "\u{8}"
            remove.keyEquivalentModifierMask = []
            menu.addItem(remove)
        }

        let tags = NSMenu()
        var tagItems: [TagID: NSMenuItem] = [:]
        for tag in model.library.tags {
            let entry = item(tag.name, #selector(MenuTarget.toggleTag(_:)))
            entry.tag = Int(tag.id.rawValue)
            tags.addItem(entry)
            tagItems[tag.id] = entry
        }
        if !tags.items.isEmpty { tags.addItem(.separator()) }
        tags.addItem(item("New Tag…", #selector(MenuTarget.newTag)))
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = tags
        tagsItem.isEnabled = hasItems
        menu.addItem(tagsItem)
        // Check marks come from the library, off the main thread, and land while the menu is open.
        if !tagItems.isEmpty {
            Task {
                let (counts, total) = await model.actionTagCounts()
                for (tag, entry) in tagItems {
                    let count = counts[tag, default: 0]
                    entry.state = count == 0 ? .off : count == total ? .on : .mixed
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("More Info", #selector(MenuTarget.moreInfo), enabled: hasItems))
        return menu
    }

    private final class MenuTarget: NSObject {
        let model: BrowserModel
        let rows: [Int]

        init(model: BrowserModel, rows: [Int]) {
            self.model = model
            self.rows = rows
        }

        @MainActor @objc func copyFiles() { model.copy() }
        @MainActor @objc func showInFinder() { model.showInFinder(rows: rows) }
        @MainActor @objc func toggleFavorite() { model.toggleFavorite() }
        @MainActor @objc func addToAlbum(_ sender: NSMenuItem) { model.addToAlbum(AlbumID(rawValue: Int64(sender.tag))) }
        @MainActor @objc func removeFromAlbum() { model.removeFromAlbum() }
        @MainActor @objc func toggleTag(_ sender: NSMenuItem) { model.toggleTag(TagID(rawValue: Int64(sender.tag))) }

        @MainActor @objc func newAlbum() {
            if let name = NamePrompt.ask("New Album", message: "Add the selected items to a new album.", initial: "Untitled Album") {
                model.newAlbum(named: name, addingItems: true)
            }
        }

        @MainActor @objc func newTag() {
            if let name = NamePrompt.ask("New Tag", message: "Tag the selected items.", initial: "") {
                model.addTag(named: name)
            }
        }

        @MainActor @objc func moreInfo() {
            if !model.isInspectorShown { model.toggleInspector() }
        }
    }
}

/// Asks for a name, for albums and tags. A sheet would be nicer, but this is shared by AppKit menus and
/// SwiftUI rows alike, and it's rare.
@MainActor
enum NamePrompt {
    static func ask(_ title: String, message: String, initial: String, action: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityIdentifier("photon.name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Confirms something that can't be undone, such as deleting an album.
    static func confirm(_ title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
