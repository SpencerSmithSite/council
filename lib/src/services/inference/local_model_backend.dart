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
    // Reachable only through a settings file carried over from a phone, since
    // the option is not offered here — but silence would look like a bug.
    if (!LocalModelChoice.runsHere) {
      return const BackendStatus.unavailable(
        'Downloaded models run on Android and iOS only. On this machine, '
        'Ollama gives you a better model for the same privacy.',
      );
    }
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
      modelType: choice.modelType,
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

  /// Which family the runtime should treat this as. Carried per model rather
  /// than fixed, because the two here are from different families and a single
  /// hardcoded `gemmaIt` — left over from when both were Gemma — would be
  /// wrong for each of them.
  final ModelType modelType;

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
    required this.modelType,
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
        await FlutterGemma.installModel(modelType: modelType)
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
  ///
  /// Both are Apache-2.0 and ungated, and that is a requirement rather than a
  /// preference. The obvious picks were Gemma 3 270M and 1B, and both failed on
  /// a real device with `HTTP 401`: the `litert-community` Gemma repositories
  /// are gated, so fetching them needs a HuggingFace account and a token. A
  /// backend whose entire claim is "no account, no key" cannot be built on
  /// weights that require an account, and embedding a shared token in the app
  /// would be a credential in a client binary, one revocation away from
  /// breaking for everyone.
  ///
  /// Qwen 2.5 0.5B is a weaker model than Gemma 3 1B would have been. That is
  /// the real cost, and it is worth it, because the alternatives were shipping
  /// a token, mirroring 550 MB of someone else's weights under their licence,
  /// or asking every reader to sign up before they can use the feature.
  ///
  /// There is deliberately only one. SmolLM 135M was offered here as a 170 MB
  /// option for older phones and was removed after being tried on a device:
  /// asked what baptism is, with the Westminster catechisms and Aquinas
  /// retrieved and in front of it, it answered with advice about learning a
  /// foreign language. It is not that it answered badly — it did not attend to
  /// the passages at all, which is the one thing this backend exists to do.
  /// A reader spending 170 MB to get that is worse served than a reader told
  /// the honest floor is 550 MB.
  static const List<LocalModelChoice> all = [
    LocalModelChoice(
      id: 'qwen2.5-0.5b',
      name: 'Qwen 2.5 0.5B',
      fileName: 'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
      url: 'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/'
          'resolve/main/'
          'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
      approximateSize: '550 MB',
      ramMb: 700,
      minDeviceRamMb: 4000,
      maxTokens: 1280,
      contextBudgetChars: 3000,
      modelType: ModelType.qwen,
      note: 'Small enough for a phone, and large enough to stay with the '
          'passages Council retrieves. Best at summarising and comparing '
          'those; a hosted model is still better for open-ended questions.',
    ),
  ];

  static LocalModelChoice byId(String id) =>
      all.firstWhere((m) => m.id == id, orElse: () => all.first);

  /// Whether a downloaded model can run on this platform at all.
  ///
  /// Both models above ship as `.task`, which is MediaPipe's format, and
  /// `flutter_gemma_mediapipe` declares android and ios only — there is no
  /// desktop `.task` support to fall back to. Offering the download on macOS,
  /// Windows or Linux would mean a reader spending 550 MB on a file that
  /// cannot be loaded.
  ///
  /// Desktop is not left without an on-device option: Ollama is trivial to
  /// install there and is better than either of these models. Running `.task`
  /// on desktop would mean the `.litertlm` engine, a second native runtime and
  /// a different pair of weights — real work, for a platform that already has
  /// the better answer.
  static bool get runsHere => Platform.isAndroid || Platform.isIOS;

  /// What to recommend on this device.
  ///
  /// Physical memory is not readable portably from Dart, so this errs toward
  /// the smaller model rather than guessing high — being handed a model that
  /// runs badly is worse than being handed one that is merely modest, and the
  /// reader can pick the larger one deliberately.
  static LocalModelChoice recommended() => all.first;
}
