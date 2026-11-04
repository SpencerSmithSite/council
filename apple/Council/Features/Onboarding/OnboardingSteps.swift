import CouncilCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The four pages of `OnboardingView`, each Flutter's page of the same name in
// lib/src/screens/onboarding_screen.dart.

// MARK: - 1. Scripture

/// Step 1, Scripture (Flutter's `_BiblesPage`). The King James is already
/// installed, and says so plainly, so a reader looking at a list of things to
/// *add* can see what they already have (`_IncludedChip`); the other
/// public-domain translations (the manifest's `scripture` collections) are
/// offered but never forced.
struct OnboardingScriptureStep: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.councilPalette) private var palette

    var body: some View {
        let library = model.packLibrary
        OnboardingPage(
            systemImage: "book.closed",
            title: "Start with Scripture",
            subtitle: "The King James Bible is already installed and works offline. Add any of these other public-domain translations if you like, or move on and add them later from Browse.",
            summary: flow.summary(in: library),
            primaryTitle: "Continue",
            primary: { flow.next(.library) },
            skip: { flow.skip(model.onboarding) },
            showsBack: false
        ) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("King James Bible")
                            .foregroundStyle(palette.text)
                        Text("Included — works offline")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.accent)
                }
                .councilListRow()
            } header: {
                Text("Included")
            }

            if let manifest = library.manifest {
                let bibles = manifest.collections.filter { $0.kind == .scripture }
                Section {
                    ForEach(bibles, id: \.id) { collection in
                        CollectionToggle(collection: collection, bytes: library.bytesToInstall(collection),
                                         isOn: flow.binding(for: collection.id))
                    }
                    if bibles.isEmpty {
                        Text("No additional translations are published yet.")
                            .foregroundStyle(palette.secondaryLabel)
                            .councilListRow()
                    }
                } header: {
                    Text("Other Translations")
                }
            } else {
                CatalogueStateSection()
            }
        }
    }
}

// MARK: - 2. The library

/// Step 2, the bodies of tradition (Flutter's `_StartHerePage`): the
/// manifest's `essential` and `era` collections. Creeds & Confessions is
/// marked as the place to start, because it is the smallest set that can
/// answer a question comparing two traditions; authors and traditions are
/// left to Browse.
struct OnboardingLibraryStep: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingFlow.self) private var flow

    var body: some View {
        let library = model.packLibrary
        OnboardingPage(
            systemImage: "books.vertical",
            title: "Build Your Library",
            subtitle: "The councils, creeds, confessions and church fathers. Start with Creeds & Confessions — the rest of the collections are always in Browse.",
            summary: flow.summary(in: library),
            primaryTitle: "Continue",
            primary: { flow.next(.answers) },
            skip: { flow.skip(model.onboarding) }
        ) {
            if let manifest = library.manifest {
                Section {
                    ForEach(manifest.collections.filter { $0.kind == .essential || $0.kind == .era },
                            id: \.id) { collection in
                        CollectionToggle(collection: collection, bytes: library.bytesToInstall(collection),
                                         recommended: collection.id == OnboardingFlow.startHere,
                                         isOn: flow.binding(for: collection.id))
                    }
                } header: {
                    Text("Collections")
                }
            } else {
                CatalogueStateSection()
            }
        }
    }
}

// MARK: - 3. Answers

/// Step 3, how answers are generated (Flutter's `_AiPage`).
///
/// It opens on whichever private backend the device can offer, which
/// `InferenceModel.start` has already chosen and stored for a reader who
/// hasn't chosen (`InferenceSettings.resolveBackend`, Flutter's
/// `_openingBackend`): Apple Intelligence when it can answer right now,
/// otherwise the downloaded model where MLX runs, otherwise search-only.
/// Selecting an option sets it there and then, as Flutter's `setBackend` on
/// tap, so Skip keeps whatever is selected.
///
/// The options and their order are Flutter's: Apple Intelligence first when
/// the device has it (already installed, nothing to configure, nothing
/// leaves the device, so strictly the easiest and most private at once); the
/// downloaded model wherever it runs, built-in model or not, with its size;
/// search-only; then the two that send the question somewhere, opt-in and
/// saying so. The rows are the AI backend screen's own (`BackendChoiceRow`),
/// privacy line included.
///
/// Where Flutter's page pushes the AI backend screen to finish setting up,
/// the chosen option's settings appear right under the choice, the same
/// sections that screen uses: the model sizes and Download (the download
/// carries on after onboarding, in `InferenceModel.downloads`), Ollama's
/// host, or the cloud provider and key; and Apple Intelligence's "turn it
/// on" help when it is chosen but switched off.
struct OnboardingAnswersStep: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.councilPalette) private var palette

    /// Every catalogue model's files, for the downloaded-model sections, read
    /// on the page for the reason `AIBackendView` reads them on its `Form`.
    @State private var disk: [String: LocalModelDownloads.DiskState] = [:]

    private var inference: InferenceModel { model.inference }
    private var selected: InferenceBackendID { inference.backend.id }
    private var localSupported: Bool { LocalModelEnvironment.current.unsupportedReason == nil }

    /// Flutter's `offersPlatformLlm`: hardware that will never run it gets no
    /// row; a switched-off Apple Intelligence keeps its row, which says where
    /// the switch is.
    private var offersPlatform: Bool {
        inference.platformAvailability.state.worthOffering || selected == .platform
    }

    var body: some View {
        OnboardingPage(
            systemImage: "sparkles",
            title: "Answers, Your Way",
            subtitle: "Council is a searchable library first. AI is optional, and you choose where it runs. Nothing leaves your device unless you add a cloud key.",
            summary: flow.summary(in: model.packLibrary),
            primaryTitle: "Get Started",
            primary: { flow.start(model.onboarding, library: model.packLibrary) },
            skip: { flow.skip(model.onboarding) }
        ) {
            Section {
                Picker("Answers", selection: Binding(
                    get: { selected },
                    set: { inference.settings.setBackend($0) }
                )) {
                    ForEach(choices) { choice in
                        BackendChoiceRow(choice: choice).tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                InlineIconText("You can change this any time in Settings. Search-only stays fully offline; the cloud option is governed by that provider's own privacy and data-retention terms.",
                               systemImage: "lock")
                    .foregroundStyle(palette.secondaryLabel)
            }
            .councilListRow()

            if selected == .platform, !inference.platformAvailability.isAvailable {
                AppleIntelligenceSection(availability: inference.platformAvailability)
            } else if let local = inference.backend as? LocalModelBackend, localSupported {
                LocalModelSettingsSections(selected: local.model, disk: disk)
            } else if let ollama = inference.backend as? OllamaBackend {
                OllamaSettingsSections(host: ollama.host, model: ollama.model)
                    .id(ollama.host)
            } else if let cloud = inference.backend as? CloudBackend {
                CloudSettingsSections(provider: cloud.provider, model: cloud.model)
            }
        }
        // Apple Intelligence may have been switched on since launch.
        .task { await inference.refreshStatus() }
        .task(id: inference.downloads.revision) {
            disk = await inference.downloads.state(of: LocalModel.catalogue)
        }
    }

    private var choices: [BackendChoice] {
        var list: [BackendChoice] = []
        if offersPlatform {
            let ready = inference.platformAvailability.isAvailable
            list.append(BackendChoice(
                id: .platform, title: "Apple Intelligence",
                summary: ready
                    ? "Already built into this \(Self.deviceName). No account, no key and no download."
                    : inference.platformAvailability.detail,
                systemImage: "apple.intelligence", privacy: .onDevice))
        }
        // Offered wherever MLX runs, including devices that already have
        // Apple Intelligence: having it is a reason to default to it, not to
        // withhold a model the reader might prefer (Flutter's
        // `offersLocalModel`).
        if localSupported || selected == .local {
            let smallest = LocalModel.tiers(deviceMemoryMB: LocalDeviceMemory.totalMB()).first?.model
                ?? LocalModel.conservativeDefault()
            list.append(BackendChoice(
                id: .local, title: "Download a Local Model",
                summary: "A one-time download that then runs entirely on this device, with no account and no key. You choose the size — from \(smallest.approximateSize) upward.",
                systemImage: "arrow.down.circle", privacy: .onDevice))
        }
        list.append(BackendChoice(
            id: .none, title: "No AI — Search Only",
            summary: "Browse and search everything offline. Nothing is generated.",
            systemImage: "book", privacy: .onDevice))
        list.append(BackendChoice(
            id: .ollama, title: "Ollama",
            summary: "A model on this machine or one you reach over your network — private, and set up in a moment.",
            systemImage: "server.rack",
            privacy: .ollama(host: (inference.backend as? OllamaBackend)?.host ?? inference.settings.ollamaHost)))
        let provider = (inference.backend as? CloudBackend)?.provider ?? inference.settings.cloudProvider
        list.append(BackendChoice(
            id: .cloud, title: "Your Own API Key",
            summary: "Claude, ChatGPT, Gemini or Grok, billed to your own account.",
            systemImage: "key", privacy: .offDevice(to: "\(provider.label) (\(provider.host))")))
        return list
    }

    /// Flutter said "your iPhone"; the native app runs on three.
    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

// MARK: - 4. Downloads

/// What Get Started set going, followed in place of Flutter's blocking
/// "Downloading …" screen (`_installing` in `OnboardingScreen.build`).
///
/// Flutter held the reader there until every collection had installed ("You
/// can start reading as soon as this finishes"). Here the queue belongs to
/// `OnboardingGate` and the installs to `PackLibrary`, so Start Reading can
/// close onboarding at any point and they carry on; Browse shows them after.
/// A model download started on the previous step is listed too, since it
/// carries on in the same way.
struct OnboardingDownloadsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.councilPalette) private var palette

    private var gate: OnboardingGate { model.onboarding }
    private var modelDownloads: [LocalModelDownloadProgress] {
        model.inference.downloads.progress.values.sorted { $0.modelID < $1.modelID }
    }
    private var done: Bool { !gate.isInstalling && modelDownloads.isEmpty }

    var body: some View {
        OnboardingPage(
            systemImage: done ? "checkmark.circle" : "arrow.down.circle",
            title: done ? "Your Library Is Ready" : "Downloading Your Library",
            subtitle: done
                ? "Everything you chose has been added. The rest of the library is always in Browse."
                : "You can start reading now. Downloads keep going in the background, and you can follow them in Browse.",
            primaryTitle: "Start Reading",
            primary: { flow.onFinish() },
            showsBack: false
        ) {
            Section {
                ForEach(gate.queued, id: \.id) { collection in
                    CollectionInstallRow(name: collection.name, state: gate.installs[collection.id] ?? .waiting,
                                         progress: model.packLibrary.busyID == collection.id
                                            ? model.packLibrary.progress : 0)
                }
            } header: {
                Text("Collections")
            }

            if !modelDownloads.isEmpty {
                Section {
                    ForEach(modelDownloads, id: \.modelID) { download in
                        CollectionInstallRow(name: LocalModel.byID(download.modelID).name, state: .installing,
                                             progress: download.fraction)
                    }
                } header: {
                    Text("Model")
                }
            }
        }
        .navigationBarBackButtonHidden()
        .animation(.default, value: done)
    }
}

/// One download on the downloads page: its name and where it has got to.
private struct CollectionInstallRow: View {
    @Environment(\.councilPalette) private var palette
    let name: String
    let state: OnboardingGate.InstallState
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                status
                    .font(.subheadline)
            }
            if state == .installing {
                ProgressView(value: progress)
                    .accessibilityLabel(Text("Downloading \(name)"))
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(palette.error)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .councilListRow()
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(palette.secondaryLabel)
        case .installing:
            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryLabel)
        case .installed:
            Label("Added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(palette.accent)
        case .failed:
            Label("Not added", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(palette.error)
        }
    }
}
