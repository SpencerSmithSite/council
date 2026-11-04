import CouncilCore
import SwiftUI

/// The Read tab: every installed work, arranged to be read rather than
/// queried. Mirrors the shelf half of `ReadScreen` in
/// lib/src/screens/read_screen.dart (`_Shelf`, `_SourceTile` and the
/// arrangement state around them).
///
/// Branch, then tradition, then works, in the order `Library.shelf()` returns
/// them (the taxonomy's, not the alphabet's). Pinned works are lifted into a
/// section of their own at the top and left out of their tradition, so no
/// work is listed twice. Tradition sections collapse, and start collapsed on a
/// shelf the reader has never arranged (`ShelfStore.applyDefaultCollapse`):
/// a dozen open sections is a screen of scrolling before the shape of the
/// library is visible, and collapsed it all fits at once.
///
/// The collapsible sections are `Section(isExpanded:)` in the sidebar list
/// style, the style in which the system draws the disclosure chevron in the
/// header, as the Files app's Browse list does on iPhone.
///
/// Typing in the search field filters the shelf by title, author and
/// tradition (Flutter's `_filtered`). In Flutter, submitting the same field
/// ran a full-text search inside the passages; here that is the Search tab's
/// job, so this offers "Search Passages for …" instead, which hands the
/// query to the Search tab (`AppModel.requestSearch`).
struct ReadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    /// Nil until the first load finishes.
    @State private var sources: [ShelfSource]?
    @State private var loadError: String?

    // The persisted arrangement, held here and applied on the spot; the store
    // is written afterwards (see `record`).
    @State private var pinned: Set<Int> = []
    @State private var starred: Set<Int> = []
    @State private var collapsed: Set<String> = []
    @State private var arrangementLoaded = false

    /// Narrows the shelf to starred works. Deliberately not persisted, as in
    /// Flutter: a filter that survived a relaunch would greet the reader with
    /// most of their library missing and only a toolbar glyph to explain why.
    @State private var starredOnly = false
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the shelf is showing a subset of what is installed. Sections
    /// are held open while it is: a collapsed section under a filter would
    /// hide the very rows the reader narrowed the shelf to find, which reads
    /// as "no results" when there are results. The reader's own collapsed
    /// arrangement is untouched and comes back when the filter lifts.
    private var narrowed: Bool { starredOnly || !trimmedQuery.isEmpty }

    var body: some View {
        content
            .navigationTitle("Read")
            // Said under the title too, because where the toolbar is short of
            // room (beside the iPad's floating tab bar) the filter button can
            // move into the overflow menu, taking its filled star with it.
            .navigationSubtitle(starredOnly ? "Starred works" : "")
            .councilScreenBackground(grouped: true)
            .searchable(text: $query, prompt: "Titles, authors, traditions")
            .toolbar { toolbarContent }
            // Reloads when the corpus opens and whenever a pack changes what
            // is installed, so a download shows up without a pull to refresh.
            .task(id: ShelfKey(ready: model.library != nil, revision: model.contentRevision)) {
                await load()
            }
    }

    // MARK: - Content

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
            if let loadError {
                ContentUnavailableView("Shelf Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if let sources {
                let visible = filtered(sources)
                if visible.isEmpty {
                    emptyState(installed: !sources.isEmpty)
                } else {
                    shelfList(visible)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func shelfList(_ visible: [ShelfSource]) -> some View {
        let layout = ShelfLayout(visible, pinned: pinned)
        return List {
            if !trimmedQuery.isEmpty {
                Section { searchPassagesButton }
                    .councilListRow()
            }

            // Always shown when unfiltered, even empty: pinning is the shelf's
            // main arrangement gesture and it is invisible, so without a
            // labelled place for pinned works to land nothing on screen
            // suggests the gesture exists.
            if !layout.pinned.isEmpty || !narrowed {
                Section {
                    if layout.pinned.isEmpty {
                        PinnedPlaceholder()
                            .councilListRow()
                    } else {
                        ForEach(layout.pinned) { row($0) }
                    }
                } header: {
                    ShelfSectionHeader(title: "Pinned", count: layout.pinned.isEmpty ? nil : layout.pinned.count)
                }
            }

            ForEach(layout.branches) { branch in
                // Not collapsible, as in Flutter: the collapsed set is stored
                // by name, and a branch can share its name with the tradition
                // inside it. Left out where it would only repeat that name.
                if branch.showsHeader {
                    Section {} header: {
                        BranchHeader(title: branch.name)
                    }
                }
                ForEach(branch.traditions) { tradition in
                    if narrowed {
                        // A plain section: no chevron offering a collapse that
                        // a filter would refuse.
                        Section {
                            ForEach(tradition.works) { row($0) }
                        } header: {
                            ShelfSectionHeader(title: tradition.name, count: tradition.works.count)
                        }
                    } else {
                        Section(isExpanded: expansion(of: tradition.name)) {
                            ForEach(tradition.works) { row($0) }
                        } header: {
                            ShelfSectionHeader(title: tradition.name, count: tradition.works.count)
                        }
                    }
                }
            }
            // Flutter's footer button. With Scripture alone the shelf is one
            // book, and the reason isn't obvious from an otherwise working
            // screen; this says where the rest comes from.
            if !narrowed {
                Section {
                    NavigationLink {
                        BrowseView()
                    } label: {
                        Label("Add More to Your Library", systemImage: "plus")
                            .foregroundStyle(palette.accent)
                    }
                }
                .councilListRow()
            }
        }
        .listStyle(.sidebar)
        .refreshable { await load() }
    }

    private func row(_ source: ShelfSource) -> some View {
        let isPinned = pinned.contains(source.id)
        let isStarred = starred.contains(source.id)
        return NavigationLink(value: ReadingRoute.source(id: source.id, title: source.title)) {
            ShelfRow(source: source, isStarred: isStarred)
        }
        // Swipe right to pin, left to star, as in Flutter. Both toggle and
        // leave the row where it is (pinning moves it, by design).
        .swipeActions(edge: .leading) {
            pinButton(source.id, isPinned: isPinned)
                .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            starButton(source.id, isStarred: isStarred)
                .tint(palette.accent)
        }
        .contextMenu {
            pinButton(source.id, isPinned: isPinned)
            starButton(source.id, isStarred: isStarred)
        }
        .councilListRow()
    }

    private func pinButton(_ id: Int, isPinned: Bool) -> some View {
        Button {
            withAnimation { togglePin(id) }
        } label: {
            Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
        }
    }

    private func starButton(_ id: Int, isStarred: Bool) -> some View {
        Button {
            withAnimation { toggleStar(id) }
        } label: {
            Label(isStarred ? "Unstar" : "Star", systemImage: isStarred ? "star.slash" : "star")
        }
    }

    /// Which nothing this is matters, as in Flutter: a filter hiding
    /// everything needs a way out, and a reader who has never starred anything
    /// needs to be told what starring is rather than shown an empty result.
    @ViewBuilder
    private func emptyState(installed: Bool) -> some View {
        if starredOnly {
            ContentUnavailableView {
                Label(starred.isEmpty ? "No Starred Works" : "No Matches", systemImage: "star")
            } description: {
                if starred.isEmpty {
                    Text("Swipe a work to the left to star it, and it will be listed here.")
                } else if !trimmedQuery.isEmpty {
                    Text("No starred work matches “\(trimmedQuery)”.")
                } else {
                    Text("No starred works are on your shelf.")
                }
            } actions: {
                Button("Show All Works") { starredOnly = false }
            }
        } else if !trimmedQuery.isEmpty {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing on your shelf matches “\(trimmedQuery)”.")
            } actions: {
                searchPassagesButton
            }
        } else if !installed {
            ContentUnavailableView {
                Label("Nothing Installed Yet", systemImage: "books.vertical")
            } description: {
                Text("Works you add to your library will appear here.")
            } actions: {
                // The way to fill it, worded as Flutter's Read tab words the
                // same button under "Nothing found in what you have installed."
                NavigationLink("Browse Collections") { BrowseView() }
            }
        }
    }

    /// The words typed here, searched for inside the texts rather than
    /// among the titles: what submitting this field did in Flutter's Read
    /// tab, now the Search tab's job.
    private var searchPassagesButton: some View {
        Button("Search Passages for “\(trimmedQuery)”", systemImage: "text.magnifyingglass") {
            model.requestSearch(trimmedQuery)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // The filled glyph is the filter's visible state: the shelf is
            // hiding most of the library and the reason has to show, or the
            // missing works read as a bug rather than a filter.
            Button {
                withAnimation { starredOnly.toggle() }
            } label: {
                Label(starredOnly ? "Show All Works" : "Show Starred Only",
                      systemImage: starredOnly ? "star.fill" : "star")
            }
            .disabled(sources == nil)
        }
        // Under a filter every section is held open, so the control would have
        // nothing to act on.
        if !narrowed && !traditionNames.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    withAnimation { toggleCollapseAll() }
                } label: {
                    if allCollapsed {
                        Label("Expand All", systemImage: "rectangle.expand.vertical")
                    } else {
                        Label("Collapse All", systemImage: "rectangle.compress.vertical")
                    }
                }
            }
        }
    }

    // MARK: - Arrangement

    /// The shelf narrowed by the starred filter and the search field. The text
    /// match covers title, author and tradition, because a reader hunting for
    /// Augustine may type any of the three.
    private func filtered(_ all: [ShelfSource]) -> [ShelfSource] {
        var shown = all
        if starredOnly {
            shown = shown.filter { starred.contains($0.id) }
        }
        let needle = trimmedQuery.lowercased()
        guard !needle.isEmpty else { return shown }
        return shown.filter { source in
            [source.title, source.author, source.tradition]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    /// Every tradition that has a (non-pinned) section on the unfiltered
    /// shelf: the set "Collapse All" acts on.
    private var traditionNames: Set<String> {
        Set((sources ?? []).filter { !pinned.contains($0.id) }.map(\.tradition))
    }

    private var allCollapsed: Bool {
        let names = traditionNames
        return !names.isEmpty && names.isSubset(of: collapsed)
    }

    private func expansion(of tradition: String) -> Binding<Bool> {
        Binding {
            !collapsed.contains(tradition)
        } set: { expanded in
            var next = collapsed
            if expanded { next.remove(tradition) } else { next.insert(tradition) }
            collapsed = next
            model.shelf.setCollapsed(next)
        }
    }

    // Every gesture below changes the state first and writes after, as in
    // Flutter, where awaiting the write first put a platform-channel hop
    // between the tap and the section opening. Here the write is a
    // `UserDefaults` set, cheap but still not something the frame should wait
    // on; if it somehow failed the shelf would still be right for this session
    // and revert on the next launch.

    private func togglePin(_ id: Int) {
        let next = pinned.symmetricDifference([id])
        pinned = next
        model.shelf.setPinned(next)
    }

    private func toggleStar(_ id: Int) {
        let next = starred.symmetricDifference([id])
        starred = next
        model.shelf.setStarred(next)
    }

    /// Collapse everything, or expand everything if it is all collapsed.
    private func toggleCollapseAll() {
        let next = allCollapsed ? [] : traditionNames
        collapsed = next
        model.shelf.setCollapsed(next)
    }

    // MARK: - Loading

    private func load() async {
        guard let library = model.library else { return }
        // The stored arrangement first, and only once: it has to be in hand
        // before the default collapse is decided (Flutter's `_restoreShelf`),
        // and after that this screen's state is the truth.
        if !arrangementLoaded {
            pinned = model.shelf.pinned()
            starred = model.shelf.starred()
            collapsed = model.shelf.collapsed()
            arrangementLoaded = true
        }
        do {
            let rows = try await library.shelf()
            sources = rows
            loadError = nil
            applyDefaultCollapse()
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Start collapsed until the reader says otherwise. Runs after every load,
    /// so a tradition that only just arrived with a pack starts collapsed too
    /// rather than being the one section left hanging open.
    private func applyDefaultCollapse() {
        guard !model.shelf.hasArrangedSections() else { return }
        let names = traditionNames
        guard !names.isEmpty else { return }
        collapsed = names
        model.shelf.applyDefaultCollapse(names)
    }
}

private struct ShelfKey: Hashable {
    let ready: Bool
    let revision: Int
}

/// The visible works grouped for display: pinned ones lifted out, the rest by
/// branch then tradition, both in the order the query returned them.
private struct ShelfLayout {
    struct Tradition: Identifiable {
        let branch: String
        let name: String
        var works: [ShelfSource]
        var id: String { branch + "\u{1F}" + name }
    }

    struct Branch: Identifiable {
        let name: String
        var traditions: [Tradition]
        var id: String { name }

        /// Whether the branch needs a heading of its own, or would only repeat
        /// the one tradition inside it (Eastern Orthodox inside Eastern
        /// Orthodox). Flutter's `_showsBranchHeader`.
        var showsHeader: Bool { !(traditions.count == 1 && traditions[0].name == name) }
    }

    let pinned: [ShelfSource]
    let branches: [Branch]

    init(_ sources: [ShelfSource], pinned ids: Set<Int>) {
        pinned = sources.filter { ids.contains($0.id) }
        var branches: [Branch] = []
        for source in sources where !ids.contains(source.id) {
            if branches.last?.name != source.branch {
                branches.append(Branch(name: source.branch, traditions: []))
            }
            let last = branches.count - 1
            if branches[last].traditions.last?.name != source.tradition {
                branches[last].traditions.append(Tradition(branch: source.branch, name: source.tradition, works: []))
            }
            branches[last].traditions[branches[last].traditions.count - 1].works.append(source)
        }
        self.branches = branches
    }
}

/// A tradition's (or Pinned's) header: its name and how many works it holds.
private struct ShelfSectionHeader: View {
    let title: String
    let count: Int?
    @Environment(\.councilPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            if let count {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
                    .accessibilityLabel(count == 1 ? "1 work" : "\(count) works")
            }
        }
    }
}

/// The name of a branch of the church, over the traditions inside it. Small
/// letter-spaced capitals in the accent, as in Flutter, so it outranks the
/// tradition headings below it without competing with the large title.
private struct BranchHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(.tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Pinned section with nothing in it: the instruction for the gesture
/// that fills it.
private struct PinnedPlaceholder: View {
    @Environment(\.councilPalette) private var palette

    var body: some View {
        Label {
            #if os(macOS)
            Text("Swipe a work right, or right-click it, to pin it here.")
            #else
            Text("Swipe a work right, or touch and hold it, to pin it here.")
            #endif
        } icon: {
            Image(systemName: "pin")
        }
        .font(.subheadline)
        .foregroundStyle(palette.secondaryLabel)
    }
}

/// A work on the shelf: title, then author, date and size, and a star when
/// it's starred. Flutter's `_SourceTile`.
private struct ShelfRow: View {
    let source: ShelfSource
    let isStarred: Bool
    @Environment(\.councilPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title.isEmpty ? "Untitled" : source.title)
                    .foregroundStyle(palette.text)
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 0)
            if isStarred {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Starred")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Augustine · c. 400 · 13 sections", leaving out whatever is missing.
    private var details: String {
        let units = source.units == 1 ? "1 section" : "\(source.units.formatted()) sections"
        return [source.author, source.dateComposed, units]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}

#Preview {
    NavigationStack { ReadView() }
        .environment(AppModel())
}
