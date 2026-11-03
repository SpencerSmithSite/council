import Testing
@testable import CouncilCore

// HighlightColour (lib/src/theme/highlight_colours.dart) and ContentsIndex
// (`_ContentsSheetState` in lib/src/screens/source_reader_screen.dart). Neither
// has a golden fixture: the colours are constants and the jump list's logic is
// small enough to pin here, with the cases test/contents_sheet_grouping_test.dart
// cares about.

@Suite("Highlight colours")
struct HighlightColourTests {
    @Test func storedIDsNeverChange() {
        #expect(HighlightColour.allCases.map(\.id) == ["yellow", "green", "blue", "pink", "purple"])
        #expect(HighlightColour.allCases.map(\.label) == ["Yellow", "Green", "Blue", "Pink", "Purple"])
    }

    @Test func valuesMatchTheFlutterPalette() {
        let light = HighlightColour.allCases.map(\.light.hexARGB)
        let dark = HighlightColour.allCases.map(\.dark.hexARGB)
        #expect(light == ["#FFFBE7A8", "#FFC8E6C3", "#FFC2DDF5", "#FFF6CCD8", "#FFDCCDF2"])
        #expect(dark == ["#FF6B571B", "#FF2C4F2A", "#FF1F3F5C", "#FF5C2434", "#FF3E2C5C"])
        #expect(HighlightColour.pink.resolve(dark: true) == HighlightColour.pink.dark)
        #expect(HighlightColour.pink.resolve(dark: false) == HighlightColour.pink.light)
    }

    @Test func fromIDRoundTrips() {
        for colour in HighlightColour.allCases {
            #expect(HighlightColour.fromID(colour.id) == colour)
        }
    }

    @Test func unknownIDsFallBackToYellow() {
        #expect(HighlightColour.fromID(nil) == .yellow)
        #expect(HighlightColour.fromID("") == .yellow)
        #expect(HighlightColour.fromID("orange") == .yellow)
        #expect(HighlightColour.fromID("Green") == .yellow)
        #expect(HighlightColour.fromID(" green") == .yellow)
    }
}

@Suite("Contents index")
struct ContentsIndexTests {
    /// Genesis 1–50, Psalms 1–150, Proverbs 1–31, 1 Corinthians 1–16,
    /// 2 Corinthians 1–13, Malachi 1–4: the books the Flutter test uses.
    static let bible: [String?] = [
        ("Genesis", 50), ("Psalms", 150), ("Proverbs", 31),
        ("1 Corinthians", 16), ("2 Corinthians", 13), ("Malachi", 4),
    ].flatMap { book, chapters in (1...chapters).map { "\(book) \($0)" } }

    @Test(arguments: [
        ("Genesis 12", "Genesis"),
        ("Genesis", "Genesis"),
        ("1 Corinthians 13", "1 Corinthians"),
        ("Session 4 ", "Session"),
        ("Session\t4\n", "Session"),
        ("Psalm 1 2", "Psalm 1"),
        ("Part2", "Part2"),
        ("Part 2b", "Part 2b"),
        ("Book  007", "Book"),
        ("12", "12"),
        (" 12", ""),
        ("Chapter \u{0663}", "Chapter \u{0663}"),      // Arabic-Indic digit: not \d
        ("Chapter\u{00A0}3", "Chapter"),               // NBSP is \s
        ("Chapter 3\u{0085}", "Chapter 3"),            // NEL is not \s, so no match; trim removes it
        ("  Genesis 12  ", "Genesis"),
        ("", ""),
    ])
    func stem(_ title: String, _ expected: String) {
        #expect(ContentsIndex.stem(of: title).utf16.elementsEqual(expected.utf16),
                "\(title.debugDescription) -> \(ContentsIndex.stem(of: title).debugDescription)")
    }

    @Test func aBibleGroupsByBookInCanonicalOrder() {
        let index = ContentsIndex(titles: Self.bible)
        #expect(index.groups)
        let groups = index.grouped(index.matching(""))
        #expect(groups.map(\.stem) == ["Genesis", "Psalms", "Proverbs", "1 Corinthians",
                                       "2 Corinthians", "Malachi"])
        #expect(groups.map(\.members.count) == [50, 150, 31, 16, 13, 4])
        #expect(groups[5].members == [260, 261, 262, 263])
    }

    @Test func groupingIsAFactAboutTheWorkNotTheFilter() {
        let index = ContentsIndex(titles: Self.bible)
        // "Corinth" matches 29 sections, under the 30 a grouped work needs; the
        // decision is the whole work's, so it still groups.
        let corinth = index.matching("Corinth")
        #expect(corinth.count == 29)
        #expect(index.groups)
        #expect(index.grouped(corinth).map(\.stem) == ["1 Corinthians", "2 Corinthians"])
    }

    @Test func distinctTitlesStayFlat() {
        let articles = (1...40).map { "Of article \(["God", "Man", "Sin", "Grace"][$0 % 4]) \($0)x" }
        #expect(!ContentsIndex(titles: articles).groups)
        let confession = (1...40).map { "Article \($0)" }
        // One stem over forty sections: grouped.
        #expect(ContentsIndex(titles: confession).groups)
    }

    @Test func thirtySectionsNeverGroup() {
        let thirty = (1...30).map { "Psalm \($0)" }
        #expect(!ContentsIndex.shouldGroup(titles: thirty))
        #expect(ContentsIndex.shouldGroup(titles: thirty + ["Psalm 31"]))
    }

    @Test func theHalfRatioIsInclusive() {
        // 32 sections, 16 stems: exactly half, which groups.
        let half = (1...16).flatMap { ["Book\($0) 1", "Book\($0) 2"] }
        #expect(ContentsIndex.shouldGroup(titles: half))
        // 32 sections, 17 stems: over half.
        let over = Array(half.dropLast()) + ["Other 1"]
        #expect(!ContentsIndex.shouldGroup(titles: over))
    }

    @Test func filterIsTrimmedAndCaseInsensitive() {
        let index = ContentsIndex(titles: ["Genesis 1", "GENESIS 2", "Exodus 1", nil, "İstanbul"])
        #expect(index.matching("  genesis ") == [0, 1])
        #expect(index.matching("EXO") == [2])
        #expect(index.matching("") == [0, 1, 2, 3, 4])
        #expect(index.matching("   ") == [0, 1, 2, 3, 4])
        #expect(index.matching("section") == [])           // nil titles match as ""
        // Dart lowercases İ to plain "i", one code unit.
        #expect(index.matching("istanbul") == [4])
        #expect(index.matching("nothing") == [])
    }

    @Test func nilTitlesShareTheEmptyStem() {
        let index = ContentsIndex(titles: ["A 1", nil, "", "A 2"])
        #expect(index.grouped([0, 1, 2, 3]).map(\.stem) == ["A", ""])
        #expect(index.grouped([0, 1, 2, 3]).map(\.members) == [[0, 3], [1, 2]])
        #expect(index.title(at: 1) == "Section 2")
        #expect(index.title(at: 2) == "")
    }

    @Test func groupsFollowTheOrderGiven() {
        let index = ContentsIndex(titles: ["B 1", "A 1", "B 2", "A 2"])
        let groups = index.grouped([3, 2, 1, 0])
        #expect(groups.map(\.stem) == ["A", "B"])
        #expect(groups.map(\.members) == [[3, 1], [2, 0]])
    }

    @Test func labels() {
        let index = ContentsIndex(titles: ["Genesis 12", "Genesis", "  Genesis 12", "Psalm 1 2", nil])
        #expect(index.label(for: 0, stem: "Genesis") == "12")
        #expect(index.label(for: 1, stem: "Genesis") == "Genesis")      // nothing left: the title
        #expect(index.label(for: 2, stem: "Genesis") == "is 12")        // Dart's quirk, kept
        #expect(index.label(for: 3, stem: "Psalm 1") == "2")
        #expect(index.label(for: 4, stem: "") == "")
        #expect(index.label(for: 0, stem: "Genesis 12 and more") == "Genesis 12")
    }
}
