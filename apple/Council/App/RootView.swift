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

    @Environment(AppModel.self) private var model
    @State private var selection: Section = .ask
    /// The Search tab's query. Here rather than in `SearchView` so another
    /// screen's request (`AppModel.pendingSearch`) can set it and switch tabs
    /// in one place, whether or not the Search tab has been opened yet.
    @State private var searchQuery = ""
    /// What the Ask tab has been asked to do (`AppModel.pendingAsk`), held
    /// here for the same reason as `searchQuery`: the request has to reach
    /// `ChatView` whether or not it has appeared yet. `ChatView` clears it.
    @State private var askRequest: AskRequest?
    /// The Ask tab's stack: citations push passages onto it, and an Ask
    /// request pops it back to the transcript.
    @State private var askPath = NavigationPath()
    /// The Library tab's stack. A `NavigationPath` rather than
    /// `[LibraryDestination]`: a stack bound to a typed array can only push
    /// that type, and the lists inside it push `ReadingRoute`s.
    @State private var libraryPath = NavigationPath()
    /// The list at the bottom of `libraryPath`, which the path can't be asked.
    @State private var libraryList: LibraryDestination?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: .ask) {
                NavigationStack(path: $askPath) {
                    ChatView(request: $askRequest, path: $askPath).settingsToolbar().readingDestinations()
                }
            }
            Tab("Read", systemImage: "book", value: .read) {
                NavigationStack { ReadView().settingsToolbar().readingDestinations() }
            }
            Tab("Browse", systemImage: "square.grid.2x2", value: .browse) {
                NavigationStack { BrowseView().settingsToolbar().readingDestinations() }
            }

            // Compact width only: the tab bar's stand-in for the section below.
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView(path: $libraryPath, list: $libraryList)
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
                NavigationStack { SearchView(query: $searchQuery).settingsToolbar().readingDestinations() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // First-run setup, over the app (OnboardingGate decides who sees it).
        .onboardingPresentation()
        // The once-per-launch update check, and its sheet.
        .updateLaunchOffer()
        // What couldn't come across from the Flutter app this one replaced.
        .migrationNotice()
        // Another screen asked for a search (the shelf's "Search Passages
        // for …"): run it in the Search tab.
        .onChange(of: model.pendingSearch) { _, query in
            guard let query else { return }
            searchQuery = query
            model.recentSearches.record(query)
            model.pendingSearch = nil
            selection = .search
        }
        // The reader's Ask, or a thread chosen in Chat History: show it in the
        // Ask tab, back at its transcript if a citation had been opened there.
        .onChange(of: model.pendingAsk) { _, request in
            guard let request else { return }
            askRequest = request
            askPath = NavigationPath()
            model.pendingAsk = nil
            selection = .ask
        }
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
        case .library where !isCompact: .list(libraryList ?? .notes)
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
            libraryPath = NavigationPath([destination])
            libraryList = destination
        case (.library, .list):
            libraryPath = NavigationPath()
            libraryList = nil
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
