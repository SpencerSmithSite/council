// The Read tab's queries: the shelf in lib/src/screens/read_screen.dart
// (`_loadShelf`), the section list in lib/src/screens/source_reader_screen.dart
// (`_load`), and `getContentUnit` / `getTagsForContent` in
// lib/src/services/database_service.dart.

import GRDB

/// A work on the Read tab's shelf.
public struct ShelfSource: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let author: String?
    public let dateComposed: String?
    /// The tradition's name, or "Other" when the source has none.
    public let tradition: String
    /// The tradition's branch, or "Other" when there is none.
    public let branch: String
    /// How many content units (sections) the work has; never 0, since the
    /// shelf only lists works that have some.
    public let units: Int

    public init(id: Int, title: String, author: String?, dateComposed: String?,
                tradition: String, branch: String, units: Int) {
        self.id = id
        self.title = title
        self.author = author
        self.dateComposed = dateComposed
        self.tradition = tradition
        self.branch = branch
        self.units = units
    }
}

/// One entry in a work's running order: enough to list it and open it.
public struct SectionHeader: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String?
    public let unitNumber: Int?

    public init(id: Int, title: String?, unitNumber: Int?) {
        self.id = id
        self.title = title
        self.unitNumber = unitNumber
    }
}

/// A subject tag on a content unit.
public struct Tag: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let slug: String
    /// `doctrine`, `practice`, … or nil.
    public let category: String?

    public init(id: Int, name: String, slug: String, category: String?) {
        self.id = id
        self.name = name
        self.slug = slug
        self.category = category
    }
}

/// What the content detail screen says about a work.
///
/// The Dart screen (lib/src/screens/content_detail_screen.dart) never loads
/// the source row itself: its provenance box reads `source_title`,
/// `source_author`, `tradition`, `date_composed`, `source_url` and `license`
/// off the joined content unit (`ContentUnitRow`). This carries the same
/// fields, so a source-level header can make the same honest distinction the
/// unit's box makes: most works name a published edition and a URL, a few
/// legacy entries have genuine text but no recorded origin, and presenting
/// both alike would lend the second the credibility of the first.
public struct SourceRow: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let author: String?
    public let dateComposed: String?
    public let sourceURL: String?
    public let license: String?
    public let tradition: String?
    public let branch: String?
    public let sourceType: String?

    public init(id: Int, title: String, author: String?, dateComposed: String?, sourceURL: String?,
                license: String?, tradition: String?, branch: String?, sourceType: String?) {
        self.id = id
        self.title = title
        self.author = author
        self.dateComposed = dateComposed
        self.sourceURL = sourceURL
        self.license = license
        self.tradition = tradition
        self.branch = branch
        self.sourceType = sourceType
    }

    /// Whether anyone could check the text against where it came from.
    public var isTraceable: Bool { !(sourceURL ?? "").isEmpty }
}

/// Read-only queries on the corpus for browsing and reading.
///
/// Takes any `DatabaseReader`: the app passes the corpus's `DatabasePool`, so
/// these run on its reader connections beside search and never wait behind a
/// pack merge; tests pass the read-only golden corpus queue. Rows decode
/// leniently, like `ContentUnitRow`, because packs come from tools that may
/// not agree on every column's type.
public struct Library: Sendable {
    public let database: any DatabaseReader

    public init(database: any DatabaseReader) {
        self.database = database
    }

    /// Every work with at least one unit, for the Read tab's shelf.
    ///
    /// Ordered by the taxonomy rather than by the alphabet: branches run in
    /// historical order (the undivided church, then each split by its date),
    /// and traditions run in their own order inside a branch. Sorting either
    /// by name would put Adventist above Anglican and the Reformation above
    /// Chalcedon, which is the shape of a list rather than of a church.
    ///
    /// The COALESCEs are for missing *rows* (a source whose tradition predates
    /// the taxonomy has a null `branch_id`). A missing `branches` table can't
    /// happen: it arrived with corpus version 16, and an older installed
    /// corpus is replaced on launch (`Corpus.installIfNeeded`).
    public func shelf() async throws -> [ShelfSource] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.title, s.author, s.date_composed,
                       COALESCE(t.name, 'Other') AS tradition,
                       COALESCE(b.name, 'Other') AS branch,
                       COUNT(cu.id) AS units
                FROM sources s
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN branches b ON t.branch_id = b.id
                JOIN content_units cu ON cu.source_id = s.id
                GROUP BY s.id
                ORDER BY COALESCE(b.sort_order, 99), b.name,
                         COALESCE(t.sort_order, 99), t.name,
                         s.author, s.title
                """).map { row in
                ShelfSource(id: row.lenientInt("id") ?? 0, title: row.lenientString("title") ?? "",
                            author: row.lenientString("author"), dateComposed: row.lenientString("date_composed"),
                            tradition: row.lenientString("tradition") ?? "Other",
                            branch: row.lenientString("branch") ?? "Other", units: row.lenientInt("units") ?? 0)
            }
        }
    }

    /// A work's sections in reading order. Empty for an unknown source.
    public func sections(ofSource id: Int) async throws -> [SectionHeader] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, unit_number FROM content_units WHERE source_id = ? ORDER BY sequence
                """, arguments: [id]).map { row in
                SectionHeader(id: row.lenientInt("id") ?? 0, title: row.lenientString("title"),
                              unitNumber: row.lenientInt("unit_number"))
            }
        }
    }

    /// One content unit with its source, tradition and source type.
    ///
    /// LEFT JOIN deliberately: 71 units in the full library carry a
    /// `source_id` with no matching row in `sources`, and an inner join would
    /// make those passages unopenable. They come back with a nil
    /// `sourceTitle` instead. Nil for an unknown id: a bookmark or citation
    /// can outlive the passage it points at, since corpus pruning removes
    /// units, and the screen shows a missing state rather than spinning.
    public func contentUnit(id: Int) async throws -> ContentUnitRow? {
        try await contentUnits(ids: [id])[id]
    }

    /// `contentUnit(id:)` for many ids in one read, for the continuous-scroll
    /// reader's prefetch. Ids with no unit are absent from the result.
    public func contentUnits(ids: [Int]) async throws -> [Int: ContentUnitRow] {
        let unique = Array(Set(ids))
        if unique.isEmpty { return [:] }
        return try await database.read { db in
            var result: [Int: ContentUnitRow] = [:]
            for chunk in unique.chunks(ofCount: SQLList.maxVariables) {
                let cursor = try Row.fetchCursor(db, sql: """
                    SELECT \(ContentUnitRow.columns)
                    FROM content_units cu
                    LEFT JOIN sources s ON cu.source_id = s.id
                    LEFT JOIN traditions t ON s.tradition_id = t.id
                    LEFT JOIN source_types st ON s.source_type_id = st.id
                    WHERE cu.id IN (\(SQLList.marks(chunk.count)))
                    """, arguments: StatementArguments(chunk))
                while let row = try cursor.next() {
                    let unit = ContentUnitRow(row: row)
                    result[unit.id] = unit
                }
            }
            return result
        }
    }

    /// A unit's tags, by category then name.
    public func tags(forUnit id: Int) async throws -> [Tag] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.slug, t.category
                FROM tags t
                JOIN content_tags ct ON t.id = ct.tag_id
                WHERE ct.content_unit_id = ?
                ORDER BY t.category, t.name
                """, arguments: [id]).map { row in
                Tag(id: row.lenientInt("id") ?? 0, name: row.lenientString("name") ?? "",
                    slug: row.lenientString("slug") ?? "", category: row.lenientString("category"))
            }
        }
    }

    /// One work's provenance, or nil for an unknown id.
    public func source(id: Int) async throws -> SourceRow? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT s.id, s.title, s.author, s.date_composed, s.source_url, s.license,
                       t.name AS tradition, b.name AS branch, st.name AS source_type
                FROM sources s
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN branches b ON t.branch_id = b.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE s.id = ?
                """, arguments: [id]).map { row in
                SourceRow(id: row.lenientInt("id") ?? 0, title: row.lenientString("title") ?? "",
                          author: row.lenientString("author"), dateComposed: row.lenientString("date_composed"),
                          sourceURL: row.lenientString("source_url"), license: row.lenientString("license"),
                          tradition: row.lenientString("tradition"), branch: row.lenientString("branch"),
                          sourceType: row.lenientString("source_type"))
            }
        }
    }
}

/// `IN (?, ?, …)` lists for the batch queries here and in `AnnotationStore`.
enum SQLList {
    /// Bound parameters per statement. SQLite's limit is far higher; this just
    /// keeps statements short.
    static let maxVariables = 500

    static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunks(ofCount size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
