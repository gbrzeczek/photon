import Foundation

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
        try run("/usr/bin/hdiutil", arguments + [url.path])
        return DiskImage(url: url)
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
        guard let mountPoint else { return }
        try Self.run("/usr/bin/hdiutil", ["detach", mountPoint] + (force ? ["-force"] : []) + ["-quiet"])
        self.mountPoint = nil
    }

    /// Detaches without a throw, for cleanup.
    public func ensureDetached() {
        guard mountPoint != nil else { return }
        if (try? detach()) == nil { try? detach(force: true) }
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
