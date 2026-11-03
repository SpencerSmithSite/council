/// The backend ids the Flutter app persists as the chosen backend.
///
/// The raw values are what is already stored on users' devices, so they must
/// not change: migration maps the saved choice by these strings. `local` stays
/// `local` even though the native app runs MLX rather than LiteRT behind it.
public enum InferenceBackendID: String, CaseIterable, Sendable {
    /// Retrieval only, no model.
    case none
    /// Apple Foundation Models.
    case platform
    /// Downloaded on-device model.
    case local
    case ollama
    case anthropic
    case openai
    case gemini
    case xai
}
