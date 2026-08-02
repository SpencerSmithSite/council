import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';

import 'inference_backend.dart';

/// A small open-weights model the reader downloads once and then runs locally.
///
/// This is the floor for everyone the platform model does not reach: Android,
/// iPhones before the 15 Pro, and desktop. It is not as good as Ollama on real
/// hardware or a frontier model behind an API key, and the picker says so
/// rather than letting the reader discover it — but it is grounded generation
/// with no account, no key and nothing leaving the device, which is otherwise
/// unavailable to them.
///
/// Runs through `flutter_gemma`, chosen on maintenance rather than features.
/// At the time of writing its last release was three days old, against seven
/// months for `llama_cpp_dart` and `cactus` and two years for `fllama` — and
/// PLAN.md already carries an entry about what an unmaintained dependency in
/// the inference path costs.
class LocalModelBackend implements InferenceBackend {
  final LocalModelChoice choice;

  const LocalModelBackend({required this.choice});

  static const String backendId = 'local';

  @override
  String get id => backendId;

  @override
  String get displayName => 'Downloaded model';

  @override
  String get description =>
      'A small open model kept on this device. One download, then it works '
      'offline with no account and no key.';

  @override
  bool get isPrivate => true;

  /// Tied to the model actually chosen rather than fixed: a 4 B model on a
  /// desktop can be given far more retrieved text than a 0.6 B one on a phone,
  /// and over-filling a small window degrades the answer instead of failing.
  @override
  int get contextBudgetChars => choice.contextBudgetChars;

  @override
  Future<BackendStatus> checkStatus() async {
    if (!await choice.isInstalled()) {
      return BackendStatus.unavailable(
        '${choice.name} is not downloaded yet. It is a '
        '${choice.approximateSize} one-time download.',
      );
    }
    return BackendStatus.available('${choice.name}, running on this device.');
  }

  @override
  Stream<String> generate({required String prompt, String? system}) async* {
    final model = await _LocalModelRuntime.instance.model(choice);
    final session = await model.openSession();
    try {
      // The system prompt is prepended rather than sent separately: these
      // models are small and inconsistent about honouring a separate system
      // role, and Council's system prompt is the part that keeps the answer
      // tied to the retrieved passages.
      final text = system == null || system.isEmpty
          ? prompt
          : '$system\n\n$prompt';
      await session.addQueryChunk(Message.text(text: text, isUser: true));
      yield* session.getResponseAsync();
    } catch (e) {
      throw InferenceException('The downloaded model failed to answer: $e');
    } finally {
      await session.close();
    }
  }

  @override
  Future<List<String>> availableModels() async =>
      LocalModelChoice.all.map((m) => m.name).toList();

  @override
  void dispose() {}
}

/// Loads the model once and keeps it.
///
/// Loading is expensive and the weights are large; doing it per question would
/// pay that cost on every message and risk two copies resident at once.
class _LocalModelRuntime {
  static final _LocalModelRuntime instance = _LocalModelRuntime._();
  _LocalModelRuntime._();

  InferenceModel? _model;
  String? _loadedId;

  Future<InferenceModel> model(LocalModelChoice choice) async {
    if (_model != null && _loadedId == choice.id) return _model!;
    await _model?.close();
    _model = await FlutterGemmaPlugin.instance.createModel(
      modelType: ModelType.gemmaIt,
      maxTokens: choice.maxTokens,
      // Capped because a second KV cache beside a multi-gigabyte model is how
      // a phone runs out of memory mid-answer.
      maxConcurrentSessions: 1,
    );
    _loadedId = choice.id;
    return _model!;
  }

  Future<void> unload() async {
    await _model?.close();
    _model = null;
    _loadedId = null;
  }
}

/// One downloadable model, with the numbers needed to decide whether to offer
/// it on a given device.
///
/// Sized in RAM rather than disk, because RAM is the binding constraint: the
/// vector index already holds every corpus embedding resident (~170 MB at
/// 445,445 chunks), and a model has to fit *beside* that, not merely onto the
/// filesystem.
class LocalModelChoice {
  final String id;
  final String name;
  final String fileName;
  final String url;
  final String approximateSize;

  /// Rough resident cost of the weights, in megabytes.
  final int ramMb;

  /// Least device memory this is sensible on, in megabytes. Deliberately well
  /// above [ramMb] — the OS, Flutter, the corpus database and the vector index
  /// are all resident too, and a model that just barely fits is a model that
  /// gets the app killed under memory pressure.
  final int minDeviceRamMb;

  final int maxTokens;
  final int contextBudgetChars;
  final String note;

  const LocalModelChoice({
    required this.id,
    required this.name,
    required this.fileName,
    required this.url,
    required this.approximateSize,
    required this.ramMb,
    required this.minDeviceRamMb,
    required this.maxTokens,
    required this.contextBudgetChars,
    required this.note,
  });

  Future<bool> isInstalled() async {
    try {
      return await FlutterGemma.isModelInstalled(fileName);
    } catch (_) {
      return false;
    }
  }

  /// Download and install, reporting progress 0-100.
  Stream<int> install() {
    final progress = StreamController<int>();
    () async {
      try {
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromNetwork(url)
            .withProgress(progress.add)
            .install();
        if (!progress.isClosed) progress.add(100);
      } catch (e) {
        if (!progress.isClosed) {
          progress.addError(
            InferenceException('Could not install $name: $e'),
          );
        }
      } finally {
        await progress.close();
      }
    }();
    return progress.stream;
  }

  /// Smallest first, so the default recommendation is the one most devices can
  /// actually run.
  static const List<LocalModelChoice> all = [
    LocalModelChoice(
      id: 'gemma3-270m',
      name: 'Gemma 3 270M',
      fileName: 'gemma3-270m-it-q8.task',
      url: 'https://huggingface.co/litert-community/Gemma3-270M-IT/resolve/'
          'main/Gemma3-270M-IT_multi-prefill-seq_q8_ekv1024.task',
      approximateSize: '300 MB',
      ramMb: 400,
      minDeviceRamMb: 3000,
      maxTokens: 1024,
      contextBudgetChars: 2500,
      note: 'The smallest option. Summarises and compares passages Council '
          'has already found; not for open-ended questions.',
    ),
    LocalModelChoice(
      id: 'gemma3-1b',
      name: 'Gemma 3 1B',
      fileName: 'gemma3-1b-it-q4.task',
      url: 'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/'
          'main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task',
      approximateSize: '550 MB',
      ramMb: 900,
      minDeviceRamMb: 4000,
      maxTokens: 2048,
      contextBudgetChars: 4000,
      note: 'The best balance for a recent phone. Noticeably better at '
          'following a question than the 270M.',
    ),
  ];

  static LocalModelChoice byId(String id) =>
      all.firstWhere((m) => m.id == id, orElse: () => all.first);

  /// What to recommend on this device.
  ///
  /// Physical memory is not readable portably from Dart, so this errs toward
  /// the smaller model rather than guessing high — being handed a model that
  /// runs badly is worse than being handed one that is merely modest, and the
  /// reader can pick the larger one deliberately.
  static LocalModelChoice recommended() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return all.last;
    }
    return all.first;
  }
}
