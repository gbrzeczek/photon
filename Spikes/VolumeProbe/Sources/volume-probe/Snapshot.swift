import DiskArbitration
import Foundation
import IOKit

/// Everything about a volume and a sample of its files that could serve as identity.
/// Snapshots only use stat-level calls, so they don't touch file contents or access times.
struct Snapshot: Codable {
    struct Volume: Codable {
        var mountPath: String
        var fsType: String
        var name: String?
        var urlVolumeUUID: String?
        var daVolumeUUID: String?
        var daMediaUUID: String?
        var bsdName: String?
        var deviceProtocol: String?
        var deviceModel: String?
        var mediumType: String?
        var isReadOnly: Bool?
        var isRemovable: Bool?
        var isEjectable: Bool?
        var isInternal: Bool?
        var supportsPersistentIDs: Bool?
        var totalCapacity: Int?
    }
    struct File: Codable {
        var path: String
        var size: Int64
        var mtime: Double
        var fileID: UInt64
    }
    var takenAt: Date
    var volume: Volume
    var fileCount: Int
    var files: [File]
}

func readVolume(_ mount: String) throws -> Snapshot.Volume {
    let url = URL(fileURLWithPath: mount, isDirectory: true)
    let keys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeIsReadOnlyKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsInternalKey, .volumeSupportsPersistentIDsKey,
        .volumeTotalCapacityKey,
    ]
    let v = try url.resourceValues(forKeys: keys)
    var st = statfs()
    guard statfs(mount, &st) == 0 else { throw posix("statfs") }
    let fsType = withUnsafeBytes(of: &st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }

    var out = Snapshot.Volume(
        mountPath: mount, fsType: fsType, name: v.volumeName, urlVolumeUUID: v.volumeUUIDString,
        isReadOnly: v.volumeIsReadOnly, isRemovable: v.volumeIsRemovable, isEjectable: v.volumeIsEjectable,
        isInternal: v.volumeIsInternal, supportsPersistentIDs: v.volumeSupportsPersistentIDs,
        totalCapacity: v.volumeTotalCapacity)

    if let session = DASessionCreate(kCFAllocatorDefault),
        let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
        let d = DADiskCopyDescription(disk) as? [String: Any]
    {
        func uuid(_ key: CFString) -> String? {
            guard let raw = d[key as String] else { return nil }
            return CFUUIDCreateString(nil, (raw as! CFUUID)) as String
        }
        out.daVolumeUUID = uuid(kDADiskDescriptionVolumeUUIDKey)
        out.daMediaUUID = uuid(kDADiskDescriptionMediaUUIDKey)
        out.bsdName = d[kDADiskDescriptionMediaBSDNameKey as String] as? String
        out.deviceProtocol = d[kDADiskDescriptionDeviceProtocolKey as String] as? String
        out.deviceModel = d[kDADiskDescriptionDeviceModelKey as String] as? String
        if let bsd = out.bsdName { out.mediumType = mediumType(bsdName: bsd) }
    }
    return out
}

/// Walks up the IORegistry from a BSD disk to the storage device. Photon needs this to pick
/// a hard drive or a flash I/O policy, and USB bridges don't always report it.
func mediumType(bsdName: String) -> String? {
    guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let found = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    return (found as? [String: Any])?["Medium Type"] as? String
}

/// `folders` limits the walk to top-level folders, so unrelated data on a drive is never listed.
func takeSnapshot(mount: String, sample: Int, folders: [String]) throws -> Snapshot {
    let volume = try readVolume(mount)
    var files: [Snapshot.File] = []
    var count = 0
    for folder in folders.isEmpty ? [""] : folders {
      let root = URL(fileURLWithPath: mount, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
      while let item = walker?.nextObject() as? URL {
        var st = stat()
        guard lstat(item.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
        count += 1
        // Reservoir sample, so that the sample doesn't favour the start of the walk.
        let entry = Snapshot.File(
            path: String(item.path.dropFirst(mount.count)).trimmingCharacters(in: ["/"]),
            size: st.st_size,
            mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
            fileID: UInt64(st.st_ino))
        if files.count < sample {
            files.append(entry)
        } else if Int.random(in: 0..<count) < sample {
            files[Int.random(in: 0..<sample)] = entry
        }
      }
    }
    files.sort { $0.path < $1.path }
    return Snapshot(takenAt: Date(), volume: volume, fileCount: count, files: files)
}

func posix(_ what: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
}

/// Compares two snapshots and prints a one-line verdict per identity signal.
func compare(_ a: Snapshot, _ b: Snapshot) {
    func same<T: Equatable>(_ label: String, _ x: T?, _ y: T?) {
        print("\(label): \(x == y ? "same" : "CHANGED") (\(x.map { "\($0)" } ?? "nil") -> \(y.map { "\($0)" } ?? "nil"))")
    }
    same("urlVolumeUUID", a.volume.urlVolumeUUID, b.volume.urlVolumeUUID)
    same("daVolumeUUID", a.volume.daVolumeUUID, b.volume.daVolumeUUID)
    same("daMediaUUID", a.volume.daMediaUUID, b.volume.daMediaUUID)
    same("mountPath", a.volume.mountPath, b.volume.mountPath)
    same("bsdName", a.volume.bsdName, b.volume.bsdName)

    let before = Dictionary(uniqueKeysWithValues: a.files.map { ($0.path, $0) })
    var sameID = 0, changedID = 0, sameStat = 0, changedStat = 0, missing = 0
    var examples: [String] = []
    for file in b.files {
        guard let old = before[file.path] else { missing += 1; continue }
        if old.fileID == file.fileID { sameID += 1 } else {
            changedID += 1
            if examples.count < 5 { examples.append("\(file.path): id \(old.fileID) -> \(file.fileID)") }
        }
        if old.size == file.size && old.mtime == file.mtime { sameStat += 1 } else { changedStat += 1 }
    }
    let idsBefore = Dictionary(grouping: a.files, by: \.fileID)
    let reused = b.files.compactMap { f in idsBefore[f.fileID]?.first { $0.path != f.path }.map { "\($0.path) id reused by or moved to \(f.path)" } }
    print("files by path: \(sameID) same ID, \(changedID) changed ID, \(missing) not in first snapshot")
    print("files by path: \(sameStat) same size+mtime, \(changedStat) changed")
    examples.forEach { print("  \($0)") }
    reused.prefix(5).forEach { print("  \($0)") }
}
