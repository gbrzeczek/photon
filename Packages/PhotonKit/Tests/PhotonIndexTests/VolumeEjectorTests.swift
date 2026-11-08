import Foundation
import Synchronization
import Testing

@testable import PhotonIndex

private func mount(
    _ path: String, location: DriveLocation, bsdName: String = "disk9s1", uuid: String = "UUID"
) -> MountedVolume {
    MountedVolume(
        mountPoint: path, bsdName: bsdName, name: "Test", uuid: uuid, filesystem: "exfat", isReadOnly: true,
        capacity: 1000, location: location)
}

private final class Calls: Sendable {
    private let urls = Mutex<[URL]>([])
    var count: Int { urls.withLock { $0.count } }
    func record(_ url: URL) { urls.withLock { $0.append(url) } }
}

/// Nothing here can eject anything: `perform` only records, and every test checks that it wasn't reached.
/// Ejecting for real is tested on disk images only, in `RemovableMediaTests`.
@Suite("Eject can't reach a real drive")
struct VolumeEjectorTests {
    @Test("The default is disk images only")
    func defaultScope() {
        #expect(VolumeEjector().scope == .diskImagesOnly)
    }

    @Test("Disk images only refuses everything else", arguments: [DriveLocation.external, .unknown, .internal])
    func refusesOtherLocations(location: DriveLocation) async {
        let calls = Calls()
        let ejector = VolumeEjector(scope: .diskImagesOnly, perform: { calls.record($0) })
        let volume = mount("/Volumes/Anything", location: location)
        #expect(ejector.refusal(for: volume) != nil)
        await #expect(throws: EjectError.self) { try await ejector.eject(volume) }
        #expect(calls.count == 0)
    }

    @Test("The internal disk is refused in every scope")
    func refusesInternal() {
        for scope in [EjectScope.diskImagesOnly, .anyExternalVolume] {
            #expect(VolumeEjector(scope: scope).refusal(for: mount("/Users", location: .internal)) != nil)
        }
    }

    @Test("A real run's scope covers external and unknown drives")
    func anyExternal() {
        let ejector = VolumeEjector(scope: .anyExternalVolume)
        #expect(ejector.canEject(mount("/Volumes/A", location: .external)))
        #expect(ejector.canEject(mount("/Volumes/A", location: .unknown)))
        #expect(ejector.canEject(mount("/Volumes/A", location: .diskImage)))
    }

    @Test("A value claiming to be a disk image is checked against the system, for every real mount")
    func forgedLocation() async throws {
        let calls = Calls()
        let ejector = VolumeEjector(scope: .diskImagesOnly, perform: { calls.record($0) })
        let real = MountedVolume.all().filter { $0.location != .diskImage }
        #expect(!real.isEmpty)
        for volume in real {
            var forged = volume
            forged.location = .diskImage
            #expect(ejector.refusal(for: forged) == nil || volume.mountPoint == "/")
            await #expect(throws: EjectError.self) { try await ejector.eject(forged) }
        }
        #expect(calls.count == 0)
    }

    @Test("A mount that has changed since it was read is refused")
    func staleValue() async {
        let calls = Calls()
        let ejector = VolumeEjector(scope: .anyExternalVolume, perform: { calls.record($0) })
        await #expect(throws: EjectError.notConnected) {
            try await ejector.eject(mount("/Volumes/NotMounted-\(UUID().uuidString)", location: .external))
        }
        #expect(calls.count == 0)
    }

    @Test("The whole disk's name comes from the BSD name", arguments: [
        ("disk4s1", "disk4"), ("disk12s3", "disk12"), ("disk3s1s1", "disk3"), ("disk7", "disk7"),
    ])
    func wholeDisk(name: String, expected: String) {
        #expect(mount("/x", location: .external, bsdName: name).wholeDiskName == expected)
    }

    @Test("An indexer won't eject a volume it hasn't connected")
    func indexerNeedsAConnection() async throws {
        let folder = try TemporaryFolder()
        let store = try LibraryStoreFixture.make(in: folder)
        let indexer = LibraryIndexer(store: store, extractor: StubExtractor())
        await #expect(throws: EjectError.notConnected) {
            try await indexer.eject(.init(rawValue: 1), using: VolumeEjector())
        }
    }
}

@Suite("Volume access")
struct VolumeAccessTests {
    @Test("Only a writable volume can change files")
    func modify() {
        #expect(VolumeAccess.writable.canModifyFiles)
        #expect(!VolumeAccess.readOnly.canModifyFiles)
        #expect(!VolumeAccess.offline.canModifyFiles)
    }

    @Test("A volume that isn't connected is offline")
    func offline() throws {
        let folder = try TemporaryFolder()
        let indexer = LibraryIndexer(store: try LibraryStoreFixture.make(in: folder), extractor: StubExtractor())
        #expect(indexer.access(to: .init(rawValue: 1)) == .offline)
        #expect(indexer.mount(of: .init(rawValue: 1)) == nil)
    }
}
