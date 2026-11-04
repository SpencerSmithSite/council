import CouncilCore
import Foundation
import Observation
import os

/// Owns CouncilCore for the life of the app: the installed corpus, retrieval,
/// the pack service, the user database's stores and the AI backend
/// (`inference`). One per process, created by `CouncilApp` and handed
/// to every scene through the environment.
///
/// Main-actor because the UI observes it; none of the work it starts runs
/// there. The corpus install is a multi-megabyte gunzip on first launch, the
/// model load is ~23 MB of ONNX, and searches go through `Retrieval`'s own
/// reader connections.
@Observable @MainActor
final class AppModel {
    enum State: Equatable {
        /// Installing or opening the corpus. Only the first launch (or one
        /// after a corpus version bump) takes long enough to notice.
        case preparing
        case ready
        /// The corpus couldn't be installed or opened. Nothing works without
        /// it, so the UI says why instead of showing empty lists.
        case failed(String)
    }

    /// Semantic search loads after the corpus is ready and search works
    /// lexically meanwhile; if it never loads, search stays lexical.
    enum SemanticState: Equatable {
        case loading
        case available
        case unavailable
    }

    private(set) var state: State = .preparing
    private(set) var semantic: SemanticState = .loading

    /// Nil until `state` is `.ready`.
    private(set) var retrieval: Retrieval?
    /// Nil until `state` is `.ready`. Phase 6's pack screen uses it.
    private(set) var packs: PackService?
    /// The content library's UI state (installed, available, the install in
    /// flight), over `packs` once the corpus is open.
    let packLibrary = PackLibrary()
    /// Nil until `state` is `.ready`. The reading screens' corpus queries.
    private(set) var library: Library?

    /// Highlights and notes, in `council_user.db`. Nil until it has opened,
    /// and nil for good if it can't: the corpus still reads without it, so a
    /// broken user database costs marking up, not reading.
    private(set) var annotations: AnnotationStore?
    /// Bumped after every highlight or note write, wherever it came from, so
    /// every screen showing one reloads with `.task(id:)` on it and two
    /// screens on the same passage can't drift apart.
    private(set) var annotationsRevision = 0

    /// Passage bookmarks, in preferences as the Flutter app keeps them. Change
    /// them through `toggleBookmark` so `bookmarksRevision` moves.
    let bookmarks = BookmarkStore()
    private(set) var bookmarksRevision = 0
    let shelf = ShelfStore()
    let readingPositions = ReadingPositionStore()
    let recentSearches = RecentSearches()

    /// A search another screen asked for (the shelf's "Search Passages
    /// for …"). `RootView` switches to the Search tab when it's set, and
    /// `SearchView` takes it as its query and clears it.
    var pendingSearch: String?

    func requestSearch(_ query: String) {
        pendingSearch = query
    }

    /// The AI backend and its status: see `InferenceModel`. Started with the
    /// app, independently of the corpus, so the Ask tab knows what it is
    /// talking to while the library is still being prepared.
    let inference = InferenceModel()

    /// Whether a newer Council is published, and getting it: see
    /// `UpdateModel`. Independent of the corpus, like `inference`.
    let updates = UpdateModel()

    /// Conversations with the model, in `council_user.db` beside the
    /// annotations. Nil until the user database has opened, and nil for good
    /// if it can't: questions are still answered, just not kept.
    private(set) var chatHistory: ChatHistoryStore?

    /// Something another screen asked the Ask tab to do: ask about a passage
    /// (the reader's Ask action) or continue a conversation (Chat History).
    /// `RootView` switches to the Ask tab when it's set and hands it on to
    /// `ChatView`, as `pendingSearch` is handed to the Search tab.
    var pendingAsk: AskRequest?

    /// The reader's Ask: a new thread about `passage`, in the Ask tab.
    func ask(about passage: PinnedPassage) {
        pendingAsk = AskRequest(.passage(passage))
    }

    /// Chat History's row: that thread, continued in the Ask tab. The history
    /// list never opens a second copy of a conversation itself, which is
    /// Flutter's rule too: two live views appending to one thread lose
    /// messages.
    func continueConversation(_ id: Int) {
        pendingAsk = AskRequest(.conversation(id))
    }

    /// Bumped after a pack install, removal or replacement changes what is in
    /// the corpus, so screens listing corpus content (the Read tab's shelf)
    /// reload with `.task(id:)` on it, as Flutter's Read tab reloads when
    /// `PackProvider`'s installed set changes.
    private(set) var contentRevision = 0

    private var started = false

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "App")

    /// Install and open the corpus, then load semantic search behind it.
    ///
    /// Safe to call from every window's `.task`: only the first call does
    /// anything, so a second Mac window doesn't install the corpus again.
    func start() async {
        guard !started else { return }
        started = true
        inference.start()

        let corpus: Corpus
        let directory: URL
        do {
            let archive = try Self.bundledResource(CorpusConstants.bundledArchiveName)
            directory = try Self.supportDirectory()
            corpus = try await Self.openCorpus(in: directory, archive: archive)
        } catch {
            Self.logger.error("Corpus unavailable: \(String(describing: error), privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }

        openUserData(in: directory)

        let retrieval = Retrieval(database: corpus.database)
        self.retrieval = retrieval
        // Packs change what's installed; retrieval caches the sources table
        // and the vector index, so both must hear about it.
        let packs = PackService(corpus: corpus, onContentChanged: { [weak self] in
            await retrieval.contentDidChange()
            await self?.contentDidChange()
        })
        self.packs = packs
        Task { await packLibrary.attach(packs) }
        library = Library(database: corpus.database)
        state = .ready

        // Unstructured, so closing the window whose `.task` called `start`
        // doesn't cancel a load the rest of the app is waiting on.
        Task { await loadSemanticSearch(corpus: corpus, into: retrieval) }
    }

    private func loadSemanticSearch(corpus: Corpus, into retrieval: Retrieval) async {
        guard let model = try? Self.bundledResource("model_quantized.onnx"),
              let vocabulary = try? Self.bundledResource("vocab.txt") else {
            // The build refuses to run without the model (project.yml's
            // "Check embedding model" phase), so this is a broken bundle.
            Self.logger.error("Embedding model or vocabulary missing from the bundle; search is lexical-only")
            semantic = .unavailable
            return
        }
        if let engine = await Self.loadSemantic(model: model, vocabulary: vocabulary, corpus: corpus) {
            await retrieval.setSemantic(engine)
            semantic = .available
        } else {
            semantic = .unavailable
        }
    }

    /// Adds or removes the bookmark on a passage and tells the screens.
    /// Returns whether it is now bookmarked.
    @discardableResult
    func toggleBookmark(contentID: Int, title: String, source: String, preview: String?) -> Bool {
        let added = bookmarks.toggle(contentId: contentID, title: title, source: source, preview: preview)
        bookmarksRevision += 1
        return added
    }

    /// Removes a passage's bookmark and tells the screens.
    func removeBookmark(contentID: Int) {
        bookmarks.remove(contentID)
        bookmarksRevision += 1
    }

    private func contentDidChange() {
        contentRevision += 1
    }

    /// Opens `council_user.db` once and hands the one `UserDatabase` to every
    /// store on it, so their writes are serialised by the same queue and each
    /// store's change stream hears the others.
    private func openUserData(in directory: URL) {
        let database: UserDatabase
        do {
            database = try UserDatabase.open(at: directory.appending(path: UserDatabase.fileName))
        } catch {
            Self.logger.error("User database unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        let store = AnnotationStore(database: database)
        annotations = store
        chatHistory = ChatHistoryStore(database: database)
        Task { [weak self] in
            for await _ in store.changes() {
                self?.annotationsRevision += 1
            }
        }
    }

    // MARK: - Off the main actor

    // `@concurrent` because the app target uses approachable concurrency, under
    // which a plain nonisolated async function runs on its caller's actor:
    // here, the main one, which would freeze the first launch's UI.

    @concurrent
    private nonisolated static func openCorpus(in directory: URL, archive: URL) async throws -> Corpus {
        try Corpus.initialize(in: directory, bundledArchive: archive)
    }

    @concurrent
    private nonisolated static func loadSemantic(model: URL, vocabulary: URL,
                                                 corpus: Corpus) async -> SemanticSearch? {
        await SemanticSearch.tryLoad(modelURL: model, vocabularyURL: vocabulary, database: corpus.database)
    }

    // MARK: - Locations

    private struct MissingResource: LocalizedError {
        let name: String
        var errorDescription: String? { "The app is missing \(name). Reinstall Council." }
    }

    private static func bundledResource(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
            throw MissingResource(name: name)
        }
        return url
    }

    /// Where the corpus, `packs/` and `council_user.db` live.
    ///
    /// The Flutter app put them in `getApplicationSupportDirectory()`, and the
    /// native app installs over it with the same bundle id (apple/PLAN.md,
    /// Phase 7), so it must use the same directory to pick them up in place.
    /// path_provider_foundation (2.6.0, lib/src/path_provider_foundation_real.dart)
    /// returns `NSApplicationSupportDirectory` as is on iOS, which in the app
    /// container is `Library/Application Support`, and appends the bundle id
    /// on macOS.
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        #if os(macOS)
        // TODO(Phase 7): the Flutter Mac app was sandboxed, so its data is in
        // ~/Library/Containers/site.spencersmith.council/Data/Library/Application Support/site.spencersmith.council.
        // This unsandboxed app gets ~/Library/Application Support/site.spencersmith.council,
        // the same layout outside the container; Phase 7 copies the user data
        // across on first launch.
        return base.appending(path: Bundle.main.bundleIdentifier ?? "site.spencersmith.council",
                              directoryHint: .isDirectory)
        #else
        return base
        #endif
    }
}

/// A request for the Ask tab from another screen (`AppModel.pendingAsk`).
///
/// Each carries an id of its own, so asking about the same passage twice in a
/// row is two requests rather than one the second time `onChange` can't see.
struct AskRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Start a new thread with this passage pinned.
        case passage(PinnedPassage)
        /// Show this stored conversation and continue it.
        case conversation(Int)
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}
