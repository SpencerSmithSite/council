import 'package:flutter/material.dart';
import '../theme/glass.dart';
import '../theme/glass_controls.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/packs/pack_provider.dart';
import '../services/read_shelf_service.dart';
import 'content_detail_screen.dart';
import 'browse_screen.dart';
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

  // Persisted shelf arrangement: pinned and starred source ids, and the names
  // of tradition sections the reader has collapsed.
  Set<int> _pinned = {};
  Set<int> _starred = {};
  Set<String> _collapsed = {};

  // Whether the shelf is narrowed to starred works.
  //
  // Deliberately not persisted, unlike the rest of the arrangement above. A
  // filter that survived a relaunch would greet the reader with most of their
  // library missing and only a small highlighted button to explain why.
  bool _starredOnly = false;

  // The library's installed set, watched so the shelf reloads the moment a pack
  // is added or removed — the reader shouldn't have to pull-to-refresh to see a
  // download they just made.
  PackProvider? _packs;
  Set<String> _knownFragments = {};

  @override
  void initState() {
    super.initState();
    // Ordered, not fired in parallel: the stored arrangement has to be in hand
    // before the shelf can decide whether to apply the collapsed-by-default
    // state, or a late-arriving preference load overwrites that decision and
    // the first open comes up expanded after all.
    _restoreShelf();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _packs = context.read<PackProvider>();
      _knownFragments = _packs!.installedFragments.toSet();
      _packs!.addListener(_onPacksChanged);
    });
  }

  /// Reload the shelf when the *installed set* changes — not on the many
  /// progress ticks a download fires — so newly installed sources appear (and
  /// removed ones disappear) without a manual refresh.
  void _onPacksChanged() {
    final packs = _packs;
    if (packs == null) return;
    final current = packs.installedFragments;
    if (current.length != _knownFragments.length ||
        !current.containsAll(_knownFragments)) {
      _knownFragments = current.toSet();
      _loadShelf();
    }
  }

  Future<void> _restoreShelf() async {
    await _loadShelfPrefs();
    if (mounted) await _loadShelf();
  }

  Future<void> _loadShelfPrefs() async {
    final pinned = await _shelf.pinned();
    final starred = await _shelf.starred();
    final collapsed = await _shelf.collapsed();
    if (mounted) {
      setState(() {
        _pinned = pinned;
        _starred = starred;
        _collapsed = collapsed;
      });
    }
  }

  // Every arrangement gesture below repaints first and writes afterwards.
  // Persisting is a platform-channel hop and a file write; awaiting it before
  // setState put that latency between the reader's tap and the section
  // actually opening, which read as the whole shelf being sluggish. The write
  // cannot meaningfully fail — and if it did, the shelf is still correct for
  // this session and merely reverts on the next launch — so nothing is gained
  // by making the frame wait for it.
  void _togglePin(int id) {
    final next = _pinned.toggled(id);
    setState(() => _pinned = next);
    _shelf.setPinned(next);
  }

  void _toggleStar(int id) {
    final next = _starred.toggled(id);
    setState(() => _starred = next);
    _shelf.setStarred(next);
  }

  void _toggleStarredOnly() {
    setState(() => _starredOnly = !_starredOnly);
  }

  void _toggleCollapse(String tradition) {
    final next = _collapsed.toggled(tradition);
    setState(() => _collapsed = next);
    _shelf.setCollapsed(next);
  }

  /// Every tradition that currently has a (non-pinned) section on the shelf —
  /// the set "collapse all" acts on.
  Set<String> _traditionNames() {
    final sources = _sources;
    if (sources == null) return {};
    return {
      for (final s in sources)
        if (!_pinned.contains(s['id'] as int)) s['tradition'] as String,
    };
  }

  /// True when every collapsible section is already collapsed, so the header
  /// button offers "expand all" rather than "collapse all".
  bool get _allCollapsed {
    final traditions = _traditionNames();
    return traditions.isNotEmpty && traditions.every(_collapsed.contains);
  }

  void _toggleCollapseAll() {
    // Collapse everything, or — if it is all collapsed already — expand it.
    final next = _allCollapsed ? <String>{} : _traditionNames();
    setState(() => _collapsed = next);
    _shelf.setCollapsed(next);
  }

  @override
  void dispose() {
    _packs?.removeListener(_onPacksChanged);
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
    if (!mounted) return;
    setState(() => _sources = rows);
    await _applyDefaultCollapse();
  }

  /// Start collapsed, until the reader says otherwise.
  ///
  /// Can only run once the shelf has loaded, because the section names come
  /// from the sources themselves — and it re-runs after a pack is installed so
  /// a tradition that has only just appeared starts collapsed too, rather than
  /// being the one section left hanging open.
  Future<void> _applyDefaultCollapse() async {
    if (await _shelf.hasArrangedSections()) return;
    final traditions = _traditionNames();
    if (traditions.isEmpty) return;
    final next = await _shelf.applyDefaultCollapse(traditions);
    if (mounted) setState(() => _collapsed = next);
  }

  /// The shelf, narrowed by the starred filter and by whatever is in the box.
  ///
  /// The text match covers title, author and tradition, because a reader
  /// hunting for Augustine may type any of the three.
  List<Map<String, dynamic>>? get _filtered {
    var all = _sources;
    if (all == null) return null;

    if (_starredOnly) {
      all = all
          .where((source) => _starred.contains(source['id'] as int))
          .toList();
    }

    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return all;

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
      // Search lives in the floating bottom bubble now: typing filters the
      // shelf live, return runs a full-text search inside the passages. It
      // hovers over the shelf, which passes behind it.
      extendBody: true,
      bottomNavigationBar: GlassComposer(
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
      body: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results != null
                    ? _Results(rows: _results!)
                    : _Shelf(
                        sources: _filtered,
                        onRefresh: _loadShelf,
                        filtered: _query.text.trim().isNotEmpty,
                        starredOnly: _starredOnly,
                        anyStarred: _starred.isNotEmpty,
                        pinned: _pinned,
                        starred: _starred,
                        collapsed: _collapsed,
                        allCollapsed: _allCollapsed,
                        onTogglePin: _togglePin,
                        onToggleStar: _toggleStar,
                        onToggleCollapse: _toggleCollapse,
                        onToggleCollapseAll: _toggleCollapseAll,
                        onToggleStarredOnly: _toggleStarredOnly,
                      ),
    );
  }
}

/// A copy of this set with [value] removed if present and added if not.
///
/// A copy rather than a mutation because the shelf's state fields are compared
/// by identity when Flutter decides what to rebuild; mutating the existing set
/// in place would leave the field pointing at the same object and the change
/// could be missed.
extension _Toggle<T> on Set<T> {
  Set<T> toggled(T value) {
    final next = Set<T>.of(this);
    if (!next.remove(value)) next.add(value);
    return next;
  }
}

/// The tradition that holds the Bibles, lifted out of alphabetical order.
///
/// Matched by name rather than by id because the shelf is built from whatever
/// is installed, and a pack can introduce sources under it.
const String _scripture = 'Scripture';

/// The installed works, grouped by tradition, with pinned works lifted to the
/// top and each tradition section collapsible.
class _Shelf extends StatelessWidget {
  final List<Map<String, dynamic>>? sources;
  final Future<void> Function() onRefresh;

  /// Narrowed by the search box.
  final bool filtered;

  /// Narrowed to starred works.
  final bool starredOnly;

  /// Whether anything is starred *at all*, which is what separates "the filter
  /// found nothing" from "there is nothing to filter for yet".
  final bool anyStarred;

  final Set<int> pinned;
  final Set<int> starred;
  final Set<String> collapsed;
  final bool allCollapsed;
  final ValueChanged<int> onTogglePin;
  final ValueChanged<int> onToggleStar;
  final ValueChanged<String> onToggleCollapse;
  final VoidCallback onToggleCollapseAll;
  final VoidCallback onToggleStarredOnly;

  const _Shelf({
    required this.sources,
    required this.onRefresh,
    required this.pinned,
    required this.starred,
    required this.collapsed,
    required this.allCollapsed,
    required this.onTogglePin,
    required this.onToggleStar,
    required this.onToggleCollapse,
    required this.onToggleCollapseAll,
    required this.onToggleStarredOnly,
    this.filtered = false,
    this.starredOnly = false,
    this.anyStarred = false,
  });

  /// Whether the shelf is showing a subset of what is installed.
  ///
  /// Sections stay open while it is: a collapsed section under a filter shows
  /// its own header and hides the very rows the reader narrowed the shelf to
  /// find, which reads as "no results" when there are results. The reader's own
  /// collapsed arrangement is untouched and comes back when the filter lifts.
  bool get _narrowed => filtered || starredOnly;

  @override
  Widget build(BuildContext context) {
    if (sources == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final scheme = Theme.of(context).colorScheme;

    // Whether there is at least one collapsible tradition section to act on.
    // Under a filter every section is forced open, so the control would have
    // nothing to say.
    final hasSections =
        !_narrowed && sources!.any((s) => !pinned.contains(s['id'] as int));

    final header = LargeTitle(
      'Read',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasSections)
            IconButton(
              tooltip: allCollapsed ? 'Expand all' : 'Collapse all',
              icon: Icon(
                  allCollapsed ? Icons.unfold_more : Icons.unfold_less),
              onPressed: onToggleCollapseAll,
            ),
          // Filled and tinted while on: the shelf is hiding most of the library
          // and the reason has to be visible, or the missing works read as a
          // bug rather than a filter.
          IconButton(
            tooltip: starredOnly ? 'Show all works' : 'Show starred only',
            icon: Icon(starredOnly ? AppIcons.starFill : AppIcons.star),
            color: starredOnly ? scheme.primary : null,
            isSelected: starredOnly,
            onPressed: onToggleStarredOnly,
          ),
        ],
      ),
    );

    if (sources!.isEmpty) {
      // Which nothing this is matters: a filter hiding everything needs a way
      // out, and a reader who has never starred anything needs to be told what
      // starring is rather than shown an empty result.
      final String message;
      if (starredOnly && !anyStarred) {
        message = 'No works are starred yet. Swipe a work to the left to star '
            'it, and it will be listed here.';
      } else if (starredOnly && filtered) {
        message = 'No starred work matches.';
      } else if (starredOnly) {
        message = 'No starred works are on your shelf.';
      } else if (filtered) {
        message = 'Nothing on your shelf matches. Press return to search '
            'inside the texts instead.';
      } else {
        message = 'Nothing installed yet.';
      }

      return ListView(
        padding: EdgeInsets.only(bottom: floatingBottomInset(context)),
        children: [
          header,
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 12),
            child: Text(message, textAlign: TextAlign.center),
          ),
          if (starredOnly)
            Center(
              child: TextButton(
                onPressed: onToggleStarredOnly,
                child: const Text('Show all works'),
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

    // Scripture sits directly under Pinned, ahead of the alphabet. It is what
    // most readers open most often, and leaving it to fall between Reformed
    // and Universal buries the one section nobody should have to look for.
    // Everything else keeps the order the query returned.
    final traditions = byTradition.keys.toList();
    final scripture = traditions.remove(_scripture);
    final order = [if (scripture) _scripture, ...traditions];

    // Slivers rather than a ListView of boxes: a section's rows have to stay
    // lazily built, or expanding an 82-work tradition would lay out 82 tiles in
    // a single frame — off-screen ones included — and visibly stutter.
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        // Dragging the shelf puts the search keyboard away.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(child: header),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // Always shown, even empty. Pinning is the shelf's main arrangement
          // gesture and it is invisible: without a labelled place for pinned
          // works to land, nothing on screen suggests the gesture exists.
          SliverToBoxAdapter(
            child: _SectionHeader(
              title: 'Pinned',
              count: pinnedSources.isEmpty ? null : pinnedSources.length,
            ),
          ),
          if (pinnedSources.isEmpty)
            const SliverToBoxAdapter(child: _EmptyPinnedSlot())
          else
            _card(context, pinnedSources),
          // The gap that separates one tradition from the next is deliberately
          // larger than the gap between a section's own label and its card, so
          // "these belong together" and "this is a new group" read differently
          // at a glance rather than as one undifferentiated run of rows.
          for (final tradition in order) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
            SliverToBoxAdapter(
              child: _SectionHeader(
                title: tradition,
                count: byTradition[tradition]!.length,
                collapsed: !_narrowed && collapsed.contains(tradition),
                // No disclosure control under a filter: the section cannot be
                // closed while narrowed, so offering the chevron would be
                // offering a control that does nothing.
                onToggle:
                    _narrowed ? null : () => onToggleCollapse(tradition),
              ),
            ),
            if (_narrowed || !collapsed.contains(tradition))
              _card(context, byTradition[tradition]!),
          ],
          // With Scripture alone the shelf is one book, and the reason is not
          // obvious from an otherwise working screen.
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  24, 24, 24, 24 + floatingBottomInset(context, extra: 8)),
              child: Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BrowseScreen()),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add more to your library'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One section's rows, each drawn as its own card.
  ///
  /// A card per work rather than one card per section with rules between the
  /// rows: grouping every work into a single slab made the individual works
  /// run together again, which is the thing this layout exists to stop. What
  /// marks a *section* is the label above it and the wider gap before it — the
  /// cards themselves only ever mark one work each.
  Widget _card(BuildContext context, List<Map<String, dynamic>> rows) {
    final scheme = Theme.of(context).colorScheme;
    final hairline =
        Theme.of(context).dividerTheme.color ?? scheme.outlineVariant;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.separated(
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        // A [Material] rather than a decorated box, because the tile inside
        // paints its ink on the nearest Material ancestor: a plain background
        // painted over that ancestor would sit on top of the splash and swallow
        // it, and the row would stop responding visibly to taps.
        itemBuilder: (context, i) => Material(
          // Outlined and barely tinted rather than solidly filled: the outline
          // is enough to bound the row, and a heavier fill would compete with
          // the glass chrome floating over it.
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
          shape: squircle(
            AppleMetrics.cardRadius,
            side: BorderSide(color: hairline.withValues(alpha: 0.4)),
          ),
          // Clipped to its own shape so a tap ripple or the coloured
          // swipe-action background stays inside the corners.
          clipBehavior: Clip.antiAlias,
          child: _tile(context, rows[i]),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> source) {
    final id = source['id'] as int;
    return _SourceTile(
      source: source,
      isPinned: pinned.contains(id),
      isStarred: starred.contains(id),
      onTogglePin: () => onTogglePin(id),
      onToggleStar: () => onToggleStar(id),
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
      // The gap above a label is whitespace the caller controls (see the
      // [SizedBox]s around this widget in [_Shelf]), so it can differ between
      // "new category" and "title to first category". This padding only
      // holds the label close to the card it introduces.
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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

/// The Pinned section with nothing in it: an empty card in the same shape the
/// filled sections take, holding the instruction for the gesture that fills it.
///
/// Drawn rather than left as bare text so the section keeps the outline every
/// other section has — an empty slot that visibly *is* a container reads as
/// somewhere works can be put, where a floating line of grey text reads as a
/// stray caption. The border is dashed to say the same thing again: this is a
/// place, and it is waiting.
class _EmptyPinnedSlot extends StatelessWidget {
  const _EmptyPinnedSlot();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hairline =
        Theme.of(context).dividerTheme.color ?? scheme.outlineVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CustomPaint(
        painter: _DashedOutlinePainter(
          radius: AppleMetrics.cardRadius,
          color: hairline.withValues(alpha: 0.45),
        ),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(AppIcons.pin,
                    size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Swipe a work right to keep it here',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded outline, in the same continuous-corner shape the filled
/// section cards use, so the empty slot lines up with them exactly.
class _DashedOutlinePainter extends CustomPainter {
  final double radius;
  final Color color;

  const _DashedOutlinePainter({required this.radius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRSuperellipse(
        RSuperellipse.fromRectXY(Offset.zero & size, radius, radius),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;

    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, (distance + dash).clamp(0, metric.length)),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter old) =>
      old.radius != radius || old.color != color;
}

/// A source on the shelf. Swipe right to pin it to the top, swipe left to star
/// it; a filled star glyph marks the starred ones. (Starring a whole source is
/// deliberately separate from the passage-level bookmarks reached from the
/// header.) The row springs back after either swipe rather than being dismissed
/// — the gestures toggle state, they do not remove anything.
class _SourceTile extends StatelessWidget {
  final Map<String, dynamic> source;
  final bool isPinned;
  final bool isStarred;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleStar;

  const _SourceTile({
    required this.source,
    required this.isPinned,
    required this.isStarred,
    required this.onTogglePin,
    required this.onToggleStar,
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
          if (isStarred)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(AppIcons.starFill, size: 16, color: scheme.primary),
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
        icon: isStarred ? AppIcons.starFill : AppIcons.star,
        label: isStarred ? 'Unstar' : 'Star',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onTogglePin();
        } else {
          onToggleStar();
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
          // Centred in the space the search capsule leaves, not behind it.
          padding: EdgeInsets.fromLTRB(32, 32, 32, floatingBottomInset(context)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Nothing found in what you have installed.'),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BrowseScreen()),
                ),
                child: const Text('Browse collections'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.only(
        top: floatingTopInset(context),
        bottom: floatingBottomInset(context, extra: 8),
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
