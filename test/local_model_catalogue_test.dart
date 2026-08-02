import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/services/device_memory.dart';
import 'package:council/src/services/device_storage.dart';
import 'package:council/src/services/inference/local_model_backend.dart';

/// These run on the host, so on a developer machine they exercise the desktop
/// branch of the catalogue — the one hardest to reach by hand, since it needs
/// a macOS, Windows or Linux build rather than an emulator.
void main() {
  group('the catalogue', () {
    test('offers only Qwen, ungated and Apache-2.0 by construction', () {
      for (final m in LocalModelChoice.catalogue) {
        expect(m.name, startsWith('Qwen'),
            reason: 'Gemma and friends are gated behind a HuggingFace '
                'account, which this backend promises readers they do not '
                'need. Anything added here must be fetchable anonymously.');
        expect(m.url, startsWith('https://huggingface.co/litert-community/'));
      }
    });

    test('every model is LiteRT-LM, declared as well as named', () {
      for (final m in LocalModelChoice.catalogue) {
        expect(m.fileName, endsWith('.litertlm'));
        expect(m.url, endsWith(m.fileName));
        // The pair that matters: a .litertlm file left declared as
        // ModelFileType.task installs cleanly and then fails at the first
        // question with "No inference engine can handle this model".
        expect(m.fileType, ModelFileType.litertlm);
        expect(m.modelType, ModelType.qwen3);
      }
    });

    test('ids are unique, since preferences are stored by id', () {
      final ids = LocalModelChoice.catalogue.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('what is offered here is a subset of the catalogue', () {
      for (final m in LocalModelChoice.all) {
        expect(LocalModelChoice.catalogue, contains(m));
      }
    });

    test('the offered list is ordered smallest first', () {
      final ram = LocalModelChoice.all.map((m) => m.ramMb).toList();
      final sorted = [...ram]..sort();
      expect(ram, sorted,
          reason: 'recommended() returns all.first and is meant to be the '
              'most conservative option, not merely the first written.');
    });
  });

  group('resolving a stored id', () {
    test('finds every model in the catalogue, offered here or not', () {
      // The case this exists for: chosen on a desktop, opened on a phone.
      // Asserted over the whole catalogue rather than by hunting for one this
      // platform excludes, because on a desktop nothing is excluded.
      for (final m in LocalModelChoice.catalogue) {
        expect(LocalModelChoice.byId(m.id).id, m.id);
      }
    });

    test('falls back to the recommendation for an id since removed', () {
      // 'gemma3-1b' shipped before the Gemma weights turned out to be gated.
      expect(LocalModelChoice.byId('gemma3-1b').id,
          LocalModelChoice.recommended().id);
    });
  });

  test('a downloaded model is offered on every platform Council ships', () {
    expect(LocalModelChoice.runsHere, isTrue,
        reason: 'LiteRT-LM covers android, ios, macOS, Windows and Linux. '
            'If this fails the host is a platform the engine does not '
            'support, and the option should be hidden rather than broken.');
  });

  group('the memory gate', () {
    tearDown(() => DeviceMemory.debugSetTotalMb(null, unknown: false));

    test('hides a model the device cannot hold', () async {
      // A 2 GB phone — an iPhone 8, which can install Council because iOS 16
      // is both its ceiling and the app's floor.
      DeviceMemory.debugSetTotalMb(2048);
      final offered = await LocalModelChoice.availableHere();
      final fitting =
          LocalModelChoice.all.where((m) => m.minDeviceRamMb <= 2048);
      if (fitting.isEmpty) {
        // Nothing fits: exactly one is shown so the card can say why, and it
        // is honest about not fitting.
        expect(offered, hasLength(1));
        expect(await offered.first.fitsThisDevice(), isFalse);
      } else {
        for (final m in offered) {
          expect(m.minDeviceRamMb, lessThanOrEqualTo(2048),
              reason: 'offering a model that cannot load means a '
                  'multi-gigabyte download ending in the OS killing the app');
        }
      }
    });

    test('never offers nothing, so the screen can explain itself', () async {
      DeviceMemory.debugSetTotalMb(512);
      final offered = await LocalModelChoice.availableHere();
      expect(offered, hasLength(1));
      expect(await offered.first.fitsThisDevice(), isFalse,
          reason: 'the card shows why rather than vanishing');
    });

    test('offers everything the platform has when memory is ample', () async {
      DeviceMemory.debugSetTotalMb(32768);
      expect(await LocalModelChoice.availableHere(), LocalModelChoice.all);
    });

    test('is permissive when the amount cannot be read', () async {
      DeviceMemory.debugSetTotalMb(null, unknown: true);
      expect(await DeviceMemory.meets(999999), isTrue,
          reason: 'unknown must not be treated as too little — hiding the '
              'feature from a device that merely failed to answer is worse '
              'than offering one it might not run');
    });
  });

  group('the recommendation matches the machine', () {
    tearDown(() => DeviceMemory.debugSetTotalMb(null, unknown: false));

    // The whole point of a catalogue: a workstation and an old phone should
    // not be pointed at the same model. This previously returned the smallest
    // option for the platform whatever the device had, so a 64 GB Mac was
    // recommended the 1.7B — the weakest thing it could run.
    Future<String> recommendedAt(int mb) async {
      DeviceMemory.debugSetTotalMb(mb);
      return (await LocalModelChoice.recommendedHere()).name;
    }

    test('more memory earns a more capable model', () async {
      final small = await recommendedAt(3000);
      final large = await recommendedAt(64000);
      expect(small, isNot(large));
      final smallRam = LocalModelChoice.catalogue
          .firstWhere((m) => m.name == small)
          .ramMb;
      final largeRam = LocalModelChoice.catalogue
          .firstWhere((m) => m.name == large)
          .ramMb;
      expect(largeRam, greaterThan(smallRam));
    });

    test('the recommendation is always one the device can hold', () async {
      for (final mb in [2048, 3000, 6000, 8000, 16000, 64000]) {
        DeviceMemory.debugSetTotalMb(mb);
        final pick = await LocalModelChoice.recommendedHere();
        final offered = await LocalModelChoice.availableHere();
        expect(offered, contains(pick));
        // Below the floor nothing fits and the smallest is shown with a
        // warning; above it, the pick must genuinely fit.
        if (offered.length > 1 || mb >= LocalModelChoice.all.first.minDeviceRamMb) {
          expect(mb, greaterThanOrEqualTo(pick.minDeviceRamMb));
        }
      }
    });

    test('it is never the smallest when the device can do better', () async {
      DeviceMemory.debugSetTotalMb(64000);
      final offered = await LocalModelChoice.availableHere();
      final pick = await LocalModelChoice.recommendedHere();
      expect(pick, isNot(offered.first));
    });

    test('it agrees with the row the picker marks Recommended', () async {
      // These disagreed once — the default was the largest that fits while
      // the picker recommended a step below it, so the selected radio and the
      // "Recommended" label pointed at different models.
      for (final mb in [3000, 8000, 64000]) {
        DeviceMemory.debugSetTotalMb(mb);
        final tiers = await LocalModelChoice.tiersHere();
        final labelled = tiers
            .firstWhere((t) => t.tier == LocalModelTier.recommended)
            .model;
        expect((await LocalModelChoice.recommendedHere()).id, labelled.id);
      }
    });

    test('a modest desktop is offered something rather than nothing',
        () async {
      // 4 GB Linux box. The 0.6B runs there; being told the 1.7B is too big
      // and offered no alternative was the old behaviour.
      DeviceMemory.debugSetTotalMb(4000);
      final offered = await LocalModelChoice.availableHere();
      expect(offered, isNotEmpty);
      expect(await offered.first.fitsThisDevice(), isTrue,
          reason: 'the smallest model must be reachable on every platform, '
              'not just on phones');
    });

    test('the heaviest models are never offered on a phone', () async {
      DeviceMemory.debugSetTotalMb(64000);
      final offered = await LocalModelChoice.availableHere();
      final phone = Platform.isAndroid || Platform.isIOS;
      for (final m in offered) {
        if (phone) {
          expect(m.minPhoneRamMb, isNotNull,
              reason: 'phones cap what one app may hold well below physical '
                  'memory, so a 16 GB phone still cannot hold a 6 GB model');
        }
      }
      if (!phone) {
        expect(offered, contains(LocalModelChoice.qwen3_8b));
      }
    });

    test('a phone needs more headroom than a desktop for the same model',
        () async {
      for (final m in LocalModelChoice.catalogue) {
        if (m.minPhoneRamMb == null) continue;
        expect(m.minPhoneRamMb, greaterThanOrEqualTo(m.minDeviceRamMb),
            reason: 'a per-app cap is stricter than physical memory, so the '
                'phone floor can never be the more generous of the two');
      }
    });
  });

  group('the tiers offered to a reader', () {
    tearDown(() {
      DeviceMemory.debugSetTotalMb(null, unknown: false);
      DeviceStorage.debugFreeMb = null;
    });

    Future<List<({LocalModelTier tier, LocalModelChoice model})>> at(
        int mb) async {
      DeviceMemory.debugSetTotalMb(mb);
      return LocalModelChoice.tiersHere();
    }

    test('never more than three, so the choice stays a choice', () async {
      for (final mb in [2048, 3000, 6000, 8000, 16000, 64000]) {
        expect((await at(mb)).length, inInclusiveRange(1, 3));
      }
    });

    test('always includes a recommendation', () async {
      for (final mb in [2048, 3000, 6000, 8000, 16000, 64000]) {
        expect((await at(mb)).map((e) => e.tier),
            contains(LocalModelTier.recommended));
      }
    });

    test('tiers run smallest to largest, and are distinct models', () async {
      final tiers = await at(64000);
      expect(tiers, hasLength(3));
      expect(tiers.map((e) => e.tier),
          [LocalModelTier.small, LocalModelTier.recommended,
           LocalModelTier.large]);
      final ram = tiers.map((e) => e.model.ramMb).toList();
      expect(ram, [...ram]..sort());
      expect(tiers.map((e) => e.model.id).toSet(), hasLength(3));
    });

    test('the recommendation is not the heaviest when there is a choice',
        () async {
      final tiers = await at(64000);
      final recommended =
          tiers.firstWhere((e) => e.tier == LocalModelTier.recommended).model;
      final large =
          tiers.firstWhere((e) => e.tier == LocalModelTier.large).model;
      expect(recommended.ramMb, lessThan(large.ramMb),
          reason: 'the largest that fits is also the slowest; defaulting to it '
              'makes the feature feel broken on the machines that can run the '
              'most');
    });

    test('every tier offered is one the device can actually hold', () async {
      for (final mb in [3000, 6000, 8000, 16000, 64000]) {
        for (final e in await at(mb)) {
          expect(mb, greaterThanOrEqualTo(e.model.requiredMb));
        }
      }
    });
  });

  group('the disk check', () {
    tearDown(() {
      DeviceStorage.debugFreeMb = null;
      DeviceStorage.debugUnknownFree = false;
    });

    test('refuses a model that will not fit in the space left', () async {
      DeviceStorage.debugFreeMb = 1000; // 1 GB free
      expect(await LocalModelChoice.qwen3_8b.fitsOnDisk(), isFalse,
          reason: 'a 4.9 GB download onto a 1 GB disk fails after the bytes '
              'have been fetched, which on a metered connection is paid for '
              'nothing');
    });

    test('leaves headroom rather than filling the disk exactly', () async {
      const model = LocalModelChoice.qwen3_06b;
      DeviceStorage.debugFreeMb = model.downloadMb + 10;
      expect(await model.fitsOnDisk(), isFalse,
          reason: 'the download lands as a file and is then installed, and a '
              'disk filled to the last megabyte breaks the OS, not just this '
              'app');
      DeviceStorage.debugFreeMb = model.downloadMb + 2000;
      expect(await model.fitsOnDisk(), isTrue);
    });

    test('is permissive when free space cannot be read', () async {
      DeviceStorage.debugUnknownFree = true;
      expect(await DeviceStorage.hasRoomFor(1 << 20), isTrue,
          reason: 'refusing a download because a probe failed is worse than '
              'letting it fail the way it already did');
    });

    test('every model declares a download size matching its label', () {
      for (final m in LocalModelChoice.catalogue) {
        expect(m.downloadMb, greaterThan(0));
        // The prose label and the number must not drift apart, since one is
        // shown to the reader and the other decides whether to allow it.
        final gb = m.downloadMb / 1024;
        final labelled = m.approximateSize.contains('GB')
            ? double.parse(m.approximateSize.split(' ').first)
            : double.parse(m.approximateSize.split(' ').first) / 1024;
        expect((gb - labelled).abs(), lessThan(0.35),
            reason: '${m.name}: label says ${m.approximateSize}, '
                'downloadMb says ${m.downloadMb}');
      }
    });
  });

  test('the platform decides the ceiling, not the floor', () {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
    // The heaviest model is desktop-only, because a phone's per-app memory cap
    // sits far below its physical RAM.
    expect(LocalModelChoice.all, contains(LocalModelChoice.qwen3_8b));
    // But the smallest stays available everywhere: a 4 GB Linux machine should
    // be offered the model that runs on it, not told nothing fits.
    expect(LocalModelChoice.all, contains(LocalModelChoice.qwen3_06b));
  });
}
