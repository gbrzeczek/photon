import PhotonUI
import SwiftUI

@main
struct PhotonApp: App {
    var body: some Scene {
        WindowGroup {
            PhotonRootView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands { PhotonCommands() }

        Settings {
            PhotonSettingsView()
        }

        Window("Keyboard Shortcuts", id: PhotonWindowID.keyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("Acknowledgements", id: PhotonWindowID.acknowledgements) {
            AcknowledgementsView()
        }
        .defaultPosition(.center)
    }
}
