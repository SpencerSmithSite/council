import SwiftUI

/// Top-level navigation, matching the Flutter app's `_Area` enum and drawer in
/// lib/main.dart: Ask, Read and Browse are the places the app sits in (Ask
/// first, because asking is what the app is for); Notes, Bookmarks and Chat
/// History are lists you go into and come back from. Search gets the system
/// search tab, which the Flutter app folds into Read.
///
/// Only standard components, so the tab bar on iPhone, the sidebar on iPad and
/// Mac, and their Liquid Glass all come from the system.
///
/// ## Where the Library lives
///
/// Notes, Bookmarks and Chat History are a `TabSection`. Where there's room
/// the system does the right thing with it by itself: the sidebar (iPad, Mac)
/// lists them under a Library heading, and the regular-width iPad tab bar
/// shows the section as one "Library" item. The compact tab bar (iPhone, and
/// iPad in narrow multitasking) is the problem: it flattens the section into
/// separate tabs, and past five tabs it adds the UIKit-era "More" tab and
/// moves them into it. `defaultVisibility(.hidden, for: .tabBar)` doesn't stop
/// that (checked on the iOS 27.2 simulator, where Phase 0's shell got a More tab).
///
/// So in compact width the three tabs are `.hidden` and a single Library tab,
/// whose root lists them, takes their place, as Music's Library tab does on
/// iPhone. Every tab stays declared at every width and only visibility
/// changes, so SwiftUI keeps each tab's identity and navigation state across
/// an iPad resize; swapping between two tab lists by size class would rebuild
/// them all.
///
/// The selection has to follow, because UIKit asserts if the selected tab is
/// hidden: see `visibleSelection`. Notes in the sidebar becomes Library → Notes
/// in the compact tab bar, and back.
///
/// Every feature view is content only. The tab supplies its NavigationStack
/// and the Settings gear, so the same view can also be pushed inside the
/// Library tab's stack without nesting stacks.
struct RootView: View {
    enum Section: Hashable {
        case ask, read, browse, library, search
        case list(LibraryDestination)
    }

    @State private var selection: Section = .ask
    @State private var libraryPath: [LibraryDestination] = []

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: .ask) {
                NavigationStack { ChatView().settingsToolbar().readingDestinations() }
            }
            Tab("Read", systemImage: "book", value: .read) {
                NavigationStack { ReadView().settingsToolbar().readingDestinations() }
            }
            Tab("Browse", systemImage: "square.grid.2x2", value: .browse) {
                NavigationStack { BrowseView().settingsToolbar().readingDestinations() }
            }

            // Compact width only: the tab bar's stand-in for the section below.
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView(path: $libraryPath)
            }
            .hidden(!isCompact)

            // Values spelled out as `Section.x`: TabSection's builder is generic
            // over its own selection type, so `.list(...)` alone can't be inferred.
            TabSection("Library") {
                ForEach(LibraryDestination.allCases) { destination in
                    Tab(destination.title, systemImage: destination.systemImage,
                        value: Section.list(destination)) {
                        NavigationStack { destination.content.settingsToolbar().readingDestinations() }
                    }
                    .hidden(isCompact)
                }
            }

            Tab(value: .search, role: .search) {
                NavigationStack { SearchView().settingsToolbar().readingDestinations() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        // The iPhone tab bar shrinks while reading down a list, as in Music
        // and News, and comes back on scrolling up.
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: sizeClass, initial: true) { _, _ in
            adoptVisibleSelection()
        }
        #endif
    }

    /// Whether the tab bar is the compact one, which gets the Library tab in
    /// place of the section. Never on the Mac, whose window always has room.
    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// `selection` mapped onto a tab that is visible at this width: a list
    /// becomes Library with that list pushed, and Library becomes the list it
    /// has pushed (or Notes).
    ///
    /// The TabView is only ever shown this, never `selection` itself, because
    /// UIKit asserts if the selected tab is hidden, even for one frame, and a
    /// resize hides tabs in the same update that changes the width, before
    /// `onChange` could move the selection.
    private var visibleSelection: Section {
        switch selection {
        case .list where isCompact: .library
        case .library where !isCompact: .list(libraryPath.last ?? .notes)
        default: selection
        }
    }

    private var tabSelection: Binding<Section> {
        Binding { visibleSelection } set: { selection = $0 }
    }

    /// After a resize, make the mapping real, so the reader comes back to the
    /// same list at either width: Notes in the sidebar becomes Library → Notes
    /// in the tab bar, and Library → Notes becomes Notes again.
    private func adoptVisibleSelection() {
        let visible = visibleSelection
        switch (selection, visible) {
        case (.list(let destination), .library):
            libraryPath = [destination]
        case (.library, .list):
            libraryPath = []
        default:
            break
        }
        selection = visible
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
