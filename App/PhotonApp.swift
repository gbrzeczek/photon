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
    }
}
