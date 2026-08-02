import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

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
    test('finds a model this platform does not itself offer', () {
      // The case this exists for: chosen on a desktop, opened on a phone.
      final elsewhere = LocalModelChoice.catalogue
          .firstWhere((m) => !LocalModelChoice.all.contains(m));
      expect(LocalModelChoice.byId(elsewhere.id).id, elsewhere.id);
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

  test('desktop is offered larger models than a phone', () {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
    expect(LocalModelChoice.all, isNot(contains(LocalModelChoice.qwen3_06b)),
        reason: 'the 0.6B exists for phones; a desktop should be offered '
            'something that uses the memory it has');
    expect(LocalModelChoice.all, contains(LocalModelChoice.qwen3_8b));
  });
}
