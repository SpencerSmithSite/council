import SwiftUI

extension View {
    /// The Flutter app keeps Settings out of the primary navigation and puts a
    /// gear top-right; on iPhone and iPad this is that gear, opening a sheet.
    /// The Mac uses its Settings scene instead (see `CouncilApp`).
    func settingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}

private struct SettingsToolbar: ViewModifier {
    @State private var showingSettings = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark", role: .confirm) {
                                    showingSettings = false
                                }
                            }
                        }
                }
            }
        #else
        content
        #endif
    }
}
