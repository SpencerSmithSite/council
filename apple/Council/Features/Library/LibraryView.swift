import SwiftUI

/// The lists you go into and come back from: the Flutter app's drawer items.
/// The sidebar shows each as its own tab; the compact tab bar folds them into
/// one Library tab whose root is `LibraryView` (see `RootView`).
enum LibraryDestination: String, Hashable, CaseIterable, Identifiable {
    case notes, bookmarks, history

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .notes: "Notes"
        case .bookmarks: "Bookmarks"
        case .history: "Chat History"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "note.text"
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .notes: NotesView()
        case .bookmarks: BookmarksView()
        case .history: ChatHistoryView()
        }
    }
}

/// The Library tab: a plain list of the three, as Music's Library tab lists
/// Playlists, Artists and Albums on iPhone.
///
/// `path` belongs to `RootView` so that a size-class change can carry the
/// reader across: Notes selected in the iPad sidebar becomes Library → Notes
/// when the window narrows to a tab bar, and back again.
struct LibraryView: View {
    @Binding var path: [LibraryDestination]

    var body: some View {
        NavigationStack(path: $path) {
            List(LibraryDestination.allCases) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.systemImage)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryDestination.self) { $0.content }
            .settingsToolbar()
        }
    }
}

#Preview {
    @Previewable @State var path: [LibraryDestination] = []
    LibraryView(path: $path)
}
