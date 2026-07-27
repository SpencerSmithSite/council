import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/chat_screen.dart';
import '../screens/note_editor_screen.dart';
import '../services/annotation_service.dart';
import '../services/chat_history_service.dart';
import '../theme/highlight_colours.dart';
import 'passage_action_bar.dart';
import 'passage_segments.dart';

/// A passage that can be marked up.
///
/// Tapping a verse selects it; tapping more extends the selection; a toolbar
/// rises from the bottom offering everything that can be done with what has
/// been picked. This replaces the platform's own text selection, which sounds
/// like a loss and is not: dragging a handle across three verses on a phone is
/// fiddly and imprecise, and the units a reader actually wants — this verse,
/// these three verses — are exactly the ones the corpus already knows about.
///
/// Highlights are loaded on open and re-read after every change, so two
/// screens showing the same passage cannot drift apart.
class PassageReader extends StatefulWidget {
  final int contentUnitId;
  final String content;
  final String? unitTitle;
  final String? sourceTitle;

  /// The base style for the passage's text. The verse numbers and the
  /// highlight washes are derived from it.
  final TextStyle? style;

  /// How far above the bottom of the screen the toolbar floats. Raised by
  /// screens that keep something of their own down there — the reader's pager —
  /// so the toolbar sits above it rather than on top of it.
  final double toolbarBottomInset;

  const PassageReader({
    super.key,
    required this.contentUnitId,
    required this.content,
    this.unitTitle,
    this.sourceTitle,
    this.style,
    this.toolbarBottomInset = 24,
  });

  @override
  State<PassageReader> createState() => _PassageReaderState();
}

class _PassageReaderState extends State<PassageReader> {
  final _annotations = AnnotationService();

  late SegmentedPassage _passage;
  List<TapGestureRecognizer> _recognizers = const [];
  List<Highlight> _highlights = const [];
  final Set<int> _selected = {};

  OverlayEntry? _toolbar;

  /// False while a route of our own is up in front of the reader. The toolbar
  /// is an overlay entry, which sits above every route the navigator pushes,
  /// so it has to stand down rather than cover what it opened.
  bool _toolbarVisible = true;

  @override
  void initState() {
    super.initState();
    _parse();
    _loadHighlights();
  }

  @override
  void didUpdateWidget(PassageReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.contentUnitId != widget.contentUnitId) {
      // A new section: nothing from the old one may survive, least of all a
      // selection whose indices now point at different words.
      _clearSelection();
      _parse();
      _loadHighlights();
    }
  }

  @override
  void dispose() {
    _removeToolbar();
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  void _parse() {
    _passage = segmentPassage(widget.content);
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    // One recognizer per segment, made once. Rebuilding them on every frame
    // would mean disposing a recognizer that may be mid-gesture.
    _recognizers = [
      for (final segment in _passage.segments)
        TapGestureRecognizer()..onTap = () => _toggle(segment.index),
    ];
  }

  Future<void> _loadHighlights() async {
    final highlights = await _annotations.highlightsFor(widget.contentUnitId);
    if (mounted) setState(() => _highlights = highlights);
  }

  // ------------------------------------------------------------------ selection

  void _toggle(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
    if (_selected.isEmpty) {
      _removeToolbar();
    } else {
      _showToolbar();
    }
  }

  void _clearSelection() {
    _removeToolbar();
    if (_selected.isEmpty) return;
    if (mounted) {
      setState(_selected.clear);
    } else {
      _selected.clear();
    }
  }

  List<PassageSegment> get _selectedSegments {
    final indices = _selected.toList()..sort();
    return [for (final index in indices) _passage.segments[index]];
  }

  /// The span the selection covers, from the first selected piece to the last.
  ///
  /// A gap in the middle is swallowed deliberately: a highlight is a mark on
  /// the page, and a reader who picks verses 4 and 6 and colours them expects
  /// a continuous stripe rather than two, which is also what every Bible app
  /// does. The quotation, unlike the mark, does show the gap.
  (int, int) get _selectedRange {
    final segments = _selectedSegments;
    return (segments.first.start, segments.last.end);
  }

  String get _reference =>
      referenceFor(widget.unitTitle, _selectedSegments);

  String get _quote => quoteFor(_passage, _selected);

  bool get _selectionIsHighlighted {
    if (_selected.isEmpty) return false;
    final (start, end) = _selectedRange;
    return _highlights.any((h) => h.overlaps(start, end));
  }

  // -------------------------------------------------------------------- toolbar

  void _showToolbar() {
    if (_toolbar != null) {
      _toolbar!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _toolbar = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        right: 0,
        bottom: MediaQuery.of(overlayContext).padding.bottom +
            widget.toolbarBottomInset,
        child: Center(
          child: _toolbarVisible
              ? PassageActionBar(
                  count: _selected.length,
                  noun: _passage.noun(_selected.length),
                  onDismiss: _clearSelection,
                  onCopy: _copy,
                  onShare: _share,
                  onNote: _note,
                  onAsk: _ask,
                  onHighlight: _pickHighlight,
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
    overlay.insert(_toolbar!);
  }

  void _removeToolbar() {
    _toolbar?.remove();
    _toolbar = null;
    _toolbarVisible = true;
  }

  void _setToolbarVisible(bool visible) {
    if (_toolbarVisible == visible) return;
    _toolbarVisible = visible;
    _toolbar?.markNeedsBuild();
  }

  // -------------------------------------------------------------------- actions

  /// The passage as it should leave the app: the words, then where they came
  /// from. A quotation without its reference is the thing this whole app
  /// exists to stop happening.
  String get _shareableText {
    final attribution = [
      if (_reference.isNotEmpty) _reference,
      if ((widget.sourceTitle ?? '').isNotEmpty) widget.sourceTitle!,
    ].join(' · ');
    return attribution.isEmpty ? _quote : '$_quote\n\n— $attribution';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _shareableText));
    if (!mounted) return;
    _announce('Copied');
    _clearSelection();
  }

  Future<void> _share() async {
    final text = _shareableText;
    final subject = _reference.isEmpty ? 'From Council' : _reference;

    // iPad and macOS anchor the share sheet to the control that opened it;
    // without an origin rect the sheet cannot be presented at all there.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    _clearSelection();
    try {
      await SharePlus.instance.share(
        ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
      );
    } catch (e) {
      if (mounted) _announce('Could not open the share sheet.');
    }
  }

  /// Opens the palette, with the toolbar out of the way for as long as it is
  /// up, and applies whatever came back.
  Future<void> _pickHighlight() async {
    _setToolbarVisible(false);
    final choice = await showHighlightSheet(
      context,
      count: _selected.length,
      noun: _passage.noun(_selected.length),
      hasHighlight: _selectionIsHighlighted,
    );
    if (!mounted) return;

    if (choice == null) {
      // Dismissed: the selection is still there, so the toolbar comes back.
      _setToolbarVisible(true);
      return;
    }

    // Either action ends the selection, which takes the toolbar with it.
    if (choice.isErase) {
      await _removeHighlight();
    } else {
      await _highlight(choice.colour!);
    }
  }

  Future<void> _highlight(HighlightColour colour) async {
    final (start, end) = _selectedRange;
    await _annotations.addHighlight(
      contentUnitId: widget.contentUnitId,
      charStart: start,
      charEnd: end,
      colour: colour.id,
      quote: _quote,
      sourceTitle: widget.sourceTitle,
      unitTitle: widget.unitTitle,
      reference: _reference,
    );
    _clearSelection();
    await _loadHighlights();
  }

  Future<void> _removeHighlight() async {
    final (start, end) = _selectedRange;
    await _annotations.removeHighlightsIn(
      contentUnitId: widget.contentUnitId,
      charStart: start,
      charEnd: end,
    );
    _clearSelection();
    await _loadHighlights();
  }

  Future<void> _note() async {
    final (start, end) = _selectedRange;
    final note = await _annotations.createNote(
      contentUnitId: widget.contentUnitId,
      charStart: start,
      charEnd: end,
      quote: _quote,
      sourceTitle: widget.sourceTitle,
      unitTitle: widget.unitTitle,
      reference: _reference,
    );
    _clearSelection();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(note: note, autofocus: true),
      ),
    );
  }

  Future<void> _ask() async {
    final passage = PinnedPassage(
      contentUnitId: widget.contentUnitId,
      quote: _quote,
      reference: _reference,
      sourceTitle: widget.sourceTitle,
    );
    _clearSelection();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(standalone: true, passage: passage),
      ),
    );
  }

  void _announce(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ------------------------------------------------------------------ rendering

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = widget.style ?? theme.textTheme.bodyLarge ?? const TextStyle();

    if (_passage.isEmpty) return const SizedBox.shrink();

    final wash = selectionWash(context);
    final separator = _passage.kind == SegmentKind.verse ? ' ' : '\n\n';

    final spans = <InlineSpan>[];
    for (final segment in _passage.segments) {
      if (segment.index > 0) {
        spans.add(TextSpan(text: separator, style: base));
      }

      final selected = _selected.contains(segment.index);
      final highlight = _highlightOn(segment);
      final background = selected
          ? wash
          : highlight == null
              ? null
              : HighlightColour.fromId(highlight.colour)
                  .resolve(theme.brightness);

      final style = background == null
          ? base
          : base.copyWith(background: Paint()..color = background);

      if (segment.number != null) {
        spans.add(TextSpan(
          text: '${segment.number} ',
          style: style.copyWith(
            fontSize: (base.fontSize ?? 16) * 0.72,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          ),
          recognizer: _recognizers[segment.index],
        ));
      }

      spans.add(TextSpan(
        text: segment.text,
        style: style,
        recognizer: _recognizers[segment.index],
        // Read out as one unit so a screen reader announces a verse at a time
        // rather than a wall of prose.
        semanticsLabel: segment.number == null
            ? null
            : '${_passage.noun(1)} ${segment.number}. ${segment.text}',
      ));
    }

    return Text.rich(TextSpan(children: spans), style: base);
  }

  /// The highlight covering [segment], if any. The last match wins, so a mark
  /// made later paints over one made earlier.
  Highlight? _highlightOn(PassageSegment segment) {
    Highlight? found;
    for (final highlight in _highlights) {
      if (segment.overlaps(highlight.charStart, highlight.charEnd)) {
        found = highlight;
      }
    }
    return found;
  }
}
