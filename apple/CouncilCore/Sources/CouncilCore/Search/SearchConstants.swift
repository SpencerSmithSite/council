/// Shape of the precomputed chunk embeddings.
///
/// Mirrors `VectorIndex` in lib/src/services/search/vector_index.dart and the
/// output of tools/build_embeddings.py.
public enum SearchConstants {
    /// all-MiniLM-L6-v2 output width.
    public static let vectorDims = 384

    /// Vectors are L2-normalised then stored as int8 scaled by this, so cosine
    /// similarity is a plain integer dot product.
    public static let quantizationScale: Float = 127.0
}
