import PhotonCore
import SwiftUI

/// The library's own rows, albums, tags and folders, from the top, as in Photos and Finder.
struct LibrarySidebar: View {
    let library: BrowserLibrary
    let model: BrowserModel
    let editSmartAlbum: (Album?) -> Void

    private var roots: [FolderNode] {
        FolderTree.build(library.folders) { root in
            library.volumes.first { $0.volume.id == root.volume }?.volume.name ?? "Volume"
        }
    }

    var body: some View {
        let selection = Binding<BrowseSource?>(get: { model.source }, set: { if let source = $0 { model.open(source) } })
        List(selection: selection) {
            Section("Library") {
                Label("All Items", systemImage: "photo.on.rectangle").tag(BrowseSource.allItems)
                Label("Favorites", systemImage: "heart").tag(BrowseSource.favorites)
            }
            Section("Albums") {
                ForEach(library.albums) { album in
                    Label(album.name, systemImage: album.isSmart ? "gearshape" : "rectangle.stack")
                        .tag(BrowseSource.album(album.id))
                        .contextMenu { albumMenu(album) }
                }
                if library.albums.isEmpty {
                    Text("No Albums").foregroundStyle(.tertiary).selectionDisabled()
                }
            }
            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(BrowseSource.tag(tag.id))
                            .contextMenu { tagMenu(tag) }
                    }
                }
            }
            Section("Folders") {
                OutlineGroup(roots, children: \.children) { node in
                    row(node)
                        .tag(BrowseSource.folder(node.scope))
                        .foregroundStyle(isOnline(node) ? .primary : .secondary)
                        .contextMenu {
                            if canEject(node) { Button(ejectTitle(node)) { library.eject(node.scope.volume) } }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("photon.sidebar")
    }

    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        if album.isSmart {
            Button("Edit Smart Album…") { editSmartAlbum(album) }.disabled(!album.isReadable)
        }
        Button("Rename Album…") {
            if let name = NamePrompt.ask("Rename Album", message: "", initial: album.name, action: "Rename") {
                model.renameAlbum(album.id, to: name)
            }
        }
        Divider()
        Button("Delete Album…", role: .destructive) {
            let detail = album.isSmart
                ? "The photos and videos it finds stay in the library."
                : "The photos and videos in it stay in the library and on their drives."
            if NamePrompt.confirm("Delete “\(album.name)”?", message: detail, action: "Delete") {
                model.deleteAlbum(album.id)
            }
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        Button("Rename Tag…") {
            if let name = NamePrompt.ask("Rename Tag", message: "", initial: tag.name, action: "Rename") {
                model.renameTag(tag.id, to: name)
            }
        }
        Divider()
        Button("Delete Tag…", role: .destructive) {
            if NamePrompt.confirm(
                "Delete the tag “\(tag.name)”?", message: "It's removed from every item. No file changes.",
                action: "Delete")
            {
                model.deleteTag(tag.id)
            }
        }
    }

    private func row(_ node: FolderNode) -> some View {
        HStack {
            Label(node.name, systemImage: isOnline(node) ? "folder" : "externaldrive.badge.xmark")
            Spacer()
            if canEject(node) {
                Button(ejectTitle(node), systemImage: "eject.fill") { library.eject(node.scope.volume) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(ejectTitle(node))
            }
        }
    }

    private func isOnline(_ node: FolderNode) -> Bool { library.onlineVolumes.contains(node.scope.volume) }

    private func canEject(_ node: FolderNode) -> Bool {
        node.isRoot && library.ejectableVolumes.contains(node.scope.volume)
    }

    private func ejectTitle(_ node: FolderNode) -> String { "Eject “\(library.name(of: node.scope.volume))”" }
}
