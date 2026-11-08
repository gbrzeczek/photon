import Foundation
import Synchronization

public enum DiskImageError: Error, CustomStringConvertible {
    case commandFailed(String)
    public var description: String {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

/// A scratch disk image. Disk images use the same FSKit exFAT driver as the real drive, so they stand
/// in for it during development. They aren't gated by TCC, and a forced detach isn't a real cable pull.
///
/// Detaching looks this image up by its own path in `hdiutil info`, and acts on the device listed there.
/// It never uses a mount point or disk number that it hasn't just confirmed belongs to this image, so it
/// can't reach anything it didn't create.
public final class DiskImage: @unchecked Sendable {
    public let url: URL
    public private(set) var mountPoint: String?

    private init(url: URL) { self.url = url }

    /// Creates an empty image. `filesystem` is what `hdiutil` calls it, such as `ExFAT` or `APFS`.
    public static func create(
        in directory: URL, name: String = "image", filesystem: String = "ExFAT", label: String, megabytes: Int = 128
    ) throws -> DiskImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name + ".dmg", directoryHint: .notDirectory)
        var arguments = ["create", "-quiet", "-size", "\(megabytes)m", "-fs", filesystem, "-volname", label]
        if filesystem != "APFS" { arguments += ["-layout", "MBRSPUD"] }
        if filesystem == "APFS" {
            try run("/usr/bin/hdiutil", arguments + [url.path])
        } else {
            try inASecondOfItsOwn { _ = try run("/usr/bin/hdiutil", arguments + [url.path]) }
        }
        return DiskImage(url: url)
    }

    /// exFAT and FAT take their serial, and so their UUID, from the clock, so two images made in one
    /// second look like clones. Suites run in parallel, so every image made in this process gets
    /// seconds of its own. A real clone comes from `clone(to:)` instead.
    private static let lastCreation = Mutex<Int>(0)

    private static func inASecondOfItsOwn(_ body: () throws -> Void) throws {
        try lastCreation.withLock { last in
            while Int(Date().timeIntervalSince1970) <= last { Thread.sleep(forTimeInterval: 0.05) }
            defer { last = Int(Date().timeIntervalSince1970) }
            try body()
        }
    }

    /// A byte-for-byte copy, which has the same UUID and file IDs as the original.
    public func clone(to url: URL) throws -> DiskImage {
        try FileManager.default.copyItem(at: self.url, to: url)
        return DiskImage(url: url)
    }

    /// Attaches the image, and returns the mount point.
    @discardableResult
    public func attach(readOnly: Bool = false, mountPoint customMountPoint: URL? = nil) throws -> String {
        var arguments = ["attach", "-nobrowse", "-plist"]
        if readOnly { arguments.append("-readonly") }
        if let customMountPoint {
            try FileManager.default.createDirectory(at: customMountPoint, withIntermediateDirectories: true)
            arguments += ["-mountpoint", customMountPoint.path]
        }
        let output = try Self.run("/usr/bin/hdiutil", arguments + [url.path])
        guard
            let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let path = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw DiskImageError.commandFailed("hdiutil attach gave no mount point") }
        mountPoint = path
        return path
    }

    /// Detaches the image. With `force`, this stands in for pulling a cable.
    public func detach(force: Bool = false) throws {
        guard let device = try attachedDevice() else {
            mountPoint = nil
            return
        }
        try Self.run("/usr/bin/hdiutil", ["detach", device] + (force ? ["-force"] : []) + ["-quiet"])
        mountPoint = nil
    }

    /// Detaches without a throw, for cleanup.
    public func ensureDetached() {
        if (try? detach()) == nil { try? detach(force: true) }
    }

    /// Whether `hdiutil` lists this image as attached.
    public var isAttached: Bool { ((try? attachedDevice()) ?? nil) != nil }

    /// The device `hdiutil info` lists for this exact image path, or nil if it isn't attached.
    private func attachedDevice() throws -> String? {
        let output = try Self.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { throw DiskImageError.commandFailed("hdiutil info gave nothing readable") }
        let path = Self.canonical(url.path)
        guard let image = images.first(where: { ($0["image-path"] as? String).map(Self.canonical) == path }),
            let entities = image["system-entities"] as? [[String: Any]]
        else { return nil }
        // The shortest entry is the whole disk: disk5 rather than disk5s1.
        return entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw DiskImageError.commandFailed(
                "\(tool) \(arguments.prefix(2).joined(separator: " ")) failed with \(process.terminationStatus): \(message)")
        }
        return data
    }
}
