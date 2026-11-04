import Foundation
import GRDB

/// Whether this device already holds a reader's library: the evidence the
/// onboarding gate uses for someone who has been through setup but whose
/// `has_onboarded` flag this app can't see yet.
///
/// The Flutter app shows onboarding until `has_onboarded` is set
/// (lib/main.dart: `home: settings.hasOnboarded ? MainScreen : OnboardingScreen`),
/// and it gates on the flag rather than on an empty library, "so someone who
/// deliberately removed everything is not walked through setup again". The
/// native app keeps that rule, and reads the Flutter flag
/// (`flutter.has_onboarded`) too. But the flag can be out of reach: on the Mac
/// the Flutter app was sandboxed, so its preferences sit in its container
/// until Phase 7 copies them out, and a native build from before onboarding
/// existed never wrote one.
///
/// What Flutter's logic does imply is that a reader's own data can only exist
/// on the far side of onboarding: highlights, notes and conversations are
/// made on `MainScreen`, which isn't shown until the flag is set, and
/// collections are installed either from Browse (on `MainScreen`) or by
/// onboarding's own finish, which sets the flag straight afterwards. So any of
/// those on disk means the reader has been through setup, and showing it again
/// would be walking an existing reader through a first run.
///
/// Things that are *not* evidence, deliberately: the files merely existing
/// (both apps create `council_user.db` and install `theology.db` on first
/// launch, before onboarding), and a stored AI backend (Flutter's
/// `_openingBackend` writes one on first launch too).
public enum ExistingInstall {
    /// True when `supportDirectory` (the app's Application Support directory,
    /// where both apps keep these files) holds a highlight, note or
    /// conversation in `council_user.db`, or an installed collection in
    /// `theology.db`.
    ///
    /// Opens both files read-only and creates nothing: it runs before the app
    /// has opened them, so a file that is missing, unreadable or lacks the
    /// table counts as no evidence rather than being created or repaired here.
    ///
    /// Synchronous and touches the disk: call it off the main actor.
    public static func hasReaderData(in supportDirectory: URL) -> Bool {
        hasRows(in: supportDirectory.appending(path: UserDatabase.fileName),
                tables: ["highlights", "notes", "conversations"])
            || hasRows(in: supportDirectory.appending(path: CorpusConstants.databaseFileName),
                       tables: ["installed_collections"])
    }

    /// Whether any of `tables` in the SQLite file at `file` has a row.
    static func hasRows(in file: URL, tables: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: file.path, configuration: configuration) else { return false }
        let found = try? queue.read { db -> Bool in
            for table in tables where try db.tableExists(table) {
                // The names are this file's own constants, never input.
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table))") == true {
                    return true
                }
            }
            return false
        }
        return found ?? false
    }
}
