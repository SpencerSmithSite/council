import CouncilCore
import SwiftUI

/// Browse: add and remove bodies of source material. The native counterpart
/// of `BrowseScreen` in lib/src/screens/browse_screen.dart, over
/// `PackLibrary` (Flutter's `PackProvider`).
///
/// The app ships the King James Bible and nothing else. Scripture is what
/// every tradition here argues about, and it makes the app useful before
/// anything has been downloaded; everything else is chosen here.
///
/// One view in every place it appears, as in Flutter (`embedded` there only
/// decided who painted the background and the back button, which the
/// navigation stack does for us): the Browse tab, and pushed from Settings'
/// Content Packs row, from the shelf's "Add More to Your Library" and from
/// the Ask tab's coverage notice. Pushed copies use a plain
/// `NavigationLink { BrowseView() }`; the view needs nothing from its caller.
///
/// A grouped `Form`, top to bottom as Flutter lays it out:
///
/// 1. Why the list couldn't load, or why the last download failed, in the
///    error colour (Flutter's error text).
/// 2. What ships with the app (`_BundledNotice`), stepped aside while
///    searching because it is about the whole library, not a result.
/// 3. The manifest's collections grouped by kind in Flutter's order
///    (`CollectionGroup.grouping`, Flutter's `_grouped`): each with its name,
///    description, what it would cost to add now, and its action.
///
/// Offline, with no manifest, Flutter shows only the error. Here the
/// installed collections are still listed from the local record
/// (`PackLibrary.installedNames`), each with Remove, which is what
/// `PackProvider.refresh`'s own comment says a reader offline should have.
///
/// Refreshes when it appears and on pull, as Flutter refreshes in
/// `initState` and through its `RefreshIndicator`. `.searchable` filters by
/// name and description (`PackCollection.matches`, Flutter's `_matching`).
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    @State private var query = ""

    private var library: PackLibrary { model.packLibrary }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searching: Bool { !trimmedQuery.isEmpty }

    var body: some View {
        content
            .navigationTitle("Browse")
            .councilScreenBackground(grouped: true)
            .searchable(text: $query, prompt: "Search packs")
            // Waits for the pack service, which arrives a moment after the
            // corpus opens on a cold launch.
            .task(id: library.attached) { await library.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .preparing:
            ContentUnavailableView {
                Label("Preparing the Library", systemImage: "books.vertical")
            } description: {
                Text("Setting up the library for the first time.")
            } actions: {
                ProgressView()
            }
        case .failed(let message):
            ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .ready:
            form
        }
    }

    // MARK: - The list

    private var form: some View {
        Form {
            if let error = library.error {
                Section {
                    Label {
                        Text(error).foregroundStyle(palette.error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.error)
                    }
                    .font(.subheadline)
                }
                .councilListRow()
            }

            if !searching {
                Section {
                    BundledNotice()
                }
                .councilListRow()
            }

            if let manifest = library.manifest {
                ForEach(CollectionGroup.grouping(manifest.collections.filter { $0.matches(query) })) { group in
                    Section(group.heading) {
                        ForEach(group.collections, id: \.id) { collection in
                            CollectionRow(
                                id: collection.id,
                                name: collection.name,
                                description: collection.description,
                                bytesToInstall: library.bytesToInstall(collection),
                                install: { Task { await library.install(collection) } }
                            )
                        }
                    }
                    .councilListRow()
                }
                if manifest.collections.isEmpty, !searching {
                    Section {
                        Text("No additional content is published yet.")
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    .councilListRow()
                }
            } else if library.loading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                .councilListRow()
            } else if !offlineInstalled.isEmpty {
                // No manifest (offline, or the catalogue is down): what is
                // installed, from the local record, so it can still be removed.
                Section {
                    ForEach(offlineInstalled, id: \.id) { entry in
                        CollectionRow(id: entry.id, name: entry.name, description: "",
                                      bytesToInstall: 0, install: nil)
                    }
                } header: {
                    Text("Installed")
                } footer: {
                    Text("Connect to the internet to see what else can be added.")
                }
                .councilListRow()
            }
        }
        .formStyle(.grouped)
        .refreshable { await library.refresh() }
        .overlay {
            if searching, nothingMatches {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No packs match “\(trimmedQuery)”.")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    /// Installed collections by name, for the list shown without a manifest.
    private var offlineInstalled: [(id: String, name: String)] {
        library.installedNames
            .map { (id: $0.key, name: $0.value) }
            .filter { PackCollection(id: $0.id, name: $0.name, fragments: []).matches(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var nothingMatches: Bool {
        if let manifest = library.manifest {
            return !manifest.collections.contains { $0.matches(query) }
        }
        return !library.loading && offlineInstalled.isEmpty
    }
}

/// What ships with the app (Flutter's `_BundledNotice`). Stated rather than
/// assumed: a reader looking at a library of things to download should see
/// what they already have without working it out from the absence of a
/// download button.
private struct BundledNotice: View {
    @Environment(\.councilPalette) private var palette

    var body: some View {
        Label {
            Text("The King James Bible is included with the app and is always available offline.")
                .foregroundStyle(palette.secondaryLabel)
        } icon: {
            Image(systemName: "book")
                .foregroundStyle(palette.secondaryLabel)
        }
        .font(.footnote)
    }
}

/// One collection (Flutter's `_PackTile`): the name with, at its trailing
/// edge, a check when installed or what adding it would cost now; the
/// description; then the one action that applies.
///
/// - Busy: progress, and no button. Downloading shows how far it has got,
///   indeterminate until the first bytes arrive so it doesn't sit empty
///   looking stalled while the request connects; removing is a spinner.
/// - Installed: Remove, confirmed first, because re-downloading costs the
///   reader data.
/// - Costs bytes: Download.
/// - Already present through another collection (zero bytes): no button at
///   all, as in Flutter. The header already reads "Already downloaded", and
///   offering a download that would fetch nothing was the bug Flutter fixed.
///
/// While any collection is busy every other button is disabled: one
/// operation at a time, because two concurrent merges would interleave
/// writes to the same tables and index (`PackService`'s rule).
private struct CollectionRow: View {
    let id: String
    let name: String
    let description: String
    let bytesToInstall: Int
    /// Nil where there is no manifest to install from (the offline list).
    let install: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var confirmingRemoval = false

    private var library: PackLibrary { model.packLibrary }
    private var installed: Bool { library.isInstalled(id) }
    private var busy: Bool { library.busyID == id }
    private var blocked: Bool { library.busyID != nil && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
            }
            action
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove \(name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await library.uninstall(id) }
            }
        } message: {
            Text("Anything also included in another collection you have downloaded will be kept.")
        }
    }

    /// Name and status side by side, stacked at accessibility text sizes so
    /// a long name isn't squeezed into a sliver beside the size.
    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(name)
                .font(.headline)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(palette.accent)
                    .imageScale(.large)
            } else if install != nil {
                // What it costs *now*. Zero is common and honest: someone
                // holding Church Fathers already has everything Augustine
                // needs, and quoting a download that won't happen would be a
                // routine small lie.
                Text(bytesToInstall == 0 ? "Already downloaded" : PackManifest.formatBytes(bytesToInstall))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if busy {
            if installed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing…").foregroundStyle(palette.secondaryLabel)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else if library.progress > 0 {
                ProgressView(value: library.progress) {
                    Text("Downloading…").foregroundStyle(palette.secondaryLabel)
                } currentValueLabel: {
                    Text(library.progress, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(palette.secondaryLabel)
                }
                .font(.footnote)
                .padding(.top, 4)
            } else {
                // A spinner rather than an indeterminate bar: iOS draws that
                // as an empty, motionless track, which reads as stalled.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(palette.secondaryLabel)
                }
                .font(.footnote)
                .padding(.top, 4)
            }
        } else if installed {
            Button("Remove", systemImage: "trash", role: .destructive) {
                confirmingRemoval = true
            }
            .buttonStyle(.bordered)
            // The red for the fill and for the symbol: a `Form` row draws a
            // label's icon in the accent, so without the foreground style
            // only the title would be red.
            .tint(palette.error)
            .foregroundStyle(palette.error)
            .disabled(blocked)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let install, bytesToInstall > 0 {
            Button("Download", systemImage: "arrow.down.circle", action: install)
                .buttonStyle(.bordered)
                .tint(palette.accent)
                .disabled(blocked)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

#Preview {
    NavigationStack { BrowseView() }
        .environment(AppModel())
}
