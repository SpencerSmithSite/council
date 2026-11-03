/// Shapes and tuning values shared by the search code.
///
/// Mirrors `VectorIndex` in lib/src/services/search/vector_index.dart and the
/// output of tools/build_embeddings.py, `WordPieceTokenizer.maxTokens` and
/// `HybridRanker.k`. The golden fixture records the last two under
/// `parameters` (`maxTokens`, `rrfK`), so a change here has to be made on both
/// sides and the fixture regenerated.
public enum SearchConstants {
    /// all-MiniLM-L6-v2 output width.
    public static let vectorDims = 384

    /// Vectors are L2-normalised then stored as int8 scaled by this, so cosine
    /// similarity is a plain integer dot product.
    public static let quantizationScale: Float = 127.0

    /// Token ids per query, `[CLS]` and `[SEP]` included. Matches the
    /// build-time truncation length.
    public static let maxTokens = 256

    /// Reciprocal rank fusion's damping constant. 60 is the value from the
    /// original RRF paper and is what most implementations use.
    public static let rrfK = 60.0
}
