import CouncilCore
import SwiftUI

/// The Search tab: full-text search over everything installed, grouped by
/// work, each result opening the reader at the words it found.
///
/// Mirrors the search half of the Flutter Read tab (`_search` and `_Results`
/// in lib/src/screens/read_screen.dart): the same query, `search(text,
/// limit: 40)`, FTS5 with the LIKE fallback. What's shown differs. Flutter
/// lists the forty units flat, each with its first 160 characters, and opens
/// the passage on its own; here the units are grouped under their work (in
/// the order of each work's best match), each shows the verse or paragraph
/// that matched with the matched words in bold (`SearchSnippet`), and a tap
/// opens the whole work in the reader scrolled to the first match, with the
/// matches marked (`ReadingRoute.source(find:)`).
///
/// With nothing typed it offers the recent searches, as the system's own
/// search screens do.
///
/// The query belongs to `RootView`, so the shelf's "Search Passages for …"
/// can fill it in. The field is pinned open under the title on iPhone and
/// iPad: by default a large title over a list folds the field away until the
/// list is pulled down, which on a screen whose whole purpose is the field
/// left nothing to type into. (The iOS 26 search tab that turns into a field
/// in the tab bar would be better still; see apple/PLAN.md, Phase 4.)
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    @Binding var query: String
    /// The results and the query they answer, kept together so "no results"
    /// is only shown for the query that actually found nothing, not for one
    /// still being searched.
    @State private var results: SearchResults?
    @State private var errorMessage: String?
    @State private var recents: [String] = []

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .councilScreenBackground(grouped: true)
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Words, phrases, names")
            #else
            .searchable(text: $query, prompt: "Words, phrases, names")
            #endif
            .onSubmit(of: .search) { remember(trimmedQuery) }
            // Restarts, cancelling the search in flight, whenever the query
            // changes or retrieval becomes available.
            .task(id: SearchKey(query: trimmedQuery, ready: model.retrieval != nil)) {
                await search(trimmedQuery)
            }
            // The shelf records the searches it hands over, so re-read when
            // the list comes back into view.
            .onChange(of: trimmedQuery.isEmpty, initial: true) { _, empty in
                if empty { recents = model.recentSearches.all() }
            }
            // A search that found something and was then left (a result
            // opened, another tab chosen) is one worth offering again. Not a
            // tap gesture on the rows: on a List row's link it takes the tap
            // and the link never opens.
            .onDisappear {
                if let results, results.query == trimmedQuery, !results.groups.isEmpty {
                    remember(results.query)
                }
            }
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
            if trimmedQuery.isEmpty {
                if recents.isEmpty {
                    ContentUnavailableView("Search the Library", systemImage: "magnifyingglass",
                                           description: Text("Find passages by word, phrase, author or work."))
                } else {
                    recentList
                }
            } else if let errorMessage {
                // Said as a sentence, as Flutter does: a query that failed is
                // not a query that found nothing.
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else if let results, !results.groups.isEmpty {
                resultList(results)
            } else if let results, results.query == trimmedQuery {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Results

    private func resultList(_ results: SearchResults) -> some View {
        List {
            ForEach(results.groups) { group in
                Section {
                    ForEach(group.results) { result in
                        NavigationLink(value: ReadingRoute.source(id: group.sourceID, title: group.title,
                                                                  unitID: result.id, find: results.hits)) {
                            SearchResultRow(result: result)
                        }
                        .councilListRow()
                    }
                } header: {
                    SearchGroupHeader(group: group)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var recentList: some View {
        List {
            Section {
                ForEach(recents, id: \.self) { recent in
                    Button {
                        query = recent
                    } label: {
                        Label(recent, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(palette.text)
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            model.recentSearches.remove(recent)
                            recents = model.recentSearches.all()
                        }
                    }
                    .councilListRow()
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") {
                        model.recentSearches.clear()
                        recents = []
                    }
                    .font(.subheadline)
                    .textCase(nil)
                }
            }
        }
    }

    private func remember(_ query: String) {
        guard !query.isEmpty else { return }
        model.recentSearches.record(query)
        recents = model.recentSearches.all()
    }

    private func search(_ text: String) async {
        guard !text.isEmpty, let retrieval = model.retrieval else {
            results = nil
            errorMessage = nil
            return
        }
        // A short pause so typing a word runs one search, not one per letter;
        // the sleep throws when the next keystroke cancels this task.
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }

        do {
            // The Read tab's limit in the Flutter app.
            let search = try await retrieval.lexicalSearch(text, limit: 40)
            let built = await SearchResults.build(query: text, search: search)
            guard !Task.isCancelled else { return }
            results = built
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong searching for that. Try different wording."
        }
    }
}

private struct SearchKey: Hashable {
    let query: String
    let ready: Bool
}

// MARK: - Model

/// One search's answer, arranged for the screen.
private struct SearchResults: Sendable {
    let query: String
    let hits: SearchHits
    let groups: [SearchGroup]

    /// Groups the rows under their work, in the order each work first
    /// appears (so the work with the best match leads), keeping the search's
    /// own order inside each, and cuts each row's snippet.
    ///
    /// Off the main actor: forty chapters segmented and scanned is real work.
    /// Short enough to fit the row's four lines on an iPhone. A hit near
    /// the end of a long paragraph pins the window to the paragraph's end,
    /// and with the default length the row's line limit then cut the hit
    /// itself off ("incar…").
    nonisolated static let snippetLength = 150

    @concurrent
    nonisolated static func build(query: String, search: LexicalSearch) async -> SearchResults {
        let hits = SearchHits(query: query, search: search)
        var order: [Int] = []
        var groups: [Int: SearchGroup] = [:]
        for row in search.rows {
            // The search joins `sources`, so every row has one; -1 keeps a
            // row the schema let through without one rather than dropping it.
            let sourceID = row.sourceId ?? -1
            let result = SearchResult(
                id: row.id, title: row.title ?? "Untitled",
                snippet: SearchSnippet(content: row.content, passage: SegmentedPassage(row.content),
                                       hits: hits.ranges(in: row.content), maxLength: snippetLength))
            if groups[sourceID] == nil {
                order.append(sourceID)
                groups[sourceID] = SearchGroup(sourceID: sourceID, title: row.sourceTitle ?? "Untitled",
                                               author: row.sourceAuthor, tradition: row.tradition, results: [])
            }
            groups[sourceID]?.results.append(result)
        }
        return SearchResults(query: query, hits: hits, groups: order.compactMap { groups[$0] })
    }
}

private struct SearchGroup: Sendable, Identifiable {
    let sourceID: Int
    let title: String
    let author: String?
    let tradition: String?
    var results: [SearchResult]

    var id: Int { sourceID }
}

private struct SearchResult: Sendable, Identifiable {
    let id: Int
    let title: String
    let snippet: SearchSnippet
}

// MARK: - Rows

private struct SearchGroupHeader: View {
    let group: SearchGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .textCase(nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "Author · Tradition", whichever are known and not just the title again.
    private var detail: String? {
        let parts = [group.author, group.tradition].compactMap { part -> String? in
            guard let part, !part.isEmpty, part != group.title else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .font(.headline)
                .foregroundStyle(palette.text)
            Text(snippet)
                .font(.subheadline)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
    }

    /// The matching verse: its number in the accent, the text in the
    /// secondary colour, and the matched words in bold in the text colour so
    /// they stand out the way a find does.
    private var snippet: AttributedString {
        let snippet = result.snippet
        var out = AttributedString()
        if let number = snippet.number {
            var marker = AttributedString("\(number) ")
            marker.foregroundColor = palette.accent
            marker.font = .subheadline.weight(.bold)
            out += marker
        }
        if snippet.leadingEllipsis { out += plain("…") }

        let units = Array(snippet.text.utf16)
        var cursor = 0
        for hit in snippet.hits where hit.lowerBound >= cursor && hit.upperBound <= units.count {
            out += plain(String(decoding: units[cursor..<hit.lowerBound], as: UTF16.self))
            var word = AttributedString(String(decoding: units[hit], as: UTF16.self))
            word.foregroundColor = palette.text
            word.font = .subheadline.weight(.semibold)
            out += word
            cursor = hit.upperBound
        }
        out += plain(String(decoding: units[cursor...], as: UTF16.self))
        if snippet.trailingEllipsis { out += plain("…") }
        return out
    }

    private func plain(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = palette.secondaryLabel
        return run
    }
}

#Preview {
    @Previewable @State var query = "grace"
    NavigationStack { SearchView(query: $query) }
        .environment(AppModel())
}
