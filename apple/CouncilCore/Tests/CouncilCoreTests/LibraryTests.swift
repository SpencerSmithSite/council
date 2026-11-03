// Covers Corpus/Library.swift against the bundled core corpus
// (assets/theology.db.gz), which holds one work: the King James Bible.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

@Suite struct LibraryTests {
    let library = Library(database: GoldenCorpus.database)
    static let kjv = 970

    @Test func theShelfHasTheKJVUnderItsBranch() async throws {
        let shelf = try await library.shelf()
        let kjv = try #require(shelf.first { $0.id == Self.kjv })
        #expect(kjv.title == "The Holy Bible: King James Version")
        #expect(kjv.tradition == "Scripture")
        #expect(kjv.branch == "The Undivided Church")
        #expect(kjv.dateComposed == "1611")
        #expect(kjv.author == nil)
        #expect(kjv.units == 1189)
    }

    @Test func theKJVHas1189SectionsInCanonicalOrder() async throws {
        let sections = try await library.sections(ofSource: Self.kjv)
        #expect(sections.count == 1189)
        #expect(sections.first == SectionHeader(id: 23558, title: "Genesis 1", unitNumber: 1))
        #expect(sections[49].title == "Genesis 50")
        #expect(sections[50].title == "Exodus 1")
        #expect(sections[929].title == "Matthew 1", "the New Testament starts after 929 Old Testament chapters")
        #expect(sections.last == SectionHeader(id: 24746, title: "Revelation 22", unitNumber: 1189))
        #expect(Set(sections.map(\.id)).count == 1189)
    }

    @Test func aUnitRoundTripsWithItsSource() async throws {
        let unit = try #require(try await library.contentUnit(id: 23558))
        #expect(unit.id == 23558)
        #expect(unit.title == "Genesis 1")
        #expect(unit.sourceId == Self.kjv)
        #expect(unit.content.hasPrefix("1. In the beginning God created the heaven and the earth."))
        #expect(unit.sourceTitle == "The Holy Bible: King James Version")
        #expect(unit.tradition == "Scripture")
        #expect(unit.sourceURL == "https://www.gutenberg.org/ebooks/10")

        // The same row the retrieval paths decode.
        let direct = try await GoldenCorpus.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT \(ContentUnitRow.columns) FROM content_units cu
                LEFT JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE cu.id = 23558
                """).map(ContentUnitRow.init(row:))
        }
        #expect(unit == direct)
    }

    @Test func batchFetchMatchesSingleFetches() async throws {
        let sections = try await library.sections(ofSource: Self.kjv)
        let ids = sections.map(\.id) + [-1, 99_999_999, sections[0].id]
        let units = try await library.contentUnits(ids: ids)
        #expect(units.count == 1189)
        #expect(units[sections[700].id] == (try await library.contentUnit(id: sections[700].id)))
        #expect(units[-1] == nil)
        #expect(try await library.contentUnits(ids: []).isEmpty)
    }

    @Test func tagsAreByCategoryThenName() async throws {
        let tags = try await library.tags(forUnit: 24604)
        #expect(tags.map(\.name) == ["Creation", "Eschatology", "Faith", "Grace", "Last Judgment",
                                     "Salvation", "Scripture", "Prayer"])
        #expect(tags.first == CouncilCore.Tag(id: 18, name: "Creation", slug: "creation", category: "doctrine"))
        #expect(tags.last?.category == "practice")
    }

    @Test func theSourceCarriesItsProvenance() async throws {
        let source = try #require(try await library.source(id: Self.kjv))
        #expect(source.title == "The Holy Bible: King James Version")
        #expect(source.dateComposed == "1611")
        #expect(source.sourceURL == "https://www.gutenberg.org/ebooks/10")
        #expect(source.license == "Public domain in the US; Crown copyright in the UK")
        #expect(source.tradition == "Scripture")
        #expect(source.branch == "The Undivided Church")
        #expect(source.sourceType == "Scripture")
        #expect(source.isTraceable)
    }

    @Test func unknownIdsGiveNilOrEmpty() async throws {
        #expect(try await library.contentUnit(id: 99_999_999) == nil)
        #expect(try await library.sections(ofSource: 99_999_999).isEmpty)
        #expect(try await library.tags(forUnit: 99_999_999).isEmpty)
        #expect(try await library.source(id: 99_999_999) == nil)
    }
}
