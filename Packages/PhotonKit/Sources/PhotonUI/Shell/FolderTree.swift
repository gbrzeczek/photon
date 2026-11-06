import PhotonCore

/// One folder in the sidebar.
struct FolderNode: Identifiable, Hashable {
    var scope: BrowseScope
    var name: String
    var children: [FolderNode]?
    var id: BrowseScope { scope }
}

enum FolderTree {
    /// Library roots with their folders below them. `folders` lists each root followed by its folders.
    /// This runs in a view body, so the cost stays linear in the folders. A drive can hold many thousands.
    static func build(_ folders: [BrowseFolder], rootName: (BrowseFolder) -> String) -> [FolderNode] {
        var groups: [(root: BrowseFolder, members: [BrowseFolder])] = []
        for folder in folders {
            if folder.isRoot {
                groups.append((folder, []))
            } else if !groups.isEmpty {
                groups[groups.count - 1].members.append(folder)
            }
        }
        return groups.map { root, members in
            var byParent: [String: [BrowseFolder]] = [:]
            for folder in members {
                let parent = folder.path.lastIndex(of: "/").map { String(folder.path[..<$0]) } ?? ""
                byParent[parent, default: []].append(folder)
            }
            return FolderNode(
                scope: BrowseScope(volume: root.volume, path: root.path),
                name: root.path.split(separator: "/").last.map(String.init) ?? rootName(root),
                children: nodes(under: root.path, byParent: byParent))
        }
    }

    private static func nodes(under parent: String, byParent: [String: [BrowseFolder]]) -> [FolderNode]? {
        guard let direct = byParent[parent] else { return nil }
        return direct.map { folder in
            FolderNode(
                scope: BrowseScope(volume: folder.volume, path: folder.path),
                name: folder.path.split(separator: "/").last.map(String.init) ?? folder.path,
                children: nodes(under: folder.path, byParent: byParent))
        }
    }
}
