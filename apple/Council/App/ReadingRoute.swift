import CouncilCore
import SwiftUI

/// Everywhere a screen can push into the reading screens: a work in the
/// reader, a single passage, a note.
///
/// Values rather than destination views, so a row anywhere (the shelf, a
/// bookmark, a note, later a search hit or a citation) can say where it goes
/// with `NavigationLink(value:)` and every stack shows it the same way. Each
/// `NavigationStack` root registers the destinations with
/// `.readingDestinations()`; a stack without it ignores the link.
enum ReadingRoute: Hashable {
    /// A work, in the continuous-scroll reader. Opens at the section holding
    /// `unitID` when given, otherwise where the reader last stopped. With
    /// `find` (a search result), the search's words are marked in that
    /// section and the first is scrolled into view.
    case source(id: Int, title: String, unitID: Int? = nil, find: SearchHits? = nil)
    /// One passage on its own, with its provenance, tags and bookmark.
    case passage(id: Int)
    case note(id: Int)
}

extension View {
    /// Registers `ReadingRoute` on the enclosing `NavigationStack`. Apply once
    /// per stack, on its root view.
    func readingDestinations() -> some View {
        navigationDestination(for: ReadingRoute.self) { route in
            switch route {
            case .source(let id, let title, let unitID, let find):
                SourceReaderView(sourceID: id, title: title, initialUnitID: unitID, find: find)
            case .passage(let id):
                ContentDetailView(contentID: id)
            case .note(let id):
                NoteEditorView(noteID: id)
            }
        }
    }
}
