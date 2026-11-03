// Port of the retrieval half of lib/src/services/database_service.dart: the
// Read tab's `search` with its `_searchLike` fallback, `searchByTags`, chat
// retrieval's `searchForRAG` with `_searchScoped`, `_unitsInScope`,
// `_unitsByIds`, `_ensureNamedTraditions`, `_traditionNames` and
// `_bestChunkText`, and the recogniser cache (`recogniser`,
// `invalidateRecogniser`). The SQL is the Dart SQL, ORDER BY included.
//
// Golden stages: `read` and everything under `rag` in
// shared/golden/search/search.json.

import Foundation
import GRDB
import os

/// One lexical query retrieval ran, and what it returned.
///
/// Recorded because which queries ran is part of the behaviour: a scoped
/// search that finds fewer than two rows falls back to an unscoped one, which
/// can fall back to LIKE. Only queries that reached SQLite appear; an empty
/// FTS expression or an empty LIKE needle runs nothing and records nothing.
public struct LexicalCall: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// The unscoped FTS5 query (`search`).
        case fts
        /// FTS5 restricted to recognised sources or traditions (`_searchScoped`).
        case ftsScoped
        /// The LIKE fallback (`_searchLike`).
        case like
    }

    public let kind: Kind
    public let limit: Int
    public let rows: [ContentUnitRow]

    public var ids: [Int] { rows.map(\.id) }
}

/// The Read tab's search: the rows, and the queries that produced them.
public struct LexicalSearch: Sendable {
    public let rows: [ContentUnitRow]
    /// `fts`, then `like` if FTS found nothing; just `like` when the query has
    /// no FTS terms; empty when it has nothing to search for at all.
    public let calls: [LexicalCall]
}

/// Chat retrieval's answer, with the stages that led to it.
///
/// The stages are returned rather than thrown away because the UI needs some
/// of them (what the question was scoped to, so a narrowed search can say
/// "searching within Aquinas"; the tags, so the coverage notice reads the
/// question the way retrieval did) and because they are what makes a bad
/// answer diagnosable. The golden tests check every one.
public struct RAGRetrieval: Sendable {
    /// The passages to answer from, best first, each with `content` replaced
    /// by the chunk of the unit that best matches the question.
    public let rows: [ContentUnitRow]

    /// The authors, works and traditions the question named.
    public let scope: RecognisedEntities
    /// Tag slugs read from the question (`QueryShaping.extractTags`).
    public let tags: [String]

    /// Every lexical query run before fusion, in order.
    public let lexicalCalls: [LexicalCall]
    /// The lexical ranking that was fused: the last call's rows.
    public let lexical: [ContentUnitRow]
    /// The tag engine's ranking (`searchByTags`), empty when there were no tags.
    public let tagRows: [ContentUnitRow]

    /// Whether a semantic engine was available. When it wasn't, retrieval was
    /// lexical only, `allowedUnitIds` is nil and `semantic` is empty.
    public let semanticAvailable: Bool
    /// The `limit` semantic ranking was asked for.
    public let semanticLimit: Int
    /// The scope semantic ranking was restricted to: nil for no scope, an
    /// empty set for a scope that admits nothing.
    public let allowedUnitIds: Set<Int>?
    /// The semantic ranking that was fused.
    public let semantic: [Int]

    /// Reciprocal-rank fusion of the three rankings.
    public let fused: [Int]
    /// The scoped queries `_ensureNamedTraditions` ran to give a named
    /// tradition a voice (only when two or more were named).
    public let namedTraditionCalls: [LexicalCall]
}

/// Lexical and hybrid retrieval over the corpus.
///
/// An actor for its two pieces of mutable state, the semantic engine (which
/// loads after the corpus, or never) and the recogniser cache. The queries
/// themselves are nonisolated and read through the database's own reader
/// connections, so a Read tab search and a chat retrieval don't queue behind
/// each other, and none of them waits on a pack merge holding the writer.
public actor Retrieval {
    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Search")

    /// The corpus. The app passes `Corpus.database` (a pool, so reads run
    /// concurrently with each other and with a write); tests may pass a queue.
    public nonisolated let database: any DatabaseReader

    /// Optional semantic retrieval. Injected rather than built here so a
    /// device that can't run the model degrades to lexical search instead of
    /// failing, and so tests can rank from recorded query vectors.
    public private(set) var semantic: (any SemanticRanker)?

    /// Built on the first chat retrieval: it reads every source row, wasted
    /// work for a session that never asks a question.
    ///
    /// The *task* is cached, not the value, so two questions asked close
    /// together share one load instead of both reading the whole sources
    /// table, as the Dart code caches the future for the same reason.
    private var recogniserLoad: Task<EntityRecogniser, any Error>?

    public init(database: any DatabaseReader, semantic: (any SemanticRanker)? = nil) {
        self.database = database
        self.semantic = semantic
    }

    /// Install or remove the semantic engine. The app starts lexical and sets
    /// this once `SemanticSearch.tryLoad` finishes.
    public func setSemantic(_ semantic: (any SemanticRanker)?) {
        self.semantic = semantic
    }

    // MARK: - Content changes

    /// Forget the recogniser, so the next question is scoped against the
    /// content that is actually installed.
    ///
    /// It holds a snapshot of the sources and traditions tables, taken once
    /// and never refreshed. A reader who installed "Augustine of Hippo"
    /// mid-session and then asked "what did Augustine say about grace?" got
    /// an empty scope and an unscoped search, the very bug scoping exists to
    /// fix, until the app was restarted.
    public func invalidateRecogniser() {
        recogniserLoad = nil
    }

    /// Everything to do after packs are installed or removed: hand this to
    /// `PackService`'s `onContentChanged`.
    ///
    /// Both caches, not just the vectors, as the Flutter app's `main.dart`
    /// does. The recogniser holds a snapshot of the sources table, and a
    /// scoped question asked after an install was answered against the
    /// library as it was before it. The vector index is a snapshot too, and
    /// without a reload new text is found lexically and ignored semantically.
    ///
    /// Doesn't throw, because `onContentChanged` can't: the content is
    /// already installed, and a failed reload leaves semantic search on the
    /// previous index, which is logged rather than failing the install.
    public func contentDidChange() async {
        invalidateRecogniser()
        guard let semantic else { return }
        do {
            try await semantic.reload()
        } catch {
            Self.logger.error("Semantic index reload failed; keeping the previous index: \(String(describing: error), privacy: .public)")
        }
    }

    /// The entity recogniser, loading it on first use.
    public func recogniser() async throws -> EntityRecogniser {
        let load: Task<EntityRecogniser, any Error>
        if let cached = recogniserLoad {
            load = cached
        } else {
            let database = self.database
            load = Task { try await database.read { try EntityRecogniser.load(from: $0) } }
            recogniserLoad = load
        }
        do {
            return try await load.value
        } catch {
            // A failed load must not be cached, or one transient error leaves
            // every later question answered from the same failure. Only
            // forget it if it is still the cached one: an invalidation and a
            // fresh load may have happened while this one was failing.
            if recogniserLoad == load { recogniserLoad = nil }
            throw error
        }
    }

    // MARK: - Read tab

    /// The Read tab's full-text search (`search(text, limit: 40)` there).
    public nonisolated func search(_ query: String, limit: Int = 20) async throws -> [ContentUnitRow] {
        try await lexicalSearch(query, limit: limit).rows
    }

    /// `search`, with the queries it ran.
    ///
    /// FTS5 first; LIKE when the question has no FTS terms or FTS finds
    /// nothing.
    ///
    /// Every retrieval query here ends its ORDER BY with `cu.id`. bm25 ties
    /// are real (a Genesis or Psalm query has several), and without a
    /// tie-breaker the order of tied rows is whatever the SQLite build's scan
    /// happens to produce. This app runs on the system SQLite and the Flutter
    /// app on the one `sqlite3_flutter_libs` bundles, and
    /// shared/golden/search holds both to the same order.
    public nonisolated func lexicalSearch(_ query: String, limit: Int = 20) async throws -> LexicalSearch {
        let ftsTerms = QueryShaping.ftsMatchQuery(query)
        if ftsTerms.isEmpty { return try await searchLike(query, limit: limit, after: []) }

        let rows = try await database.read { db in
            try Self.fetchRows(db, sql: """
                SELECT \(ContentUnitRow.columns), fts.rank
                FROM content_fts fts
                JOIN content_units cu ON fts.rowid = cu.id
                JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE content_fts MATCH ?
                ORDER BY fts.rank, cu.id
                LIMIT ?
                """, arguments: [ftsTerms, limit])
        }
        let fts = LexicalCall(kind: .fts, limit: limit, rows: rows)

        // FTS5 found nothing: fall back to LIKE.
        if rows.isEmpty { return try await searchLike(query, limit: limit, after: [fts]) }
        return LexicalSearch(rows: rows, calls: [fts])
    }

    /// The LIKE fallback, for a query FTS5 found nothing for.
    ///
    /// Unindexed by nature, so it reads the corpus: the most expensive query
    /// in the app, and the reason for the guard below.
    private nonisolated func searchLike(_ query: String, limit: Int,
                                        after previous: [LexicalCall]) async throws -> LexicalSearch {
        let needle = DartText.trimmed(query)
        // An empty query is not a search for everything. Without this it
        // becomes LIKE '%%', which matches every unit in the corpus and hands
        // back the first `limit` of them as though they had been found.
        if needle.isEmpty { return LexicalSearch(rows: [], calls: previous) }

        let pattern = "%" + QueryShaping.escapeLike(needle) + "%"
        let rows = try await database.read { db in
            try Self.fetchRows(db, sql: """
                SELECT \(ContentUnitRow.columns)
                FROM content_units cu
                JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE cu.content LIKE ? ESCAPE '\\'
                ORDER BY cu.sequence, cu.id
                LIMIT ?
                """, arguments: [pattern, limit])
        }
        return LexicalSearch(rows: rows, calls: previous + [LexicalCall(kind: .like, limit: limit, rows: rows)])
    }

    // MARK: - Tags

    /// Units carrying any of `tags` (slugs; spaces become hyphens), most tags
    /// matched first.
    ///
    /// Nearly every tagged unit matches exactly one tag, so `tag_matches`
    /// alone ties almost everything and `cu.id` decides which units survive
    /// the limit.
    public nonisolated func searchByTags(_ tags: [String], limit: Int = 20) async throws -> [ContentUnitRow] {
        // The Dart code never calls this with no tags; SQLite would accept the
        // empty `IN ()` and match nothing, which this says without a query.
        if tags.isEmpty { return [] }
        let placeholders = Array(repeating: "?", count: tags.count).joined(separator: ",")
        var arguments = StatementArguments()
        for tag in tags {
            // `t.toLowerCase().replaceAll(' ', '-')`, by scalar: `replacing`
            // matches Characters, and a space followed by a combining mark is
            // one Character, which Dart's code-unit replace would still hit.
            let slug = String(String.UnicodeScalarView(
                DartText.lowercased(tag).unicodeScalars.map { $0 == " " ? "-" : $0 }))
            arguments += [slug]
        }
        arguments += [limit]
        return try await database.read { [arguments] db in
            try Self.fetchRows(db, sql: """
                SELECT \(ContentUnitRow.columns), COUNT(ct.tag_id) as tag_matches
                FROM content_units cu
                JOIN content_tags ct ON cu.id = ct.content_unit_id
                JOIN tags tg ON ct.tag_id = tg.id
                JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE tg.slug IN (\(placeholders))
                GROUP BY cu.id
                ORDER BY tag_matches DESC, cu.id
                LIMIT ?
                """, arguments: arguments)
        }
    }

    // MARK: - Chat retrieval

    /// Chat retrieval: the passages to answer `query` from (the chat screen
    /// asks for 6).
    public func searchForRAG(_ query: String, limit: Int = 5) async throws -> [ContentUnitRow] {
        try await retrieve(query, limit: limit).rows
    }

    /// `searchForRAG`, with every stage of it.
    ///
    /// Full-text search (scoped to what the question named, when it named
    /// something), tag search and semantic search, fused by reciprocal rank,
    /// spread across sources and traditions, balanced across the traditions a
    /// comparison named, and each passage cut to its best-matching chunk.
    public func retrieve(_ query: String, limit: Int = 5) async throws -> RAGRetrieval {
        // When a question names an author, work or tradition, that is a
        // constraint rather than another term to match. Without this, "what
        // did Aquinas say about Mary?" ranks passages about Mary by whoever
        // wrote most about her, and a question about the Council of Trent
        // returns Carthage and Nicaea.
        let scope = try await recogniser().recognise(query)

        var lexicalCalls: [LexicalCall] = []
        var ftsResults: [ContentUnitRow]
        if !scope.isEmpty {
            let scoped = try await searchScoped(query, scope: scope, limit: limit * 4)
            if let scoped { lexicalCalls.append(scoped) }
            ftsResults = scoped?.rows ?? []
            // A scope the corpus can barely satisfy should narrow the answer,
            // not empty it: fall back rather than returning nothing.
            if ftsResults.count < 2 {
                let unscoped = try await lexicalSearch(query, limit: limit * 2)
                lexicalCalls += unscoped.calls
                ftsResults = unscoped.rows
            }
        } else {
            let unscoped = try await lexicalSearch(query, limit: limit * 2)
            lexicalCalls += unscoped.calls
            ftsResults = unscoped.rows
        }

        let tags = QueryShaping.extractTags(query)
        var tagResults: [ContentUnitRow] = []
        if !tags.isEmpty {
            tagResults = try await searchByTags(tags, limit: limit)
        }

        // Semantic ranking, when the model is available. This is what lets a
        // question be answered by passages that share its meaning but not its
        // words: "how is a person saved?" against confessional language about
        // justification, which lexical search structurally can't reach.
        //
        // A scope that admits no units is not the same as no scope: it is an
        // empty set, and semantic search returns nothing for it. In the core
        // corpus that is every tradition but Scripture.
        let semantic = self.semantic
        let semanticLimit = limit * 4
        var allowedUnitIds: Set<Int>?
        var semanticUnits: [Int] = []
        if let semantic {
            allowedUnitIds = scope.isEmpty ? nil : try await unitsInScope(scope)
            semanticUnits = try await semantic.rankedUnits(
                for: query, limit: semanticLimit, allowedUnitIds: allowedUnitIds)
        }

        // Fuse the rankings by reciprocal rank. BM25 and cosine sit on
        // incomparable scales, so rank position is what can be combined
        // without calibrating either distribution.
        var byId: [Int: ContentUnitRow] = [:]
        for row in ftsResults + tagResults where byId[row.id] == nil {
            byId[row.id] = row
        }
        let missing = semanticUnits.filter { byId[$0] == nil }
        for row in try await unitsByIds(missing) {
            byId[row.id] = row
        }

        // Three rankings, not two lists with one appended to the other. Tag
        // matching is its own engine and is handed over as one, so a unit the
        // tags and FTS both found is promoted for being agreed on rather than
        // for appearing twice in the same list.
        let fused = HybridRanker.fuse(
            lexical: ftsResults.map(\.id),
            semantic: semanticUnits,
            tags: tagResults.map(\.id),
            limit: limit * 4
        )
        let combined = fused.compactMap { byId[$0] }

        // Spread the results across sources and traditions before truncating.
        // Relevance order alone fills every slot from whichever tradition the
        // corpus holds most of, which for a comparative question is the wrong
        // answer even when each passage is relevant. Keyed by code units, as
        // the Dart map is.
        let selected = HybridRanker.diversify(
            combined,
            sourceOf: { $0.sourceTitle.map(ExactString.init) },
            traditionOf: { $0.tradition.map(ExactString.init) },
            limit: limit
        )

        // A question naming two traditions is asking for a comparison, and an
        // answer drawn entirely from one of them doesn't answer it. Diversity
        // quotas alone can't guarantee this: they cap how many slots a
        // tradition may take, but if the other tradition never reaches the
        // candidate pool there is nothing to fill the remainder with, and the
        // backfill hands the slots straight back. This became a live failure
        // when Aquinas was added: 14 million characters of Catholic material
        // against 0.79 million Lutheran meant "how do Catholics and Lutherans
        // differ on baptism" returned six Catholic passages and no Lutheran.
        let (balanced, namedTraditionCalls) = try await ensureNamedTraditions(
            query, scope: scope, selected: selected, limit: limit)

        // Replace each unit's full text with the chunk that best matches the
        // query. A unit can be 162 KB; handing the model its first N
        // characters means the relevant passage is usually not in the window.
        let rows = try await withBestChunks(balanced, query: query)

        return RAGRetrieval(
            rows: rows,
            scope: scope,
            tags: tags,
            lexicalCalls: lexicalCalls,
            lexical: ftsResults,
            tagRows: tagResults,
            semanticAvailable: semantic != nil,
            semanticLimit: semanticLimit,
            allowedUnitIds: allowedUnitIds,
            semantic: semanticUnits,
            fused: fused,
            namedTraditionCalls: namedTraditionCalls
        )
    }

    /// FTS5 search restricted to particular sources or traditions, or nil
    /// when the question has no FTS terms and nothing was run.
    ///
    /// Sources OR traditions: naming both ("what does the Belgic Confession
    /// say, and Reformed teaching generally") should widen the scope, not
    /// demand a passage satisfy both at once.
    private nonisolated func searchScoped(_ query: String, scope: RecognisedEntities,
                                          limit: Int) async throws -> LexicalCall? {
        let ftsTerms = QueryShaping.ftsMatchQuery(query)
        if ftsTerms.isEmpty { return nil }
        // Callers only scope when something was recognised; an empty clause
        // would be `AND ()`, a syntax error.
        precondition(!scope.isEmpty, "searchScoped needs a non-empty scope")

        var clauses: [String] = []
        var arguments: StatementArguments = [ftsTerms]
        if !scope.sourceIds.isEmpty {
            clauses.append("s.id IN (\(Self.marks(scope.sourceIds.count)))")
            arguments += StatementArguments(scope.sourceIds)
        }
        if !scope.traditionIds.isEmpty {
            clauses.append("s.tradition_id IN (\(Self.marks(scope.traditionIds.count)))")
            arguments += StatementArguments(scope.traditionIds)
        }
        arguments += [limit]
        let scopeClause = clauses.joined(separator: " OR ")

        let rows = try await database.read { [arguments] db in
            try Self.fetchRows(db, sql: """
                SELECT \(ContentUnitRow.columns), fts.rank
                FROM content_fts fts
                JOIN content_units cu ON fts.rowid = cu.id
                JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE content_fts MATCH ?
                  AND (\(scopeClause))
                ORDER BY fts.rank, cu.id
                LIMIT ?
                """, arguments: arguments)
        }
        return LexicalCall(kind: .ftsScoped, limit: limit, rows: rows)
    }

    /// The content unit ids a recognised scope admits.
    private nonisolated func unitsInScope(_ scope: RecognisedEntities) async throws -> Set<Int> {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if !scope.sourceIds.isEmpty {
            clauses.append("s.id IN (\(Self.marks(scope.sourceIds.count)))")
            arguments += StatementArguments(scope.sourceIds)
        }
        if !scope.traditionIds.isEmpty {
            clauses.append("s.tradition_id IN (\(Self.marks(scope.traditionIds.count)))")
            arguments += StatementArguments(scope.traditionIds)
        }
        if clauses.isEmpty { return [] }

        let scopeClause = clauses.joined(separator: " OR ")
        return try await database.read { [arguments] db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT cu.id FROM content_units cu
                JOIN sources s ON cu.source_id = s.id
                WHERE \(scopeClause)
                """, arguments: arguments)
            var ids = Set<Int>()
            while let row = try rows.next() {
                if let id = row.lenientInt("id") { ids.insert(id) }
            }
            return ids
        }
    }

    /// Fetch units the semantic ranking found that the lexical pass didn't.
    ///
    /// LEFT JOIN on `sources`, unlike the FTS queries, so a unit whose source
    /// row is missing still comes back. Unordered, as in Dart: the rows go
    /// into a map keyed by id, and the fused ranking supplies the order.
    private nonisolated func unitsByIds(_ ids: [Int]) async throws -> [ContentUnitRow] {
        if ids.isEmpty { return [] }
        return try await database.read { db in
            try Self.fetchRows(db, sql: """
                SELECT \(ContentUnitRow.columns)
                FROM content_units cu
                LEFT JOIN sources s ON cu.source_id = s.id
                LEFT JOIN traditions t ON s.tradition_id = t.id
                LEFT JOIN source_types st ON s.source_type_id = st.id
                WHERE cu.id IN (\(Self.marks(ids.count)))
                """, arguments: StatementArguments(ids))
        }
    }

    /// Guarantee that every tradition the question named is actually present.
    ///
    /// Only acts when the question named more than one: a question about a
    /// single tradition should be answered from it, and one that named none
    /// has no comparison to balance.
    private nonisolated func ensureNamedTraditions(
        _ query: String,
        scope: RecognisedEntities,
        selected: [ContentUnitRow],
        limit: Int
    ) async throws -> (rows: [ContentUnitRow], calls: [LexicalCall]) {
        if scope.traditionIds.count < 2 { return (selected, []) }

        let names = try await traditionNames(scope.traditionIds)
        let present = Set(selected.map { $0.tradition.map(ExactString.init) })
        let missing = names.filter { !present.contains(ExactString($0.name)) }
        if missing.isEmpty { return (selected, []) }

        var result = selected
        var calls: [LexicalCall] = []
        for entry in missing {
            guard let call = try await searchScoped(
                query, scope: RecognisedEntities(traditionIds: [entry.id]), limit: 2)
            else { continue }
            calls.append(call)
            guard let first = call.rows.first else { continue }

            // Displace the lowest-ranked passage from whichever tradition is
            // most over-represented, so the comparison gains a voice without
            // the answer growing or a thinly represented tradition losing its
            // only one.
            //
            // Counted in first-seen order, and the earliest of equal counts
            // wins, as Dart's `reduce((a, b) => a.value >= b.value ? a : b)`
            // over an insertion-ordered map picks it.
            var order: [ExactString?] = []
            var counts: [ExactString?: Int] = [:]
            for row in result {
                let tradition = row.tradition.map(ExactString.init)
                if counts[tradition] == nil { order.append(tradition) }
                counts[tradition, default: 0] += 1
            }
            var crowded = order[0]
            for tradition in order.dropFirst() where counts[tradition]! > counts[crowded]! {
                crowded = tradition
            }

            let victim = result.lastIndex { $0.tradition.map(ExactString.init) == crowded }
            if result.count >= limit, let victim {
                result[victim] = first
            } else if result.count < limit {
                result.append(first)
            }
        }
        return (result, calls)
    }

    /// Names of the given traditions, in the order SQLite returns them.
    ///
    /// The Dart query has no ORDER BY and its result is a map iterated in row
    /// order, which decides which missing tradition `_ensureNamedTraditions`
    /// tries first. Kept verbatim: an `id IN (...)` lookup on the integer
    /// primary key walks the sorted IN list on both SQLite builds, so rows
    /// come back by ascending id either way.
    private nonisolated func traditionNames(_ ids: [Int]) async throws -> [(id: Int, name: String)] {
        if ids.isEmpty { return [] }
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM traditions WHERE id IN (\(Self.marks(ids.count)))",
                             arguments: StatementArguments(ids))
                .compactMap { row -> NamedTradition? in
                    guard let id = row.lenientInt("id"), let name = row.lenientString("name") else { return nil }
                    return NamedTradition(id: id, name: name)
                }
        }
        return rows.map { ($0.id, $0.name) }
    }

    private struct NamedTradition: Sendable {
        let id: Int
        let name: String
    }

    /// `rows`, each with its content replaced by `bestChunkText`, the chunk
    /// table read in one transaction.
    private nonisolated func withBestChunks(_ rows: [ContentUnitRow], query: String) async throws -> [ContentUnitRow] {
        if rows.isEmpty { return [] }
        return try await database.read { db in
            try rows.map { row in
                let chunks = try Row.fetchAll(db, sql: """
                    SELECT char_start, char_end FROM content_chunks WHERE content_unit_id = ? ORDER BY sequence
                    """, arguments: [row.id])
                    .map { (start: $0.lenientInt("char_start") ?? 0, end: $0.lenientInt("char_end") ?? 0) }
                return row.withContent(Self.bestChunkText(content: row.content, chunks: chunks, query: query))
            }
        }
    }

    /// The text of the chunk of `content` that best matches `query`.
    ///
    /// Scoring is term overlap, which is crude but adequate: the unit has
    /// already been selected, so this only has to choose between a handful
    /// of slices of one document. Semantic scoring happens earlier, at the
    /// point units are selected.
    ///
    /// Dart string semantics throughout, since the golden `finalContent` was
    /// measured on them: chunk offsets index UTF-16 code units, the text is
    /// lowercased code point by code point, and a term is found by code-unit
    /// search (Swift's `contains` compares Characters, so "nice" would not be
    /// found in a decomposed "nicé", where Dart finds it). The first chunk
    /// with the highest score wins.
    static func bestChunkText(content: String, chunks: [(start: Int, end: Int)], query: String) -> String {
        if chunks.count <= 1 { return content }

        // `query.toLowerCase().split(RegExp(r'[^a-z0-9]+'))
        //      .where((t) => t.length > 2).toSet()`
        var terms = Set<[UInt16]>()
        var current: [UInt16] = []
        for unit in DartText.lowercased(query).utf16 {
            if (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) {
                current.append(unit)
            } else {
                if current.count > 2 { terms.insert(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count > 2 { terms.insert(current) }
        if terms.isEmpty { return content }

        let units = Array(content.utf16)
        var best: String?
        var bestScore = -1

        for chunk in chunks {
            let end = min(max(chunk.end, 0), units.count)
            // Dart's `substring` throws on a negative start; skip such a
            // chunk instead of failing the whole retrieval.
            guard chunk.start >= 0, chunk.start < end else { continue }

            // A slice that splits a surrogate pair decodes the lone half as
            // U+FFFD, one code unit as the half was, so lengths still agree
            // with Dart's.
            let text = String(decoding: units[chunk.start..<end], as: UTF16.self)
            let lower = Array(DartText.lowercased(text).utf16)

            var score = 0
            for term in terms where Self.containsCodeUnits(lower, term) {
                score += 1
            }
            if score > bestScore {
                bestScore = score
                best = text
            }
        }
        return best ?? content
    }

    private static func containsCodeUnits(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        let first = needle[0]
        for start in 0...(haystack.count - needle.count) where haystack[start] == first {
            var matched = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    // MARK: - Helpers

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func fetchRows(_ db: Database, sql: String, arguments: StatementArguments) throws -> [ContentUnitRow] {
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        var rows: [ContentUnitRow] = []
        while let row = try cursor.next() {
            rows.append(ContentUnitRow(row: row))
        }
        return rows
    }
}
