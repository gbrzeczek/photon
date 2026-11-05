import Darwin
import DiskArbitration
import Foundation

/// Where a volume physically is. `isRemovable` and `isEjectable` can't answer this, because the
/// T7 Touch reports both as false, so this comes from DiskArbitration.
public enum DriveLocation: String, Sendable, Hashable {
    case `internal`
    case external
    case diskImage
    case unknown
}

public enum MountError: Error, Equatable, Sendable {
    case pathNotFound
    /// Not backed by a disk, such as a network share or a synthetic mount.
    case noDiskIdentity
}

/// A mounted volume, read from the system. Reading one touches the disk, so never do it on the main thread.
public struct MountedVolume: Hashable, Sendable {
    public var mountPoint: String
    /// For example `disk4s1`. Only meaningful for this session.
    public var bsdName: String
    public var name: String
    /// From DiskArbitration. `URLResourceKey.volumeUUIDStringKey` isn't stable on FAT32 clones.
    public var uuid: String
    public var filesystem: String
    public var isReadOnly: Bool
    public var capacity: Int64
    public var location: DriveLocation
    var filesystemID: [Int32]

    public init(
        mountPoint: String, bsdName: String, name: String, uuid: String, filesystem: String,
        isReadOnly: Bool, capacity: Int64, location: DriveLocation
    ) {
        self.mountPoint = mountPoint
        self.bsdName = bsdName
        self.name = name
        self.uuid = uuid
        self.filesystem = filesystem
        self.isReadOnly = isReadOnly
        self.capacity = capacity
        self.location = location
        filesystemID = []
    }

    /// The volume holding `path`, and the path relative to its root.
    public static func containing(path: String) throws -> (volume: MountedVolume, relativePath: String) {
        guard let resolved = realpath(path, nil) else { throw MountError.pathNotFound }
        defer { free(resolved) }
        let absolute = String(cString: resolved)

        var info = statfs()
        guard statfs(absolute, &info) == 0 else { throw MountError.pathNotFound }
        let volume = try MountedVolume(info)
        return (volume, relative(absolute, to: volume.mountPoint))
    }

    /// The relative path of `absolute` on a volume mounted at `mountPoint`.
    static func relative(_ absolute: String, to mountPoint: String) -> String {
        if absolute == mountPoint { return "" }
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        if absolute.hasPrefix(prefix) { return String(absolute.dropFirst(prefix.count)) }
        // Firmlinks: /Users lives on the data volume at /System/Volumes/Data, and realpath keeps
        // the short form.
        return String(absolute.drop { $0 == "/" })
    }

    private init(_ info: statfs) throws {
        mountPoint = Self.string(info.f_mntonname)
        filesystem = Self.string(info.f_fstypename)
        isReadOnly = info.f_flags & UInt32(MNT_RDONLY) != 0
        capacity = Int64(info.f_blocks) &* Int64(info.f_bsize)
        filesystemID = [info.f_fsid.val.0, info.f_fsid.val.1]

        let device = Self.string(info.f_mntfromname)
        guard device.hasPrefix("/dev/") else { throw MountError.noDiskIdentity }
        bsdName = String(device.dropFirst("/dev/".count))

        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = bsdName.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
            let description = DADiskCopyDescription(disk) as? [String: Any],
            let uuidValue = description[kDADiskDescriptionVolumeUUIDKey as String],
            CFGetTypeID(uuidValue as CFTypeRef) == CFUUIDGetTypeID(),
            let uuidString = CFUUIDCreateString(kCFAllocatorDefault, (uuidValue as! CFUUID)) as String?
        else { throw MountError.noDiskIdentity }

        uuid = uuidString
        name = description[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? URL(fileURLWithPath: mountPoint).lastPathComponent
        location = Self.location(
            model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool)
    }

    static func location(model: String?, isInternal: Bool?) -> DriveLocation {
        if model?.trimmingCharacters(in: .whitespaces) == "Disk Image" { return .diskImage }
        switch isInternal {
        case true?: return .internal
        case false?: return .external
        case nil: return .unknown
        }
    }

    /// Whether this exact mount still exists. A different volume at the same path doesn't count.
    public func isStillMounted() -> Bool {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return false }
        return Self.string(info.f_mntonname) == mountPoint
            && (filesystemID.isEmpty || filesystemID == [info.f_fsid.val.0, info.f_fsid.val.1])
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The safety rule for reading real drives during development.
public enum MountPolicy {
    /// Why this volume mustn't be read, or nil if it may be. Photon never writes to a drive, but until
    /// that has been proven on real media, an external drive has to be mounted read-only, so that
    /// a bug can't damage it. Unknown drives count as external.
    public static func refusalReason(for volume: MountedVolume) -> String? {
        switch volume.location {
        case .internal, .diskImage:
            return nil
        case .external, .unknown:
            return volume.isReadOnly
                ? nil
                : "This external volume is mounted writable. Remount it read-only before indexing it."
        }
    }
}
