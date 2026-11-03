/// The backend ids the Flutter app persists under `inference_backend`.
///
/// The raw values are what is already stored on users' devices, so they must
/// not change: migration maps the saved choice by these strings. `local` stays
/// `local` even though the native app runs MLX rather than LiteRT behind it.
/// The cloud provider is not part of the id: Flutter stores `cloud` here and
/// the provider separately under `cloud_provider` (`InferenceProvider` in
/// lib/src/services/inference/inference_provider.dart).
public enum InferenceBackendID: String, CaseIterable, Sendable {
    /// Retrieval only, no model.
    case none
    /// Apple Foundation Models.
    case platform
    /// Downloaded on-device model.
    case local
    case ollama
    /// Anthropic, OpenAI, Gemini or xAI, whichever `cloud_provider` names.
    case cloud
}
