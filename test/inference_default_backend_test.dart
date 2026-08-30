import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:council/src/services/inference/inference_provider.dart';
import 'package:council/src/services/inference/local_model_backend.dart';
import 'package:council/src/services/inference/platform_llm_backend.dart';

/// Which backend a reader who has never chosen one starts on.
///
/// It used to be search-only, so the AI step of onboarding opened on the app's
/// least capable setting and anyone who wanted an answer had to go looking for
/// the option that gives one. It now opens on whichever private backend the
/// device can offer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('site.spencersmith.council/platform_llm');

  /// Answer the availability call the way a given device would.
  void poseAsDevice({required bool hasBuiltInModel}) {
    PlatformLlmBackend.debugForgetAvailability();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'availability') return null;
      return hasBuiltInModel
          ? {'supported': true, 'reason': 'available', 'detail': 'Ready.'}
          : {
              'supported': true,
              'reason': 'device_not_eligible',
              'detail': 'This device cannot run it.',
            };
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PlatformLlmBackend.debugForgetAvailability();
  });

  test('a device with a built-in model opens on it', () async {
    poseAsDevice(hasBuiltInModel: true);

    final inference = InferenceProvider();
    await inference.load();

    expect(inference.backendId, PlatformLlmBackend.backendId);
  });

  test('a device without one opens on the local download', () async {
    poseAsDevice(hasBuiltInModel: false);

    final inference = InferenceProvider();
    await inference.load();

    // The engine runs on every architecture these tests are run on, so the
    // third case — neither backend available, search-only stands — is the one
    // asserted in 'a device that can run neither stays on search only'.
    expect(LocalModelChoice.runsHere, isTrue);
    expect(inference.backendId, LocalModelBackend.backendId);
  });

  test('a device that can run neither stays on search only', () async {
    // Nothing here can pose as a 32-bit phone, so this asserts the rule the
    // opening choice is built on rather than the wiring: with no built-in model
    // and no local engine there is nothing to lead with.
    expect(LocalModelChoice.runsOn(Abi.androidArm), isFalse);
  });

  test('the opening choice survives the launch after onboarding', () async {
    poseAsDevice(hasBuiltInModel: true);

    await InferenceProvider().load();

    // What onboarding does on finish. Before the choice was written back, this
    // is where it was lost: the reader saw the built-in model selected, never
    // touched the row, and the next launch had them on search-only.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_onboarded', true);

    final relaunched = InferenceProvider();
    await relaunched.load();

    expect(relaunched.backendId, PlatformLlmBackend.backendId);
  });

  test('an install already past onboarding is left on search only', () async {
    // Someone who has been through onboarding has been offered this choice and
    // left it where it was; switching a model on for them would be changing
    // their mind rather than defaulting.
    SharedPreferences.setMockInitialValues({'has_onboarded': true});
    poseAsDevice(hasBuiltInModel: true);

    final inference = InferenceProvider();
    await inference.load();

    expect(inference.backendId, 'none');
  });

  test('a stored choice is never overridden', () async {
    SharedPreferences.setMockInitialValues({'inference_backend': 'none'});
    poseAsDevice(hasBuiltInModel: true);

    final inference = InferenceProvider();
    await inference.load();

    expect(inference.backendId, 'none');
  });
}
