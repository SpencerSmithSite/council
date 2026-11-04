import CouncilCore
import SwiftUI

/// The cloud backend's settings: provider, model, the reader's API key, and
/// the warning that this is the one option that sends questions off the
/// device. Flutter's `_CloudSettings` (lib/src/screens/ai_backend_screen.dart).
///
/// The key is a `SecureField` saved to the Keychain on submit (or Save Key),
/// never to `UserDefaults`; `InferenceModel.setCloudKey` rebuilds the backend
/// afterwards, since the Keychain sends no change notice. The field is
/// cleared once saved, as Flutter clears it, so the key isn't left sitting in
/// the view.
struct CloudSettingsSections: View {
    @Environment(AppModel.self) private var app
    @Environment(\.councilPalette) private var palette

    /// The stored provider and model, from the current backend.
    let provider: CloudProvider
    let model: String

    @State private var keyDraft = ""
    /// Whether a key is saved for `provider`; nil until the Keychain has
    /// answered.
    @State private var hasKey: Bool?
    @State private var confirmingRemove = false
    @State private var failure: String?
    @FocusState private var keyFocused: Bool

    private var inference: InferenceModel { app.inference }
    private var trimmedDraft: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        providerSection
        keySection
        warningSection
    }

    // MARK: - Provider and model

    private var providerSection: some View {
        Section {
            Picker(selection: Binding(
                get: { provider },
                // Resets the model to the new provider's default: a Claude
                // model name means nothing to Gemini.
                set: { inference.settings.setCloudProvider($0) }
            )) {
                ForEach(CloudProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            } label: {
                Text("Provider").foregroundStyle(palette.text)
            }
            Picker(selection: Binding(
                get: { provider.models.contains(model) ? model : provider.defaultModel },
                set: { inference.settings.setCloudModel($0) }
            )) {
                ForEach(provider.models, id: \.self) { name in
                    Text(name).tag(name)
                }
            } label: {
                Text("Model").foregroundStyle(palette.text)
            }
        } header: {
            Text("Provider")
        }
        .councilListRow()
    }

    // MARK: - The key

    private var keySection: some View {
        Section {
            SecureField(hasKey == true ? "Replace \(provider.label) Key" : "\(provider.label) API Key",
                        text: $keyDraft,
                        prompt: Text(hasKey == true ? "Key saved — enter a new one to replace it" : "Paste your key"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit { save() }
                .foregroundStyle(palette.text)
                // On this row rather than the section: a modifier on a
                // `Section` runs once per row.
                .task(id: provider) {
                    hasKey = nil
                    hasKey = await inference.hasCloudKey(for: provider)
                }

            Button("Save Key", systemImage: "key") { save() }
                .disabled(trimmedDraft.isEmpty)

            if hasKey == true {
                Button("Remove Key…", systemImage: "trash", role: .destructive) {
                    confirmingRemove = true
                }
                .confirmationDialog("Remove your \(provider.label) key?", isPresented: $confirmingRemove,
                                    titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { remove() }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text("It is deleted from this device’s keychain. Questions can’t go to \(provider.label) "
                         + "until you add a key again.")
                }
            }

            Link(destination: provider.keyURL) {
                Label("Get a \(provider.label) Key", systemImage: "arrow.up.forward.square")
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(palette.error)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Stored in your device keychain, never in the app database or in plain text.")
                .foregroundStyle(palette.secondaryLabel)
        }
        .councilListRow()
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty else { return }
        write(key)
    }

    private func remove() {
        write("")
    }

    /// Writes (or, empty, deletes) the key off the main actor, then reloads
    /// the backend so the status above says whether it is usable.
    private func write(_ key: String) {
        let provider = provider
        Task {
            do {
                try await inference.setCloudKey(key, for: provider)
                failure = nil
                keyDraft = ""
                keyFocused = false
                hasKey = !key.isEmpty
            } catch {
                failure = String(localized: "Couldn’t save to the keychain: \(String(describing: error))")
            }
        }
    }

    // MARK: - Off the device

    /// Kept in the error tone, as Flutter keeps its card, because this is the
    /// one option that sends a reader's questions off the device: the app's
    /// central promise reversed. A standing caution, read once, rather than
    /// something broken. Flutter's wording.
    private var warningSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 8) {
                    Text("With a cloud key, your questions and the passages retrieved for them are sent to that "
                         + "provider. Every other option keeps them on your device.")
                    Text("What happens to them after that is governed by that provider’s privacy policy and "
                         + "data-retention terms, not by this app. Depending on your account and their current "
                         + "terms, they may retain your questions, have staff review them, or use them to train "
                         + "models. Council cannot see, control, or undo any of that — check the terms of "
                         + "whichever provider you use.")
                }
                .font(.subheadline)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(palette.error)
            }
        } header: {
            Text("Privacy")
        }
        .councilListRow()
    }
}
