import SwiftUI

/// Settings, shown in a sheet on iPhone and iPad and as the Settings scene on
/// the Mac. Both callers wrap it in a NavigationStack, so it carries none of
/// its own and its rows can push.
///
/// A shell for now: the sections are where later phases put their settings
/// (themes in Phase 2, the AI backend in Phase 5, packs and updates in
/// Phase 6), so the layout is settled before they arrive.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Appearance") {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
            }
            .councilListRow()

            Section("AI") {
                NavigationLink {
                    // TODO(Phase 5): the AI backend screen.
                    Text("AI Backend")
                } label: {
                    Label("AI Backend", systemImage: "sparkles")
                }
            }
            .councilListRow()

            Section {
                NavigationLink {
                    // TODO(Phase 6): content packs, backed by `AppModel.packs`.
                    Text("Content Packs")
                } label: {
                    Label("Content Packs", systemImage: "shippingbox")
                }
                LabeledContent("Semantic Search", value: semanticStatus)
            } header: {
                Text("Library")
            } footer: {
                if model.semantic == .unavailable {
                    Text("Searching by meaning couldn't start on this device, so search matches words only.")
                }
            }
            .councilListRow()

            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            .councilListRow()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .councilScreenBackground(grouped: true)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var semanticStatus: String {
        switch model.semantic {
        case .loading: String(localized: "Loading…")
        case .available: String(localized: "On")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    /// "2026.10.29 (8)": the CalVer release date and the build counter, both
    /// set in project.yml and carried into Info.plist.
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(release) (\(build))"
    }()
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AppModel())
}
