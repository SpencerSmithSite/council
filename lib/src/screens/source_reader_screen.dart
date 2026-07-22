import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/settings_provider.dart';

/// Read a work straight through, one section at a time.
///
/// The app could previously only open a passage as an isolated card reached
/// from a search result, with no way to continue to the next one. For a
/// commentary that is merely awkward; for Scripture, where the whole act is
/// reading on from where you are, it is the wrong shape entirely.
class SourceReaderScreen extends StatefulWidget {
  final int sourceId;
  final String title;

  /// Which section to open at. Defaults to the beginning.
  final int initialIndex;

  const SourceReaderScreen({
    super.key,
    required this.sourceId,
    required this.title,
    this.initialIndex = 0,
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

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
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
    await _open(_index.clamp(0, sections.length - 1));
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
      body: sections == null
          ? const Center(child: CircularProgressIndicator())
          : sections.isEmpty
              ? const Center(child: Text('This work has no sections.'))
              : Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
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
                            SelectableText(
                              _current?['content'] as String? ?? '',
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
                    _Pager(
                      index: _index,
                      total: sections.length,
                      onPrevious:
                          _index > 0 ? () => _open(_index - 1) : null,
                      onNext: _index < sections.length - 1
                          ? () => _open(_index + 1)
                          : null,
                    ),
                  ],
                ),
    );
  }

  /// A jump list, because 1,189 chapters cannot be paged through.
  void _showContents(List<Map<String, dynamic>> sections) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: sections.length,
          itemBuilder: (context, index) => ListTile(
            dense: true,
            selected: index == _index,
            title: Text(sections[index]['title'] as String? ??
                'Section ${index + 1}'),
            onTap: () {
              Navigator.pop(context);
              _open(index);
            },
          ),
        ),
      ),
    );
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
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
    );
  }
}
