import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_backend.dart';
import 'inference_backend.dart';
import 'local_model_backend.dart';
import 'ollama_backend.dart';
import 'platform_llm_backend.dart';

/// Owns the user's choice of inference backend and its configuration.
///
/// API keys go to the platform keychain rather than shared_preferences — they
/// are the user's own credentials and must not sit in plaintext on disk.
/// Everything else (which backend, which model, Ollama host) is ordinary
/// preference data.
class InferenceProvider extends ChangeNotifier {
  static const _backendKey = 'inference_backend';
  static const _ollamaHostKey = 'ollama_host';
  static const _ollamaModelKey = 'ollama_model';
  static const _cloudProviderKey = 'cloud_provider';
  static const _cloudModelKey = 'cloud_model';
  static const _localModelKey = 'local_model';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String _backendId = 'none';
  String _ollamaHost = OllamaBackend.defaultHost;
  String _ollamaModel = OllamaBackend.defaultModel;
  CloudProvider _cloudProvider = CloudProvider.anthropic;
  String _cloudModel = CloudProvider.anthropic.defaultModel;
  String _cloudKey = '';
  String _localModelId = LocalModelChoice.recommended().id;

  BackendStatus? _status;
  bool _isLoaded = false;
  PlatformLlmAvailability? _platformLlm;

  String get backendId => _backendId;
  String get ollamaHost => _ollamaHost;
  String get ollamaModel => _ollamaModel;
  CloudProvider get cloudProvider => _cloudProvider;
  String get cloudModel => _cloudModel;
  bool get hasCloudKey => _cloudKey.isNotEmpty;
  LocalModelChoice get localModel => LocalModelChoice.byId(_localModelId);
  BackendStatus? get status => _status;
  bool get isLoaded => _isLoaded;

  /// What the device's own model reported, or null before the first check.
  PlatformLlmAvailability? get platformLlm => _platformLlm;

  /// Whether to show the built-in model in the picker. False on hardware that
  /// can never run it, so those readers are not given a row they cannot use.
  bool get offersPlatformLlm => _platformLlm?.state.worthOffering ?? false;

  /// True when the device can generate answers right now with nothing
  /// installed and no key — the case onboarding should lead with.
  bool get platformLlmReady => _platformLlm?.isAvailable ?? false;

  /// Whether to offer a downloadable model.
  ///
  /// Everywhere the engine runs, including devices that already have a built-in
  /// model. Having Apple Intelligence is a reason to *default* to it, not a
  /// reason to withhold the alternative: the built-in model is a fixed, modest
  /// one, and a reader on a Mac with plenty of memory may well prefer a 4B or
  /// 8B they choose themselves. Hiding the option meant they could not.
  bool get offersLocalModel => LocalModelChoice.runsHere;

  /// The backend the user selected, constructed fresh so configuration edits
  /// always take effect.
  InferenceBackend get backend {
    switch (_backendId) {
      case PlatformLlmBackend.backendId:
        return const PlatformLlmBackend();
      case LocalModelBackend.backendId:
        return LocalModelBackend(choice: localModel);
      case 'ollama':
        return OllamaBackend(host: _ollamaHost, model: _ollamaModel);
      case 'cloud':
        return CloudBackend(
          provider: _cloudProvider,
          model: _cloudModel,
          apiKey: _cloudKey,
        );
      default:
        return RetrievalOnlyBackend();
    }
  }

  /// True when the user has opted into a backend that sends data off-device.
  bool get sendsDataOffDevice => !backend.isPrivate;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _backendId = prefs.getString(_backendKey) ?? 'none';
    _ollamaHost = prefs.getString(_ollamaHostKey) ?? OllamaBackend.defaultHost;
    _ollamaModel =
        prefs.getString(_ollamaModelKey) ?? OllamaBackend.defaultModel;
    _cloudProvider =
        CloudProvider.fromId(prefs.getString(_cloudProviderKey) ?? 'anthropic');
    _cloudModel =
        prefs.getString(_cloudModelKey) ?? _cloudProvider.defaultModel;
    _cloudKey = await _readKey(_cloudProvider);
    // Only when the reader has not chosen: an explicit pick is theirs to keep,
    // including a smaller model than the device could manage. Otherwise the
    // recommendation is made from what this machine can actually hold, so a
    // powerful desktop is pointed at a capable model without anyone having to
    // discover the picker.
    _localModelId = prefs.getString(_localModelKey) ??
        (await LocalModelChoice.recommendedHere()).id;
    _platformLlm = await PlatformLlmBackend.availability();

    _isLoaded = true;
    notifyListeners();
    unawaited(refreshStatus());
  }

  Future<String> _readKey(CloudProvider provider) async {
    try {
      return await _secure.read(key: 'api_key_${provider.id}') ?? '';
    } catch (_) {
      // Keychain can be unavailable (locked device, unsupported platform);
      // treat that as "no key" rather than crashing the app.
      return '';
    }
  }

  Future<void> setBackend(String id) async {
    _backendId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backendKey, id);
    await refreshStatus();
  }

  Future<void> setOllama({String? host, String? model}) async {
    if (host != null) _ollamaHost = host.trim();
    if (model != null) _ollamaModel = model.trim();
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ollamaHostKey, _ollamaHost);
    await prefs.setString(_ollamaModelKey, _ollamaModel);
    await refreshStatus();
  }

  Future<void> setCloudProvider(CloudProvider provider) async {
    _cloudProvider = provider;
    _cloudModel = provider.defaultModel;
    _cloudKey = await _readKey(provider);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cloudProviderKey, provider.id);
    await prefs.setString(_cloudModelKey, _cloudModel);
    await refreshStatus();
  }

  Future<void> setCloudModel(String model) async {
    _cloudModel = model;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cloudModelKey, model);
  }

  Future<void> setCloudKey(String key) async {
    _cloudKey = key.trim();
    notifyListeners();

    final name = 'api_key_${_cloudProvider.id}';
    if (_cloudKey.isEmpty) {
      await _secure.delete(key: name);
    } else {
      await _secure.write(key: name, value: _cloudKey);
    }
    await refreshStatus();
  }

  /// Re-ask the platform, for a reader returning from iOS Settings having just
  /// switched Apple Intelligence on.
  Future<void> refreshPlatformLlm() async {
    _platformLlm = await PlatformLlmBackend.availability(refresh: true);
    notifyListeners();
  }

  Future<void> setLocalModel(String id) async {
    _localModelId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localModelKey, id);
    await refreshStatus();
  }

  Future<void> refreshStatus() async {
    // Construct the backend once so the status check and the warm-up act on the
    // same instance/config.
    final active = backend;
    _status = await active.checkStatus();
    notifyListeners();

    // When Ollama is the reachable backend, warm its model now — on app start,
    // on selecting Ollama, and after editing host/model — so the user's first
    // question streams from a loaded model instead of triggering the cold-start
    // connection drop. Fire-and-forget; it must never block the UI.
    if (active is OllamaBackend && (_status?.available ?? false)) {
      unawaited(active.warmUp());
    }
  }
}
