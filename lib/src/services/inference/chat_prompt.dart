import '../chat_history_service.dart';
import '../ollama_service.dart';

/// A cited passage. Carries the content unit id so the citation can be opened
/// — a citation the reader cannot follow is not much of a citation.
/// A passage the answer was built from, described well enough to check.
///
/// Tradition is carried because it is the point of the app: an answer about
/// baptism drawn entirely from Reformed confessions is a different claim from
/// one spanning four traditions, and until now the citations looked identical
/// either way.
///
/// [sourceUrl] is carried for the same reason in the other direction. The
/// corpus holds both editions traced to a published text and legacy entries
/// with no recorded origin, and showing them the same way asserts a confidence
/// the second kind has not earned.
///
/// Moved here from the chat screen, with [ChatPrompt], so the prompt can be
/// built (and its golden fixture generated) without a widget. The native Apple
/// app mirrors it in `apple/CouncilCore/.../Inference/Citation.swift`, and
/// reads the JSON below out of the same `conversation_messages.citations`
/// column, so [toJson] is a storage format: change it in both apps or neither.
class Citation {
  final int contentId;
  final String source;
  final String? author;
  final String? tradition;
  final String? sourceUrl;

  const Citation({
    required this.contentId,
    required this.source,
    this.author,
    this.tradition,
    this.sourceUrl,
  });

  bool get isTraceable => sourceUrl != null && sourceUrl!.isNotEmpty;

  /// Stored alongside the message it belongs to, so a reopened conversation
  /// still shows what its answers were built from. An answer that arrives
  /// without its sources is the thing this app is trying not to be.
  Map<String, dynamic> toJson() => {
        'contentId': contentId,
        'source': source,
        'author': author,
        'tradition': tradition,
        'sourceUrl': sourceUrl,
      };

  static Citation fromJson(Map<String, dynamic> json) => Citation(
        contentId: json['contentId'] as int? ?? 0,
        source: json['source'] as String? ?? 'Unknown source',
        author: json['author'] as String?,
        tradition: json['tradition'] as String?,
        sourceUrl: json['sourceUrl'] as String?,
      );

  /// How the passage is described to the model, as opposed to to the reader.
  ///
  /// The tradition is included deliberately: a comparative question is exactly
  /// the case where the model needs to know which camp a passage speaks for,
  /// and without it the answer attributes positions by guesswork.
  String get promptLabel {
    final parts = [
      source,
      if (author != null && author!.isNotEmpty) author!,
      if (tradition != null && tradition!.isNotEmpty) '$tradition tradition',
    ];
    return parts.join(' — ');
  }
}

/// What is sent to a backend for one question: the system prompt, the prompt
/// with the retrieved sources in it, and the citations those sources become.
///
/// Pulled out of the chat screen's `_streamAnswer` and `_pinnedAsPassage`
/// unchanged, so that it can be tested on its own and held to
/// `shared/golden/prompts/prompts.json` (test/chat_prompt_golden_test.dart),
/// which the native Apple app's `ChatPrompt` reproduces character for
/// character. Change the wording here and the fixture has to be regenerated,
/// and the Swift side follow.
class ChatPrompt {
  final String system;
  final String prompt;
  final List<Citation> citations;

  const ChatPrompt({
    required this.system,
    required this.prompt,
    required this.citations,
  });

  /// Built once. The prompt is a constant string, and the chat screen used to
  /// construct a whole OllamaService per question to read it.
  static final String systemPrompt = OllamaService().buildSystemPrompt();

  /// The selected passage leads, ahead of anything retrieval found. The
  /// reader is asking about *that* text, so it is the source the answer has to
  /// be about; the rest is context brought in to interpret it.
  static List<Map<String, dynamic>> passagesFor(
    List<Map<String, dynamic>> retrieved, {
    PinnedPassage? pinned,
  }) =>
      [
        if (pinned != null) pinnedAsPassage(pinned),
        ...retrieved,
      ];

  /// The selected passage shaped like a retrieved one, so it can travel
  /// through the same prompt-building and citation code as everything else.
  ///
  /// It carries no `source_url`, which is not an oversight: the citation tile
  /// reads a missing URL as "origin not recorded", and for a passage quoted out
  /// of the reader's own screen that is exactly right — the traceable thing is
  /// the unit it came from, which the citation links to.
  static Map<String, dynamic> pinnedAsPassage(PinnedPassage passage) => {
        'id': passage.contentUnitId,
        'content': passage.quote,
        'source_title': passage.sourceTitle ?? passage.reference,
        'source_author': null,
        'tradition': null,
        'source_url': null,
      };

  static List<Citation> citationsFor(List<Map<String, dynamic>> passages) =>
      passages
          .map((p) => Citation(
                contentId: p['id'] as int,
                source: p['source_title'] as String? ?? 'Unknown source',
                author: p['source_author'] as String?,
                tradition: p['tradition'] as String?,
                sourceUrl: p['source_url'] as String?,
              ))
          .toList();

  /// Spend the backend's context budget across the passages rather than using
  /// one fixed size for every backend — an on-device model and a cloud model
  /// differ by an order of magnitude here.
  static int perPassageBudget(int contextBudgetChars, int passageCount) =>
      (contextBudgetChars / passageCount).floor().clamp(400, 8000);

  /// The prompt for [question] over [passages] (with [citations] built from
  /// them by [citationsFor]). [anchor] is the passage the reader selected, if
  /// any, which [passages] already leads with.
  static String promptFor({
    required String question,
    required List<Map<String, dynamic>> passages,
    required List<Citation> citations,
    required PinnedPassage? anchor,
    required int contextBudgetChars,
  }) {
    final perPassage = perPassageBudget(contextBudgetChars, passages.length);

    final context = StringBuffer()..writeln('Relevant sources:\n');
    for (var i = 0; i < passages.length; i++) {
      final content = passages[i]['content'] as String? ?? '';
      context
        ..writeln('[${i + 1}] ${citations[i].promptLabel}')
        ..writeln(content.length > perPassage
            ? '${content.substring(0, perPassage).trimRight()}… [truncated]'
            : content)
        ..writeln();
    }

    // When the reader selected a passage, say so plainly. Without it the model
    // is handed several sources of equal standing and answers about the topic
    // rather than about the text in front of the person asking.
    final anchorSentence = anchor == null
        ? ''
        : 'The reader is reading ${anchor.promptLabel}, quoted as source '
            '[1], and their question is about it. Answer about that passage '
            'first, using the other sources to illuminate it.\n\n';

    return '$context\n${anchorSentence}User question: $question\n\n'
        'Answer using the provided sources. Cite them as [1], [2] and so on.';
  }

  /// Everything at once, from what retrieval returned. Null when there is
  /// nothing to build a prompt from: no pinned passage and nothing retrieved.
  static ChatPrompt? build({
    required String question,
    required List<Map<String, dynamic>> retrieved,
    PinnedPassage? pinned,
    required int contextBudgetChars,
  }) {
    final passages = passagesFor(retrieved, pinned: pinned);
    if (passages.isEmpty) return null;
    final citations = citationsFor(passages);
    return ChatPrompt(
      system: systemPrompt,
      citations: citations,
      prompt: promptFor(
        question: question,
        passages: passages,
        citations: citations,
        anchor: pinned,
        contextBudgetChars: contextBudgetChars,
      ),
    );
  }
}
