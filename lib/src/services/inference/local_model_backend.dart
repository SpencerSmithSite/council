import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../device_memory.dart';
import '../device_storage.dart';
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
    // Not reachable on any platform Council ships today; kept so that a future
    // target which the engine does not cover fails with a sentence rather than
    // with silence.
    if (!LocalModelChoice.runsHere) {
      return const BackendStatus.unavailable(
        'A downloaded model cannot run on this platform. Ollama or an API key '
        'will work here.',
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
      fileType: choice.fileType,
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

/// How a model is being offered on this particular device.
///
/// A label about *fit*, not about the model: the same weights are the "large"
/// option on a mid-range phone and the "small" one on a workstation, which is
/// the whole point of choosing per device.
enum LocalModelTier {
  /// Faster and lighter, at the cost of answer quality.
  small,

  /// The sensible default here.
  recommended,

  /// The best answers this device can produce, and the slowest.
  large;

  String get label => switch (this) {
        LocalModelTier.small => 'Smaller and faster',
        LocalModelTier.recommended => 'Recommended',
        LocalModelTier.large => 'Best answers',
      };

  /// Why a reader might pick this one. Phrased as the trade being made, since
  /// every one of these is a trade rather than a ranking.
  String get rationale => switch (this) {
        LocalModelTier.small =>
          'Quickest to download and to answer. Best when you mostly want the '
              'passages found and summarised.',
        LocalModelTier.recommended =>
          'The best balance for this device — capable enough to follow a '
              'question, quick enough to stay usable.',
        LocalModelTier.large =>
          'The most capable model this device can hold. Noticeably slower to '
              'answer, and a much larger download.',
      };
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

  /// The download, in megabytes, for checking it will fit on disk.
  ///
  /// Separate from [approximateSize], which is prose for the reader and cannot
  /// be compared against anything. Measured from the actual file rather than
  /// rounded from the label.
  final int downloadMb;

  /// Rough resident cost of the weights, in megabytes.
  final int ramMb;

  /// Least device memory this is sensible on, in megabytes. Deliberately above
  /// [ramMb] — the OS, Flutter, the corpus database and the vector index are
  /// all resident too, and a model that just barely fits is one that gets the
  /// app killed under memory pressure.
  ///
  /// Compared against what the OS *reports*, which is materially less than what
  /// the device is sold as: a 4 GB Android reports about 3,967 MB, because the
  /// kernel reserves the rest. These were first written against the marketing
  /// figures and immediately mis-fired — a 4 GB emulator that had already run
  /// the 0.6B was told it did not have the memory for it. Each is set roughly a
  /// tier below the nominal size it is meant to admit.
  final int minDeviceRamMb;

  final int maxTokens;
  final int contextBudgetChars;
  final String note;

  /// Which family the runtime should treat this as. Carried per model rather
  /// than fixed, because the two here are from different families and a single
  /// hardcoded `gemmaIt` — left over from when both were Gemma — would be
  /// wrong for each of them.
  final ModelType modelType;

  /// What a *phone* needs, or null if this model is desktop-only.
  ///
  /// Separate from [minDeviceRamMb] because the same number cannot serve both.
  /// A desktop may page and is limited by physical memory; iOS and Android cap
  /// what a single app may hold at well under the physical amount, and going
  /// over means the OS kills the app rather than swapping. So a 16 GB phone
  /// reports 16 GB and still cannot hold a 6 GB model, while a 16 GB laptop
  /// can.
  ///
  /// A ceiling, not a floor: the small models stay available everywhere, so a
  /// 4 GB Linux machine is offered the one that runs on it instead of being
  /// told nothing fits.
  ///
  /// The phone figures are deliberately cautious and are the least-evidenced
  /// numbers here — only the 0.6B has been run on real hardware. Being too
  /// conservative costs a flagship reader a better model; being too generous
  /// costs an ordinary reader a multi-gigabyte download that ends in a crash.
  final int? minPhoneRamMb;

  /// The container format, which decides which engine will accept the model.
  ///
  /// Explicit because both `installModel` and `createModel` default it to
  /// `ModelFileType.task`, and the engine registry matches on it exactly: with
  /// LiteRT-LM the only registered engine, a `.litertlm` file left declared as
  /// `task` downloads and installs perfectly and then fails at the first
  /// question with "No inference engine can handle this model". The package
  /// README's advice to use `task` for `.litertlm` predates this enum value.
  final ModelFileType fileType;

  const LocalModelChoice({
    required this.id,
    required this.name,
    required this.fileName,
    required this.url,
    required this.approximateSize,
    required this.downloadMb,
    required this.ramMb,
    required this.minDeviceRamMb,
    required this.maxTokens,
    required this.contextBudgetChars,
    required this.note,
    required this.modelType,
    required this.fileType,
    this.minPhoneRamMb,
  });

  Future<bool> isInstalled() async {
    try {
      return await FlutterGemma.isModelInstalled(fileName);
    } catch (_) {
      return false;
    }
  }

  /// Delete the downloaded weights.
  ///
  /// Half a gigabyte the reader can no longer account for is not something to
  /// leave on a phone with no way to remove it, and "reinstall the app" is not
  /// an answer when doing so also discards their library, notes and highlights.
  Future<void> uninstall() async {
    // Unloaded first: the runtime holds the file open, and on Windows deleting
    // it underneath a live handle fails outright rather than quietly.
    await _LocalModelRuntime.instance.unload();
    await FlutterGemma.uninstallModel(fileName);
  }

  /// Download and install, reporting progress 0-100.
  Stream<int> install() {
    final progress = StreamController<int>();
    () async {
      try {
        await FlutterGemma.installModel(
                modelType: modelType, fileType: fileType)
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
  /// Every model on offer, across all platforms.
  ///
  /// Qwen throughout, and deliberately so: it publishes at every size from
  /// 0.6B to 8B under Apache-2.0 with no gate, which means one family can
  /// cover a phone and a desktop workstation without the picker turning into
  /// a tour of unrelated projects. Gemma was the original choice and is not
  /// usable here at all — its repositories are gated behind a HuggingFace
  /// account, which is exactly what this backend promises readers they will
  /// not need.
  ///
  /// All `.litertlm`, the format LiteRT-LM reads, because LiteRT-LM is the
  /// only engine covering desktop as well as phones. MediaPipe reads `.task`
  /// and is Android and iOS only.
  ///
  /// Qwen 3 rather than 3.5 or 3.6, which do exist upstream: neither has a
  /// LiteRT build, and 3.5 starts at 4B while 3.6 starts at 27B, so even
  /// converted they would miss the phone end entirely. Worth re-checking when
  /// `litert-community` catches up.
  ///
  /// SmolLM 135M was offered here as a 170 MB option for older phones and was
  /// removed after being tried on a device: asked what baptism is, with the
  /// Westminster catechisms and Aquinas retrieved and in front of it, it
  /// answered with advice about learning a foreign language. It did not attend
  /// to the passages at all, which is the one thing this backend exists to do.
  static const LocalModelChoice qwen3_06b = LocalModelChoice(
    id: 'qwen3-0.6b',
    name: 'Qwen 3 0.6B',
    fileName: 'qwen3_0_6b_mixed_int4.litertlm',
    url: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/'
        'qwen3_0_6b_mixed_int4.litertlm',
    approximateSize: '500 MB',
    downloadMb: 497,
    ramMb: 700,
    // Admits a nominal 3 GB phone, excludes a 2 GB one. Verified: it runs on
    // a device reporting 3,967 MB.
    minDeviceRamMb: 2600,
    minPhoneRamMb: 2600,
    maxTokens: 2048,
    contextBudgetChars: 3000,
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    note: 'Small enough for any recent phone. Good at summarising and '
        'comparing the passages Council retrieves; a hosted model is still '
        'better for open-ended questions.',
  );

  static const LocalModelChoice qwen3_17b = LocalModelChoice(
    id: 'qwen3-1.7b',
    name: 'Qwen 3 1.7B',
    fileName: 'Qwen3_1.7B.litertlm',
    url: 'https://huggingface.co/litert-community/Qwen3-1.7B/resolve/main/'
        'Qwen3_1.7B.litertlm',
    approximateSize: '2.1 GB',
    downloadMb: 2056,
    ramMb: 2400,
    // Admits a nominal 6 GB desktop; on a phone it wants a nominal 12 GB,
    // because 2.4 GB resident has to fit inside a per-app cap rather than
    // inside physical memory.
    minDeviceRamMb: 5000,
    minPhoneRamMb: 11000,
    maxTokens: 2048,
    contextBudgetChars: 4000,
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    note: 'Noticeably better reasoning than the 0.6B. Only worth it on a '
        'phone with plenty of memory to spare.',
  );

  static const LocalModelChoice qwen3_4b = LocalModelChoice(
    id: 'qwen3-4b-2507',
    name: 'Qwen 3 4B Instruct',
    fileName: 'qwen3_4b_instruct_2507_mixed_int4.litertlm',
    url: 'https://huggingface.co/litert-community/Qwen3-4B-Instruct-2507/'
        'resolve/main/qwen3_4b_instruct_2507_mixed_int4.litertlm',
    approximateSize: '2.7 GB',
    downloadMb: 2659,
    ramMb: 3200,
    // Desktop only: 3.2 GB resident is beyond what a phone will let one app
    // hold, whatever its physical memory says.
    minDeviceRamMb: 7000,
    maxTokens: 4096,
    contextBudgetChars: 6000,
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    note: 'The best balance on a desktop. Handles a longer question and more '
        'retrieved text than the smaller two.',
  );

  static const LocalModelChoice qwen3_8b = LocalModelChoice(
    id: 'qwen3-8b',
    name: 'Qwen 3 8B',
    fileName: 'qwen3_8b_mixed_int4.litertlm',
    url: 'https://huggingface.co/litert-community/Qwen3-8B/resolve/main/'
        'qwen3_8b_mixed_int4.litertlm',
    approximateSize: '4.9 GB',
    downloadMb: 4887,
    ramMb: 6000,
    // Admits a nominal 16 GB machine. Desktop only, as above.
    minDeviceRamMb: 14000,
    maxTokens: 4096,
    contextBudgetChars: 8000,
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    note: 'The most capable option, and the heaviest. For a machine with '
        'memory to spare, where it approaches what a hosted model gives you.',
  );

  /// Every model, for resolving a stored id whatever device wrote it.
  ///
  /// A reader who picked the 4B on a laptop and opens the same account's
  /// settings on a phone must not hit a lookup failure; [byId] resolves
  /// against this and [recommended] decides what is sensible here.
  static const List<LocalModelChoice> catalogue = [
    qwen3_06b,
    qwen3_17b,
    qwen3_4b,
    qwen3_8b,
  ];

  /// What to offer on this device, smallest first.
  ///
  /// Split because the sizes that make sense differ by an order of magnitude:
  /// a 4.9 GB model is reasonable on a desktop and absurd on a phone, and a
  /// picker showing all four everywhere would mostly be offering downloads
  /// that cannot run.
  static List<LocalModelChoice> get all =>
      catalogue.where((m) => _isDesktop || m.minPhoneRamMb != null).toList();

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// [all], minus anything this device does not have the memory for.
  ///
  /// [all] is what the platform *could* run; this is what this machine can.
  /// Without it `minDeviceRamMb` was decoration: a 2 GB phone was offered the
  /// 2.1 GB model, which would have downloaded in full and then been killed by
  /// the OS — and old phones are precisely who this feature is for, since the
  /// built-in model covers the new ones.
  ///
  /// Never returns empty. If nothing fits, the smallest is offered anyway with
  /// [fitsThisDevice] false, so the screen can say plainly that it is more than
  /// the device has rather than hiding the feature and explaining nothing.
  static Future<List<LocalModelChoice>> availableHere() async {
    final total = await DeviceMemory.totalMb();
    if (total == null) return all;
    final fits = all.where((m) => total >= m.requiredMb).toList();
    return fits.isEmpty ? [all.first] : fits;
  }

  /// What this model asks for on the platform it is running on.
  int get requiredMb =>
      LocalModelChoice._isDesktop ? minDeviceRamMb : (minPhoneRamMb ?? 1 << 30);

  /// Whether this device has the memory this model asks for. Permissive when
  /// the amount cannot be read — see [DeviceMemory.totalMb].
  Future<bool> fitsThisDevice() => DeviceMemory.meets(requiredMb);

  /// Resolved against the whole catalogue, not the platform's shortlist, so a
  /// choice made on another device is recognised rather than silently reset.
  /// Falls back to what this device would recommend when the id is unknown —
  /// a model removed in a later version, most likely.
  static LocalModelChoice byId(String id) => catalogue.firstWhere(
        (m) => m.id == id,
        orElse: recommended,
      );

  /// Whether a downloaded model can run on this platform at all.
  ///
  /// Every platform Council targets, now that LiteRT-LM is the engine. Ollama
  /// is still the better answer on a desktop, but it is only a better answer
  /// for someone who has it — this exists for the reader who does not, and
  /// sending them off to install a server was the gap.
  ///
  /// The architecture caveats match what the download page already promises:
  /// LiteRT-LM covers macOS on Apple silicon (not Intel), Windows x64 (not
  /// arm64) and Linux on both, and those are exactly the builds shipped.
  static bool get runsHere =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  /// Whether this model's download will fit in the space left on the device.
  Future<bool> fitsOnDisk() => DeviceStorage.hasRoomFor(downloadMb);

  /// The two or three models worth putting in front of this reader.
  ///
  /// Everything that fits is not a useful list — on a workstation that is four
  /// entries differing by an order of magnitude in both download size and
  /// speed, with nothing to say which is which. These are the three questions a
  /// reader actually has: what is the sensible choice, what if I want it
  /// smaller and faster, and what if I want the best answers this machine can
  /// give.
  ///
  /// [LocalModelTier.recommended] is deliberately *not* the largest that fits
  /// once there are three or more. The largest is the slowest, and picking it
  /// by default would make the feature feel broken on the very machines that
  /// can run the most; it is offered as [LocalModelTier.large] instead, plainly
  /// described as slower.
  static Future<List<({LocalModelTier tier, LocalModelChoice model})>>
      tiersHere() async {
    final fits = await availableHere();
    if (fits.length == 1) {
      return [(tier: LocalModelTier.recommended, model: fits.first)];
    }
    if (fits.length == 2) {
      return [
        (tier: LocalModelTier.small, model: fits.first),
        (tier: LocalModelTier.recommended, model: fits.last),
      ];
    }
    return [
      (tier: LocalModelTier.small, model: fits.first),
      (tier: LocalModelTier.recommended, model: fits[fits.length - 2]),
      (tier: LocalModelTier.large, model: fits.last),
    ];
  }

  /// The most capable model this device can actually hold.
  ///
  /// The point of the catalogue: a Mac with 64 GB should be pointed at the 8B
  /// and a 3 GB Android at the 0.6B, without either reader having to know that
  /// a picker exists. This previously returned the *smallest* option for the
  /// platform and never consulted memory at all, so a Mac Studio was offered
  /// the 1.7B by default — the weakest thing it could possibly run.
  ///
  /// Defined as whatever the picker labels [LocalModelTier.recommended], so
  /// the model selected by default and the row marked "Recommended" can never
  /// disagree — which they did briefly, this returning the largest that fits
  /// while the picker recommended one step below it.
  static Future<LocalModelChoice> recommendedHere() async {
    final tiers = await tiersHere();
    return tiers
        .firstWhere((t) => t.tier == LocalModelTier.recommended)
        .model;
  }

  /// The conservative default, for the moment before memory has been read.
  ///
  /// [InferenceProvider] needs a value at construction and the memory probe is
  /// asynchronous, so this is the smallest — being briefly under-ambitious
  /// costs a reader nothing, while briefly claiming a model the device cannot
  /// hold would show them a download they should not start. Replaced by
  /// [recommendedHere] as soon as `load()` completes.
  static LocalModelChoice recommended() => all.first;
}
