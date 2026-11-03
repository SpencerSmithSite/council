import CouncilCore
import SwiftUI

/// Read a work straight through: every section in one continuous scroll.
/// Mirrors `SourceReaderScreen` in lib/src/screens/source_reader_screen.dart,
/// which pages one section at a time; see apple/PLAN.md, Phase 3, for why this
/// one scrolls.
///
/// Each section is its title and its `PassageText`; tapping verses selects
/// them and brings up the selection toolbar (`passageActions`). The section
/// at the top of the screen is the reading position: it names the subtitle,
/// takes the bookmark button, and is saved as Flutter saves it
/// (`reading_position_<sourceId>`, a section index), so the next visit opens
/// there.
struct SourceReaderView: View {
    let sourceID: Int
    let title: String
    /// Open at the section holding this unit. Takes precedence over the saved
    /// reading position.
    var initialUnitID: Int?

    @Environment(AppModel.self) private var model
    @Environment(ReaderStyle.self) private var style

    @State private var reader: SourceReaderModel
    @State private var selection = PassageSelection()
    @State private var contentsIndex: ContentsIndex?
    @State private var showingContents = false
    @State private var showingControls = false
    @State private var bookmarked: Set<Int> = []

    init(sourceID: Int, title: String, initialUnitID: Int? = nil) {
        self.sourceID = sourceID
        self.title = title
        self.initialUnitID = initialUnitID
        _reader = State(initialValue: SourceReaderModel(sourceID: sourceID, title: title, initialUnitID: initialUnitID))
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(selection.subtitle(otherwise: currentTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // The reader is a place to read, not to switch tabs from; the
            // selection toolbar takes the bottom edge while it's up.
            .toolbar(.hidden, for: .tabBar)
            #endif
            .toolbar { readerToolbar }
            .passageActions(selection)
            .sheet(isPresented: $showingContents) {
                if let contentsIndex {
                    ContentsSheet(index: contentsIndex, current: reader.currentIndex) { index in
                        selection.clear()
                        Task { await reader.jump(to: index) }
                    }
                }
            }
            .councilScreenBackground()
            .task {
                guard let library = model.library else { return }
                await reader.load(library: library, annotations: model.annotations, positions: model.readingPositions)
                contentsIndex = ContentsIndex(titles: reader.sections.map(\.title))
                await reader.settle()
            }
            .task(id: model.annotationsRevision) {
                await reader.reloadHighlights()
                if let unitID = selection.source?.unitID, let section = reader.loaded[unitID] {
                    selection.update(highlights: section.highlights, forUnit: unitID)
                }
            }
            .task(id: model.bookmarksRevision) {
                bookmarked = Set(model.bookmarks.bookmarks().map(\.contentId))
            }
            .task(id: reader.currentIndex) {
                // Throttled: a fling past fifty chapters shouldn't write fifty
                // times. Cancelled and restarted by each new position.
                guard let index = reader.currentIndex else { return }
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                model.readingPositions.setPosition(index, forSource: sourceID)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("No Sections", systemImage: "book",
                                   description: Text("This work has no sections."))
        case .failed(let message):
            ContentUnavailableView("Couldn't Open This Work", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .ready:
            scroll
        }
    }

    private var scroll: some View {
        @Bindable var reader = reader
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reader.sections) { section in
                    ReaderSection(header: section, loaded: reader.loaded[section.id],
                                  sourceTitle: title, selection: selection,
                                  store: model.annotations)
                        .padding(.horizontal, style.horizontalMargin)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .onAppear { reader.sectionAppeared(section.id) }
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, 24)
        }
        .scrollPosition($reader.scrollPosition, anchor: .top)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { reader.userScrolled() }
        }
    }

    private var currentTitle: String {
        guard let index = reader.currentIndex else { return "" }
        return reader.sections[index].title ?? "Section \(index + 1)"
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Contents", systemImage: "list.bullet") {
                showingContents = true
            }
            .disabled(contentsIndex == nil)

            Button("Reading Controls", systemImage: "textformat.size") {
                showingControls = true
            }
            .popover(isPresented: $showingControls) {
                ReadingControlsView()
                    .presentationDetents([.medium])
                    // No dimming and the page stays live behind the sheet,
                    // so each change can be judged on the text, as in Books.
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationCompactAdaptation(.sheet)
            }

            bookmarkButton
        }
    }

    @ViewBuilder
    private var bookmarkButton: some View {
        let id = reader.currentID
        let isBookmarked = id.map(bookmarked.contains) ?? false
        Button(isBookmarked ? "Remove Bookmark" : "Bookmark",
               systemImage: isBookmarked ? "bookmark.fill" : "bookmark") {
            toggleBookmark()
        }
        .disabled(id == nil)
    }

    /// Bookmarks the section at the top, as the passage screen bookmarks a
    /// passage: the same entry (title, work, a preview), so the Bookmarks list
    /// can't tell which screen made it.
    private func toggleBookmark() {
        guard let id = reader.currentID, let index = reader.index(of: id) else { return }
        let section = reader.sections[index]
        let unit = reader.loaded[id]?.unit
        model.toggleBookmark(contentID: id,
                             title: unit?.title ?? section.title ?? "Untitled",
                             source: unit?.sourceTitle ?? title,
                             preview: unit.map { BookmarkPreview.text($0.content) })
    }
}

/// One section: its title, then its text, or a stand-in of fixed height until
/// the text arrives.
private struct ReaderSection: View {
    let header: SectionHeader
    let loaded: LoadedSection?
    let sourceTitle: String
    let selection: PassageSelection
    let store: AnnotationStore?

    @Environment(ReaderStyle.self) private var style
    @Environment(\.councilPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = header.title, !title.isEmpty {
                Text(title)
                    .font(style.typography.titleFont(dynamicTypeSize))
                    .foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if let loaded {
                passage(loaded)
            } else {
                Color.clear
                    .frame(height: SourceReaderModel.placeholderHeight)
                    .overlay(alignment: .top) {
                        ProgressView().padding(.top, 24)
                    }
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private func passage(_ loaded: LoadedSection) -> some View {
        let source = PassageSource(unitID: loaded.unit.id,
                                   unitTitle: loaded.unit.title ?? header.title,
                                   sourceTitle: loaded.unit.sourceTitle ?? sourceTitle,
                                   passage: loaded.passage)
        return PassageText(
            passage: loaded.passage,
            highlights: loaded.highlights,
            selected: selection.indices(inUnit: loaded.unit.id),
            onTap: { index in
                selection.toggle(index, in: source, highlights: loaded.highlights)
            },
            menu: { index in
                selection.include(index, in: source, highlights: loaded.highlights)
                return selection.menu(store: store)
            }
        )
    }
}

/// The preview a bookmark carries: Flutter's `_getPreview`, whitespace
/// collapsed and cut at 100 characters.
enum BookmarkPreview {
    static func text(_ content: String) -> String {
        let cleaned = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let units = Array(cleaned.utf16)
        guard units.count > 100 else { return cleaned }
        return String(decoding: units[0..<100], as: UTF16.self) + "..."
    }
}
