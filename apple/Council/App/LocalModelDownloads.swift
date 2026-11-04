import CouncilCore
import Foundation
import Observation

/// The running downloads of the MLX models, and the disk facts the AI backend
/// screen shows about each model.
///
/// Owned by `InferenceModel` rather than by the screen, which is the one thing
/// the Flutter original got wrong here: `_LocalModelSettingsState` held the
/// download's `StreamSubscription` and cancelled it in `dispose`
/// (lib/src/screens/ai_backend_screen.dart), so backing out of the screen
/// mid-download threw the download away. A 2 GB download has to survive the
/// reader looking at something else, so it lives as long as the app does and
/// the screen only observes it.
///
/// One task per model, so two models can download at once and switching the
/// chosen model while one downloads can't attach the finished file to the
/// wrong choice (the reason Flutter's radio group refused to change mid-
/// download). `LocalModelStore` refuses a second download of the same model
/// itself; `start` refuses it first so the screen never sees that error.
///
/// Main-actor because the UI observes it. The download runs in the store's
/// own task, off the main actor; only the newest-wins progress values land
/// here. The disk reads (`state(of:)`) run `@concurrent` for the same reason
/// `AppModel` opens the corpus that way: the app target's approachable
/// concurrency would otherwise run them on the main actor.
@Observable @MainActor
final class LocalModelDownloads {
    /// The latest progress of each running download, by model id.
    private(set) var progress: [String: LocalModelDownloadProgress] = [:]
    /// Why the last download of a model failed, worded for the reader, by
    /// model id. Cleared when the model's next download starts.
    private(set) var failures: [String: String] = [:]
    /// Bumped whenever what is on disk changes (a download finishing, stopping
    /// or failing, a delete), so screens re-read `state(of:)` with
    /// `.task(id:)` on it.
    private(set) var revision = 0

    /// Called after anything that may change whether the chosen model is
    /// installed, so `InferenceModel` re-checks the backend's status even
    /// when the screen that started the download has gone.
    var onDiskChange: (() -> Void)?

    private let store: LocalModelStore
    private var tasks: [String: Task<Void, Never>] = [:]

    init(store: LocalModelStore) {
        self.store = store
    }

    func isRunning(_ model: LocalModel) -> Bool {
        tasks[model.id] != nil
    }

    /// Starts downloading `model` (or resumes an interrupted download).
    ///
    /// The disk check runs first, at the moment of pressing, as Flutter's
    /// `_download` does: the reader may have freed space since the screen was
    /// drawn, and the refusal must hold however the button was reached. Its
    /// wording is Flutter's.
    func start(_ model: LocalModel) {
        guard tasks[model.id] == nil else { return }
        failures[model.id] = nil
        progress[model.id] = LocalModelDownloadProgress(modelID: model.id, completedBytes: 0,
                                                        totalBytes: model.downloadBytes, phase: .preparing)
        tasks[model.id] = Task { [store] in
            defer { finish(model) }
            let check = await Self.diskCheck(model, in: store)
            guard check.fits else {
                let free = check.freeBytes.map { " and this device has \(Self.size($0)) free" } ?? ""
                failures[model.id] = "Not enough free space for \(model.name). It needs \(model.approximateSize)\(free)."
                return
            }
            do {
                for try await update in store.download(model) {
                    progress[model.id] = update
                }
            } catch is CancellationError {
                // Cancelled by the reader: the partial download is kept for
                // resuming, which the screen shows.
            } catch {
                failures[model.id] = error.localizedDescription
            }
        }
    }

    /// Stops `model`'s download, keeping what has arrived so the next
    /// `start` resumes from it. Cancelling this task ends the progress
    /// stream, which cancels the store's own download task.
    func cancel(_ model: LocalModel) {
        tasks[model.id]?.cancel()
    }

    /// Deletes `model`, complete or partial, stopping its download first.
    ///
    /// Through `LocalModelBackend.delete()` rather than the store, so a model
    /// loaded into memory for the last answer is unloaded before its files go.
    func delete(_ model: LocalModel) async throws {
        if let running = tasks[model.id] {
            running.cancel()
            await running.value
        }
        defer {
            revision += 1
            onDiskChange?()
        }
        try await LocalModelBackend(model: model, store: store).delete()
    }

    private func finish(_ model: LocalModel) {
        tasks[model.id] = nil
        progress[model.id] = nil
        revision += 1
        onDiskChange?()
    }

    // MARK: - What is on disk

    /// One model's files as the screen needs them.
    struct DiskState: Sendable, Equatable {
        /// Complete, verified and of the pinned revision.
        var downloaded: Bool
        /// What deleting it would free, complete or partial.
        var bytesOnDisk: Int64
        /// Bytes of an interrupted download a new one keeps.
        var resumableBytes: Int64
        /// Whether the rest of the download fits, with the store's headroom.
        var diskCheck: LocalModelDiskCheck

        /// An interrupted download is waiting to be resumed or deleted.
        var isPartial: Bool { !downloaded && resumableBytes > 0 }
    }

    /// The disk state of each of `models`, read off the main actor: these are
    /// `stat`s, directory walks and a volume query.
    func state(of models: [LocalModel]) async -> [String: DiskState] {
        await Self.read(models, in: store)
    }

    @concurrent
    private nonisolated static func read(_ models: [LocalModel], in store: LocalModelStore) async -> [String: DiskState] {
        var states: [String: DiskState] = [:]
        for model in models {
            states[model.id] = DiskState(downloaded: store.isDownloaded(model),
                                         bytesOnDisk: store.bytesOnDisk(for: model),
                                         resumableBytes: store.resumableBytes(for: model),
                                         diskCheck: store.diskCheck(for: model))
        }
        return states
    }

    @concurrent
    private nonisolated static func diskCheck(_ model: LocalModel, in store: LocalModelStore) async -> LocalModelDiskCheck {
        store.diskCheck(for: model)
    }

    /// Decimal units, as `LocalModel.approximateSize` and Finder count.
    nonisolated static func size(_ bytes: Int64) -> String {
        // Not "Zero kB" at the start of a download.
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}
