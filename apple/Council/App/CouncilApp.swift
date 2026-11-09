import SwiftUI

@main
struct CouncilApp: App {
    /// One for the process, shared by every window and the Settings scene, so
    /// the corpus is installed and opened once.
    @State private var model: AppModel

    /// The reader's theme, likewise one per process so every window and the
    /// Mac's Settings window change together.
    @State private var themeStore: ThemeStore

    /// The reader's typography (size, face, spacing, margins), one per
    /// process for the same reason.
    @State private var readerStyle: ReaderStyle

    init() {
        // A Flutter install's preferences and cloud keys first: all three of
        // these read `UserDefaults` as they're made, and the first frame
        // should already be in the reader's theme.
        let migrated = AppModel.migrateFlutterSettings()
        let model = AppModel()
        model.migration = migrated
        _model = State(initialValue: model)
        _themeStore = State(initialValue: ThemeStore())
        _readerStyle = State(initialValue: ReaderStyle())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .councilTheme(themeStore)
                .environment(readerStyle)
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
            .councilTheme(themeStore)
            .environment(readerStyle)
            .environment(model)
        }
        #endif
    }
}
