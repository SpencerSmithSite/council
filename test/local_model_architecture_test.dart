import 'dart:ffi' show Abi;

import 'package:council/src/services/inference/local_model_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which devices are offered a downloaded model.
///
/// This began as a platform check — `Platform.isAndroid || Platform.isIOS ||
/// …` — which asks a different question and answers it wrongly. A Galaxy A13
/// 5G running a 32-bit build satisfies `Platform.isAndroid`, so it was offered
/// the feature, downloaded 500 MB, and got a plugin exception about ABIs at
/// the first question. The engine ships arm64 only on Android; nothing about
/// that phone was ever going to work.
///
/// Every case is asserted against an architecture passed in, because the fault
/// was invisible on the only architecture the developer's machines have: a
/// test that could only ask about the host would have passed throughout.
void main() {
  group('runs on', () {
    test('the architectures LiteRT-LM actually ships', () {
      expect(LocalModelChoice.runsOn(Abi.androidArm64), isTrue);
      expect(LocalModelChoice.runsOn(Abi.iosArm64), isTrue);
      expect(LocalModelChoice.runsOn(Abi.macosArm64), isTrue);
      expect(LocalModelChoice.runsOn(Abi.windowsX64), isTrue);
      expect(LocalModelChoice.runsOn(Abi.linuxX64), isTrue);
      expect(LocalModelChoice.runsOn(Abi.linuxArm64), isTrue);
    });

    test('not 32-bit Android — the phone that found this', () {
      expect(LocalModelChoice.runsOn(Abi.androidArm), isFalse);
      expect(LocalModelChoice.runsOn(Abi.androidIA32), isFalse);
    });

    test('not x86 Android: the app ships no LiteRT for that slice', () {
      expect(LocalModelChoice.runsOn(Abi.androidX64), isFalse);
    });

    test('not an Intel Mac, and not a Windows on Arm PC', () {
      // Both caveats were already written in the doc comment and neither was
      // enforced, which is the same defect as the phone — just rarer hardware.
      expect(LocalModelChoice.runsOn(Abi.macosX64), isFalse);
      expect(LocalModelChoice.runsOn(Abi.windowsArm64), isFalse);
    });
  });

  group('the reason given', () {
    test('is nothing at all where it runs', () {
      expect(LocalModelChoice.reasonFor(Abi.androidArm64), isNull);
      expect(LocalModelChoice.reasonFor(Abi.macosArm64), isNull);
    });

    test('names the actual obstacle, not a generic apology', () {
      // The software, not the processor: the Galaxy A13 5G that found this
      // has a 64-bit chip and a 32-bit kernel, and telling its owner their
      // hardware was too old would be false.
      expect(LocalModelChoice.reasonFor(Abi.androidArm),
          contains('32-bit version of Android'));
      expect(LocalModelChoice.reasonFor(Abi.androidArm),
          contains('system software'));
      expect(LocalModelChoice.reasonFor(Abi.macosX64), contains('Apple'));
      // One sentence covers Windows on Arm and 32-bit x86 alike, so it names
      // what is needed rather than what the machine is.
      expect(LocalModelChoice.reasonFor(Abi.windowsArm64),
          contains('Intel or AMD'));
    });

    test('exists for every architecture that cannot run one', () {
      // Including ones not enumerated by hand: an unfamiliar architecture
      // should still produce a sentence rather than a null the UI would
      // silently render as an empty card.
      for (final abi in [
        Abi.androidArm,
        Abi.androidIA32,
        Abi.androidX64,
        Abi.macosX64,
        Abi.windowsArm64,
        Abi.windowsIA32,
        Abi.iosX64,
        Abi.linuxIA32,
        Abi.linuxRiscv64,
      ]) {
        expect(LocalModelChoice.reasonFor(abi), isNotNull, reason: '$abi');
        expect(LocalModelChoice.reasonFor(abi), isNotEmpty, reason: '$abi');
      }
    });

    test('agrees with runsOn, on every architecture there is', () {
      // The UI keys off `runsHere` and the copy off `unsupportedReason`. If
      // they ever disagree, one of them shows a reader a contradiction.
      for (final abi in Abi.values) {
        expect(
          LocalModelChoice.reasonFor(abi) == null,
          LocalModelChoice.runsOn(abi),
          reason: '$abi',
        );
      }
    });
  });
}
