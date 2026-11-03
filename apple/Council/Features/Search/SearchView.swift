import CouncilCore
import SwiftUI

/// The search tab: the Read tab's full-text search over the installed corpus.
///
/// Deliberately minimal, to prove the app is wired to CouncilCore. Grouping by
/// source and jumping into the reader are Phase 4.
struct SearchView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    /// The results and the query they answer, kept together so "no results"
    /// is only shown for the query that actually found nothing, not for one
    /// still being searched.
    @State private var results: (query: String, rows: [ContentUnitRow])?
    @State private var errorMessage: String?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .councilScreenBackground()
            .searchable(text: $query, prompt: "Search the library")
            // Restarts, cancelling the search in flight, whenever the query
            // changes or retrieval becomes available.
            .task(id: SearchKey(query: trimmedQuery, ready: model.retrieval != nil)) {
                await search(trimmedQuery)
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
                ContentUnavailableView("Search the Library", systemImage: "magnifyingglass",
                                       description: Text("Find passages by word, phrase, author or work."))
            } else if let errorMessage {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else if let results, !results.rows.isEmpty {
                List(results.rows) { row in
                    NavigationLink(value: ReadingRoute.passage(id: row.id)) {
                        SearchResultRow(row: row)
                    }
                    .councilListRow()
                }
            } else if let results, results.query == trimmedQuery {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ProgressView()
            }
        }
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
            let rows = try await retrieval.search(text, limit: 40)
            guard !Task.isCancelled else { return }
            results = (text, rows)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct SearchKey: Hashable {
    let query: String
    let ready: Bool
}

private struct SearchResultRow: View {
    let row: ContentUnitRow
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title ?? row.sourceTitle ?? "Untitled")
                .font(.headline)
                .foregroundStyle(palette.text)
            if let source = sourceLine {
                Text(source)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
            }
            if let tradition = row.tradition, !tradition.isEmpty {
                Text(tradition)
                    .font(.caption)
                    // The palette's secondary colour, not `.tertiary`: the
                    // system's tertiary label doesn't know the theme and falls
                    // below legible contrast on darker palettes like Gruvbox.
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
    }

    /// "Work — Author", omitting whichever is missing, and the work when it's
    /// already the row's title.
    private var sourceLine: String? {
        let work = row.sourceTitle == row.title ? nil : row.sourceTitle
        let parts = [work, row.sourceAuthor].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(AppModel())
}
