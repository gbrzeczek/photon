import AppKit
import Foundation

public enum EjectError: Error, Equatable, Sendable {
    /// Refused before touching the volume. The reason is safe to show.
    case refused(String)
    /// The volume wasn't connected, or it's not the one it was.
    case notConnected
    /// macOS wouldn't do it, usually because another app has a file open.
    case failed(String)
}

extension EjectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        case .notConnected: "That volume isn't connected."
        case .failed(let message): message
        }
    }
}

/// Which volumes an ejector may act on.
public enum EjectScope: Sendable, Hashable {
    /// The default. Tests, tools and any run that isn't using the real library stay here, so that
    /// nothing but the user's own click can reach a real drive.
    case diskImagesOnly
    /// Any volume that isn't on the internal disk. Only the app with its real library uses this.
    case anyExternalVolume
}

/// Unmounts and ejects a volume, as the user's own command.
///
/// `eject` reads the volume again from the system immediately before acting, and checks that again,
/// rather than trusting a value that may have been built by hand or gone stale. DiskArbitration is the
/// only source of a volume's location.
public struct VolumeEjector: Sendable {
    public let scope: EjectScope
    private let perform: @Sendable (URL) throws -> Void

    public init(scope: EjectScope = .diskImagesOnly) {
        self.init(scope: scope, perform: { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) })
    }

    /// For tests, which prove what reaches `perform`.
    init(scope: EjectScope, perform: @escaping @Sendable (URL) throws -> Void) {
        self.scope = scope
        self.perform = perform
    }

    /// Why this volume can't be ejected, or nil if it can.
    public func refusal(for mount: MountedVolume) -> String? {
        switch (mount.location, scope) {
        case (.diskImage, _), (.external, .anyExternalVolume), (.unknown, .anyExternalVolume):
            return mount.mountPoint == "/" ? "The startup disk can't be ejected." : nil
        case (.internal, _):
            return "This volume is on the internal disk."
        case (.external, .diskImagesOnly), (.unknown, .diskImagesOnly):
            return "Eject is limited to disk images in this run."
        }
    }

    public func canEject(_ mount: MountedVolume) -> Bool { refusal(for: mount) == nil }

    /// Blocks until macOS has finished, on an I/O thread. Call `LibraryIndexer.eject`, which stops
    /// Photon's own work first.
    func eject(_ mount: MountedVolume) async throws {
        if let reason = refusal(for: mount) { throw EjectError.refused(reason) }
        let perform = perform
        try await onIOThread {
            guard let fresh = try? MountedVolume.containing(path: mount.mountPoint).volume,
                fresh.bsdName == mount.bsdName, fresh.uuid == mount.uuid, fresh.mountPoint == mount.mountPoint
            else { throw EjectError.notConnected }
            if let reason = refusal(for: fresh) { throw EjectError.refused(reason) }
            do {
                try perform(URL(fileURLWithPath: fresh.mountPoint, isDirectory: true))
            } catch {
                throw EjectError.failed(error.localizedDescription)
            }
        }
    }
}
