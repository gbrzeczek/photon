import Darwin
import Foundation
import PhotonCore

/// One entry from a directory listing.
public struct DirectoryEntry: Hashable, Sendable {
    public enum Kind: Sendable { case file, directory, other }
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modifiedTime: FileTimestamp
}

/// Lists directories with `getattrlistbulk`, which took 1.1 s per 100k files on the T7 Touch against
/// 8.0 s for `FileManager`.
///
/// File IDs are deliberately not requested. exFAT reuses them for unrelated files, so they mustn't be
/// used for identity, and asking for them only invites someone to.
enum DirectoryLister {
    private static let bufferSize = 256 * 1024

    static func list(_ path: String, token: IOToken) throws -> [DirectoryEntry] {
        try token.check()
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ENOENT || code == ENOTDIR
                ? VolumeIOError.notFound : VolumeIOError.system(operation: "open directory", code: code)
        }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [DirectoryEntry] = []
        while true {
            try token.check()
            let count = getattrlistbulk(descriptor, &attributes, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw VolumeIOError.system(operation: "getattrlistbulk", code: code)
            }
            if count == 0 { return entries }
            parse(UnsafeRawPointer(buffer), count: Int(count), into: &entries)
        }
    }

    /// Attributes in each record follow in bit order, after the returned-attributes set. Records are
    /// variable length, so each one starts with its own length.
    private static func parse(_ buffer: UnsafeRawPointer, count: Int, into entries: inout [DirectoryEntry]) {
        var record = buffer
        for _ in 0..<count {
            let length = record.loadUnaligned(as: UInt32.self)
            defer { record += Int(length) }

            var cursor = record + MemoryLayout<UInt32>.size
            let returned = cursor.loadUnaligned(as: attribute_set_t.self)
            cursor += MemoryLayout<attribute_set_t>.size

            if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                let error = cursor.loadUnaligned(as: UInt32.self)
                cursor += MemoryLayout<UInt32>.size
                if error != 0 { continue }
            }

            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            // attr_length counts the terminating NUL.
            let nameLength = max(0, Int(reference.attr_length) - 1)
            let nameBytes = UnsafeBufferPointer(
                start: (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self),
                count: nameLength)
            cursor += MemoryLayout<attrreference_t>.size

            let type = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
            let modified = cursor.loadUnaligned(as: timespec.self)
            cursor += MemoryLayout<timespec>.size

            // A name that isn't valid UTF-8 couldn't be opened again from a stored String.
            guard let name = String(validating: nameBytes, as: UTF8.self) else { continue }

            let kind: DirectoryEntry.Kind
            var size: Int64 = 0
            switch type {
            case VREG.rawValue:
                kind = .file
                size = cursor.loadUnaligned(as: Int64.self)
            case VDIR.rawValue:
                kind = .directory
            default:
                // Symlinks aren't followed, so a link can't create a cycle or leave the volume.
                kind = .other
            }
            entries.append(
                DirectoryEntry(
                    name: name, kind: kind, size: size,
                    modifiedTime: FileTimestamp(seconds: modified.tv_sec, nanoseconds: modified.tv_nsec)))
        }
    }
}
