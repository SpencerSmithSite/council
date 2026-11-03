// Ported from lib/src/services/packs/pack_service.dart.
//
// shared/golden/packs/README.md is the contract this is held to: the fixtures
// there are replayed by PackGoldenTests.swift and by the Flutter app's
// test/pack_golden_test.dart, and both must end with the same database.

import CryptoKit
import Foundation
import GRDB

/// Downloads content and merges it into the corpus.
///
/// Two layers, because the reader and the file system want different things.
/// The reader wants overlapping ways to find text — by author, by era, by
/// tradition — and the same work belongs to several of them. The file system
/// wants each body of text published and stored exactly once.
///
/// So **fragments** are the unit that is downloaded, stored and reference
/// counted, and **collections** are lists of fragment ids. Installing a
/// collection fetches the fragments not already present; removing one drops
/// only the fragments no other installed collection still needs. Nothing is
/// ever downloaded or deleted twice, and adding a new way to browse costs no
/// bytes at all.
///
/// Callers run one install or uninstall at a time, as the Flutter app's
/// `PackProvider` does (it ignores a request while another is busy). Two
/// concurrent installs of the same fragment would share workspace file names.
public final class PackService: Sendable {
    /// The corpus being merged into. Any GRDB writer: the app passes the
    /// corpus's `DatabasePool`; tests may pass a queue.
    public let database: any DatabaseWriter

    /// Scratch space for archives and expanded fragments while they install.
    /// Emptied after every fragment, whether it installed or not.
    public let workspace: URL

    /// Where the published manifest lives. Fragment URLs are derived from it.
    /// Overridable so tests can serve real fragments from fixture files.
    public let manifestURL: URL

    private let fetcher: any PackFetcher

    /// Invoked after content is added or removed.
    ///
    /// Semantic search holds the vectors in memory as a snapshot taken at
    /// startup, so without this newly installed text is found by lexical search
    /// and ignored by semantic search — an install that looks successful with
    /// quietly worse answers.
    private let onContentChanged: (@Sendable () async -> Void)?

    /// The workspace folder's name inside the app-support directory, as the
    /// Flutter app names it.
    public static let workspaceDirectoryName = "packs"

    /// `<supportDirectory>/packs`, where the Flutter app keeps its workspace.
    public static func workspace(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: workspaceDirectoryName, directoryHint: .isDirectory)
    }

    public init(
        database: any DatabaseWriter,
        workspace: URL,
        fetcher: any PackFetcher = URLSessionPackFetcher(),
        manifestURL: URL = PackEndpoints.defaultManifestURL,
        onContentChanged: (@Sendable () async -> Void)? = nil
    ) {
        self.database = database
        self.workspace = workspace
        self.fetcher = fetcher
        self.manifestURL = manifestURL
        self.onContentChanged = onContentChanged
    }

    /// A service merging into `corpus`, with its workspace beside the corpus
    /// file as in the Flutter app.
    public convenience init(
        corpus: Corpus,
        fetcher: any PackFetcher = URLSessionPackFetcher(),
        manifestURL: URL = PackEndpoints.defaultManifestURL,
        onContentChanged: (@Sendable () async -> Void)? = nil
    ) {
        self.init(
            database: corpus.database,
            workspace: Self.workspace(in: corpus.directory),
            fetcher: fetcher,
            manifestURL: manifestURL,
            onContentChanged: onContentChanged
        )
    }

    // MARK: - Bookkeeping

    /// Bookkeeping, kept in the corpus database so it cannot drift from the
    /// content it describes.
    ///
    /// `collection_fragments` records what each installed collection required,
    /// at the time it was installed. It duplicates the manifest deliberately:
    /// removing a collection has to work out which fragments are still needed
    /// by the others, and that must not depend on being online — nor on the
    /// published manifest still saying what it said last month.
    ///
    /// `installed_collections.corpus_version` holds the **id space** the
    /// collection was installed under, not the corpus version: the column was
    /// named before the two were decoupled, and renaming it would break the
    /// files already on readers' devices.
    public static func createTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS installed_collections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              corpus_version INTEGER NOT NULL,
              installed_at TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collection_fragments (
              collection_id TEXT NOT NULL,
              fragment_id TEXT NOT NULL,
              PRIMARY KEY (collection_id, fragment_id)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS installed_fragments (
              id TEXT PRIMARY KEY,
              bytes INTEGER NOT NULL,
              units INTEGER NOT NULL,
              installed_at TEXT NOT NULL,
              sha256 TEXT
            )
            """)
        // The checksum is what makes a *republished* fragment distinguishable
        // from the one already installed. Added after the table shipped, so an
        // existing library needs the column bolted on; it is nullable because
        // the fragments already on disk were installed before anything recorded
        // which build they came from, and guessing would be worse than admitting
        // it. A null reads as "unknown, so replace when the catalogue offers
        // one" in `install`.
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('installed_fragments')")
        if !columns.contains("sha256") {
            try db.execute(sql: "ALTER TABLE installed_fragments ADD COLUMN sha256 TEXT")
        }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS fragment_sources (
              fragment_id TEXT NOT NULL,
              source_id INTEGER NOT NULL,
              PRIMARY KEY (fragment_id, source_id)
            )
            """)
    }

    public func installedCollections() async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM installed_collections"))
        }
    }

    public func installedFragments() async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM installed_fragments"))
        }
    }

    /// Installed fragment id -> the checksum of the file it came from.
    ///
    /// Nil for anything installed before checksums were recorded. Callers treat
    /// that as "not known to be current" rather than as "current", because the
    /// whole point of asking is to find fragments that need replacing.
    public func installedFragmentChecksums() async throws -> [String: String?] {
        try await database.read { db in
            var result: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, sha256 FROM installed_fragments") {
                result[row["id"] as String] = .some(row["sha256"] as String?)
            }
            return result
        }
    }

    // MARK: - Catalogue

    public func fetchManifest() async throws -> PackManifest {
        let response: (status: Int, body: Data)
        do {
            response = try await fetcher.get(manifestURL)
        } catch PackFetcherError.timedOut {
            throw PackError.catalogueTimedOut
        }
        guard response.status == 200 else {
            throw PackError.catalogueUnavailable(status: response.status)
        }
        return try PackManifest.parse(response.body)
    }

    // MARK: - Install

    /// Install every fragment `collection` needs that is not already present.
    ///
    /// - Parameters:
    ///   - idSpace: The app's id space. A parameter, as in Dart, only so the
    ///     golden tests can bypass the gate and pin what it protects against.
    ///   - onProgress: `(received, total)` in bytes across the whole operation
    ///     rather than per fragment, since the reader chose a collection and
    ///     does not know fragments exist. Called from whatever task is
    ///     downloading; hop to the main actor before touching UI state.
    public func install(
        _ collection: PackCollection,
        from manifest: PackManifest,
        idSpace: Int = CorpusConstants.idSpace,
        onProgress: (@Sendable (_ received: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        guard manifest.idSpace == idSpace else {
            throw PackError.differentIdSpace
        }

        // Vectors built by one embedding model and compared against queries
        // encoded by another are noise, and nothing downstream would notice:
        // every checksum, count and row stays correct while semantic retrieval
        // quietly stops working.
        guard manifest.embeddingsCompatible(with: CorpusConstants.embeddingModel) else {
            throw PackError.incompatibleEmbeddingModel
        }

        // A fragment already present is skipped — unless the catalogue is
        // offering a different file than the one installed, in which case it is
        // replaced.
        //
        // Skipping on presence alone was the reason a corrected corpus could not
        // reach anyone who already had it: the City of God was republished with
        // its actual text instead of its contents page, and every reader holding
        // `f-augustine` would have been told they were up to date and kept the
        // summary. Presence is not currency.
        //
        // An id the manifest does not list is skipped silently, but still
        // recorded against the collection below.
        let installed = try await installedFragmentChecksums()
        var wanted: [(fragment: PackFragment, replacing: Bool)] = []
        for id in collection.fragments {
            guard let fragment = manifest.fragment(id) else { continue }
            if let checksum = installed[id] {
                // Nil (installed before checksums were recorded) differs too.
                if checksum != fragment.sha256 { wanted.append((fragment, true)) }
            } else {
                wanted.append((fragment, false))
            }
        }

        let total = wanted.reduce(0) { $0 + $1.fragment.bytes }
        var done = 0

        for (fragment, replacing) in wanted {
            // Torn down inside the same call rather than beforehand, so a
            // download that fails leaves the old copy in place. Replacing
            // content the reader already has should never be able to end with
            // them holding neither.
            let base = done
            try await installFragment(fragment, replacing: replacing) { received in
                onProgress?(base + received, total)
            }
            done += fragment.bytes
        }

        // Recorded even when every fragment was already present: the collection
        // is what the reader chose, and it has to be removable later.
        //
        // Reached only when every fragment succeeded. A collection whose second
        // fragment fails keeps the first merged and recorded in
        // installed_fragments, but gets no row here; installing it again later
        // fetches only what is missing.
        //
        // One transaction here where Dart issues separate statements; the rows
        // that result are the same.
        let installedAt = Self.timestamp()
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO installed_collections (id, name, corpus_version, installed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                // The id space, in the column named corpus_version.
                arguments: [collection.id, collection.name, idSpace, installedAt]
            )
            for id in collection.fragments {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO collection_fragments (collection_id, fragment_id) VALUES (?, ?)",
                    arguments: [collection.id, id]
                )
            }
        }

        // Only when every fragment succeeded, as in Dart. A collection that
        // fails part-way has still merged its earlier fragments, which this
        // therefore does not announce; the next successful install or uninstall
        // does.
        if !wanted.isEmpty { await onContentChanged?() }
    }

    private func installFragment(
        _ fragment: PackFragment,
        replacing: Bool,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Last path component only: the names come from a downloaded manifest,
        // and "../" in one must not place a file outside the workspace. For any
        // name the publisher actually writes this is the name itself.
        let archive = workspace.appending(path: Self.fileName(fragment.file))
        let expanded = workspace.appending(path: Self.fileName(fragment.id) + ".db")

        // Whether or not it worked: a failed install that leaves 100 MB of
        // temporary files behind is its own bug.
        defer {
            try? fm.removeItem(at: archive)
            try? fm.removeItem(at: expanded)
        }

        try await download(fragment, to: archive, onProgress: onProgress)
        try verify(fragment, archive: archive)
        try Gzip.decompress(archive, to: expanded)
        // Only once the replacement is downloaded, checksummed and unpacked.
        // Any failure above this line leaves the reader with the copy they had,
        // and the teardown commits only together with the merge, so a failure
        // in it does too.
        try await merge(fragment, expanded: expanded, replacing: replacing)
    }

    /// The fragment's URL: the manifest URL with its first `manifest.json`
    /// replaced by the file name, exactly as Dart's `replaceFirst` builds it.
    func downloadURL(for fragment: PackFragment) -> URL {
        let base = manifestURL.absoluteString
        guard let range = base.range(of: "manifest.json") else { return manifestURL }
        return URL(string: base.replacingCharacters(in: range, with: fragment.file)) ?? manifestURL
    }

    private func download(
        _ fragment: PackFragment,
        to destination: URL,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        let status: Int
        do {
            status = try await fetcher.download(downloadURL(for: fragment), to: destination, progress: onProgress)
        } catch PackFetcherError.timedOut {
            throw PackError.downloadTimedOut(fragment: fragment.id)
        }
        guard status == 200 else { throw PackError.downloadFailed(status: status) }
    }

    /// Reject anything whose bytes do not match the manifest.
    ///
    /// A fragment is a database about to be merged into the reader's library,
    /// so a truncated download is not merely useless — it is a partially valid
    /// SQLite file that could merge and leave the library subtly wrong.
    ///
    /// The hash is over the compressed bytes, as published. The manifest's
    /// `bytes` is not checked; the hash already covers it.
    private func verify(_ fragment: PackFragment, archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == fragment.sha256 else { throw PackError.checksumMismatch }
    }

    /// The tables a fragment carries, in merge order (`build_packs.REFERENCE_TABLES`).
    ///
    /// Reference rows legitimately overlap — every fragment carries the full
    /// tradition and tag vocabulary, so no source can arrive pointing at a
    /// tradition the app has never seen. Branches come first because
    /// traditions point at them.
    static let referenceTables = ["branches", "traditions", "source_types", "tags", "authors", "works"]

    /// `build_packs.CONTENT_TABLES`, in merge order.
    static let contentTables = ["sources", "content_units", "content_tags", "content_chunks", "chunk_embeddings"]

    private func merge(_ fragment: PackFragment, expanded: URL, replacing: Bool) async throws {
        let installedAt = Self.timestamp()
        try await database.writeWithoutTransaction { db in
            // ATTACH cannot run inside a transaction, so it brackets one.
            try db.execute(sql: "ATTACH DATABASE ? AS pack", arguments: [expanded.path])
            do {
                try db.inTransaction {
                    try Self.mergeAttached(db, fragment: fragment, replacing: replacing, installedAt: installedAt)
                    return .commit
                }
            } catch {
                // Dart detaches in a `finally`, so a DETACH failure there would
                // replace the merge's error. Here the merge's error wins.
                try? db.execute(sql: "DETACH DATABASE pack")
                throw error
            }
            try db.execute(sql: "DETACH DATABASE pack")
        }
    }

    /// The body of the merge transaction, with the fragment attached as `pack`.
    ///
    /// Every copy is a positional `INSERT … SELECT *`, so the pack's tables must
    /// have the app's columns in the app's declaration order. A different count
    /// fails here and rolls back (the golden `reshaped` case); the same count in
    /// a different order is not detected by anything, in either app. Matching
    /// by name would be more correct and also different, so it is not done.
    private static func mergeAttached(_ db: Database, fragment: PackFragment, replacing: Bool, installedAt: String) throws {
        // In the same transaction as the merge, not one of its own. It used to
        // commit first, so a replacement that verified but then failed to merge
        // left the reader holding neither copy.
        if replacing { try retire(db, fragmentID: fragment.id) }

        // OR IGNORE keeps the app's row: a revised description in a newer build
        // of a tradition never arrives, and a new row whose unique name or slug
        // collides with an existing one is dropped silently.
        for table in referenceTables {
            try db.execute(sql: "INSERT OR IGNORE INTO \(table) SELECT * FROM pack.\(table)")
        }

        // Content rows deliberately do *not* use OR IGNORE. Fragments are a
        // partition, so their ids are disjoint and a collision means the
        // fragment and the app disagree about the corpus — which should fail
        // loudly rather than silently drop half of it and report success.
        for table in contentTables {
            try db.execute(sql: "INSERT INTO \(table) SELECT * FROM pack.\(table)")
        }

        // Appended to the existing index rather than rebuilding it. The column
        // list must match the FTS declaration order (content, title).
        try db.execute(sql: """
            INSERT INTO content_fts(rowid, content, title)
            SELECT id, content, title FROM pack.content_units
            """)

        try db.execute(
            sql: """
                INSERT INTO fragment_sources(fragment_id, source_id)
                SELECT ?, id FROM pack.sources
                """,
            arguments: [fragment.id]
        )

        // Every value from the manifest, not from the file. The checksum is
        // what a later catalogue is compared against to decide whether this
        // fragment has been republished since.
        try db.execute(
            sql: """
                INSERT INTO installed_fragments (id, bytes, units, installed_at, sha256)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [fragment.id, fragment.bytes, fragment.units, installedAt, fragment.sha256]
        )
    }

    // MARK: - Uninstall

    /// Remove a collection, keeping any fragment another collection still needs.
    ///
    /// This is the whole reason fragments exist as a separate layer. Someone
    /// with both "Church Fathers" and "Augustine of Hippo" who removes the
    /// former must keep Augustine; someone who removes the latter must keep
    /// everything, since Church Fathers needs it too.
    ///
    /// Reference rows the packs added (traditions, tags, branches) are never
    /// removed.
    public func uninstall(_ collectionID: String) async throws {
        let changed = try await database.write { db -> Bool in
            let ownFragments = Set(try String.fetchAll(
                db,
                sql: "SELECT fragment_id FROM collection_fragments WHERE collection_id = ?",
                arguments: [collectionID]
            ))

            // What the *other* installed collections still require. Read from
            // the local record rather than the manifest, so this works offline
            // and cannot be changed underneath the reader by a new publication.
            let stillNeeded = Set(try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT cf.fragment_id FROM collection_fragments cf
                    JOIN installed_collections ic ON ic.id = cf.collection_id
                    WHERE cf.collection_id != ?
                    """,
                arguments: [collectionID]
            ))

            let doomed = ownFragments.subtracting(stillNeeded)
            let present = Set(try String.fetchAll(db, sql: "SELECT id FROM installed_fragments"))

            for fragment in doomed where present.contains(fragment) {
                try Self.deleteFragment(db, fragmentID: fragment)
            }

            if !doomed.isEmpty {
                // External-content FTS5 has no sync triggers, so deleting the
                // rows leaves the index pointing at text that is gone and
                // searches return matches that cannot be opened. The index is
                // rebuilt rather than patched with 'delete' commands, which
                // require passing the exact original column values back and
                // corrupt the index silently when they do not match.
                try db.execute(sql: "INSERT INTO content_fts(content_fts) VALUES('rebuild')")
            }

            try db.execute(sql: "DELETE FROM collection_fragments WHERE collection_id = ?", arguments: [collectionID])
            try db.execute(sql: "DELETE FROM installed_collections WHERE id = ?", arguments: [collectionID])
            return !doomed.isEmpty
        }

        if changed { await onContentChanged?() }
    }

    /// Delete one fragment's content and bookkeeping, scoped through
    /// `fragment_sources`. Children first.
    private static func deleteFragment(_ db: Database, fragmentID: String) throws {
        let scope = "(SELECT source_id FROM fragment_sources WHERE fragment_id = ?)"
        let args: StatementArguments = [fragmentID]

        try db.execute(sql: """
            DELETE FROM chunk_embeddings WHERE chunk_id IN (
              SELECT c.id FROM content_chunks c
              JOIN content_units u ON c.content_unit_id = u.id
              WHERE u.source_id IN \(scope))
            """, arguments: args)
        try db.execute(sql: """
            DELETE FROM content_chunks WHERE content_unit_id IN (
              SELECT id FROM content_units WHERE source_id IN \(scope))
            """, arguments: args)
        try db.execute(sql: """
            DELETE FROM content_tags WHERE content_unit_id IN (
              SELECT id FROM content_units WHERE source_id IN \(scope))
            """, arguments: args)
        try db.execute(sql: "DELETE FROM content_units WHERE source_id IN \(scope)", arguments: args)
        try db.execute(sql: "DELETE FROM sources WHERE id IN \(scope)", arguments: args)

        try db.execute(sql: "DELETE FROM fragment_sources WHERE fragment_id = ?", arguments: args)
        try db.execute(sql: "DELETE FROM installed_fragments WHERE id = ?", arguments: args)
    }

    /// Remove a fragment's content so a newer build of it can be merged over.
    ///
    /// The same teardown `uninstall` performs, minus the collection
    /// bookkeeping: the reader is not removing anything, so their collections
    /// stay exactly as they were and only the text underneath is exchanged.
    ///
    /// The FTS rebuild is not optional. The index is external-content with no
    /// sync triggers, so leaving it would have it describing rows that are
    /// gone — and the replacement's rows get their own ids, so the stale
    /// entries would not even be overwritten. Searches would return passages
    /// that cannot be opened.
    ///
    /// It runs inside the merge's transaction, so the old copy is only gone
    /// once the new one is in.
    private static func retire(_ db: Database, fragmentID: String) throws {
        try deleteFragment(db, fragmentID: fragmentID)
        try db.execute(sql: "INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    }

    // MARK: - Helpers

    private static func fileName(_ name: String) -> String {
        let last = URL(filePath: name).lastPathComponent
        return last.isEmpty || last == "/" || last == ".." ? "_" : last
    }

    /// `DateTime.now().toIso8601String()`: local time, no zone designator,
    /// milliseconds then microseconds only when they are non-zero — the format
    /// the Flutter app wrote into the same columns. Nothing reads it back; it
    /// is kept identical so the two apps' rows look alike.
    static func timestamp(_ date: Date = Date()) -> String {
        // Whole microseconds, as Dart's DateTime holds them, taken from the
        // interval rather than from Calendar's `nanosecond`, which rounds
        // (.25 s can come back as 249,999,999 ns).
        let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
        let (seconds, remainder) = totalMicros.quotientAndRemainder(dividingBy: 1_000_000)
        let wholeSeconds = remainder < 0 ? seconds - 1 : seconds
        let micros = Int(remainder < 0 ? remainder + 1_000_000 : remainder)

        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents(in: .current, from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        let ms = micros / 1000
        let us = micros % 1000
        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms
        )
        if us != 0 { text += String(format: "%03d", us) }
        return text
    }
}
