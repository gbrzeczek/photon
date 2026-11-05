import Darwin
import Foundation

struct Entry: Sendable {
    var path: String
    var size: Int64
    var fileID: UInt64
    var mtime: Int
}

private let bufferSize = 256 * 1024

/// Streams one directory with getattrlistbulk. Returns files and subdirectories.
/// Attribute order in each record follows bit order, after ATTR_CMN_RETURNED_ATTRS.
private func listDirectory(_ path: String, into files: inout [Entry], dirs: inout [String]) {
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { return }
    defer { close(fd) }

    var attrs = attrlist()
    attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
    attrs.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    defer { buffer.deallocate() }

    while true {
        let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
        if count <= 0 { return }
        var record = UnsafeRawPointer(buffer)
        for _ in 0..<count {
            let length = record.loadUnaligned(as: UInt32.self)
            var cursor = record + 4
            let returned = cursor.loadUnaligned(as: attribute_set_t.self)
            cursor += MemoryLayout<attribute_set_t>.size

            // Failed entries carry a 32-bit error before the other attributes.
            if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                let error = cursor.loadUnaligned(as: UInt32.self)
                cursor += 4
                if error != 0 { record += Int(length); continue }
            }
            let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
            let name = String(cString: (cursor + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            cursor += MemoryLayout<attrreference_t>.size
            let type = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
            let mtime = cursor.loadUnaligned(as: timespec.self)
            cursor += MemoryLayout<timespec>.size
            let fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8

            if !name.hasPrefix(".") {
                let child = path.hasSuffix("/") ? path + name : path + "/" + name
                if type == VDIR.rawValue {
                    dirs.append(child)
                } else if type == VREG.rawValue {
                    let size = cursor.loadUnaligned(as: Int64.self)
                    files.append(Entry(path: child, size: size, fileID: fileID, mtime: mtime.tv_sec))
                }
            }
            record += Int(length)
        }
    }
}

func enumerateBulk(_ root: String) -> [Entry] {
    var pending = [root]
    var files: [Entry] = []
    while let dir = pending.popLast() {
        var dirs: [String] = []
        listDirectory(dir, into: &files, dirs: &dirs)
        pending.append(contentsOf: dirs.sorted().reversed())
    }
    return files
}

/// The baseline that getattrlistbulk has to beat.
func enumerateFileManager(_ root: String) -> Int {
    var count = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { count += 1 }
    }
    return count
}
