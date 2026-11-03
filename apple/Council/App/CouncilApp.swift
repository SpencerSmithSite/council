import SwiftUI

@main
struct CouncilApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }

        #if os(macOS)
        // On the Mac, settings live where Mac apps keep them: the app menu and
        // Cmd-, — not in the window's navigation.
        Settings {
            SettingsView()
        }
        #endif
    }
}
