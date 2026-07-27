/// Splitting a passage into the pieces a reader can tap.
///
/// The right piece depends on what the text is. Scripture in this corpus is
/// stored one numbered verse per line — `1. In the beginning…` — and a verse is
/// unarguably the unit someone means to select. Prose has no such markers, so
/// paragraphs serve, except that a paragraph can run to several hundred words,
/// at which point "select the paragraph" is no longer a useful thing to offer
/// and sentences are.
///
/// Nothing here knows what a Bible is. It knows what a numbered line looks
/// like, which is also true of numbered canons and articles.
library;

/// One tappable piece of a passage.
class PassageSegment {
  /// Position in the passage, counting from zero. This is what selection state
  /// and rendering key off.
  final int index;

  /// Character offsets into the *unit's* content, so an annotation made here
  /// can be stored against the passage rather than against this parse of it.
  final int start;
  final int end;

  /// The text itself, trimmed — and, for a numbered segment, *without* the
  /// number. The marker is rendered separately and is not part of what gets
  /// quoted: nobody pastes "4. and they encamped against them" into a note.
  final String text;

  /// The verse (or article) number, when the segment carried one. Null for
  /// prose, where a segment has no name of its own.
  final int? number;

  const PassageSegment({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    this.number,
  });

  bool overlaps(int otherStart, int otherEnd) =>
      start < otherEnd && otherStart < end;
}

/// How the passage was divided, which the reader is told so the interface can
/// say "3 verses" rather than "3 selected".
enum SegmentKind { verse, paragraph, sentence }

class SegmentedPassage {
  final List<PassageSegment> segments;
  final SegmentKind kind;

  const SegmentedPassage({required this.segments, required this.kind});

  bool get isEmpty => segments.isEmpty;

  /// "verse" / "verses", "paragraph" / "paragraphs", …
  String noun(int count) {
    final singular = switch (kind) {
      SegmentKind.verse => 'verse',
      SegmentKind.paragraph => 'paragraph',
      SegmentKind.sentence => 'sentence',
    };
    return count == 1 ? singular : '${singular}s';
  }
}

/// A paragraph longer than this is split at sentence boundaries instead.
///
/// Chosen so that a confessional article — typically one dense paragraph of
/// two or three hundred characters — stays whole and selectable in a single
/// tap, while a page-long stretch of Augustine becomes something a reader can
/// pick a line out of.
const int _paragraphSplitThreshold = 700;

/// A numbered line: `12. And the LORD said…`, at the start of a line.
final RegExp _versePattern = RegExp(r'^[ \t]*(\d{1,3})\.[ \t]+', multiLine: true);

/// A sentence end: terminal punctuation, whitespace, then something that can
/// begin a sentence.
///
/// The lookahead is what keeps `Gen. 1` and `St. Paul` in one piece — an
/// abbreviation is followed by a capitalised word too, but the requirement for
/// whitespace *after* the stop plus a following capital is enough to make the
/// common cases behave. This is a reading aid, not a parser: an occasional
/// wrong split costs a reader one extra tap.
final RegExp _sentenceEnd = RegExp(r'(?<=[.!?][")\]]?)\s+(?=[A-Z"“(\[])');

/// Divide [content] into the pieces a reader can select.
SegmentedPassage segmentPassage(String content) {
  if (content.trim().isEmpty) {
    return const SegmentedPassage(segments: [], kind: SegmentKind.paragraph);
  }

  final verses = _segmentVerses(content);
  if (verses != null) {
    return SegmentedPassage(segments: verses, kind: SegmentKind.verse);
  }

  return _segmentProse(content);
}

/// Verses, or null when the passage is not numbered like that.
///
/// Two markers are required before this is believed. A single leading `1.` is
/// as likely to be a list item, or the opening of an enumerated argument, as it
/// is the start of a numbered text.
List<PassageSegment>? _segmentVerses(String content) {
  final matches = _versePattern.allMatches(content).toList();
  if (matches.length < 2) return null;

  // Numbered text that does not *begin* numbered — a chapter heading above
  // verse 1, say — would put everything before the first marker into no
  // segment at all. Give it one.
  final segments = <PassageSegment>[];

  /// [start] is where the segment begins for annotation purposes — the number
  /// included, so highlighting a verse colours its number too. [textStart] is
  /// where the words begin.
  void add(int start, int textStart, int end, int? number) {
    final text = content.substring(textStart, end).trim();
    if (text.isEmpty) return;
    segments.add(PassageSegment(
      index: segments.length,
      start: start,
      end: textStart + content.substring(textStart, end).trimRight().length,
      text: text,
      number: number,
    ));
  }

  if (matches.first.start > 0) add(0, 0, matches.first.start, null);

  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final end =
        i + 1 < matches.length ? matches[i + 1].start : content.length;
    add(match.start, match.end, end, int.tryParse(match.group(1)!));
  }

  return segments.isEmpty ? null : segments;
}

/// Paragraphs, with over-long ones broken into sentences.
SegmentedPassage _segmentProse(String content) {
  final segments = <PassageSegment>[];
  var sawSplitParagraph = false;

  void add(int start, int end) {
    final raw = content.substring(start, end);
    final leading = raw.length - raw.trimLeft().length;
    final text = raw.trim();
    if (text.isEmpty) return;
    segments.add(PassageSegment(
      index: segments.length,
      start: start + leading,
      end: start + leading + text.length,
      text: text,
    ));
  }

  for (final block in _blocks(content)) {
    final text = content.substring(block.$1, block.$2);
    if (text.trim().length <= _paragraphSplitThreshold) {
      add(block.$1, block.$2);
      continue;
    }

    sawSplitParagraph = true;
    var cursor = block.$1;
    for (final boundary in _sentenceEnd.allMatches(text)) {
      add(cursor, block.$1 + boundary.start);
      cursor = block.$1 + boundary.end;
    }
    add(cursor, block.$2);
  }

  if (segments.isEmpty) {
    // A passage with no blank lines and no sentence ends — a title, a fragment.
    // One segment is still better than none: it can be copied and highlighted.
    add(0, content.length);
  }

  return SegmentedPassage(
    segments: segments,
    // Reported as sentences only when something actually was split that way;
    // calling a list of whole paragraphs "sentences" would be a lie the count
    // in the toolbar repeats back to the reader.
    kind: sawSplitParagraph ? SegmentKind.sentence : SegmentKind.paragraph,
  );
}

/// Paragraph spans: runs separated by a blank line, or — when the text has
/// none — by single newlines.
List<(int, int)> _blocks(String content) {
  final byBlankLine = _spansSplitBy(content, RegExp(r'\n[ \t]*\n+'));
  if (byBlankLine.length > 1) return byBlankLine;
  return _spansSplitBy(content, RegExp(r'\n+'));
}

List<(int, int)> _spansSplitBy(String content, RegExp separator) {
  final spans = <(int, int)>[];
  var cursor = 0;
  for (final match in separator.allMatches(content)) {
    if (match.start > cursor) spans.add((cursor, match.start));
    cursor = match.end;
  }
  if (cursor < content.length) spans.add((cursor, content.length));
  return spans;
}

/// How a selection should be cited: "Genesis 1:4–6", "Genesis 1:4, 9", or for
/// prose simply the section's own title.
///
/// Contiguous runs are collapsed to a range because that is how anyone writes a
/// reference down, and a reader selecting nine verses does not want nine
/// numbers listed back at them.
String referenceFor(String? unitTitle, Iterable<PassageSegment> selected) {
  final title = (unitTitle ?? '').trim();
  final numbers = selected
      .map((s) => s.number)
      .whereType<int>()
      .toSet()
      .toList()
    ..sort();
  if (numbers.isEmpty) return title;

  final parts = <String>[];
  var runStart = numbers.first;
  var previous = numbers.first;

  void closeRun() {
    if (runStart == previous) {
      parts.add('$runStart');
    } else if (previous == runStart + 1) {
      parts.add('$runStart, $previous');
    } else {
      parts.add('$runStart–$previous');
    }
  }

  for (final number in numbers.skip(1)) {
    if (number == previous + 1) {
      previous = number;
      continue;
    }
    closeRun();
    runStart = number;
    previous = number;
  }
  closeRun();

  final verses = parts.join(', ');
  return title.isEmpty ? verses : '$title:$verses';
}

/// The selected text, joined as it would be quoted.
///
/// Verses run together with a space, the way a quoted passage reads; prose
/// keeps its paragraph breaks. A gap in the selection is marked with an
/// ellipsis rather than silently closed, because quoting verses 4 and 9 as
/// though they were consecutive misrepresents the text.
String quoteFor(SegmentedPassage passage, Iterable<int> selectedIndices) {
  final indices = selectedIndices.toList()..sort();
  if (indices.isEmpty) return '';

  final joiner = passage.kind == SegmentKind.verse ? ' ' : '\n\n';
  final buffer = StringBuffer();

  for (var i = 0; i < indices.length; i++) {
    if (i > 0) {
      buffer.write(indices[i] == indices[i - 1] + 1 ? joiner : '$joiner… ');
    }
    buffer.write(passage.segments[indices[i]].text);
  }
  return buffer.toString();
}
