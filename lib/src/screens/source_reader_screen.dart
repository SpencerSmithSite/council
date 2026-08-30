import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../reader/passage_reader.dart';
import '../services/database_service.dart';
import '../services/settings_provider.dart';
import '../services/settings_service.dart';
import '../theme/glass.dart';
import '../theme/glass_controls.dart';

/// Read a work straight through, one section at a time.
///
/// The app could previously only open a passage as an isolated card reached
/// from a search result, with no way to continue to the next one. For a
/// commentary that is merely awkward; for Scripture, where the whole act is
/// reading on from where you are, it is the wrong shape entirely.
class SourceReaderScreen extends StatefulWidget {
  final int sourceId;
  final String title;

  /// Which section to open at. When null, resumes where the reader stopped.
  final int? initialIndex;

  /// Open at the section holding this content unit, wherever it falls.
  ///
  /// What a citation knows is the passage's id, not its position in the work,
  /// and the position is a property of the ordering rather than of the unit —
  /// so it is resolved here, against the same list the pager walks, instead of
  /// being computed by every caller against an ordering it would have to
  /// duplicate. Takes precedence over [initialIndex] and over the saved place.
  final int? initialUnitId;

  const SourceReaderScreen({
    super.key,
    required this.sourceId,
    required this.title,
    this.initialIndex,
    this.initialUnitId,
  });

  @override
  State<SourceReaderScreen> createState() => _SourceReaderScreenState();
}

class _SourceReaderScreenState extends State<SourceReaderScreen> {
  /// Section titles only. Loading every section's text would mean holding a
  /// whole Bible in memory to read one chapter of it.
  List<Map<String, dynamic>>? _sections;
  Map<String, dynamic>? _current;
  int _index = 0;
  final _scroll = ScrollController();

  final SettingsService _settings = SettingsService();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.read<DatabaseService>();
    final sections = await db.database.rawQuery('''
      SELECT id, title, unit_number FROM content_units
      WHERE source_id = ? ORDER BY sequence
    ''', [widget.sourceId]);
    if (!mounted) return;
    setState(() => _sections = sections);
    if (sections.isEmpty) return;

    // Resume where this work was left, unless a specific section was asked
    // for. Always opening at section one is tolerable for a short confession
    // and useless for a Bible of 1,189 chapters.
    //
    // A named unit that is not in the list — a citation kept across a pack
    // change that dropped the passage — falls through to the saved place
    // rather than to nothing.
    final asked = _indexOfUnit(sections) ?? widget.initialIndex;
    final start =
        asked ?? await _settings.getReadingPosition(widget.sourceId);
    await _open(start.clamp(0, sections.length - 1));
  }

  /// Where [SourceReaderScreen.initialUnitId] sits in the running order.
  int? _indexOfUnit(List<Map<String, dynamic>> sections) {
    final wanted = widget.initialUnitId;
    if (wanted == null) return null;
    final index = sections.indexWhere((s) => s['id'] == wanted);
    return index < 0 ? null : index;
  }

  Future<void> _open(int index) async {
    final sections = _sections;
    if (sections == null || sections.isEmpty) return;
    final bounded = index.clamp(0, sections.length - 1);

    final unit = await context
        .read<DatabaseService>()
        .getContentUnit(sections[bounded]['id'] as int);
    if (!mounted) return;

    setState(() {
      _index = bounded;
      _current = unit;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _settings.setReadingPosition(widget.sourceId, bounded);
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final scale = context.watch<SettingsProvider>().fontScale;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (sections != null && sections.isNotEmpty)
            IconButton(
              tooltip: 'Contents',
              icon: const Icon(Icons.list),
              onPressed: () => _showContents(sections),
            ),
        ],
      ),
      // The pager floats over the page rather than closing it off, so the last
      // lines of a section pass behind the glass instead of stopping at it.
      extendBody: true,
      bottomNavigationBar: sections == null || sections.isEmpty
          ? null
          : _Pager(
              index: _index,
              total: sections.length,
              onPrevious: _index > 0 ? () => _open(_index - 1) : null,
              onNext: _index < sections.length - 1
                  ? () => _open(_index + 1)
                  : null,
            ),
      body: sections == null
          ? const Center(child: CircularProgressIndicator())
          : sections.isEmpty
              ? const Center(child: Text('This work has no sections.'))
              : Builder(
                  // Inside the body, so the pager's measured height is in
                  // scope. See [floatingBottomInset].
                  builder: (context) => SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          20,
                          16,
                          20,
                          floatingBottomInset(context, extra: 32),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _current?['title'] as String? ??
                                  sections[_index]['title'] as String? ??
                                  '',
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            // Keyed on the section so that paging to the next
                            // one rebuilds the reader from scratch rather than
                            // carrying a selection across a change of text.
                            PassageReader(
                              key: ValueKey(_current?['id'] ?? _index),
                              contentUnitId:
                                  (_current?['id'] as int?) ?? -1,
                              content:
                                  _current?['content'] as String? ?? '',
                              unitTitle: _current?['title'] as String? ??
                                  sections[_index]['title'] as String?,
                              sourceTitle:
                                  _current?['source_title'] as String? ??
                                      widget.title,
                              // Clear of the pager floating below. The
                              // selection toolbar is an overlay entry, so it
                              // measures from the true screen edge — hence the
                              // safe area is taken back off the body inset,
                              // which already includes it.
                              toolbarBottomInset: floatingBottomInset(
                                    context,
                                    extra: 8,
                                  ) -
                                  MediaQuery.of(context).viewPadding.bottom,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                // Reading type, not UI type: a little larger
                                // and much looser than the default, and it
                                // honours the font-size setting.
                                fontSize:
                                    (theme.textTheme.bodyLarge?.fontSize ?? 16) *
                                        scale,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                ),
    );
  }

  /// A jump list, because 1,189 chapters cannot be paged through.
  void _showContents(List<Map<String, dynamic>> sections) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ContentsSheet(
        sections: sections,
        current: _index,
        onSelect: (index) {
          Navigator.pop(context);
          _open(index);
        },
      ),
    );
  }
}

/// Jump to a section.
///
/// A flat list works for a confession of forty articles and fails completely
/// for a Bible: scrolling 1,189 undifferentiated rows to reach Habakkuk is not
/// navigation. So this filters, and it groups when grouping helps.
///
/// The grouping is derived from the titles rather than from a Scripture-aware
/// special case — "Genesis 1", "Genesis 2" share a stem, and so do "Session 4"
/// and "Session 5". Nothing here knows what a Bible is, which means it also
/// works for the next long work with numbered parts.
class _ContentsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> sections;
  final int current;
  final ValueChanged<int> onSelect;

  const _ContentsSheet({
    required this.sections,
    required this.current,
    required this.onSelect,
  });

  @override
  State<_ContentsSheet> createState() => _ContentsSheetState();
}

class _ContentsSheetState extends State<_ContentsSheet> {
  final _filter = TextEditingController();

  /// Only worth grouping when it collapses the list substantially. Sixty-six
  /// groups over 1,189 chapters is navigation; 190 groups over 196 questions
  /// is the same list with headings in it.
  static const double _usefulRatio = 0.5;

  /// Whether this work is shown as books-with-chapter-chips or as a flat list.
  ///
  /// Decided once, from the *whole* work, rather than per keystroke from
  /// whatever the filter currently matches. Measuring the filtered set made the
  /// presentation depend on the query: "prove" matches Proverbs' 31 chapters and
  /// grouped, while "Corinth" matches 29 and fell back to a flat list — so the
  /// same Bible changed shape depending on which book you went looking for.
  /// Whether a work *has* books is a fact about the work, not about the search.
  late final bool _groups = _shouldGroup();

  bool _shouldGroup() {
    final stems = <String>{};
    for (final section in widget.sections) {
      stems.add(_stemOf(section['title'] as String? ?? ''));
    }
    return widget.sections.length > 30 &&
        stems.length <= widget.sections.length * _usefulRatio;
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// The title with any trailing number removed: "Genesis 12" -> "Genesis".
  static String _stemOf(String title) =>
      title.replaceFirst(RegExp(r'\s+\d+\s*$'), '').trim();

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.trim().toLowerCase();

    final matches = <int>[];
    for (var i = 0; i < widget.sections.length; i++) {
      final title = widget.sections[i]['title'] as String? ?? '';
      if (query.isEmpty || title.toLowerCase().contains(query)) {
        matches.add(i);
      }
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _filter,
              autofocus: false,
              decoration: InputDecoration(
                hintText: 'Jump to…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _filter.clear();
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? const Center(child: Text('Nothing matches.'))
                : _groups
                    ? _grouped(controller, matches)
                    : _flat(controller, matches),
          ),
        ],
      ),
    );
  }

  Widget _flat(ScrollController controller, List<int> matches) {
    return ListView.builder(
      controller: controller,
      itemCount: matches.length,
      itemBuilder: (context, position) {
        final index = matches[position];
        return ListTile(
          dense: true,
          selected: index == widget.current,
          title: Text(widget.sections[index]['title'] as String? ??
              'Section ${index + 1}'),
          onTap: () => widget.onSelect(index),
        );
      },
    );
  }

  /// Two levels: the stem, then its numbered parts as a wrap of chips. A
  /// hundred and fifty Psalms fit in a few rows this way, where as list rows
  /// they are a scroll of their own.
  Widget _grouped(ScrollController controller, List<int> matches) {
    // Insertion-ordered, so books stay in canonical order rather than
    // whatever order a hash map hands back.
    final byStem = <String, List<int>>{};
    for (final index in matches) {
      final stem = _stemOf(widget.sections[index]['title'] as String? ?? '');
      byStem.putIfAbsent(stem, () => []).add(index);
    }
    final order = byStem.keys.toList();

    return ListView.builder(
      controller: controller,
      itemCount: order.length,
      itemBuilder: (context, position) {
        final stem = order[position];
        final members = byStem[stem]!;
        // Opened when it holds where the reader is, so the sheet lands on their
        // place rather than at the top of the book — and when the filter has
        // narrowed to a single book, since naming a book is itself a request to
        // see inside it.
        final expanded = members.contains(widget.current) || order.length == 1;

        return ExpansionTile(
          // Keyed by book, not by row: without this the tile at a given position
          // keeps its open/closed state as the filter changes the book standing
          // there, so opening Genesis and then searching left some unrelated
          // book hanging open. The expansion intent is in the key too, so a
          // group that becomes the only match reopens rather than staying shut.
          key: ValueKey('$stem/$expanded'),
          title: Text(stem),
          subtitle: Text('${members.length} sections',
              style: Theme.of(context).textTheme.labelSmall),
          initiallyExpanded: expanded,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final index in members)
                    ActionChip(
                      label: Text(_labelFor(index, stem)),
                      backgroundColor: index == widget.current
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      onPressed: () => widget.onSelect(index),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Inside "Genesis" a chip should read "12", not "Genesis 12".
  String _labelFor(int index, String stem) {
    final title = widget.sections[index]['title'] as String? ?? '';
    final short = title.substring(stem.length).trim();
    return short.isEmpty ? title : short;
  }
}

class _Pager extends StatelessWidget {
  final int index;
  final int total;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const _Pager({
    required this.index,
    required this.total,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    // A floating capsule rather than a bar ruled off from the page: the text is
    // the thing being read, and a solid strip bolted across the bottom of it
    // ends the page early. Held off the edges to the same margin as every other
    // floating control, so the chrome shares one rhythm.
    final capsule = floatingGlass(
      context: context,
      shape: squircle(
        26,
        side: BorderSide(
          color: (Theme.of(context).dividerTheme.color ?? scheme.outlineVariant)
              .withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous',
            ),
            Expanded(
              child: Text(
                '${index + 1} of $total',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            IconButton(
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next',
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppleMetrics.edgeInset,
        6,
        AppleMetrics.edgeInset,
        safeBottom + 8,
      ),
      child: capsule,
    );
  }
}
