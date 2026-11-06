import PhotonUI
import SwiftUI

@main
struct PhotonApp: App {
    var body: some Scene {
        WindowGroup {
            PhotonRootView()
        }
        .commands { PhotonCommands() }
    }
}
