import CouncilCore
import SwiftUI

extension View {
    /// Tells the reader what couldn't come across from the Flutter app this
    /// one replaced (`AppModel.migration`), one alert at a time.
    func migrationNotice() -> some View {
        modifier(MigrationNotice())
    }
}

/// The alerts for `FlutterMigration.Outcome`, most serious first: the earlier
/// library (the Mac's container wouldn't open or copy), a cloud key to enter
/// again, then the downloaded model to fetch again. Each clears its part of
/// the outcome when answered, so the next shows.
///
/// Every Mac window has this, so the first to appear claims the notices and
/// only that one raises them, as `UpdateLaunchOffer` does.
private struct MigrationNotice: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()
    @State private var showingAIBackend = false

    enum Notice {
        case library(FlutterMigration.Outcome.LibraryProblem)
        case key(CloudProvider)
        case model(bytes: Int64)
    }

    func body(content: Content) -> some View {
        content
            .task {
                if model.migrationNoticeOwner == nil { model.migrationNoticeOwner = id }
            }
            .alert(title, isPresented: presented, presenting: notice) { notice in
                actions(for: notice)
            } message: { notice in
                Text(message(for: notice))
            }
            .sheet(isPresented: $showingAIBackend) {
                NavigationStack {
                    AIBackendView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark", role: .confirm) {
                                    showingAIBackend = false
                                }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
            }
    }

    /// The notice to show now, if any. The model notice only while the
    /// downloaded model is the chosen backend, this device can run one, and
    /// none is on disk yet: a reader who has moved on, already downloaded, or
    /// is on an Intel Mac (whose status row says why) needs no telling.
    private var notice: Notice? {
        guard model.migrationNoticeOwner == id, !model.onboarding.isPresented else { return nil }
        let outcome = model.migration
        if let problem = outcome.library { return .library(problem) }
        if let provider = outcome.keyToReenter { return .key(provider) }
        if outcome.removedModelBytes > 0, model.inference.backend.id == .local,
           LocalModelEnvironment.current.unsupportedReason == nil,
           model.inference.localModels.downloadedModels().isEmpty {
            return .model(bytes: outcome.removedModelBytes)
        }
        return nil
    }

    private var presented: Binding<Bool> {
        Binding { notice != nil } set: { _ in }
    }

    private var title: String {
        switch notice {
        case .library(.unreadable): "Your Earlier Library Couldn't Be Opened"
        case .library(.copyFailed): "Your Earlier Library Couldn't Be Copied"
        case .key(let provider): "Enter Your \(provider.label) Key Again"
        case .model: "Download the Model Again"
        case nil: ""
        }
    }

    private func message(for notice: Notice) -> String {
        switch notice {
        case .library(.unreadable):
            "Your notes, highlights, chats and collections from the previous version of Council are still on "
                + "this Mac, but macOS didn't let this version read them. Quit and reopen Council to try again, "
                + "and choose Allow if macOS asks about Council's data."
        case .library(.copyFailed(let reason)):
            "Your notes, highlights, chats and collections from the previous version of Council are still on "
                + "this Mac, but copying them failed: \(reason) Quit and reopen Council to try again."
        case .key(let provider):
            "Council couldn't bring over the \(provider.label) API key saved in the previous version. "
                + "Answers won't use \(provider.label) until you enter it again."
        case .model(let bytes):
            "This version of Council runs the downloaded model differently and can't use the previous "
                + "version's copy, so it was removed to free \(bytes.formatted(.byteCount(style: .file))). "
                + "Download it again to keep getting answers on this device."
        }
    }

    @ViewBuilder
    private func actions(for notice: Notice) -> some View {
        switch notice {
        case .library:
            Button("Try Again Next Time", role: .cancel) {
                model.migration.library = nil
            }
            Button("Start Fresh") {
                Task { await model.startFresh() }
            }
        case .key:
            Button("Not Now", role: .cancel) {
                model.migration.keyToReenter = nil
            }
            Button("Enter Key") {
                model.migration.keyToReenter = nil
                showingAIBackend = true
            }
        case .model:
            Button("Not Now", role: .cancel) {
                model.migration.removedModelBytes = 0
            }
            Button("Download") {
                model.migration.removedModelBytes = 0
                showingAIBackend = true
            }
        }
    }
}
