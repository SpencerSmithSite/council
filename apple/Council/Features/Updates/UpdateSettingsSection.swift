import CouncilCore
import SwiftUI

/// Settings' Updates section: check automatically, the version, Check Now.
/// Mirrors `_UpdatesGroup` in lib/src/screens/settings_screen.dart.
/// `SettingsView` embeds it in its `Form`.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    @State private var showingOffer = false

    private var updates: UpdateModel { model.updates }

    var body: some View {
        @Bindable var updates = updates
        Section {
            Toggle(isOn: $updates.autoCheck) {
                Label("Check for Updates Automatically", systemImage: "arrow.triangle.2.circlepath")
            }
            LabeledContent {
                if updates.flow.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { checkNow() }
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version")
                        Text(versionText)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            if updates.confirmedUpToDate {
                Label("Council is up to date.", systemImage: "checkmark.circle")
                    .foregroundStyle(palette.secondaryLabel)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(footer)
        }
        .councilListRow()
        .sheet(isPresented: $showingOffer) {
            UpdateSheet()
        }
    }

    /// "2026.10.29 (build 8)", or just the date for a build of zero, as
    /// Flutter writes it. The version wasn't shown anywhere before, which made
    /// every bug report begin with working out which build the reader had.
    private var versionText: String {
        let version = updates.flow.currentVersion
        if version == .impossiblyNew { return String(localized: "Unknown") }
        return version.build == 0 ? version.name : String(localized: "\(version.name) (build \(version.build))")
    }

    /// Named rather than vague, as in Flutter: on iPhone and iPad the app
    /// can't install anything, and saying so saves a reader wondering why
    /// their Mac updates itself and their iPhone sends them to TestFlight.
    private var footer: String {
        #if os(iOS)
        String(localized: "Council checks for a new version at launch and offers to open TestFlight. Apps on iPhone and iPad cannot install updates themselves.")
        #else
        String(localized: "Council checks for a new version at launch. Nothing is downloaded until you say so, and every download is checked against the published checksum and its developer's signature before it is installed.")
        #endif
    }

    private func checkNow() {
        Task {
            if await updates.checkNow() { showingOffer = true }
        }
    }
}
