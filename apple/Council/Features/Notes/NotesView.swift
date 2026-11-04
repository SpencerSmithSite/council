import CouncilCore
import SwiftUI

/// Everything the reader has written or marked, newest first. Mirrors
/// `NotesScreen` in lib/src/screens/notes_screen.dart.
///
/// Two lists rather than one, switched by a segmented control, as Flutter's
/// two tabs: a note is a thought and is opened to be read again; a highlight
/// is emphasis and is opened to get back to the page. Mixing them would bury
/// the handful of notes under the marks, since highlighting is by far the
/// cheaper gesture.
///
/// Notes are ordered by when they were last written in (`allNotes`), so a note
/// the reader came back to is live again; highlights by when they were made.
/// Tapping a note opens it in the editor; tapping a highlight opens its
/// passage, as Flutter's `ContentDetailScreen` push does.
///
/// The search field is new: Flutter has none. It filters the list showing by
/// the words of the note, the quotation, the reference and the work.
struct NotesView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case notes, highlights
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .notes: "Notes"
            case .highlights: "Highlights"
            }
        }
    }

    @Environment(AppModel.self) private var model

    @State private var kind: Kind = .notes
    /// Nil until the first load finishes.
    @State private var notes: [Note]?
    @State private var highlights: [Highlight]?
    @State private var loadError: String?
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        content
            .navigationTitle("Notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .councilScreenBackground()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .searchable(text: $query, prompt: kind == .notes ? "Search notes" : "Search highlights")
            // Every highlight or note write, from any screen, moves the
            // revision, so a note edited in the reader's sheet or deleted in
            // its editor is reflected here without a pull to refresh.
            .task(id: NotesKey(ready: model.annotations != nil, revision: model.annotationsRevision)) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.annotations == nil {
            // The user database failed to open, or the app is still starting.
            switch model.state {
            case .preparing:
                ProgressView()
            default:
                ContentUnavailableView("Notes Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Your notes and highlights couldn’t be opened."))
            }
        } else if let loadError {
            ContentUnavailableView("Notes Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else {
            switch kind {
            case .notes: notesList
            case .highlights: highlightsList
            }
        }
    }

    @ViewBuilder
    private var notesList: some View {
        if let notes {
            let shown = notes.filter { matches([$0.body, $0.quote, $0.reference, $0.sourceTitle]) }
            if notes.isEmpty {
                ContentUnavailableView("No Notes Yet", systemImage: "note.text",
                                       description: Text("While reading, tap a verse or paragraph and choose Note to write about it."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                List(shown) { note in
                    NavigationLink(value: ReadingRoute.note(id: note.id)) {
                        NoteRow(note: note)
                    }
                    .deleteWithConfirmation(title: "Delete this note?") {
                        await delete(note: note)
                    }
                    .councilListRow()
                }
                .refreshable { await load() }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var highlightsList: some View {
        if let highlights {
            let shown = highlights.filter { matches([$0.quote, $0.reference, $0.sourceTitle]) }
            if highlights.isEmpty {
                ContentUnavailableView("Nothing Highlighted Yet", systemImage: "highlighter",
                                       description: Text("Tap a verse or paragraph while reading, then choose a colour."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                List(shown) { highlight in
                    NavigationLink(value: ReadingRoute.passage(id: highlight.contentUnitId)) {
                        HighlightRow(highlight: highlight)
                    }
                    .deleteWithConfirmation(title: "Delete this highlight?") {
                        await delete(highlight: highlight)
                    }
                    .councilListRow()
                }
                .refreshable { await load() }
            }
        } else {
            ProgressView()
        }
    }

    private func matches(_ fields: [String?]) -> Bool {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(needle) == true }
    }

    // MARK: - Data

    private func load() async {
        guard let store = model.annotations else { return }
        do {
            let loadedNotes = try await store.allNotes()
            let loadedHighlights = try await store.allHighlights()
            notes = loadedNotes
            highlights = loadedHighlights
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    // Removed from the list on the spot, so the row animates out with the
    // swipe; the write's change notification then reloads the list from the
    // database, which agrees.

    private func delete(note: Note) async {
        guard let store = model.annotations else { return }
        withAnimation { notes?.removeAll { $0.id == note.id } }
        try? await store.deleteNote(id: note.id)
    }

    private func delete(highlight: Highlight) async {
        guard let store = model.annotations else { return }
        withAnimation { highlights?.removeAll { $0.id == highlight.id } }
        try? await store.deleteHighlight(id: highlight.id)
    }
}

private struct NotesKey: Hashable {
    let ready: Bool
    let revision: Int
}

/// "Romans 8:28 · The Holy Bible · Yesterday", leaving out what's missing.
/// Flutter's `_caption`.
private func caption(reference: String?, source: String?, date: Date) -> String {
    [reference, source, RelativeDate.format(date)]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: " · ")
}

/// A note: what the reader wrote, the quotation it's about, and where and
/// when. The reader's own words lead, because they're what the list is
/// scanned for.
private struct NoteRow: View {
    let note: Note
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.body.isEmpty ? "No text" : note.body)
                .font(.body.weight(.medium))
                .foregroundStyle(note.body.isEmpty ? palette.secondaryLabel : palette.text)
                .lineLimit(2)
            if let quote = note.quote, !quote.isEmpty {
                Text("“\(quote)”")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(2)
            }
            Text(caption(reference: note.reference, source: note.sourceTitle, date: note.updatedAt))
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }
        .padding(.vertical, 2)
    }
}

/// A highlight: its colour, the words marked, and where and when.
private struct HighlightRow: View {
    let highlight: Highlight
    @Environment(\.councilPalette) private var palette
    @ScaledMetric(relativeTo: .body) private var swatchHeight = 36

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            let colour = HighlightColour.fromID(highlight.colour)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(rgba: colour.resolve(dark: palette.brightness == .dark)))
                // A hairline so the pale light-mode washes still show on a
                // white row.
                .strokeBorder(palette.separator, lineWidth: 0.5)
                .frame(width: 12, height: swatchHeight)
                .accessibilityLabel(colour.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.quote)
                    .foregroundStyle(palette.text)
                    .lineLimit(3)
                Text(caption(reference: highlight.reference, source: highlight.sourceTitle,
                             date: highlight.createdAt))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
    }
}

extension View {
    /// A Delete swipe action and context menu item that ask first, as
    /// Flutter's `_confirmDelete` does ("This cannot be undone."). `message`
    /// is for screens whose Flutter dialog words it differently (Chat
    /// History's "The whole thread will be removed.").
    ///
    /// The swipe button is tinted red rather than given the destructive role:
    /// a destructive swipe action slides the row away before the question is
    /// answered, and a Cancel would then have to bring it back.
    func deleteWithConfirmation(title: LocalizedStringKey, message: LocalizedStringKey = "This cannot be undone.",
                                perform: @escaping @MainActor () async -> Void) -> some View {
        modifier(DeleteWithConfirmation(title: title, message: message, perform: perform))
    }
}

private struct DeleteWithConfirmation: ViewModifier {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let perform: @MainActor () async -> Void
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                Button {
                    asking = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                Button(role: .destructive) {
                    asking = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            // On the row, so on iPad and Mac it points at what is going.
            .confirmationDialog(title, isPresented: $asking, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await perform() }
                }
            } message: {
                Text(message)
            }
    }
}

#Preview {
    NavigationStack { NotesView() }
        .environment(AppModel())
}
