import AppKit

/// Delivers mount and unmount events, so that work can stop before a volume goes away.
///
/// These fire for every local volume, including disk images attached with `-nobrowse`, and a forced
/// detach sends both unmount events.
public final class VolumeEventMonitor: @unchecked Sendable {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// The handlers run on the thread that posts the notification, usually the main thread, so they
    /// must not block.
    public init(
        center: NotificationCenter,
        willUnmount: @escaping @Sendable (String) -> Void,
        didUnmount: @escaping @Sendable (String) -> Void,
        didMount: @escaping @Sendable (String) -> Void = { _ in },
        didRename: @escaping @Sendable (_ old: String, _ new: String) -> Void = { _, _ in }
    ) {
        self.center = center
        let events: [(Notification.Name, @Sendable (String) -> Void)] = [
            (NSWorkspace.willUnmountNotification, willUnmount),
            (NSWorkspace.didUnmountNotification, didUnmount),
            (NSWorkspace.didMountNotification, didMount),
        ]
        observers = events.map { name, handler in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                if let path = notification.userInfo?["NSDevicePath"] as? String { handler(path) }
            }
        }
        // A rename moves the mount point, so a session's path stops working without any unmount.
        observers.append(
            center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: nil) { notification in
                guard let old = notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
                    let new = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                else { return }
                didRename(old.path, new.path)
            })
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
