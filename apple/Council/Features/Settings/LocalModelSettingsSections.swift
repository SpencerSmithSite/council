import CouncilCore
import SwiftUI

/// The downloaded model's settings: which size, and downloading, stopping and
/// deleting it. Flutter's `_LocalModelSettings`
/// (lib/src/screens/ai_backend_screen.dart), as three sections:
///
/// - **Model**: the two or three sizes worth offering on this device
///   (`LocalModel.tiers`), labelled by how they fit it rather than by size,
///   the recommended one marked. A single size is described rather than
///   offered, since a picker of one can't be operated.
/// - **The chosen model**: its download, with the disk check, a progress bar
///   with bytes and Cancel while it runs, or the space it uses and Delete.
/// - **Also on this device**: any other model with files here, complete,
///   partial or downloading, so none is left taking space the reader can't
///   see or reclaim.
///
/// The download itself belongs to `InferenceModel.downloads`, not to this
/// view, so it carries on when the reader leaves the screen.
struct LocalModelSettingsSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    let selected: LocalModel
    /// Every catalogue model's files, read by `AIBackendView` off the main
    /// actor whenever `downloads.revision` moves. Read there, on the `Form`,
    /// because a modifier on a `Section` is applied to each of its rows.
    let disk: [String: LocalModelDownloads.DiskState]

    private var downloads: LocalModelDownloads { model.inference.downloads }

    /// Read once per appearance: physical memory doesn't change while the app
    /// runs, and the property is a cheap `ProcessInfo` read.
    private var tiers: [LocalModelOption] { LocalModel.tiers(deviceMemoryMB: LocalDeviceMemory.totalMB()) }

    var body: some View {
        modelSection
        chosenModelSection
        otherModelsSections
    }

    // MARK: - Choosing a size

    /// The tiers, plus the stored choice if it isn't one of them (a size picked
    /// on a device with different memory, or one of the catalogue's other
    /// sizes): unlisted, the picker would show nothing chosen.
    private var rows: [(tier: LocalModelTier?, model: LocalModel)] {
        var rows: [(tier: LocalModelTier?, model: LocalModel)] = tiers.map { ($0.tier, $0.model) }
        if !rows.contains(where: { $0.model == selected }) {
            rows.append((nil, selected))
        }
        return rows
    }

    @ViewBuilder private var modelSection: some View {
        Section {
            if rows.count == 1, let only = rows.first {
                TierRow(tier: nil, model: only.model, state: rowState(only.model))
            } else {
                Picker("Model", selection: Binding(
                    get: { selected.id },
                    set: { model.inference.settings.setLocalModel($0) }
                )) {
                    ForEach(rows, id: \.model.id) { row in
                        TierRow(tier: row.tier, model: row.model, state: rowState(row.model))
                            .tag(row.model.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } header: {
            Text("Model")
        } footer: {
            // Said plainly rather than by hiding the section: a reader whose
            // device is under the floor should know that is why.
            if !selected.fits(deviceMemoryMB: LocalDeviceMemory.totalMB()) {
                Text("\(selected.name) asks for more memory than this device has. It would download and then fail "
                     + "to load — Ollama or an API key will work here instead.")
                    .foregroundStyle(palette.error)
            }
        }
        .councilListRow()
    }

    private func rowState(_ model: LocalModel) -> TierRow.State {
        if let progress = downloads.progress[model.id] { return .downloading(progress.percent) }
        guard let state = disk[model.id] else { return .unknown }
        if state.downloaded { return .downloaded }
        if state.isPartial { return .partial }
        return .notDownloaded
    }

    // MARK: - The chosen model's download

    private var chosenModelSection: some View {
        Section {
            ModelDownloadControls(model: selected, state: disk[selected.id],
                                  deleteMessage: "Council will fall back to search-only answers until you choose "
                                      + "another option, and getting the model back means downloading it again.")
        } header: {
            Text(selected.name)
        } footer: {
            if let failure = downloads.failures[selected.id] {
                Text(failure).foregroundStyle(palette.error)
            } else if let state = disk[selected.id], !state.downloaded, !state.diskCheck.fits,
                      !downloads.isRunning(selected) {
                // Disk is treated differently from memory, as in Flutter: the
                // reader can free space and try again, so the model stays
                // offered with its download blocked and the numbers shown.
                let free = state.diskCheck.freeBytes.map(LocalModelDownloads.size) ?? "less"
                Text("Not enough free space for \(selected.name): it needs \(selected.approximateSize) and this "
                     + "device has \(free) free. Free some up, or choose a smaller model.")
                    .foregroundStyle(palette.error)
            }
        }
        .councilListRow()
    }

    // MARK: - Other models on the device

    private var otherModels: [LocalModel] {
        LocalModel.catalogue.filter { other in
            other != selected && (downloads.isRunning(other) || (disk[other.id]?.bytesOnDisk ?? 0) > 0)
        }
    }

    /// A section each, so each control is a row of its own: several buttons
    /// in one `Form` row would all fire on a tap.
    private var otherModelsSections: some View {
        ForEach(otherModels) { other in
            Section {
                ModelDownloadControls(model: other, state: disk[other.id],
                                      deleteMessage: "Getting it back means downloading it again.",
                                      allowsDownload: false)
            } header: {
                Text("Also on This Device: \(other.name)")
            } footer: {
                if let failure = downloads.failures[other.id] {
                    Text(failure).foregroundStyle(palette.error)
                }
            }
            .councilListRow()
        }
    }
}

// MARK: - A tier

/// One size in the picker: what it is for, then which model and how big, why
/// pick it, and what it takes from memory (Flutter's `TierTitle` and the
/// tier's rationale). The tier leads because it is what the reader is
/// choosing between; a parameter count isn't a decision anyone can make
/// unaided.
private struct TierRow: View {
    enum State: Equatable {
        case unknown, notDownloaded, partial, downloaded
        case downloading(Int)
    }

    @Environment(\.councilPalette) private var palette
    let tier: LocalModelTier?
    let model: LocalModel
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(tier?.label ?? model.name)
                    .fontWeight(tier == .recommended ? .semibold : .regular)
                    .foregroundStyle(tier == .recommended ? palette.accent : palette.text)
                Spacer(minLength: 8)
                stateBadge
            }
            Text("\(model.name) · \(model.approximateSize)")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
            Text(tier?.rationale ?? model.note)
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
            // RAM rather than only disk, because RAM decides whether it runs:
            // the corpus's vector index is already resident beside it.
            InlineIconText("Uses about \(Self.gigabytes(model.ramMB)) of memory while answering",
                           systemImage: "memorychip")
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }

    @ViewBuilder private var stateBadge: some View {
        switch state {
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        case .downloading(let percent):
            Text("\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.secondaryLabel)
        case .partial:
            Text("Paused")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        case .unknown, .notDownloaded:
            EmptyView()
        }
    }

    private static func gigabytes(_ mb: Int) -> String {
        String(format: "%.1f GB", Double(mb) / 1024)
    }
}

// MARK: - Download controls

/// A model's download, whatever state it is in: running (a progress bar with
/// bytes and Cancel), downloaded (the space it uses and Delete), interrupted
/// (what has arrived, Resume and Delete) or not started (Download). Rows of a
/// `Form` section, so they lay out as the platform lays out forms.
private struct ModelDownloadControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.councilPalette) private var palette
    let model: LocalModel
    let state: LocalModelDownloads.DiskState?
    /// The confirmation's second sentence, which depends on whether this is
    /// the chosen model.
    let deleteMessage: String
    /// Whether to offer Download and Resume: only for the chosen model, so
    /// what is downloaded is always what answers.
    var allowsDownload = true

    private var downloads: LocalModelDownloads { app.inference.downloads }

    var body: some View {
        if let progress = downloads.progress[model.id] {
            ProgressView(value: progress.phase == .preparing ? nil : progress.fraction) {
                Text(progress.phase == .preparing
                     ? "Preparing to download \(model.name)…"
                     : "Downloading \(model.name)… \(progress.percent)%")
                    .foregroundStyle(palette.text)
            } currentValueLabel: {
                Text("\(LocalModelDownloads.size(progress.completedBytes)) of "
                     + "\(LocalModelDownloads.size(progress.totalBytes))")
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
            }
            Button("Cancel Download", systemImage: "xmark.circle") {
                downloads.cancel(model)
            }
        } else if let state {
            if state.downloaded {
                LabeledContent("Space Used", value: LocalModelDownloads.size(state.bytesOnDisk))
                    .foregroundStyle(palette.text)
                deleteButton("Delete \(model.name)…", state: state)
            } else {
                if state.isPartial {
                    LabeledContent("Downloaded So Far",
                                   value: "\(LocalModelDownloads.size(state.resumableBytes)) of \(model.approximateSize)")
                        .foregroundStyle(palette.text)
                }
                if allowsDownload {
                    Button(state.isPartial ? "Resume Download" : "Download \(model.approximateSize)",
                           systemImage: "arrow.down.circle") {
                        downloads.start(model)
                    }
                    // Blocked, not hidden, when the disk is short: the footer
                    // gives the numbers.
                    .disabled(!state.diskCheck.fits)
                }
                if state.bytesOnDisk > 0 {
                    deleteButton(state.isPartial ? "Delete Partial Download…" : "Delete \(model.name)…", state: state)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private func deleteButton(_ title: String, state: LocalModelDownloads.DiskState) -> some View {
        DeleteModelButton(title: title, model: model,
                          message: "This frees about \(LocalModelDownloads.size(state.bytesOnDisk)) on this device. "
                              + deleteMessage)
    }
}

// MARK: - Deleting

/// Delete, after asking (Flutter's `_remove`): confirmed rather than
/// immediate because getting the model back means downloading it again,
/// which is what the reader was trying to reclaim. Deletes through
/// `InferenceModel.downloads`, which stops a running download and unloads
/// the model first.
///
/// The dialog hangs off the button itself, a single view, so it is presented
/// once and anchored to what was tapped.
private struct DeleteModelButton: View {
    @Environment(AppModel.self) private var app
    let title: String
    let model: LocalModel
    let message: String

    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        Button(title, systemImage: "trash", role: .destructive) {
            confirming = true
        }
        .confirmationDialog("Remove \(model.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await app.inference.downloads.delete(model)
                    } catch {
                        failure = "Could not remove \(model.name): \(error.localizedDescription)"
                    }
                }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(message)
        }
        .alert("Couldn’t Remove the Model", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

// MARK: - Unsupported devices

/// Shown in place of the downloaded-model option on a device that can't run
/// one: the Simulator, an Intel Mac (Flutter's `_LocalModelUnavailable`).
///
/// It says why, since a missing option on exactly the device where it is
/// missing looks like a bug, and it offers to remove any model already here,
/// which can't run and is only taking space.
struct LocalModelUnavailableSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    let reason: String
    /// As `LocalModelSettingsSections.disk`.
    let disk: [String: LocalModelDownloads.DiskState]

    var body: some View {
        Section {
            ContentUnavailableView {
                Label {
                    Text("Downloaded models are not available on this device")
                        .foregroundStyle(palette.text)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(palette.secondaryLabel)
                }
            } description: {
                Text("\(reason) Ollama or an API key will work here.")
                    .foregroundStyle(palette.secondaryLabel)
            }
            ForEach(LocalModel.catalogue.filter { (disk[$0.id]?.bytesOnDisk ?? 0) > 0 }) { installed in
                let size = LocalModelDownloads.size(disk[installed.id]?.bytesOnDisk ?? 0)
                Text("\(installed.name) is downloaded and unused")
                    .foregroundStyle(palette.text)
                DeleteModelButton(title: "Remove and Free \(size)", model: installed,
                                  message: "This frees about \(size) on this device. It cannot run here, so nothing "
                                      + "is lost by removing it.")
            }
        } header: {
            Text("Downloaded Model")
        }
        .councilListRow()
    }
}
