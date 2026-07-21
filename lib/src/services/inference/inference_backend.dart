/// A source of generated answers.
///
/// The app supports several, chosen by the user: no model at all, a local or
/// LAN Ollama server, a cloud provider the user holds a key for, or the
/// platform's own on-device model. They differ enough — in availability, in
/// context size, and crucially in whether anything leaves the device — that
/// those properties belong on the interface rather than being assumed.
abstract class InferenceBackend {
  /// Stable identifier, persisted in settings.
  String get id;

  /// Name shown in the backend picker.
  String get displayName;

  /// One line describing what this backend is, for the picker.
  String get description;

  /// Whether answers are generated without anything leaving the device.
  ///
  /// Drives the privacy disclosure. The app is chosen partly for being
  /// offline-first, so a cloud backend must say so plainly rather than letting
  /// a blanket "everything is local" claim stand.
  bool get isPrivate;

  /// How much retrieved source text to include in a prompt.
  ///
  /// Varies by an order of magnitude across backends: the on-device platform
  /// models have small context windows, while the cloud providers have very
  /// large ones. A single fixed budget is wrong for almost all of them.
  int get contextBudgetChars;

  /// Whether this backend can currently serve a request — Ollama reachable,
  /// key present, platform model supported on this hardware.
  ///
  /// Cheap enough to call on screen load; implementations should time out
  /// rather than hang.
  Future<BackendStatus> checkStatus();

  /// Stream an answer. Throws [InferenceException] on failure.
  Stream<String> generate({
    required String prompt,
    String? system,
  });

  /// Models offered by this backend, if it offers a choice.
  Future<List<String>> availableModels() async => const [];

  void dispose() {}
}

/// Result of an availability check, carrying a reason when unavailable so the
/// UI can tell the user what to fix rather than just greying something out.
class BackendStatus {
  final bool available;
  final String? detail;

  const BackendStatus.available([this.detail]) : available = true;
  const BackendStatus.unavailable(this.detail) : available = false;
}

class InferenceException implements Exception {
  final String message;

  InferenceException(this.message);

  @override
  String toString() => message;
}

/// The do-nothing backend: the app is a searchable library and nothing more.
///
/// This is the floor every platform reaches, including devices too old for an
/// on-device model and users who want no AI involved. It is a first-class
/// choice, not a failure state.
class RetrievalOnlyBackend implements InferenceBackend {
  @override
  String get id => 'none';

  @override
  String get displayName => 'No AI (search only)';

  @override
  String get description =>
      'Browse and search the library. No answers are generated and nothing '
      'leaves your device.';

  @override
  bool get isPrivate => true;

  @override
  int get contextBudgetChars => 0;

  @override
  Future<BackendStatus> checkStatus() async => const BackendStatus.available();

  @override
  Stream<String> generate({required String prompt, String? system}) {
    throw InferenceException(
      'Search-only mode is selected. Choose an AI backend in Settings to ask '
      'questions.',
    );
  }

  @override
  Future<List<String>> availableModels() async => const [];

  @override
  void dispose() {}
}
