import 'package:flutter/material.dart';
import '../theme/glass.dart';
import '../theme/glass_controls.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/read_shelf_service.dart';
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
  final _shelf = ReadShelfService();

  List<Map<String, dynamic>>? _sources;
  List<Map<String, dynamic>>? _results;
  bool _searching = false;

  // Persisted shelf arrangement: pinned and bookmarked source ids, and the
  // names of tradition sections the reader has collapsed.
  Set<int> _pinned = {};
  Set<int> _saved = {};
  Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _loadShelf();
    _loadShelfPrefs();
  }

  Future<void> _loadShelfPrefs() async {
    final pinned = await _shelf.pinned();
    final saved = await _shelf.saved();
    final collapsed = await _shelf.collapsed();
    if (mounted) {
      setState(() {
        _pinned = pinned;
        _saved = saved;
        _collapsed = collapsed;
      });
    }
  }

  Future<void> _togglePin(int id) async {
    final next = await _shelf.togglePinned(id);
    if (mounted) setState(() => _pinned = next);
  }

  Future<void> _toggleSave(int id) async {
    final next = await _shelf.toggleSaved(id);
    if (mounted) setState(() => _saved = next);
  }

  Future<void> _toggleCollapse(String tradition) async {
    final next = await _shelf.toggleCollapsed(tradition);
    if (mounted) setState(() => _collapsed = next);
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
                        pinned: _pinned,
                        saved: _saved,
                        collapsed: _collapsed,
                        onTogglePin: _togglePin,
                        onToggleSave: _toggleSave,
                        onToggleCollapse: _toggleCollapse,
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

/// The installed works, grouped by tradition, with pinned works lifted to the
/// top and each tradition section collapsible.
class _Shelf extends StatelessWidget {
  final List<Map<String, dynamic>>? sources;
  final Future<void> Function() onRefresh;
  final bool filtered;
  final VoidCallback onOpenBookmarks;
  final Set<int> pinned;
  final Set<int> saved;
  final Set<String> collapsed;
  final ValueChanged<int> onTogglePin;
  final ValueChanged<int> onToggleSave;
  final ValueChanged<String> onToggleCollapse;

  const _Shelf({
    required this.sources,
    required this.onRefresh,
    required this.onOpenBookmarks,
    required this.pinned,
    required this.saved,
    required this.collapsed,
    required this.onTogglePin,
    required this.onToggleSave,
    required this.onToggleCollapse,
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

    // Pinned works are lifted into their own section at the top and dropped
    // from their tradition group, so they are never listed twice.
    final pinnedSources =
        sources!.where((s) => pinned.contains(s['id'] as int)).toList();

    final byTradition = <String, List<Map<String, dynamic>>>{};
    for (final source in sources!) {
      if (pinned.contains(source['id'] as int)) continue;
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
          if (pinnedSources.isNotEmpty) ...[
            const _SectionHeader(title: 'Pinned'),
            for (final source in pinnedSources) _tile(context, source),
          ],
          for (final entry in byTradition.entries) ...[
            _SectionHeader(
              title: entry.key,
              count: entry.value.length,
              collapsed: collapsed.contains(entry.key),
              onToggle: () => onToggleCollapse(entry.key),
            ),
            if (!collapsed.contains(entry.key))
              for (final source in entry.value) _tile(context, source),
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

  Widget _tile(BuildContext context, Map<String, dynamic> source) {
    final id = source['id'] as int;
    return _SourceTile(
      source: source,
      isPinned: pinned.contains(id),
      isSaved: saved.contains(id),
      onTogglePin: () => onTogglePin(id),
      onToggleSave: () => onToggleSave(id),
    );
  }
}

/// A grouped-shelf section header. Plain for "Pinned"; a tappable disclosure
/// row (with a rotating chevron and a count) for the collapsible tradition
/// sections.
class _SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final bool collapsed;
  final VoidCallback? onToggle;

  const _SectionHeader({
    required this.title,
    this.count,
    this.collapsed = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: theme.textTheme.titleSmall),
          ),
          if (count != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '$count',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (onToggle != null)
            // Points down when the section is open, right when it is collapsed —
            // the standard iOS disclosure behaviour.
            AnimatedRotation(
              turns: collapsed ? 0 : 0.25,
              duration: const Duration(milliseconds: 150),
              child: Icon(AppIcons.chevronRight,
                  size: 18, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );

    if (onToggle == null) return row;
    return InkWell(onTap: onToggle, child: row);
  }
}

/// A source on the shelf. Swipe right to pin it to the top, swipe left to
/// bookmark it; a filled bookmark glyph marks the saved ones. The row springs
/// back after either swipe rather than being dismissed — the gestures toggle
/// state, they do not remove anything.
class _SourceTile extends StatelessWidget {
  final Map<String, dynamic> source;
  final bool isPinned;
  final bool isSaved;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleSave;

  const _SourceTile({
    required this.source,
    required this.isPinned,
    required this.isSaved,
    required this.onTogglePin,
    required this.onToggleSave,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = source['id'] as int;
    final title = source['title'] as String? ?? 'Untitled';

    final tile = ListTile(
      title: Text(title),
      subtitle: Text([
        if ((source['author'] as String?)?.isNotEmpty ?? false)
          source['author'] as String,
        if ((source['date_composed'] as String?)?.isNotEmpty ?? false)
          source['date_composed'] as String,
        '${source['units']} sections',
      ].join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSaved)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(AppIcons.bookmarkFill, size: 16, color: scheme.primary),
            ),
          Icon(AppIcons.chevronRight, size: 18),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SourceReaderScreen(sourceId: id, title: title),
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('shelf-source-$id'),
      background: _swipeAction(
        leading: true,
        color: scheme.primary,
        onColor: scheme.onPrimary,
        icon: AppIcons.pin,
        label: isPinned ? 'Unpin' : 'Pin to top',
      ),
      secondaryBackground: _swipeAction(
        leading: false,
        color: scheme.tertiary,
        onColor: scheme.onTertiary,
        icon: isSaved ? AppIcons.bookmarkFill : AppIcons.bookmark,
        label: isSaved ? 'Remove' : 'Bookmark',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onTogglePin();
        } else {
          onToggleSave();
        }
        // Never actually dismiss: the swipe is an action, and the row stays.
        return false;
      },
      child: tile,
    );
  }

  Widget _swipeAction({
    required bool leading,
    required Color color,
    required Color onColor,
    required IconData icon,
    required String label,
  }) {
    return Container(
      color: color,
      alignment: leading ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onColor, size: 22),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: onColor, fontWeight: FontWeight.w600),
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
