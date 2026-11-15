import SwiftUI

/// The windows Help opens. The app declares them as scenes, by these identifiers.
public enum PhotonWindowID {
    public static let keyboardShortcuts = "keyboard-shortcuts"
    public static let acknowledgements = "acknowledgements"
}

/// About Photon, and the Help menu: Keyboard Shortcuts, Acknowledgements and the project's page. Photon
/// has no help book, so these take the place of the system's "Photon Help" item.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Photon") { AboutPanel.show() }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: PhotonWindowID.keyboardShortcuts) }
            Button("Acknowledgements") { openWindow(id: PhotonWindowID.acknowledgements) }
            Divider()
            Link("Photon on GitHub", destination: AboutPanel.repository)
        }
    }
}
