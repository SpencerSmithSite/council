import SwiftUI

@main
struct CouncilApp: App {
    /// One for the process, shared by every window and the Settings scene, so
    /// the corpus is installed and opened once.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }

        #if os(macOS)
        // On the Mac, settings live where Mac apps keep them: the app menu and
        // Cmd-, — not in the window's navigation.
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(model)
        }
        #endif
    }
}
