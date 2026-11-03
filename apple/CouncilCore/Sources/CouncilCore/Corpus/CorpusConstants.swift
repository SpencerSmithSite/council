/// Values the bundled corpus and every downloaded pack must agree on.
///
/// Mirrors `DatabaseService` in lib/src/services/database_service.dart. Both
/// apps read the same files, so these must change in both places together.
public enum CorpusConstants {
    /// Bumped when the bundled corpus changes, so an installed copy of an older
    /// database is replaced rather than kept forever.
    ///
    /// This governs the database that ships *inside the binary*, and nothing
    /// else. It can only change with a release, because the file it describes
    /// can only change with a release. Reinstalling discards any packs the
    /// reader downloaded, since they were merged into the file being replaced.
    public static let corpusVersion = 16

    /// Which assignment of row ids the bundled database belongs to. Packs are
    /// gated on this, not on the corpus version: a pack must never carry an id
    /// that already means something else here.
    ///
    /// The two used to be the same number, and that made every corpus
    /// correction wait for an app release. A rebuild that only appends leaves
    /// every id meaning what it meant, and `tools/build_packs.py` proves that
    /// per build. Only a rebuild that reassigns ids, or reshapes a table a pack
    /// carries (the merge copies columns by position), advances this. Space 2
    /// was the latter: `traditions` gained four columns with the branch
    /// taxonomy.
    public static let idSpace = 2

    /// The model the corpus vectors were built with. Compared against a pack
    /// manifest's `embeddingModel`; vectors from different models are noise
    /// to each other and nothing else would notice.
    public static let embeddingModel = "all-MiniLM-L6-v2-int8-384"

    /// The installed corpus, in the app-support directory. The Flutter app
    /// uses the same name, which is what lets the native app open a Flutter
    /// install's corpus in place.
    public static let databaseFileName = "theology.db"

    /// Holds the `corpusVersion` the installed database was copied from, as
    /// decimal text with no newline (what Dart's `writeAsString('$v')` wrote).
    public static let stampFileName = "theology.corpus-version"

    /// The bundled, gzipped seed corpus.
    public static let bundledArchiveName = "theology.db.gz"
}
