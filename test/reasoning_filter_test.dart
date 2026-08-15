import 'package:flutter_test/flutter_test.dart';
import 'package:council/src/services/inference/reasoning_filter.dart';

/// The filter, exercised on the chunk boundaries that make it hard.
///
/// The failure it exists to stop was not a parsing failure but a *rendering*
/// one: the markers reached the transcript intact, `MarkdownBody` dropped them
/// as unknown HTML, and the reasoning was left looking like prose. So the
/// assertions here are all about what survives, never about what the markers
/// looked like on the way through.
void main() {
  /// Feed [chunks] through and collect the answer.
  Future<String> filtered(List<String> chunks) async {
    final out = await ReasoningFilter.strip(Stream.fromIterable(chunks))
        .toList();
    return out.join();
  }

  /// The same text, delivered one character at a time. Every marker is split
  /// across a boundary this way, which is the case a naive `replaceAll` on
  /// each chunk gets wrong.
  Future<String> perCharacter(String text) => filtered(text.split(''));

  group('a stream with no reasoning in it', () {
    test('passes through unchanged', () async {
      expect(
        await filtered(['John ', 'baptised ', 'in the Jordan.']),
        'John baptised in the Jordan.',
      );
    });

    test('survives being split character by character', () async {
      expect(
        await perCharacter('Baptism [1] is discussed in [2].'),
        'Baptism [1] is discussed in [2].',
      );
    });

    test('keeps a lone angle bracket that starts no marker', () async {
      expect(
        await perCharacter('2 < 3 and <b> is not <think'),
        '2 < 3 and <b> is not <think',
      );
    });
  });

  test('reasoning opened before the stream started is NOT caught', () async {
    // Pinned as a known limit rather than left to be discovered. A template
    // that prefills `<think>` would make the closer the first thing the model
    // emits, and by then the reasoning has already been streamed to the
    // reader — catching it would mean withholding the start of every answer
    // on the chance that a closer follows. Qwen 3 emits its own opener, which
    // is what integration_test/local_model_reasoning_test.dart establishes
    // against the real weights. Change this test only alongside that evidence.
    // The marker itself is still removed — that much costs nothing and keeps
    // a raw tag out of the stored transcript. Only the prose ahead of it,
    // already streamed, gets through.
    expect(
      await perCharacter('reasoning with no opener</think>\n\nThe answer.'),
      'reasoning with no opener\n\nThe answer.',
    );
  });

  group('<think> blocks, the form Qwen 3 emits itself', () {
    test('are removed', () async {
      expect(
        await filtered(['<think>First, source [1]…</think>1. John:']),
        '1. John:',
      );
    });

    test('are removed when every marker straddles a chunk', () async {
      expect(
        await perCharacter('<think>scratch work</think>\n\nThe answer.'),
        'The answer.',
      );
    });

    test('do not swallow text that precedes them', () async {
      expect(
        await perCharacter('Before.<think>hidden</think>After.'),
        'Before.After.',
      );
    });

    test('are removed more than once', () async {
      expect(
        await perCharacter('<think>a</think>One.<think>b</think>Two.'),
        'One.Two.',
      );
    });
  });

  group('<|channel>thought blocks, the form the SDK rewrites into', () {
    test('are removed', () async {
      expect(
        await perCharacter(
          '<|channel>thought\nreasoning here<channel|>The answer.',
        ),
        'The answer.',
      );
    });

    test('are removed when mixed with a <think> block', () async {
      expect(
        await perCharacter(
          '<think>a</think><|channel>thought\nb<channel|>Answer.',
        ),
        'Answer.',
      );
    });
  });

  test('reasoning the model never closed is dropped, not printed', () async {
    // The whole budget went to thinking. There is no answer, and the point of
    // the filter is that the scratch work does not become one.
    expect(
      await perCharacter('<think>on and on and the tokens ran out'),
      '',
    );
  });

  test('the blank line a model leaves after </think> is trimmed', () async {
    // Leading only. Trailing whitespace is left alone deliberately: trimming
    // it would mean holding every run of whitespace back until the next token
    // proved the answer had ended, which stalls the stream the reader is
    // watching in order to fix something Markdown already ignores.
    expect(
      await perCharacter('<think>x</think>\n\n\nAnswer.\n'),
      'Answer.\n',
    );
  });

  test('whitespace inside the answer is the model\'s to keep', () async {
    expect(
      await perCharacter('<think>x</think>1. John\n\n2. Paul'),
      '1. John\n\n2. Paul',
    );
  });

  test('an empty stream yields nothing', () async {
    expect(await filtered([]), '');
  });

  test('nothing is held back once the answer is under way', () async {
    // The reader watches this arrive, so the filter must not buffer the whole
    // answer waiting for a marker that never comes. Only a possible partial
    // marker may be withheld, which is at most a few characters.
    final chunks = await ReasoningFilter.strip(
      Stream.fromIterable(['The Didache ', 'says ', 'plainly']),
    ).toList();
    expect(chunks.length, 3);
  });
}
