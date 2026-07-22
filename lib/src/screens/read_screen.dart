import 'package:flutter/material.dart';
import '../theme/glass.dart';
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
      appBar: AppBar(
        title: const Text('Read'),
        actions: [
          IconButton(
            tooltip: 'Bookmarks',
            icon: const Icon(Icons.bookmark_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookmarksScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _query,
              decoration: InputDecoration(
                hintText: 'Filter your shelf, or press return to search text',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _query.clear();
                          _search('');
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              // Typing filters the shelf; return searches inside the texts.
              // With 380 works installed, a reader looking for the Bible was
              // scrolling past every apocryphal Acts to reach it — the box was
              // the only search on screen and it searched the wrong thing.
              onChanged: (_) => setState(() => _results = null),
              onSubmitted: _search,
            ),
          ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results != null
                    ? _Results(rows: _results!)
                    : _Shelf(
                        sources: _filtered,
                        onRefresh: _loadShelf,
                        filtered: _query.text.trim().isNotEmpty,
                      ),
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

  const _Shelf({
    required this.sources,
    required this.onRefresh,
    this.filtered = false,
  });

  @override
  Widget build(BuildContext context) {
    if (sources == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sources!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            filtered
                ? 'Nothing on your shelf matches. Press return to search '
                    'inside the texts instead.'
                : 'Nothing installed yet.',
            textAlign: TextAlign.center,
          ),
        ),
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
        // Clear the translucent tab bar the body runs behind on Apple.
        padding: EdgeInsets.only(bottom: appleTabBarInset(context)),
        children: [
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
                trailing: const Icon(Icons.chevron_right, size: 18),
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
      padding: EdgeInsets.only(bottom: appleTabBarInset(context)),
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
