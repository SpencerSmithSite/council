import CouncilCore
import Observation
import SwiftUI

/// One section of the work, fetched: its row, its segments and its marks.
nonisolated struct LoadedSection: Sendable {
    let unit: ContentUnitRow
    let passage: SegmentedPassage
    var highlights: [Highlight]
}

/// The continuous reader's data: the work's running order, the sections
/// fetched so far, and the scroll position.
///
/// Flutter's `SourceReaderScreen` holds one section's text at a time ("loading
/// every section's text would mean holding a whole Bible in memory to read one
/// chapter of it"). The native reader scrolls the whole work, so it holds the
/// titles of every section and fetches text in small batches around whatever
/// comes on screen (`Library.contentUnits(ids:)`, with their highlights in the
/// same pass). A section not yet fetched stands in at a fixed height, so the
/// scroll content doesn't change size under the reader while text arrives.
@Observable @MainActor
final class SourceReaderModel {
    enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    let sourceID: Int
    let title: String
    let initialUnitID: Int?

    private(set) var phase: Phase = .loading
    private(set) var sections: [SectionHeader] = []
    private(set) var loaded: [Int: LoadedSection] = [:]

    /// The scroll view's position, by section id, anchored at the top: where
    /// the reader is. Set to jump; read to know which section is at the top.
    var scrollPosition = ScrollPosition(idType: Int.self)

    @ObservationIgnored private var indexByID: [Int: Int] = [:]
    @ObservationIgnored private var inFlight: Set<Int> = []
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var annotations: AnnotationStore?

    /// How many sections to fetch around one that comes on screen: a few
    /// behind for scrolling back, more ahead for reading on. A KJV chapter is
    /// a few kilobytes, so a batch is one quick query.
    private static let behind = 3
    private static let ahead = 6

    /// Height of a section whose text hasn't arrived: about a chapter of
    /// Scripture on an iPhone, so the estimate the lazy stack makes for the
    /// sections it hasn't laid out stays close to the truth.
    static let placeholderHeight: CGFloat = 900

    init(sourceID: Int, title: String, initialUnitID: Int?) {
        self.sourceID = sourceID
        self.title = title
        self.initialUnitID = initialUnitID
    }

    /// The id of the section at the top of the screen.
    var currentID: Int? {
        scrollPosition.viewID(type: Int.self) ?? openingID
    }

    var currentIndex: Int? {
        currentID.flatMap { indexByID[$0] }
    }

    /// Where the reader opened, until the scroll view reports a position.
    private var openingID: Int?

    func index(of id: Int) -> Int? { indexByID[id] }

    /// Loads the running order and the first batch of text, then opens at
    /// the section holding `initialUnitID`, else where this work was left
    /// (`ReadingPositionStore`), as Flutter's `_load` does: a named unit that
    /// isn't in the work any more (a citation kept across a pack change)
    /// falls through to the saved place rather than to nothing.
    func load(library: Library, annotations: AnnotationStore?, positions: ReadingPositionStore) async {
        guard phase == .loading else { return }
        self.library = library
        self.annotations = annotations
        do {
            let sections = try await library.sections(ofSource: sourceID)
            guard !sections.isEmpty else {
                phase = .empty
                return
            }
            self.sections = sections
            indexByID = Dictionary(sections.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

            let asked = initialUnitID.flatMap { indexByID[$0] }
            let start = min(max(asked ?? positions.position(forSource: sourceID), 0), sections.count - 1)
            // Text first, so the section the reader lands on is laid out at
            // its real height before the scroll view first measures it.
            await fetch(window(around: start))
            openingID = sections[start].id
            scrollPosition = ScrollPosition(id: sections[start].id, anchor: .top)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Jumps to a section (the contents sheet), fetching its batch first so
    /// it lands at its true height.
    func jump(to index: Int) async {
        guard sections.indices.contains(index) else { return }
        await fetch(window(around: index))
        openingID = sections[index].id
        scrollPosition.scrollTo(id: sections[index].id, anchor: .top)
        await settle()
    }

    /// Set by the first touch after a jump, so `settle` never pulls the page
    /// out from under a reader who has started scrolling.
    @ObservationIgnored private(set) var scrolledSinceJump = false

    func userScrolled() { scrolledSinceJump = true }

    /// Scrolls to the section opened or jumped to again, a few times over the
    /// next half second, until the reader touches the screen.
    ///
    /// A lazy stack positions a far-off section from *estimated* heights for
    /// everything above it, and the sections around the landing place then
    /// lay out (and fetch) at their real heights, which moves the target. In
    /// the 1,189-chapter KJV a first jump to Psalm 119 came to rest at verse
    /// 56; scrolling again once the neighbours have their true heights lands
    /// on the heading. Revelation 22 and second visits were already exact.
    func settle() async {
        guard let target = openingID else { return }
        scrolledSinceJump = false
        for delay in [60, 180, 400] {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard !scrolledSinceJump, openingID == target else { return }
            scrollPosition.scrollTo(id: target, anchor: .top)
        }
    }

    /// A section came on screen: make sure it and its neighbours are fetched.
    func sectionAppeared(_ id: Int) {
        guard let index = indexByID[id] else { return }
        let wanted = window(around: index).filter { loaded[$0] == nil && !inFlight.contains($0) }
        guard !wanted.isEmpty else { return }
        Task { await fetch(wanted) }
    }

    /// Re-reads the highlights of every fetched section, after the store
    /// announces a write (`AppModel.annotationsRevision`).
    func reloadHighlights() async {
        guard let annotations, !loaded.isEmpty else { return }
        let ids = Array(loaded.keys)
        guard let highlights = try? await annotations.highlights(forUnits: ids) else { return }
        for (id, marks) in highlights where loaded[id] != nil && loaded[id]?.highlights != marks {
            loaded[id]?.highlights = marks
        }
    }

    private func window(around index: Int) -> [Int] {
        let range = max(0, index - Self.behind)...min(sections.count - 1, index + Self.ahead)
        return range.map { sections[$0].id }
    }

    private func fetch(_ ids: [Int]) async {
        let wanted = ids.filter { loaded[$0] == nil && !inFlight.contains($0) }
        guard let library, !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        guard let fetched = try? await Self.fetch(wanted, library: library, annotations: annotations) else { return }
        for (id, section) in fetched {
            loaded[id] = section
        }
    }

    /// The query and the segmentation, off the main actor: segmenting a long
    /// chapter is real work, and a batch is several of them.
    @concurrent
    private nonisolated static func fetch(_ ids: [Int], library: Library,
                                          annotations: AnnotationStore?) async throws -> [Int: LoadedSection] {
        async let units = library.contentUnits(ids: ids)
        async let marks = annotations?.highlights(forUnits: ids)
        let rows = try await units
        let highlights = (try? await marks) ?? nil
        var out: [Int: LoadedSection] = [:]
        for (id, row) in rows {
            out[id] = LoadedSection(unit: row, passage: SegmentedPassage(row.content),
                                    highlights: highlights?[id] ?? [])
        }
        return out
    }
}
