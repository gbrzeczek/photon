import SwiftUI

/// Every shortcut, for Help → Keyboard Shortcuts. Each row's context and keys are written exactly as in
/// the table in docs/PLAN.md, and a test checks the two match, so neither can drift.
enum ShortcutTable {
    struct Row: Hashable, Identifiable {
        /// As in the plan's table.
        let context: String
        /// As in the plan's table, such as "Cmd-Equals, Cmd-Minus".
        let keys: String
        /// What the window says it does.
        let action: String
        /// Rows whose action isn't built stay in the plan, and out of the window.
        var isBuilt = true

        var id: String { context + "|" + keys }
    }

    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    static let rows: [Row] = [
        Row(context: "Grid and list", keys: "Arrow keys", action: "Move the current item"),
        Row(context: "Grid and list", keys: "Shift-arrow keys", action: "Extend the selection"),
        Row(context: "Grid and list", keys: "Home, End", action: "Go to the first or last item"),
        Row(context: "Grid and list", keys: "Page Up, Page Down", action: "Move by one screen"),
        Row(context: "Grid and list", keys: "Cmd-A, Cmd-Shift-A", action: "Select all, select none"),
        Row(context: "Grid and list", keys: "Space, Return, Cmd-Down", action: "Open in the viewer"),
        Row(context: "Grid and list", keys: "Cmd-Up", action: "Go to the enclosing folder"),
        Row(context: "Grid and list", keys: "Type a name", action: "Jump to a matching file name, in the list"),
        Row(context: "Grid", keys: "Cmd-Equals, Cmd-Minus", action: "Larger or smaller tiles"),
        Row(context: "Grid, list and viewer", keys: "Period", action: "Favorite or unfavorite"),
        Row(context: "Grid and list", keys: "Delete", action: "Remove from the album, in a manual album"),
        Row(context: "Everywhere", keys: "Cmd-1, Cmd-2", action: "Show as tiles, show as a list"),
        Row(context: "Everywhere", keys: "Cmd-C", action: "Copy"),
        Row(context: "Everywhere", keys: "Cmd-E", action: "Eject the drive holding this folder"),
        Row(context: "Everywhere", keys: "Cmd-I", action: "Show or hide the inspector"),
        Row(context: "Everywhere", keys: "Cmd-F", action: "Search"),
        Row(context: "Everywhere", keys: "Cmd-N, Cmd-Option-N", action: "New album, new smart album"),
        Row(context: "Everywhere", keys: "Cmd-R, Cmd-Option-R", action: "Rotate right, rotate left"),
        Row(context: "Everywhere", keys: "Cmd-Shift-R", action: "Rename", isBuilt: false),
        Row(context: "Everywhere", keys: "Cmd-Delete", action: "Move to Trash", isBuilt: false),
        Row(context: "Everywhere", keys: "Ctrl-Cmd-S", action: "Show or hide the sidebar"),
        Row(context: "Everywhere", keys: "Ctrl-Cmd-F", action: "Enter or leave full screen"),
        Row(context: "Viewer", keys: "Left, Right", action: "Previous or next item, or pan when zoomed in"),
        Row(context: "Viewer", keys: "Up, Down", action: "Pan when zoomed in"),
        Row(context: "Viewer", keys: "Home, End", action: "Go to the first or last item"),
        Row(context: "Viewer", keys: "Escape, Space, Cmd-Up", action: "Close the viewer"),
        Row(context: "Viewer", keys: "Cmd-Equals, Cmd-Minus, Cmd-0", action: "Zoom in, zoom out, zoom to fit"),
        Row(context: "Video", keys: "Space", action: "Play or pause"),
        Row(context: "Video", keys: "J, K, L", action: "Play backward, pause, play forward, faster with each press"),
        Row(context: "Video", keys: "Shift-Left, Shift-Right", action: "Skip back or forward 5 seconds"),
        Row(context: "Video", keys: "Option-Left, Option-Right", action: "Step one frame"),
        Row(context: "Video", keys: "M", action: "Mute or unmute"),
        Row(context: "Video", keys: "`[`, `]`, `=`", action: "Slower, faster, normal speed"),
    ]

    /// The window's sections, in the order someone meets them.
    static var sections: [Section] {
        let groups: [(String, Set<String>)] = [
            ("Browsing", ["Grid and list", "Grid", "Grid, list and viewer"]),
            ("Everywhere", ["Everywhere"]),
            ("Viewer", ["Viewer"]),
            ("Videos", ["Video"]),
        ]
        return groups.map { title, contexts in
            Section(title: title, rows: rows.filter { $0.isBuilt && contexts.contains($0.context) })
        }
    }

    /// The plan's spelling of keys, as the symbols macOS menus use: "Cmd-Shift-A" is "⇧⌘A". Alternatives
    /// stay separated by commas.
    static func symbols(_ keys: String) -> String {
        keys.replacingOccurrences(of: "`", with: "")
            .components(separatedBy: ", ")
            .map(symbolsForOne)
            .joined(separator: ", ")
    }

    private static let modifiers: [(String, String)] = [("Ctrl", "⌃"), ("Option", "⌥"), ("Shift", "⇧"), ("Cmd", "⌘")]
    private static let keyNames: [String: String] = [
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Equals": "=", "Minus": "−", "Delete": "⌫",
        "Return": "↩", "Escape": "esc", "Space": "Space", "Page Up": "Page Up", "Page Down": "Page Down",
        "Home": "Home", "End": "End", "Period": ".", "arrow keys": "Arrow Keys", "Arrow keys": "Arrow Keys",
    ]

    private static func symbolsForOne(_ combination: String) -> String {
        var parts = combination.components(separatedBy: "-")
        let key = parts.removeLast()
        let held = Set(parts)
        // Only a run of modifier names is a combination. Anything else, such as "Type a name", is text.
        guard held.allSatisfy({ name in modifiers.contains { $0.0 == name } }) else { return combination }
        let prefix = modifiers.filter { held.contains($0.0) }.map(\.1).joined()
        let name = keyNames[key] ?? key
        return prefix.isEmpty || name.count == 1 ? prefix + name : prefix + " " + name
    }
}

/// Help → Keyboard Shortcuts: every shortcut, grouped by where it works.
public struct KeyboardShortcutsView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ShortcutTable.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(section.rows) { row in
                                GridRow {
                                    Text(ShortcutTable.symbols(row.keys))
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                        .frame(minWidth: 170, alignment: .trailing)
                                    Text(row.action)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                Text("Grid, list and viewer also take a pinch, a scroll with Command or Option held to zoom, and a double click to open or zoom.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photon.shortcuts")
    }
}
