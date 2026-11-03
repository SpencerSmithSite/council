// The row shape of `_contentUnitColumns` in
// lib/src/services/database_service.dart: a content unit joined to its source,
// tradition and source type, as every retrieval path returns it.

import GRDB

/// A content unit with everything a citation needs to be checkable.
///
/// The Dart code returns these as `Map<String, dynamic>` rows of
/// `cu.*, s.title as source_title, s.author as source_author, s.date_composed,
/// s.source_url, s.license, t.name as tradition, st.name as source_type`, and
/// one column list is shared by *every* retrieval path on purpose. Chat
/// retrieval fuses full-text, tag and vector results, and each of those used
/// to hand-write its own columns, so the same passage carried different
/// metadata depending on which engine happened to find it: a citation showed
/// its tradition or not according to how it was found. Decoding every path
/// into this one type keeps that from coming back.
///
/// `sourceURL` and `license` are here because a citation that names a work
/// without saying where the text came from can't be verified, and the corpus
/// holds both properly sourced editions and legacy stubs with no recorded
/// origin. Carrying them lets the UI tell the two apart.
///
/// The source columns are optional even where the schema says `NOT NULL`:
/// `getContentUnit` and the semantic path join `sources` with a LEFT JOIN,
/// because 71 units in the full library carry a `source_id` with no matching
/// source row, and an inner join would make those passages unopenable. They
/// surface with a nil `sourceTitle` instead.
public struct ContentUnitRow: Sendable, Hashable, Identifiable {
    // content_units (`cu.*`). `created_at` is left out: nothing reads it, and
    // its storage class varies with whichever tool wrote the row.
    public let id: Int
    public let sourceId: Int?
    public let unitType: String?
    public let unitNumber: Int?
    public let title: String?
    /// The unit's text. Chat retrieval replaces it with the chunk that best
    /// matches the question (`_bestChunkText`); everywhere else it is the
    /// whole unit.
    public var content: String
    public let parentId: Int?
    public let sequence: Int?
    public let provenance: String?

    // The joined source, tradition and source type.
    public let sourceTitle: String?
    public let sourceAuthor: String?
    public let dateComposed: String?
    public let sourceURL: String?
    public let license: String?
    public let tradition: String?
    public let sourceType: String?

    /// FTS5's `rank` (bm25; more negative is better) when the row came from a
    /// full-text query, nil when it came from LIKE, tags or the vector index.
    public let rank: Double?

    public init(
        id: Int, sourceId: Int?, unitType: String?, unitNumber: Int?, title: String?,
        content: String, parentId: Int?, sequence: Int?, provenance: String?,
        sourceTitle: String?, sourceAuthor: String?, dateComposed: String?,
        sourceURL: String?, license: String?, tradition: String?, sourceType: String?,
        rank: Double?
    ) {
        self.id = id
        self.sourceId = sourceId
        self.unitType = unitType
        self.unitNumber = unitNumber
        self.title = title
        self.content = content
        self.parentId = parentId
        self.sequence = sequence
        self.provenance = provenance
        self.sourceTitle = sourceTitle
        self.sourceAuthor = sourceAuthor
        self.dateComposed = dateComposed
        self.sourceURL = sourceURL
        self.license = license
        self.tradition = tradition
        self.sourceType = sourceType
        self.rank = rank
    }

    /// The column list every query returning a `ContentUnitRow` selects,
    /// verbatim from the Dart `_contentUnitColumns`. Expects the aliases
    /// `cu`, `s`, `t` and `st`.
    static let columns = """
        cu.*,
        s.title as source_title,
        s.author as source_author,
        s.date_composed,
        s.source_url,
        s.license,
        t.name as tradition,
        st.name as source_type
        """

    /// Decodes a row selected with `columns` (plus `rank` for FTS queries).
    ///
    /// Leniently: a value of an unexpected storage class reads as the nearest
    /// sensible value, or nil, rather than trapping. GRDB's typed subscripts
    /// crash on a conversion failure, and these rows come from packs built by
    /// tools that may not agree on every column's type. sqflite handed the
    /// Dart code whatever SQLite stored, and the UI coped.
    init(row: Row) {
        id = row.lenientInt("id") ?? 0
        sourceId = row.lenientInt("source_id")
        unitType = row.lenientString("unit_type")
        unitNumber = row.lenientInt("unit_number")
        title = row.lenientString("title")
        // `row['content'] as String? ?? ''`, as `_bestChunkText` reads it.
        content = row.lenientString("content") ?? ""
        parentId = row.lenientInt("parent_id")
        sequence = row.lenientInt("sequence")
        provenance = row.lenientString("provenance")
        sourceTitle = row.lenientString("source_title")
        sourceAuthor = row.lenientString("source_author")
        dateComposed = row.lenientString("date_composed")
        sourceURL = row.lenientString("source_url")
        license = row.lenientString("license")
        tradition = row.lenientString("tradition")
        sourceType = row.lenientString("source_type")
        rank = row.lenientDouble("rank")
    }

    /// This row with its text replaced.
    func withContent(_ newContent: String) -> ContentUnitRow {
        var copy = self
        copy.content = newContent
        return copy
    }
}

extension Row {
    /// The value in `column`, or nil when it is NULL or absent.
    private func storage(_ column: String) -> DatabaseValue.Storage? {
        guard let value: DatabaseValue = self[column] else { return nil }
        return value.isNull ? nil : value.storage
    }

    func lenientInt(_ column: String) -> Int? {
        switch storage(column) {
        case .int64(let value): Int(exactly: value)
        case .double(let value): value.isFinite ? Int(exactly: value.rounded(.towardZero)) : nil
        case .string(let value): Int(value)
        case .blob, .null, nil: nil
        }
    }

    func lenientDouble(_ column: String) -> Double? {
        switch storage(column) {
        case .int64(let value): Double(value)
        case .double(let value): value
        case .string(let value): Double(value)
        case .blob, .null, nil: nil
        }
    }

    func lenientString(_ column: String) -> String? {
        switch storage(column) {
        case .string(let value): value
        case .int64(let value): String(value)
        case .double(let value): String(value)
        case .blob(let data): String(decoding: data, as: UTF8.self)
        case .null, nil: nil
        }
    }
}
