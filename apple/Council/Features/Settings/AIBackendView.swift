import CouncilCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Choose and configure how answers are generated: the native counterpart of
/// Flutter's `AiBackendScreen` (lib/src/screens/ai_backend_screen.dart),
/// pushed from Settings' "AI Backend" row.
///
/// A grouped `Form` in the order the Flutter screen reads:
///
/// 1. The live status of the chosen backend (Flutter's `_StatusBanner`), with
///    a re-check.
/// 2. The choice itself, as an inline picker: each backend with its one-line
///    summary and a privacy line, because the app is offline-first and every
///    option has to say plainly whether the question leaves the device.
/// 3. Apple Intelligence's state when it is worth offering but can't answer
///    yet (`_PlatformLlmNotice`): switched off, or still downloading.
/// 4. The chosen backend's own settings, shown only for the chosen one as in
///    Flutter: the downloaded model's sizes and download
///    (`LocalModelSettingsSections`), Ollama's host and model
///    (`OllamaSettingsSections`), or the cloud provider, key and model
///    (`CloudSettingsSections`).
/// 5. On a device that can't run a downloaded model, why not, in place of
///    that option (`_LocalModelUnavailable`).
///
/// Every setter writes `InferenceSettings`; `InferenceModel` hears the
/// `UserDefaults` change and rebuilds the backend and its status by itself.
/// The configuration shown is read back from the rebuilt backend
/// (`inference.backend`), which is observed, rather than from
/// `InferenceSettings`, which reads `UserDefaults` and isn't.
///
/// Flutter's screen has nothing else: the citations toggle (`show_citations`)
/// lives on its Settings screen, not here.
struct AIBackendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    /// Every catalogue model's files, for the downloaded-model sections. Read
    /// here, on the `Form`, rather than in those sections: a modifier on a
    /// `Section` is applied to each of its rows, so a `.task` there would run
    /// once per row.
    @State private var disk: [String: LocalModelDownloads.DiskState] = [:]

    private var inference: InferenceModel { model.inference }
    private var selected: InferenceBackendID { inference.backend.id }
    private var localUnsupportedReason: String? { LocalModelEnvironment.current.unsupportedReason }

    var body: some View {
        Form {
            statusSection
            choiceSection

            if offersPlatform, !inference.platformAvailability.isAvailable {
                AppleIntelligenceSection(availability: inference.platformAvailability)
            }

            if let local = inference.backend as? LocalModelBackend, localUnsupportedReason == nil {
                LocalModelSettingsSections(selected: local.model, disk: disk)
            } else if let ollama = inference.backend as? OllamaBackend {
                OllamaSettingsSections(host: ollama.host, model: ollama.model)
                    // A fresh section state per stored host, so a host saved
                    // elsewhere (another Mac window) isn't shadowed by a stale
                    // draft.
                    .id(ollama.host)
            } else if let cloud = inference.backend as? CloudBackend {
                CloudSettingsSections(provider: cloud.provider, model: cloud.model)
            }

            if let reason = localUnsupportedReason {
                LocalModelUnavailableSection(reason: reason, disk: disk)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Backend")
        .councilScreenBackground(grouped: true)
        // Apple Intelligence may have been switched on in Settings since the
        // last check, and an Ollama host may have come up.
        .task { await inference.refreshStatus() }
        .task(id: inference.downloads.revision) {
            disk = await inference.downloads.state(of: LocalModel.catalogue)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    // MARK: - Status

    /// Flutter's `_StatusBanner`: the backend's own sentence, or "Ready" /
    /// "Not available" when it gives none, with a re-check.
    private var statusSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let status = inference.status {
                    Label {
                        Text(status.detail ?? (status.available ? "Ready" : "Not available"))
                            .foregroundStyle(palette.text)
                    } icon: {
                        Image(systemName: status.available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(status.available ? palette.accent : palette.error)
                    }
                } else {
                    Label {
                        Text("Checking…").foregroundStyle(palette.secondaryLabel)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
                Button("Check Again", systemImage: "arrow.clockwise") {
                    Task { await inference.refreshStatus() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(inference.status == nil)
            }
        } header: {
            Text("Status")
        }
        .councilListRow()
    }

    // MARK: - The choice

    /// Apple Intelligence is offered when it can answer or the reader can
    /// make it (`worthOffering`); hardware that never will doesn't get a
    /// permanently dead row. Kept while chosen, so the checkmark never
    /// vanishes from under a stored choice.
    private var offersPlatform: Bool {
        inference.platformAvailability.state.worthOffering || selected == .platform
    }

    private var choices: [BackendChoice] {
        var list: [BackendChoice] = []
        // First when the device has one, as in Flutter: no host, no key, no
        // download, and nothing leaves the device.
        if offersPlatform {
            list.append(BackendChoice(
                id: .platform, title: "Apple Intelligence",
                summary: "The model already on this device. No account, no key and no download.",
                systemImage: "apple.intelligence", privacy: .onDevice))
        }
        list.append(BackendChoice(
            id: .none, title: "No AI — search only",
            summary: "Browse and search the library. Nothing is generated.",
            systemImage: "book", privacy: .onDevice))
        // Offered wherever MLX runs, built-in model or not (Flutter's
        // `offersLocalModel`). Elsewhere the unavailable section says why.
        if localUnsupportedReason == nil || selected == .local {
            let smallest = LocalModel.tiers(deviceMemoryMB: LocalDeviceMemory.totalMB()).first?.model
                ?? LocalModel.conservativeDefault()
            list.append(BackendChoice(
                id: .local, title: "Download a local model",
                summary: "A one-time download that then runs on this device, with no account and no key. "
                    + "You choose the size — from \(smallest.approximateSize) upward.",
                systemImage: "arrow.down.circle", privacy: .onDevice))
        }
        list.append(BackendChoice(
            id: .ollama, title: "Ollama",
            summary: "A model running on this machine, or on another one you can reach over your network or VPN.",
            systemImage: "server.rack", privacy: ollamaPrivacy))
        let provider = (inference.backend as? CloudBackend)?.provider ?? inference.settings.cloudProvider
        list.append(BackendChoice(
            id: .cloud, title: "Your own API key",
            summary: "Claude, ChatGPT, Gemini or Grok, billed to your own account.",
            systemImage: "key", privacy: .offDevice(to: "\(provider.label) (\(provider.host))")))
        return list
    }

    /// Ollama on this machine keeps everything on the device; on another
    /// machine the question crosses the network to it, which is worth saying
    /// even though it is the reader's own server.
    private var ollamaPrivacy: BackendChoice.Privacy {
        let host = (inference.backend as? OllamaBackend)?.host ?? inference.settings.ollamaHost
        let name = URL(string: host)?.host() ?? host
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(name.lowercased()) {
            return .onDevice
        }
        return .offDevice(to: "your Ollama server at \(name)")
    }

    private var choiceSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { selected },
                set: { inference.settings.setBackend($0) }
            )) {
                ForEach(choices) { choice in
                    BackendChoiceRow(choice: choice).tag(choice.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Answers")
        } footer: {
            Text("The app is offline-first: every option says whether your question leaves this device.")
                .foregroundStyle(palette.secondaryLabel)
        }
        .councilListRow()
    }
}

// MARK: - Rows

/// One backend in the picker.
private struct BackendChoice: Identifiable {
    enum Privacy {
        case onDevice
        /// Sent to someone else's computer, or across the network to the
        /// reader's own: named, so the line says where.
        case offDevice(to: String)
    }

    let id: InferenceBackendID
    let title: String
    let summary: String
    let systemImage: String
    let privacy: Privacy
}

/// The icon beside the text, as a `Label` would put it, but laid out here:
/// at the accessibility text sizes a list `Label` flows its icon into the
/// first line, which scrambles a title over several lines of detail. There
/// the icon goes above the text instead.
private struct BackendChoiceRow: View {
    @Environment(\.councilPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let choice: BackendChoice

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 14))
        layout {
            Image(systemName: choice.systemImage)
                .foregroundStyle(palette.accent)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title)
                    .foregroundStyle(palette.text)
                Text(choice.summary)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                privacyLine
                    .font(.footnote)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// An inline icon and text rather than a `Label`: inside a list row a
    /// `Label` reserves the row's icon column, which leaves a wide gap in a
    /// secondary line like this one.
    @ViewBuilder private var privacyLine: some View {
        switch choice.privacy {
        case .onDevice:
            InlineIconText("Nothing leaves your device", systemImage: "lock")
                .foregroundStyle(palette.secondaryLabel)
        case .offDevice(let destination):
            InlineIconText("Your question and the passages are sent to \(destination)",
                           systemImage: "arrow.up.forward.circle")
                .foregroundStyle(palette.error)
        }
    }
}

/// A small icon leading a line of secondary text, aligned on the text's
/// first baseline so it sits right when the text wraps.
struct InlineIconText: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
        }
    }
}

// MARK: - Apple Intelligence

/// Apple Intelligence is supported but can't answer yet: switched off, or its
/// model still downloading (Flutter's `_PlatformLlmNotice`). Both are the
/// reader's to fix, or wait out, so the row stays selectable and this says
/// how, with Flutter's wording (`FoundationModelsBackend.systemAvailability`).
private struct AppleIntelligenceSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    @Environment(\.openURL) private var openURL
    let availability: PlatformLlmAvailability

    var body: some View {
        Section {
            if availability.state == .modelNotReady {
                ProgressView {
                    Text(availability.detail).foregroundStyle(palette.text)
                }
            } else {
                Text(availability.detail)
                    .foregroundStyle(palette.text)
            }
            if availability.state == .notEnabled, let url = Self.settingsURL {
                Button(Self.settingsTitle, systemImage: "gear") { openURL(url) }
            }
            // The reader fixes this in Settings and comes back; without a way
            // to ask again the screen would show what it read on arrival.
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await model.inference.refreshStatus() }
            }
        } header: {
            Text("Apple Intelligence")
        }
        .councilListRow()
    }

    #if os(iOS)
    /// iOS has no public URL for the Apple Intelligence & Siri page, so this
    /// opens Settings (at the app's own page); the sentence above names the
    /// page to go to.
    private static let settingsURL = URL(string: UIApplication.openSettingsURLString)
    private static let settingsTitle: LocalizedStringKey = "Open Settings"
    #else
    /// System Settings' Apple Intelligence & Siri pane: the extension id it
    /// has had since it was the Siri pane, which macOS 15.1+ opens at the
    /// Apple Intelligence switch.
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
    private static let settingsTitle: LocalizedStringKey = "Open System Settings"
    #endif
}

// MARK: - Settings' row

extension InferenceModel {
    /// The chosen backend in a word or two, for the value of Settings' "AI
    /// Backend" row: the model's name for the downloaded model, the
    /// provider's for the cloud.
    var backendName: String {
        switch backend {
        case let local as LocalModelBackend: local.model.name
        case let cloud as CloudBackend: cloud.provider.label
        case is OllamaBackend: "Ollama"
        case is FoundationModelsBackend: "Apple Intelligence"
        default: String(localized: "Search Only")
        }
    }
}

#Preview {
    NavigationStack { AIBackendView() }
        .environment(AppModel())
}
