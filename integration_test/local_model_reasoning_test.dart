import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:council/src/services/inference/local_model_backend.dart';

/// What the downloaded model actually emits, against real weights.
///
/// Qwen 3 is a hybrid reasoning model, and its chain of thought reached the
/// transcript looking like prose — the markers around it are dropped by
/// `MarkdownBody` as unknown HTML, so the rendered answer gave no clue that
/// anything had been stripped or should have been. Nothing short of the raw
/// token stream settles what the model is emitting, and no fixture can stand
/// in for it: whether the reasoning arrives as `<think>` tags, as the SDK's
/// rewritten `<|channel>thought` markers, or unmarked, is a property of the
/// model bundle and the engine build.
///
/// So this runs the real thing. It is slow and it downloads 500 MB the first
/// time, which is why it is opt-in rather than part of the suite:
///
///     flutter test integration_test/local_model_reasoning_test.dart -d macos \
///       --dart-define=RUN_LOCAL_MODEL=true
///
/// Add `--dart-define=PRINT_RAW_OUTPUT=true` to dump the raw stream chunk by
/// chunk, which is the diagnostic the fix was written against.
const _run = bool.fromEnvironment('RUN_LOCAL_MODEL');
const _printRaw = bool.fromEnvironment('PRINT_RAW_OUTPUT');

/// A question that reliably makes a small model reason first: it asks for a
/// comparison across several retrieved passages rather than a lookup, which is
/// the shape that produced the reported leak.
const _question = 'Compare views on baptism';

/// Stands in for retrieval. Deliberately not the real thing — this is a test
/// about generation, and running the retriever would make a failure here
/// ambiguous between the two.
const _sources = '''
Relevant sources:

[1] Matthew 3:1 — In those days came John the Baptist, preaching in the
wilderness of Judaea.

[2] Westminster Confession XXVIII — Baptism is a sacrament of the New
Testament, ordained by Jesus Christ.

[3] Acts 19:1 — Paul, having passed through the upper coasts, came to Ephesus
and found certain disciples.
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const model = LocalModelChoice.qwen3_06b;

  setUpAll(() async {
    if (!_run) return;
    await FlutterGemma.initialize(inferenceEngines: const [LiteRtLmEngine()]);
    if (!await model.isInstalled()) {
      // ignore: avoid_print
      print('Downloading ${model.name} (${model.approximateSize})…');
      await for (final percent in model.install()) {
        if (percent % 20 == 0) {
          // ignore: avoid_print
          print('  $percent%');
        }
      }
    }
  });

  group('the downloaded model', () {
    testWidgets('does not put its reasoning in the answer', (_) async {
      if (!_run) {
        markTestSkipped(
          'Needs real weights — pass --dart-define=RUN_LOCAL_MODEL=true.',
        );
        return;
      }

      const backend = LocalModelBackend(choice: model);
      final buffer = StringBuffer();
      await for (final chunk in backend.generate(
        prompt: '$_sources\nUser question: $_question\n\n'
            'Answer using the provided sources. Cite them as [1], [2] and so '
            'on.',
        system: 'You are a theological research assistant.',
      )) {
        buffer.write(chunk);
      }
      final answer = buffer.toString();

      // ignore: avoid_print
      print('--- filtered answer ---\n$answer\n--- end ---');

      expect(answer.trim(), isNotEmpty);
      // The markers themselves, which is the cheap half of the check.
      expect(answer, isNot(contains('<think>')));
      expect(answer, isNot(contains('</think>')));
      expect(answer, isNot(contains('<|channel>')));
      expect(answer, isNot(contains('<channel|>')));
      // The reasoning register, which is the half that would have caught the
      // reported bug even with the markers absent. Qwen 3 opens its thinking
      // with a first-person plan and its answers with the substance.
      expect(
        answer.toLowerCase().trimLeft(),
        isNot(startsWith('first, looking at')),
      );
      expect(
        answer.toLowerCase(),
        isNot(contains('so, the key points are')),
      );
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('emits reasoning when nothing suppresses it', (_) async {
      if (!_run) {
        markTestSkipped(
          'Needs real weights — pass --dart-define=RUN_LOCAL_MODEL=true.',
        );
        return;
      }

      // The bare session, driven exactly as LocalModelBackend drove it before
      // the fix: no `/no_think`, no filter. This is the evidence that the
      // filter is removing something real rather than passing a test that
      // would pass with no model at all, and printing it is how the shape of
      // the markers was established in the first place.
      final runtime = await FlutterGemmaPlugin.instance.createModel(
        modelType: model.modelType,
        fileType: model.fileType,
        maxTokens: model.maxTokens,
        maxConcurrentSessions: 1,
      );
      final session = await runtime.openSession();
      final raw = StringBuffer();
      try {
        await session.addQueryChunk(
          Message.text(
            text: '$_sources\nUser question: $_question\n\n'
                'Answer using the provided sources.',
            isUser: true,
          ),
        );
        await for (final chunk in session.getResponseAsync()) {
          if (_printRaw) {
            // ignore: avoid_print
            print('raw chunk: ${jsonEncode(chunk)}');
          }
          raw.write(chunk);
        }
      } finally {
        await session.close();
        await runtime.close();
      }

      // ignore: avoid_print
      print('--- raw, unfiltered ---\n${jsonEncode(raw.toString())}\n--- end ---');

      // Not an assertion about *which* markers — that is what the print is
      // for, and pinning it would make this test fail on a model bundle that
      // reports reasoning the other way round without anything being wrong.
      expect(raw.toString().trim(), isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
