import CouncilCore
import SwiftUI

/// One passage on its own: its text (markable, as in the reader), where it
/// comes from, its tags, a bookmark, and a way into the whole work. Mirrors
/// the single-passage path of `ContentDetailScreen` in
/// lib/src/screens/content_detail_screen.dart.
///
/// This is where someone lands to check a citation, so, in Flutter's order,
/// the passage's provenance (`_Provenance`) comes first, then "Read in
/// Context", which answers the question provenance raises (having been told
/// where a passage comes from, the next thing wanted is to see it there),
/// then the passage itself, then its topics. A chapter-long passage would
/// otherwise push the way into the work far below the fold.
struct ContentDetailView: View {
    let contentID: Int

    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    private enum Phase {
        case loading
        case loaded(LoadedSection, tags: [Tag])
        /// A bookmark or citation can outlive the passage it points at:
        /// corpus pruning removes units.
        case missing
    }

    @State private var phase: Phase = .loading
    @State private var selection = PassageSelection()
    @State private var isBookmarked = false

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .navigationSubtitle(selection.subtitle(otherwise: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Pushed detail, and the selection toolbar wants the bottom edge.
            .toolbar(.hidden, for: .tabBar)
            #endif
            .toolbar {
                if case .loaded(let section, _) = phase {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isBookmarked ? "Remove Bookmark" : "Bookmark",
                               systemImage: isBookmarked ? "bookmark.fill" : "bookmark") {
                            toggleBookmark(section.unit)
                        }
                    }
                }
            }
            .passageActions(selection)
            .councilScreenBackground(grouped: true)
            .task(id: model.library != nil) { await load() }
            .task(id: model.annotationsRevision) { await reloadHighlights() }
            .task(id: model.bookmarksRevision) {
                isBookmarked = model.bookmarks.isBookmarked(contentID)
            }
    }

    private var navigationTitle: String {
        if case .loaded(let section, _) = phase {
            return section.unit.title ?? section.unit.sourceTitle ?? "Passage"
        }
        return "Passage"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(
                "This Passage Is No Longer Available", systemImage: "text.badge.xmark",
                description: Text("It may have been removed from the library. Saved links to it can be deleted."))
        case .loaded(let section, let tags):
            passageList(section, tags: tags)
        }
    }

    private func passageList(_ section: LoadedSection, tags: [Tag]) -> some View {
        let unit = section.unit
        let source = PassageSource(unitID: unit.id, unitTitle: unit.title, sourceTitle: unit.sourceTitle,
                                   passage: section.passage)
        return List {
            Section {
                ProvenanceView(unit: unit)
                if let sourceID = unit.sourceId {
                    // 71 units carry a source_id with no row in `sources`, so
                    // the title can genuinely be missing; the work is still
                    // readable straight through, only its name is unknown.
                    NavigationLink(value: ReadingRoute.source(id: sourceID,
                                                              title: nonEmpty(unit.sourceTitle) ?? "Source",
                                                              unitID: unit.id)) {
                        Label("Read in Context", systemImage: "book.pages")
                            .foregroundStyle(palette.text)
                    }
                }
            } header: {
                if let kind = unitLabel(unit) { Text(kind) }
            }
            .councilListRow()

            Section {
                PassageText(
                    passage: section.passage,
                    highlights: section.highlights,
                    selected: selection.indices(inUnit: unit.id),
                    onTap: { index in
                        selection.toggle(index, in: source, highlights: section.highlights)
                    },
                    menu: { index in
                        selection.include(index, in: source, highlights: section.highlights)
                        return selection.menu(store: model.annotations)
                    }
                )
                .padding(.vertical, 6)
            }
            .councilListRow()

            if !tags.isEmpty {
                Section("Topics") {
                    ForEach(tags) { tag in
                        LabeledContent {
                            if let category = nonEmpty(tag.category) {
                                Text(category.capitalized)
                                    .foregroundStyle(palette.secondaryLabel)
                            }
                        } label: {
                            Text(tag.name)
                                .foregroundStyle(palette.text)
                        }
                    }
                }
                .councilListRow()
            }
        }
    }

    /// "Article 4", "Question 12": Flutter's header line over the passage,
    /// from `unit_type` and `unit_number` (`_formatUnitType`).
    private func unitLabel(_ unit: ContentUnitRow) -> String? {
        let type = Self.formatUnitType(unit.unitType ?? "")
        let label = [type, unit.unitNumber.map(String.init)].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    private static func formatUnitType(_ type: String) -> String? {
        switch type {
        case "article": "Article"
        case "qa": "Question"
        case "section": "Section"
        case "chapter": "Chapter"
        case "canon": "Canon"
        // Guarded, as in Dart: a pack may carry an empty unit_type.
        case "": nil
        default: type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    private func load() async {
        guard let library = model.library else { return }
        do {
            async let unit = library.contentUnit(id: contentID)
            async let tags = library.tags(forUnit: contentID)
            guard let row = try await unit else {
                phase = .missing
                return
            }
            let highlights = (try? await model.annotations?.highlights(forUnit: contentID)) ?? []
            let passage = await Self.segment(row.content)
            phase = .loaded(LoadedSection(unit: row, passage: passage, highlights: highlights),
                            tags: (try? await tags) ?? [])
        } catch {
            phase = .missing
        }
    }

    private func reloadHighlights() async {
        guard case .loaded(var section, let tags) = phase, let store = model.annotations,
              let highlights = try? await store.highlights(forUnit: contentID),
              highlights != section.highlights else { return }
        section.highlights = highlights
        phase = .loaded(section, tags: tags)
        selection.update(highlights: highlights, forUnit: contentID)
    }

    private func toggleBookmark(_ unit: ContentUnitRow) {
        isBookmarked = model.toggleBookmark(contentID: contentID,
                                            title: unit.title ?? "Untitled",
                                            source: unit.sourceTitle ?? "Unknown Source",
                                            preview: BookmarkPreview.text(unit.content))
    }

    @concurrent
    private nonisolated static func segment(_ content: String) async -> SegmentedPassage {
        SegmentedPassage(content)
    }
}

private func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
}

/// Where this text came from: Flutter's `_Provenance`.
///
/// Most sources name a published edition and a URL; a handful are legacy
/// entries whose text is genuine but whose origin was never recorded, and
/// nobody can verify those. Presenting both alike would quietly lend the
/// second the credibility of the first, so the second says so, in the error
/// colour.
private struct ProvenanceView: View {
    let unit: ContentUnitRow
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nonEmpty(unit.sourceTitle) ?? "Unknown source")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.text)

            if let tradition = nonEmpty(unit.tradition) {
                Text(tradition)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.onAccentContainer)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(palette.accentContainer, in: .capsule)
            }

            let facts = [unit.sourceAuthor, unit.dateComposed, unit.license].compactMap(nonEmpty)
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
            }

            if let address = nonEmpty(unit.sourceURL) {
                if let url = URL(string: address), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) {
                        Label(address, systemImage: "link")
                            .font(.footnote)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } else {
                    Label(address, systemImage: "link")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                        .textSelection(.enabled)
                }
            } else {
                Label("The origin of this text was never recorded, so it can't be checked against a published edition.",
                      systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(palette.error)
            }
        }
        .padding(.vertical, 4)
    }
}
