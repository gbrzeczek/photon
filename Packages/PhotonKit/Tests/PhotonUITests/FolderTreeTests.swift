import Foundation
import PhotonCore
import Testing

@testable import PhotonUI

@Suite("Folder tree")
struct FolderTreeTests {
    private let volume = VolumeID(rawValue: 1)

    private func folder(_ path: String, root: Bool = false) -> BrowseFolder {
        BrowseFolder(volume: volume, path: path, isRoot: root)
    }

    @Test("Folders nest under their parents, even when a sibling sorts between them")
    func nesting() {
        // A space sorts before a slash, so `Photos 2` lands between `Photos` and `Photos/2020`.
        let tree = FolderTree.build(
            [folder("Root", root: true), folder("Root/Photos"), folder("Root/Photos 2"), folder("Root/Photos/2020")]
        ) { _ in "Volume" }
        #expect(tree.count == 1)
        #expect(tree[0].name == "Root")
        let children = tree[0].children ?? []
        #expect(children.map(\.name) == ["Photos", "Photos 2"])
        #expect(children[0].children?.map(\.name) == ["2020"])
        #expect(children[1].children == nil)
    }

    @Test("A root at the top of a volume takes the volume's name")
    func volumeRoot() {
        let tree = FolderTree.build([folder("", root: true), folder("Photos"), folder("Photos/2020")]) { _ in "T7" }
        #expect(tree[0].name == "T7")
        #expect(tree[0].children?.map(\.name) == ["Photos"])
        #expect(tree[0].children?[0].children?.map(\.name) == ["2020"])
    }

    @Test("Each root keeps its own folders")
    func twoRoots() {
        let tree = FolderTree.build(
            [folder("A", root: true), folder("A/x"), folder("B", root: true), folder("B/y")]
        ) { _ in "Volume" }
        #expect(tree.map(\.name) == ["A", "B"])
        #expect(tree[1].children?.map(\.name) == ["y"])
    }

    @Test("A large tree builds within a frame or two")
    func large() {
        var folders = [folder("Root", root: true)]
        for top in 0..<100 {
            folders.append(folder("Root/\(top)"))
            for inner in 0..<500 { folders.append(folder("Root/\(top)/\(inner)")) }
        }
        let start = ContinuousClock.now
        let tree = FolderTree.build(folders) { _ in "Volume" }
        #expect(tree[0].children?.count == 100)
        // Debug builds are slow, and this only has to rule out a quadratic pass over 50k folders.
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
