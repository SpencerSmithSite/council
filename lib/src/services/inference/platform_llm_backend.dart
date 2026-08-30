import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'inference_backend.dart';

/// Why the platform's own model cannot be used, when it cannot.
///
/// Kept as a type rather than a string because the three unavailable cases need
/// different treatment in the UI: two are fixable by the reader and one is not,
/// and only [notEligible] should stop the option being offered at all.
enum PlatformLlmState {
  /// Ready to answer.
  available,

  /// The OS is too old for the framework to exist.
  osTooOld,

  /// The framework exists but this hardware cannot run the model.
  notEligible,

  /// Supported, but the reader has not switched Apple Intelligence on.
  notEnabled,

  /// Supported and enabled; the model is still downloading.
  modelNotReady,

  /// No bridge on this platform — Android, desktop, or a build without it.
  unsupportedPlatform,

  /// The bridge answered with something this version does not recognise.
  unknown;

  static PlatformLlmState fromReason(String? reason, bool supported) {
    switch (reason) {
      case 'available':
        return PlatformLlmState.available;
      case 'device_not_eligible':
        return PlatformLlmState.notEligible;
      case 'not_enabled':
        return PlatformLlmState.notEnabled;
      case 'model_not_ready':
        return PlatformLlmState.modelNotReady;
      case 'os_too_old':
        return PlatformLlmState.osTooOld;
      default:
        return supported ? PlatformLlmState.unknown
                         : PlatformLlmState.unsupportedPlatform;
    }
  }

  /// Whether to show this backend in the picker at all.
  ///
  /// A reader whose iPhone simply cannot run Apple Intelligence is not helped
  /// by a permanently greyed-out row; one who has merely left it switched off
  /// is, because the row tells them where the switch is.
  bool get worthOffering => switch (this) {
        PlatformLlmState.available ||
        PlatformLlmState.notEnabled ||
        PlatformLlmState.modelNotReady =>
          true,
        _ => false,
      };
}

/// A snapshot of what the platform reported.
class PlatformLlmAvailability {
  final PlatformLlmState state;
  final String detail;

  const PlatformLlmAvailability(this.state, this.detail);

  bool get isAvailable => state == PlatformLlmState.available;
}

/// The language model built into the device, used through the OS.
///
/// On iOS this is Apple's Foundation Models framework: a model already on the
/// phone, with no key, no download and no network. That makes it the only
/// generating backend that keeps the app's own privacy claim intact —
/// [isPrivate] is true here for the same reason it is true for Ollama on your
/// own hardware, and unlike the cloud backends.
///
/// Availability is asked of the platform, never inferred from a version number.
/// Apple Intelligence needs an iPhone 15 Pro or newer, so an iOS 26 device can
/// qualify while a newer OS on older silicon cannot; and only the platform can
/// distinguish hardware that will never support it from a switch the reader has
/// not turned on.
class PlatformLlmBackend implements InferenceBackend {
  static const MethodChannel _methods =
      MethodChannel('site.spencersmith.council/platform_llm');
  static const EventChannel _events =
      EventChannel('site.spencersmith.council/platform_llm_stream');

  /// Cached because the picker, the onboarding step and the status line all ask
  /// on the same frame, and the platform call is not free.
  static PlatformLlmAvailability? _cached;

  /// Test seam: forget what the platform last said, so one test run can pose as
  /// several devices. The app never needs it — a reader who has just switched
  /// Apple Intelligence on is served by `availability(refresh: true)`.
  @visibleForTesting
  static void debugForgetAvailability() => _cached = null;

  const PlatformLlmBackend();

  static const String backendId = 'platform';

  @override
  String get id => backendId;

  /// Whether this platform has a bridge to a built-in model at all.
  ///
  /// iOS and macOS: Apple's Foundation Models framework is on both, and the
  /// same Swift file serves each runner. The Mac was left out originally and
  /// silently reported "no built-in model" on hardware that has Apple
  /// Intelligence — the gate here said `isIOS` and the macOS runner never
  /// registered the channel, so both halves had to be wrong for the symptom to
  /// appear, and both had to be fixed.
  static bool get bridgedHere => Platform.isIOS || Platform.isMacOS;

  @override
  String get displayName =>
      bridgedHere ? 'Apple Intelligence' : 'Built-in model';

  @override
  String get description =>
      'The model already on this device. No account, no key, no download, and '
      'nothing leaves it.';

  @override
  bool get isPrivate => true;

  /// Deliberately small. Apple's on-device model has a context window of a few
  /// thousand tokens, an order of magnitude under the cloud backends, and
  /// overfilling it degrades the answer rather than erroring — so retrieval
  /// must send fewer passages here, not truncated ones.
  @override
  int get contextBudgetChars => 4000;

  /// Ask the platform. [refresh] skips the cache, for a reader who has just
  /// gone to Settings to switch Apple Intelligence on and come back.
  static Future<PlatformLlmAvailability> availability(
      {bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;

    if (!bridgedHere) {
      return _cached = const PlatformLlmAvailability(
        PlatformLlmState.unsupportedPlatform,
        'This platform has no built-in model Council can use yet.',
      );
    }

    try {
      final raw = await _methods.invokeMapMethod<String, dynamic>('availability');
      final supported = raw?['supported'] as bool? ?? false;
      final state = PlatformLlmState.fromReason(
          raw?['reason'] as String?, supported);
      return _cached = PlatformLlmAvailability(
        state,
        raw?['detail'] as String? ?? 'Unavailable.',
      );
    } on MissingPluginException {
      // Running against a build without the bridge compiled in. Not an error
      // worth surfacing as a failure — the option simply is not there.
      return _cached = const PlatformLlmAvailability(
        PlatformLlmState.unsupportedPlatform,
        'This build of Council has no built-in model support.',
      );
    } catch (e) {
      return _cached = PlatformLlmAvailability(
        PlatformLlmState.unknown,
        'Could not ask the system about its model: $e',
      );
    }
  }

  @override
  Future<BackendStatus> checkStatus() async {
    final report = await availability(refresh: true);
    return report.isAvailable
        ? BackendStatus.available(report.detail)
        : BackendStatus.unavailable(report.detail);
  }

  @override
  Stream<String> generate({required String prompt, String? system}) {
    return _events
        .receiveBroadcastStream({'prompt': prompt, 'system': system})
        .map((event) => event as String)
        .handleError((Object error) {
      throw InferenceException(
        error is PlatformException
            ? error.message ?? 'The built-in model failed to answer.'
            : error.toString(),
      );
    });
  }

  /// Empty on purpose: the platform ships exactly one model and does not name
  /// it. There is nothing for a model picker to offer.
  @override
  Future<List<String>> availableModels() async => const [];

  @override
  void dispose() {}
}
