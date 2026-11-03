import SwiftUI

/// Shown in a sheet on iPhone and iPad, and as the Settings scene on the Mac,
/// so it carries no NavigationStack of its own.
struct SettingsView: View {
    var body: some View {
        ContentUnavailableView("Settings", systemImage: "gearshape",
                               description: Text("Theme, AI backend and updates will live here."))
            .navigationTitle("Settings")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 280)
            #endif
    }
}

#Preview {
    SettingsView()
}
