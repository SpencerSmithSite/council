/// Values the bundled corpus and every downloaded pack must agree on.
///
/// Mirrors `DatabaseService` in lib/src/services/database_service.dart. Both
/// apps read the same files, so these must change in both places together.
public enum CorpusConstants {
    /// Which assignment of row ids the bundled database belongs to. Packs are
    /// gated on this, not on the corpus version: a pack must never carry an id
    /// that already means something else here.
    public static let idSpace = 2

    /// The model the corpus vectors were built with. Compared against a pack
    /// manifest's `embeddingModel`; vectors from different models are noise
    /// to each other and nothing else would notice.
    public static let embeddingModel = "all-MiniLM-L6-v2-int8-384"
}
