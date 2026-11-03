import Foundation
import Testing
@testable import CouncilCore

@Suite("Search hits")
struct SearchHitsTests {
    private func marked(_ content: String, _ hits: SearchHits) -> [String] {
        let units = Array(content.utf16)
        return hits.ranges(in: content).map { String(decoding: units[$0], as: UTF16.self) }
    }

    @Test("FTS terms mark whole words they prefix, folded as unicode61 folds")
    func prefixes() {
        let hits = SearchHits(mode: .prefixes(QueryShaping.ftsTerms("grac Gregoire")))
        #expect(marked("Grace and gracious Grégoire; disgrace.", hits) == ["Grace", "gracious", "Grégoire"])
    }

    @Test("Stopwords and short words are not marked, as FTS never searched them")
    func stopwords() {
        let hits = SearchHits(mode: .prefixes(QueryShaping.ftsTerms("what is the grace of God")))
        #expect(marked("The grace of God is what saves.", hits) == ["grace", "God"])
    }

    @Test("Offsets are UTF-16, past characters outside the BMP")
    func utf16() {
        let content = "𝔊 grace"
        let hits = SearchHits(mode: .prefixes(["grace"]))
        #expect(hits.ranges(in: content) == [3..<8])
    }

    @Test("The LIKE path marks the phrase anywhere, case-insensitively")
    func phrase() {
        let hits = SearchHits(mode: .phrase("100%"))
        #expect(marked("Give 100% — 100% is all.", hits) == ["100%", "100%"])
    }

    @Test("The path follows the last query the search ran")
    func path() {
        let fts = LexicalSearch(rows: [], calls: [LexicalCall(kind: .fts, limit: 40, rows: [])])
        let like = LexicalSearch(rows: [], calls: [LexicalCall(kind: .fts, limit: 40, rows: []),
                                                   LexicalCall(kind: .like, limit: 40, rows: [])])
        #expect(SearchHits(query: " Grace ", search: fts).mode == .prefixes(["Grace"]))
        #expect(SearchHits(query: " Grace ", search: like).mode == .phrase("Grace"))
        #expect(SearchHits(mode: .prefixes([])).isEmpty)
    }

    @Test("A snippet is the verse holding the first hit, with the hits inside it")
    func verseSnippet() {
        let content = "1. In the beginning.\n2. And grace was given.\n3. And light."
        let passage = SegmentedPassage(content)
        let hits = SearchHits(mode: .prefixes(["grace"])).ranges(in: content)
        let snippet = SearchSnippet(content: content, passage: passage, hits: hits)
        #expect(snippet.number == 2)
        #expect(snippet.text == "And grace was given.")
        let units = Array(snippet.text.utf16)
        #expect(snippet.hits.map { String(decoding: units[$0], as: UTF16.self) } == ["grace"])
        #expect(!snippet.leadingEllipsis && !snippet.trailingEllipsis)
    }

    @Test("A long segment is cut around the hit at word boundaries")
    func longSnippet() {
        let filler = Array(repeating: "word", count: 120).joined(separator: " ")
        let content = filler + " propitiation " + filler
        let passage = SegmentedPassage(content)
        let hits = SearchHits(mode: .prefixes(["propitiation"])).ranges(in: content)
        let snippet = SearchSnippet(content: content, passage: passage, hits: hits, maxLength: 80)
        #expect(snippet.leadingEllipsis && snippet.trailingEllipsis)
        #expect(snippet.text.utf16.count <= 80)
        #expect(!snippet.text.hasPrefix(" ") && !snippet.text.hasPrefix("ord"))
        let units = Array(snippet.text.utf16)
        #expect(snippet.hits.map { String(decoding: units[$0], as: UTF16.self) } == ["propitiation"])
    }

    @Test("No hit falls back to the first segment")
    func noHit() {
        let content = "1. In the beginning.\n2. And light."
        let snippet = SearchSnippet(content: content, passage: SegmentedPassage(content), hits: [])
        #expect(snippet.number == 1)
        #expect(snippet.text == "In the beginning.")
        #expect(snippet.hits.isEmpty)
    }
}

@Suite("Recent searches")
struct RecentSearchesTests {
    private func store() -> RecentSearches {
        let suite = "RecentSearchesTests-\(UUID().uuidString)"
        return RecentSearches(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Newest first, deduplicated without regard to case, capped")
    func ordering() {
        let recents = store()
        recents.record("grace")
        recents.record("  Justification ")
        recents.record("GRACE")
        #expect(recents.all() == ["GRACE", "Justification"])
        for i in 0..<20 { recents.record("q\(i)") }
        #expect(recents.all().count == RecentSearches.limit)
        #expect(recents.all().first == "q19")
    }

    @Test("Blank searches aren't kept; remove and clear")
    func editing() {
        let recents = store()
        recents.record("   ")
        #expect(recents.all().isEmpty)
        recents.record("a")
        recents.record("b")
        recents.remove("a")
        #expect(recents.all() == ["b"])
        recents.clear()
        #expect(recents.all().isEmpty)
    }
}
