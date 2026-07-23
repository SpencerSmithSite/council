import 'package:flutter/material.dart';
import '../theme/glass.dart';
import '../theme/glass_controls.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import 'bookmarks_screen.dart';
import 'content_detail_screen.dart';
import 'library_screen.dart';
import 'source_reader_screen.dart';

/// Everything installed, arranged to be read rather than queried.
///
/// Replaces the separate Browse, Search and Bookmarks tabs, which were three
/// routes into the same act. A reader looking for a text wants a shelf and a
/// search box, not a choice between three verbs.
class ReadScreen extends StatefulWidget {
  const ReadScreen({super.key});

  @override
  State<ReadScreen> createState() => _ReadScreenState();
}

class _ReadScreenState extends State<ReadScreen> {
  final _query = TextEditingController();

  List<Map<String, dynamic>>? _sources;
  List<Map<String, dynamic>>? _results;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _loadShelf();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadShelf() async {
    final db = context.read<DatabaseService>();
    final rows = await db.database.rawQuery('''
      SELECT s.id, s.title, s.author, s.date_composed,
             COALESCE(t.name, 'Other') AS tradition,
             COUNT(cu.id) AS units
      FROM sources s
      LEFT JOIN traditions t ON s.tradition_id = t.id
      JOIN content_units cu ON cu.source_id = s.id
      GROUP BY s.id
      ORDER BY t.name, s.author, s.title
    ''');
    if (mounted) setState(() => _sources = rows);
  }

  /// The shelf, narrowed by whatever is in the box.
  ///
  /// Matches title, author and tradition, because a reader hunting for
  /// Augustine may type any of the three.
  List<Map<String, dynamic>>? get _filtered {
    final all = _sources;
    final query = _query.text.trim().toLowerCase();
    if (all == null || query.isEmpty) return all;

    return all.where((source) {
      final haystack = [
        source['title'],
        source['author'],
        source['tradition'],
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  Future<void> _search(String text) async {
    if (text.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _searching = true);
    final rows =
        await context.read<DatabaseService>().search(text, limit: 40);
    if (mounted) {
      setState(() {
        _results = rows;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results != null
                    ? _Results(rows: _results!)
                    : _Shelf(
                        sources: _filtered,
                        onRefresh: _loadShelf,
                        filtered: _query.text.trim().isNotEmpty,
                        onOpenBookmarks: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const BookmarksScreen()),
                        ),
                      ),
          ),
          // Search lives in the floating bottom bubble now: typing filters the
          // shelf live, return runs a full-text search inside the passages.
          GlassComposer(
            controller: _query,
            hintText: 'Search the library',
            leadingIcon: AppIcons.search,
            onChanged: (_) => setState(() => _results = null),
            onSubmit: () => _search(_query.text),
            onClear: () {
              _query.clear();
              _search('');
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

/// The installed works, grouped by tradition.
class _Shelf extends StatelessWidget {
  final List<Map<String, dynamic>>? sources;
  final Future<void> Function() onRefresh;
  final bool filtered;
  final VoidCallback onOpenBookmarks;

  const _Shelf({
    required this.sources,
    required this.onRefresh,
    required this.onOpenBookmarks,
    this.filtered = false,
  });

  @override
  Widget build(BuildContext context) {
    if (sources == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final header = LargeTitle(
      'Read',
      trailing: IconButton(
        tooltip: 'Bookmarks',
        icon: Icon(AppIcons.bookmark),
        onPressed: onOpenBookmarks,
      ),
    );

    if (sources!.isEmpty) {
      return ListView(
        children: [
          header,
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              filtered
                  ? 'Nothing on your shelf matches. Press return to search '
                      'inside the texts instead.'
                  : 'Nothing installed yet.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    final byTradition = <String, List<Map<String, dynamic>>>{};
    for (final source in sources!) {
      byTradition
          .putIfAbsent(source['tradition'] as String, () => [])
          .add(source);
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          header,
          for (final entry in byTradition.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(entry.key,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final source in entry.value)
              ListTile(
                title: Text(source['title'] as String? ?? 'Untitled'),
                subtitle: Text([
                  if ((source['author'] as String?)?.isNotEmpty ?? false)
                    source['author'] as String,
                  if ((source['date_composed'] as String?)?.isNotEmpty ?? false)
                    source['date_composed'] as String,
                  '${source['units']} sections',
                ].join(' · ')),
                trailing: Icon(AppIcons.chevronRight, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourceReaderScreen(
                      sourceId: source['id'] as int,
                      title: source['title'] as String? ?? 'Untitled',
                    ),
                  ),
                ),
              ),
          ],
          // With Scripture alone the shelf is one book, and the reason is not
          // obvious from an otherwise working screen.
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LibraryScreen()),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add more to your library'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  final List<Map<String, dynamic>> rows;

  const _Results({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Nothing found in what you have installed.'),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LibraryScreen()),
                ),
                child: const Text('Browse the Library'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.only(top: floatingTopInset(context), bottom: 8),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = rows[index];
        final body = (row['content'] as String? ?? '').replaceAll('\n', ' ');
        return ListTile(
          title: Text(row['title'] as String? ?? 'Untitled'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${row['source_title'] ?? ''}'
                '${row['tradition'] != null ? ' · ${row['tradition']}' : ''}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 2),
              Text(
                body.length > 160 ? '${body.substring(0, 160)}…' : body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          isThreeLine: true,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ContentDetailScreen(contentId: row['id'] as int),
            ),
          ),
        );
      },
    );
  }
}
