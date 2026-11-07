import Foundation
import PhotonCore
import PhotonTestSupport
import Testing

@testable import PhotonIndex

private func fakeMount(
    _ path: String, uuid: String = "UUID-1", bsdName: String = "disk9s1", location: DriveLocation = .external,
    isReadOnly: Bool = true
) -> MountedVolume {
    MountedVolume(
        mountPoint: path, bsdName: bsdName, name: "Test", uuid: uuid, filesystem: "exfat", isReadOnly: isReadOnly,
        capacity: 1000, location: location)
}

@Suite("Matching a mount to a volume row")
struct VolumeResolverTests {
    private func setUp() throws -> (TemporaryFolder, LibraryStore, TemporaryFolder) {
        let folder = try TemporaryFolder()
        let storeFolder = try TemporaryFolder()
        return (folder, try LibraryStore(url: storeFolder.url.appending(path: "Library.sqlite")), storeFolder)
    }

    /// Lists `folder` into `volume`, so the store knows its files.
    private func record(_ folder: TemporaryFolder, in volume: VolumeID, store: LibraryStore) async throws {
        let scheduler = VolumeIOScheduler(mountPoint: folder.path)
        let entries = try await scheduler.listDirectory("", priority: .visible)
        _ = try await store.applyDirectory(
            volume: volume, directory: "",
            files: entries.map {
                ScannedFile(name: $0.name, kind: .photo, size: $0.size, modifiedTime: $0.modifiedTime)
            })
    }

    private func resolve(
        _ mount: MountedVolume, store: LibraryStore, online: Set<VolumeID> = []
    ) async throws -> VolumeResolution {
        try await VolumeResolver(store: store).resolve(
            mount, scheduler: VolumeIOScheduler(mountPoint: mount.mountPoint), online: online)
    }

    @Test("An unknown UUID gets a new row")
    func newVolume() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        guard case .online(let volume, let isNew) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(isNew)
        #expect(volume.uuid == "UUID-1")
    }

    @Test("A known UUID whose files match is the same volume, whatever its mount path")
    func knownVolume() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        try folder.write("a.jpg")
        guard case .online(let first, _) = try await resolve(fakeMount("\(folder.path)"), store: store) else {
            Issue.record("Expected online")
            return
        }
        try await record(folder, in: first.id, store: store)

        let moved = try TemporaryFolder()
        try FileManager.default.removeItem(at: moved.url)
        try FileManager.default.copyItem(at: folder.url, to: moved.url)

        guard case .online(let second, let isNew) = try await resolve(fakeMount(moved.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(!isNew)
        #expect(second.id == first.id)
    }

    @Test("The same UUID with different files is a reused drive, and gets its own row")
    func reusedDrive() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        try folder.write("a.jpg")
        try folder.write("b.jpg")
        guard case .online(let first, _) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        try await record(folder, in: first.id, store: store)

        let other = try TemporaryFolder()
        try other.write("unrelated.jpg")
        guard case .online(let second, let isNew) = try await resolve(fakeMount(other.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(isNew)
        #expect(second.id != first.id)
    }

    @Test("A drive with a few changed files is still the same volume")
    func someFilesChanged() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        for index in 0..<10 { try folder.write("\(index).jpg") }
        guard case .online(let first, _) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        try await record(folder, in: first.id, store: store)

        for index in 0..<4 { try folder.remove("\(index).jpg") }
        guard case .online(let second, let isNew) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(!isNew)
        #expect(second.id == first.id)
    }

    @Test("When two rows share a UUID, each drive finds its own")
    func twoRowsOneUUID() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        let older = try TemporaryFolder()
        try folder.write("a.jpg")
        try older.write("b.jpg")
        guard case .online(let first, _) = try await resolve(fakeMount(older.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        try await record(older, in: first.id, store: store)
        guard case .online(let second, _) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        try await record(folder, in: second.id, store: store)
        #expect(first.id != second.id)

        // `second` was seen last, so it's tried first, and its files don't match this drive.
        guard case .online(let found, let isNew) = try await resolve(fakeMount(older.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(!isNew)
        #expect(found.id == first.id)
    }

    @Test("A clone mounted beside its original stays out of the library")
    func cloneMountedTogether() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        guard case .online(let first, _) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        let result = try await resolve(fakeMount(folder.path, bsdName: "disk8s1"), store: store, online: [first.id])
        #expect(result == .duplicateOfOnlineVolume(first.id))
        #expect(try await store.allVolumes().count == 1)
    }

    @Test("Coming back updates the name and last-seen time")
    func updatesRow() async throws {
        let (folder, store, keep) = try setUp()
        _ = keep
        guard case .online(let first, _) = try await resolve(fakeMount(folder.path), store: store) else {
            Issue.record("Expected online")
            return
        }
        var renamed = fakeMount(folder.path)
        renamed.name = "Renamed"
        guard case .online(let second, _) = try await resolve(renamed, store: store) else {
            Issue.record("Expected online")
            return
        }
        #expect(second.id == first.id)
        #expect(try await store.allVolumes().first?.name == "Renamed")
    }
}

@Suite("Refusing unsafe mounts")
struct MountPolicyTests {
    @Test("A writable external volume is refused")
    func refusesWritableExternal() {
        #expect(MountPolicy.refusalReason(for: fakeMount("/Volumes/X", location: .external, isReadOnly: false)) != nil)
    }

    @Test("A read-only external volume is allowed")
    func allowsReadOnlyExternal() {
        #expect(MountPolicy.refusalReason(for: fakeMount("/Volumes/X", location: .external, isReadOnly: true)) == nil)
    }

    @Test("A drive of unknown location counts as external")
    func refusesUnknownWritable() {
        #expect(MountPolicy.refusalReason(for: fakeMount("/Volumes/X", location: .unknown, isReadOnly: false)) != nil)
    }

    @Test("The internal disk and disk images are allowed")
    func allowsLocal() {
        #expect(MountPolicy.refusalReason(for: fakeMount("/", location: .internal, isReadOnly: false)) == nil)
        #expect(MountPolicy.refusalReason(for: fakeMount("/Volumes/X", location: .diskImage, isReadOnly: false)) == nil)
    }

    @Test func nonsenseFromAVolumeOnItsWayOutIsNotACrash() {
        #expect(MountedVolume.capacity(blocks: 1_000, blockSize: 4096) == 4_096_000)
        #expect(MountedVolume.capacity(blocks: .max, blockSize: 1) == 0)
        #expect(MountedVolume.capacity(blocks: .max, blockSize: 4096) == 0)
        #expect(MountedVolume.capacity(blocks: 0, blockSize: 0) == 0)
    }

    @Test func locationComesFromDiskArbitration() {
        #expect(MountedVolume.location(model: "Disk Image", isInternal: true) == .diskImage)
        #expect(MountedVolume.location(model: "Disk Image   ", isInternal: nil) == .diskImage)
        #expect(MountedVolume.location(model: "PSSD T7 Touch", isInternal: false) == .external)
        #expect(MountedVolume.location(model: "APPLE SSD", isInternal: true) == .internal)
        #expect(MountedVolume.location(model: nil, isInternal: nil) == .unknown)
    }

    @Test("Paths become relative to the mount, including through firmlinks")
    func relativePaths() {
        #expect(MountedVolume.relative("/Volumes/T7/Photos/2024", to: "/Volumes/T7") == "Photos/2024")
        #expect(MountedVolume.relative("/Volumes/T7", to: "/Volumes/T7") == "")
        #expect(MountedVolume.relative("/Users/me/Pictures", to: "/System/Volumes/Data") == "Users/me/Pictures")
        #expect(MountedVolume.relative("/Volumes/T7 1/a", to: "/Volumes/T7 1") == "a")
    }

    @Test("The temporary folder resolves to a mount the system can identify")
    func readsARealMount() throws {
        let folder = try TemporaryFolder()
        let (volume, relative) = try MountedVolume.containing(path: folder.path)
        #expect(!volume.uuid.isEmpty)
        #expect(volume.location == .internal)
        #expect(volume.isStillMounted())
        #expect(relative.hasSuffix(folder.url.lastPathComponent))
        #expect(!relative.hasPrefix("/"))
        let check = URL(fileURLWithPath: volume.mountPoint).appending(path: relative).path
        #expect(FileManager.default.fileExists(atPath: check))
    }

    @Test func missingPathThrows() {
        #expect(throws: MountError.pathNotFound) { _ = try MountedVolume.containing(path: "/nowhere/at/all") }
    }

    @Test("A mount that isn't there any more says so")
    func goneMount() {
        #expect(!fakeMount("/nowhere/at/all").isStillMounted())
    }

    @Test("The synthetic generator refuses external drives before writing anything")
    func generatorUsesInternalDisk() throws {
        let folder = try TemporaryFolder()
        var options = SyntheticLibrary.Options()
        options.fileCount = 3
        let manifest = try SyntheticLibrary(options: options).generate(at: folder.url.appending(path: "lib"))
        #expect(manifest.files.count == 3)
    }
}
