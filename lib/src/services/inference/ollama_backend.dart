import '../ollama_service.dart';
import 'inference_backend.dart';

/// Ollama, either on this machine or reachable over the local network / VPN.
///
/// The host is user-configurable rather than pinned to localhost: on a phone
/// there is no local Ollama, but there is often one on a desktop the user can
/// reach. Note that LAN access needs platform permissions on mobile (iOS
/// requires a local-network usage description and an ATS exception for
/// cleartext HTTP).
class OllamaBackend implements InferenceBackend {
  final String host;
  final String model;

  late final OllamaService _service = OllamaService(
    baseUrl: host,
    defaultModel: model,
  );

  OllamaBackend({required this.host, required this.model});

  static const String defaultHost = 'http://localhost:11434';
  static const String defaultModel = 'llama3.2';

  @override
  String get id => 'ollama';

  @override
  String get displayName => 'Ollama';

  @override
  String get description =>
      'A local or self-hosted model. Runs on your own hardware, so nothing '
      'leaves your network.';

  @override
  bool get isPrivate => true;

  /// Generous but not unbounded: context length depends on the model the user
  /// pulled, and small local models degrade badly when the window is filled.
  @override
  int get contextBudgetChars => 12000;

  @override
  Future<BackendStatus> checkStatus() async {
    if (host.trim().isEmpty) {
      return const BackendStatus.unavailable('No Ollama host configured.');
    }

    final reachable = await _service.isAvailable();
    if (!reachable) {
      return BackendStatus.unavailable(
        'Could not reach Ollama at $host. Check that it is running and, if it '
        'is on another machine, that the address is correct.',
      );
    }

    final models = await _service.getModels();
    if (models.isEmpty) {
      return const BackendStatus.unavailable(
        'Ollama is running but has no models. Pull one, e.g. '
        '"ollama pull llama3.2".',
      );
    }
    if (model.isNotEmpty && !models.any((m) => m.startsWith(model))) {
      return BackendStatus.unavailable(
        'Ollama is running but "$model" is not installed. Pull it or pick '
        'another model.',
      );
    }

    return BackendStatus.available('Connected to $host');
  }

  @override
  Stream<String> generate({required String prompt, String? system}) {
    return _service.generateStream(
      prompt: prompt,
      system: system,
      model: model.isEmpty ? null : model,
    );
  }

  @override
  Future<List<String>> availableModels() => _service.getModels();

  /// Preload the model so the *first* question isn't the one that pays the
  /// cold start (which, unwarmed, can drop the connection before any token
  /// arrives). Best-effort and cheap to call whenever this backend becomes the
  /// active one.
  Future<void> warmUp() => _service.preload(model: model.isEmpty ? null : model);

  @override
  void dispose() {}
}
