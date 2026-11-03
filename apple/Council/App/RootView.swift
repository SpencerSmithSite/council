import SwiftUI

/// Top-level navigation, matching the Flutter app's `_Area` enum and drawer in
/// lib/main.dart: Ask, Read and Browse are the places the app sits in (Ask
/// first, because asking is what the app is for); Bookmarks, Notes and Chat
/// history are lists you go into and come back from. Search gets the system
/// search tab, which the Flutter app folds into Read.
///
/// Only standard components, so the tab bar on iPhone, the sidebar on iPad and
/// Mac, and their Liquid Glass all come from the system.
struct RootView: View {
    enum Section: Hashable {
        case ask, read, browse, search, bookmarks, notes, history
    }

    @State private var selection: Section = .ask

    var body: some View {
        TabView(selection: $selection) {
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: .ask) {
                ChatView()
            }
            Tab("Read", systemImage: "book", value: .read) {
                ReadView()
            }
            Tab("Browse", systemImage: "square.grid.2x2", value: .browse) {
                BrowseView()
            }

            // Values spelled out as `Section.x`: TabSection's builder is generic
            // over its own selection type, so `.notes` alone can't be inferred.
            TabSection("Library") {
                Tab("Notes", systemImage: "note.text", value: Section.notes) {
                    NotesView()
                }
                // Hidden from the iPhone tab bar, which fits five items; the
                // sidebar on iPad and Mac lists them. Flutter reaches them from
                // its drawer; where they surface on iPhone is a Phase 2 decision.
                Tab("Bookmarks", systemImage: "bookmark", value: Section.bookmarks) {
                    BookmarksView()
                }
                .defaultVisibility(.hidden, for: .tabBar)
                Tab("Chat History", systemImage: "clock.arrow.circlepath", value: Section.history) {
                    ChatHistoryView()
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }

            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

#Preview {
    RootView()
}
