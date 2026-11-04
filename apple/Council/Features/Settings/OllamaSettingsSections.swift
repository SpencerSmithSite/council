import CouncilCore
import SwiftUI

/// Ollama's settings: the host, whether it answers, and which of its models
/// to use. Flutter's `_OllamaSettings` (lib/src/screens/ai_backend_screen.dart).
///
/// The order of operations is Flutter's, and deliberate: enter the host,
/// fetch what it has, choose from that. The model stays free text until a
/// connection has listed what the server actually has pulled, then becomes a
/// picker of exactly those, so the reader never guesses a name and meets a
/// silent "model not found".
///
/// Unlike Flutter, the connection is tested on arrival too, not only on the
/// button: the section then opens on the list and the connection's state
/// rather than on a question.
struct OllamaSettingsSections: View {
    @Environment(AppModel.self) private var app
    @Environment(\.councilPalette) private var palette

    /// The stored host and model, from the current backend.
    let host: String
    let model: String

    @State private var hostDraft: String
    @State private var modelDraft: String
    @State private var hostError: String?
    /// Models the host reported on the last successful test, or nil before
    /// one has succeeded.
    @State private var models: [String]?
    @State private var testing = false
    @State private var result: TestResult?
    /// Bumped by each test, so a slow one that finishes after a newer one
    /// started doesn't overwrite it.
    @State private var testGeneration = 0

    private struct TestResult: Equatable {
        let ok: Bool
        let message: String
    }

    init(host: String, model: String) {
        self.host = host
        self.model = model
        _hostDraft = State(initialValue: host)
        _modelDraft = State(initialValue: model)
    }

    private var settings: InferenceSettings { app.inference.settings }

    var body: some View {
        hostSection
        modelSection
    }

    // MARK: - Host

    private var hostSection: some View {
        Section {
            TextField("Host", text: $hostDraft, prompt: Text(OllamaBackend.defaultHost))
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .textContentType(.URL)
                #endif
                .submitLabel(.go)
                .onSubmit { connect() }
                // The complaint is about what was submitted, not what is
                // being typed now.
                .onChange(of: hostDraft) { hostError = nil }
                .foregroundStyle(palette.text)
                // On this row rather than the section: a modifier on a
                // `Section` runs once per row.
                .task { await test(host) }
            if let hostError {
                Label(hostError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(palette.error)
            }
        } header: {
            Text("Ollama Server")
        } footer: {
            Text(Self.hostHelp)
                .foregroundStyle(palette.secondaryLabel)
        }
        .councilListRow()
    }

    /// Guidance for the host, which differs by platform for a reason the
    /// reader can't be expected to infer (Flutter's `_hostHelp`): App
    /// Transport Security's exceptions match domain names, not IP literals,
    /// so a Tailscale MagicDNS name works on iOS while the same machine's
    /// 100.x address is refused, as a plain connection failure that reads as
    /// "Ollama is down".
    private static var hostHelp: String {
        let base = "e.g. http://localhost:11434, or a machine on your network or VPN."
        #if os(iOS)
        return base + " On iPhone and iPad, use a Tailscale name like http://desktop.tailnet.ts.net:11434 rather "
            + "than a 100.x address."
        #else
        return base
        #endif
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            connectionRow

            if let models, !models.isEmpty {
                Picker(selection: Binding(
                    get: { models.contains(model) ? model : "" },
                    set: { chosen in
                        guard !chosen.isEmpty else { return }
                        modelDraft = chosen
                        settings.setOllama(model: chosen)
                    }
                )) {
                    // Unset until the reader picks, unless the previous choice
                    // is still installed: an empty picker is the honest state
                    // after a first connection, and it makes the next step
                    // obvious.
                    if !models.contains(model) {
                        Text("Choose a model").tag("")
                    }
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                } label: {
                    Text("Model").foregroundStyle(palette.text)
                }
            } else {
                TextField("Model", text: $modelDraft, prompt: Text("Connect first"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { settings.setOllama(model: modelDraft) }
                    .foregroundStyle(palette.text)
            }

            Button(models == nil ? "Test Connection and Load Models" : "Refresh Models",
                   systemImage: "arrow.clockwise") {
                connect()
            }
            .disabled(testing)
        } header: {
            Text("Model")
        } footer: {
            Text(models?.isEmpty == false
                 ? "Models installed on this host."
                 : "Leave this blank — connect first, then pick from the models the host reports.")
                .foregroundStyle(palette.secondaryLabel)
        }
        .councilListRow()
    }

    @ViewBuilder private var connectionRow: some View {
        if testing {
            Label {
                Text("Connecting…").foregroundStyle(palette.secondaryLabel)
            } icon: {
                ProgressView().controlSize(.small)
            }
        } else if let result {
            Label {
                Text(result.message)
                    .foregroundStyle(result.ok ? palette.text : palette.error)
            } icon: {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(result.ok ? palette.accent : palette.error)
            }
        }
    }

    // MARK: - Testing the connection

    /// Validates and saves the typed host, then tests it.
    ///
    /// Saved before probing, as Flutter's `_test` does, so the status above
    /// and the warm-up check the address the reader just entered. Trimmed by
    /// `setOllama`; refused, without saving, unless it is an http(s) address
    /// with a host, which is all `OllamaBackend` can use.
    private func connect() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else {
            hostError = String(localized: "Enter an address starting with http:// or https://, such as http://localhost:11434.")
            return
        }
        hostError = nil
        hostDraft = trimmed
        if trimmed != host {
            // Saving rebuilds the backend, which gives this section a fresh
            // identity (`.id(host)` in `AIBackendView`); the new one tests the
            // new host as it appears.
            settings.setOllama(host: trimmed)
        } else {
            Task { await test(trimmed) }
        }
    }

    /// Flutter's `_test`: reach the host, list its models, and keep the
    /// stored model only if the host has it.
    private func test(_ host: String) async {
        testGeneration += 1
        let generation = testGeneration
        testing = true
        let (reachable, found) = await Self.probe(host)
        guard generation == testGeneration else { return }
        testing = false

        guard reachable else {
            models = nil
            result = TestResult(ok: false, message: String(localized:
                "Could not reach Ollama at \(host). Check it is running and the address is correct."))
            return
        }
        guard !found.isEmpty else {
            models = []
            result = TestResult(ok: false, message: String(localized:
                "Connected, but no models are installed. Pull one, e.g. \"ollama pull llama3.2\"."))
            return
        }

        // Keep the current model if the server has it, matching the exact tag
        // or a bare name ("llama3.2" against "llama3.2:latest"). Otherwise
        // leave it unset rather than choosing the first for the reader: the
        // choice that decides the quality of every answer shouldn't be made
        // by a sort order.
        let current = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = current.isEmpty ? nil : found.contains(current) ? current : found.first { $0.hasPrefix(current) }
        modelDraft = chosen ?? ""
        if (chosen ?? "") != model {
            settings.setOllama(model: chosen ?? "")
        }
        models = found
        let count = found.count == 1 ? "1 model" : "\(found.count) models"
        result = TestResult(ok: true, message: chosen != nil
            ? "Connected — \(count) available."
            : "Connected — \(count) found. Now choose one below.")
    }

    /// Reachability and the model list, off the main actor.
    @concurrent
    private nonisolated static func probe(_ host: String) async -> (reachable: Bool, models: [String]) {
        let backend = OllamaBackend(host: host, model: "")
        guard await backend.isReachable() else { return (false, []) }
        return (true, await backend.availableModels())
    }
}
