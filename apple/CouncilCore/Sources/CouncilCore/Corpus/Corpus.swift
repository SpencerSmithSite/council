// Ported from lib/src/services/database_service.dart: the part that owns the
// corpus file (`initialize`, `_reinstall`, `_copyDatabaseFromAsset`). Search
// lives elsewhere.

import Foundation
import GRDB

/// The installed corpus: the bundled seed database, copied out of the app
/// bundle into a writable directory, plus whatever packs have been merged into
/// it since.
///
/// Writable, unlike every early version of the Flutter app: content packs
/// merge downloaded sources into these same tables, so the corpus is no longer
/// purely a read-only shipped artefact.
///
/// ## Why a `DatabasePool`, and what WAL means for the Flutter install
///
/// Retrieval reads the corpus constantly and concurrently (lexical and
/// semantic search run side by side, and the Read tab searches while chat
/// retrieves), while pack installs write to it for seconds at a time — an
/// uninstall's FTS `rebuild` over the whole index is the long one. A
/// `DatabasePool` gives every reader its own connection and a consistent
/// snapshot that a write in progress never blocks. A `DatabaseQueue` would
/// serialise every search behind every merge.
///
/// A pool requires WAL, and `journal_mode = WAL` is persistent: it is written
/// into the file header, so the Flutter app's rollback-journal `theology.db`
/// becomes a WAL database the first time the native app opens it. That is
/// acceptable here because:
///
/// - The two apps never share the file at once. On iOS and iPadOS the native
///   app *replaces* the Flutter one (same bundle id), and App Store updates
///   cannot be rolled back. On the Mac the Flutter app was sandboxed, so its
///   corpus lives in its container and the native app works on its own copy
///   (apple/PLAN.md, Phase 7).
/// - Even if the Flutter app did open it again, every SQLite since 3.7.0 reads
///   and writes WAL databases, and sqflite simply keeps them in WAL.
/// - The bookkeeping tables `PackService` reads are the same either way.
///
/// What WAL does change is that the database is now three files:
/// `theology.db`, `-wal` and `-shm`. Anything that copies or replaces the
/// corpus has to treat them as one unit. Reinstalling deletes all of them
/// (see `installIfNeeded`), because a leftover `-wal` from the old file would
/// otherwise be replayed into the new one and corrupt it; the same is true of
/// a rollback journal left by a crash, which the Flutter app never cleared.
public struct Corpus: Sendable {
    /// The open corpus. Writes (pack installs) go through its single writer
    /// connection; reads may run concurrently on its reader connections.
    public let database: DatabasePool

    /// Where `theology.db` and its version stamp live.
    public let directory: URL

    public var databaseURL: URL { directory.appending(path: CorpusConstants.databaseFileName) }

    /// What `installIfNeeded` found and did.
    public enum InstallOutcome: Equatable, Sendable {
        /// The installed database was current and has been left alone.
        case reused
        /// There was no database and the bundled one was copied in.
        case installed
        /// A database was there but its stamp named another corpus version, or
        /// was missing or unreadable (`previousVersion` nil), so the bundled
        /// database replaced it, discarding any packs merged into it.
        case reinstalled(previousVersion: Int?)
    }

    /// Install the bundled corpus if needed, then open it.
    ///
    /// - Parameters:
    ///   - directory: Where the corpus lives; the app passes its Application
    ///     Support directory, the same place the Flutter app used
    ///     (`getApplicationSupportDirectory()`), so an existing install is
    ///     picked up in place. Created if missing.
    ///   - bundledArchive: The gzipped seed corpus (`theology.db.gz`), usually
    ///     from the app bundle.
    ///   - version: The corpus version the archive holds.
    ///
    /// Synchronous and potentially slow on first launch (a multi-megabyte
    /// gunzip): call it off the main actor.
    public static func initialize(
        in directory: URL,
        bundledArchive: URL,
        version: Int = CorpusConstants.corpusVersion
    ) throws -> Corpus {
        try installIfNeeded(in: directory, bundledArchive: bundledArchive, version: version)
        let url = directory.appending(path: CorpusConstants.databaseFileName)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        try pool.write { db in try PackService.createTables(db) }
        return Corpus(database: pool, directory: directory)
    }

    /// The connection settings every corpus handle uses, tests included.
    ///
    /// Foreign keys stay **off**, as they are under sqflite. GRDB turns them on
    /// by default, and the schema declares plenty of them, but nothing in the
    /// corpus or the pack format was ever written to satisfy them: the merge
    /// copies reference and content tables in a fixed order with no regard to
    /// referential integrity, and shared/golden/packs/README.md records "Foreign
    /// keys are not enforced" as part of the contract. Turning them on would
    /// make the two apps disagree about which packs install.
    public static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        config.label = "Corpus"
        return config
    }

    /// Copy the bundled corpus into `directory` when it is absent or stale.
    ///
    /// Stale means the stamp file is missing, unreadable, or names a version
    /// other than `version`. Without the version check, readers who already
    /// ran the app would keep the old corpus forever.
    ///
    /// Must run before anything opens the database: it deletes and replaces
    /// the file underneath any open connection.
    @discardableResult
    public static func installIfNeeded(
        in directory: URL,
        bundledArchive: URL,
        version: Int = CorpusConstants.corpusVersion
    ) throws -> InstallOutcome {
        let fm = FileManager.default
        let dbURL = directory.appending(path: CorpusConstants.databaseFileName)
        let stampURL = directory.appending(path: CorpusConstants.stampFileName)

        let stampExists = fm.fileExists(atPath: stampURL.path)
        // Dart's `int.tryParse` of the file's text, surrounding whitespace
        // ignored as it ignores it: anything unparseable reads
        // as no version at all, which forces a reinstall.
        let installedVersion = stampExists
            ? (try? String(contentsOf: stampURL, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            : nil
        let dbExists = fm.fileExists(atPath: dbURL.path)

        if dbExists && installedVersion == version { return .reused }

        try reinstall(dbURL: dbURL, stampURL: stampURL, archive: bundledArchive, version: version)
        return dbExists ? .reinstalled(previousVersion: installedVersion) : .installed
    }

    /// Reinstalling the bundled corpus discards any packs the user downloaded.
    ///
    /// The stamp is written *after* the copy so that a crash midway leaves the
    /// app looking un-installed and retrying, rather than looking current while
    /// holding a half-written database.
    ///
    /// The copy goes to a temporary name first and is moved into place, which
    /// the Flutter app did not do: `theology.db` is then never a half-written
    /// file, even before the stamp check catches it.
    private static func reinstall(dbURL: URL, stampURL: URL, archive: URL, version: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let partial = dbURL.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            try Gzip.decompress(archive, to: partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        // The old database and everything SQLite keeps beside it. A `-wal` or
        // hot `-journal` that outlived its database would be applied to the new
        // file the next time it is opened.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(filePath: dbURL.path + suffix)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try fm.moveItem(at: partial, to: dbURL)

        try Data("\(version)".utf8).write(to: stampURL, options: .atomic)
    }
}
