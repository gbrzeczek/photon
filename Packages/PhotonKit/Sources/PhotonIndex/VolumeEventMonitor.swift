import AppKit

/// Delivers mount and unmount events, so that work can stop before a volume goes away.
public final class VolumeEventMonitor: @unchecked Sendable {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// The handlers run on the thread that posts the notification, usually the main thread, so they
    /// must not block.
    public init(
        center: NotificationCenter,
        willUnmount: @escaping @Sendable (String) -> Void,
        didUnmount: @escaping @Sendable (String) -> Void,
        didMount: @escaping @Sendable (String) -> Void = { _ in }
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
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
