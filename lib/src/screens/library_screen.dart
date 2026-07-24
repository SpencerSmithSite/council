import 'package:flutter/material.dart';
import '../theme/glass_controls.dart';
import 'package:provider/provider.dart';

import '../services/packs/pack_manifest.dart';
import '../services/packs/pack_provider.dart';

/// Add and remove bodies of source material.
///
/// The app ships the King James Bible and nothing else. Scripture is what every
/// tradition here is arguing about, so an app without it starts every
/// conversation missing the text under discussion — and it is the one body of
/// material that makes the app useful before anything has been downloaded.
/// Everything else is chosen.
class LibraryScreen extends StatefulWidget {
  /// True when hosted inside the main tab shell, which already paints the
  /// background and floats the menu and settings bubbles over the content.
  ///
  /// False when the screen is pushed as its own route — from Settings' "Manage
  /// content" or from the Read tab. A pushed route has none of that chrome, so
  /// it must paint its own themed background (a transparent scaffold otherwise
  /// shows through to black) and offer a back button of its own.
  final bool embedded;

  const LibraryScreen({super.key, this.embedded = false});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<PackProvider>().refresh(),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// The collections matching the search box, by name and description.
  ///
  /// A reader looking for the Westminster standards should find the pack that
  /// contains them without knowing it is called "Reformed & Presbyterian", so
  /// the description is searched as well as the title — the description is where
  /// the individual works are named.
  List<Collection> _matching(List<Collection> all) {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((c) {
      return c.name.toLowerCase().contains(query) ||
          c.description.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final manifest = packs.manifest;
    final searching = _query.text.trim().isNotEmpty;

    final visible =
        manifest == null ? const <Collection>[] : _matching(manifest.collections);
    final top = MediaQuery.of(context).padding.top;

    final content = Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: packs.refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  const LargeTitle('Library'),
                  if (packs.error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        packs.error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  if (packs.loading && manifest == null)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  // The bundled-Bible notice is about the whole library, not a
                  // search result, so it steps aside while searching.
                  if (!searching) const _BundledNotice(),
                  if (manifest != null)
                    for (final group in _grouped(visible)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(group.key,
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      for (final collection in group.value)
                        _PackTile(pack: collection),
                    ],
                  if (manifest != null &&
                      manifest.collections.isEmpty &&
                      !searching)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('No additional content is published yet.'),
                    ),
                  if (searching && visible.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No packs match "${_query.text.trim()}".',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
          GlassComposer(
            controller: _query,
            hintText: 'Search packs',
            leadingIcon: AppIcons.search,
            onChanged: (_) => setState(() {}),
            onClear: () {
              _query.clear();
              setState(() {});
            },
          ),
        ],
      );

    // As a tab, the shell paints the background and the chrome; the screen stays
    // transparent. As a pushed route it owns both — a themed background and a
    // floating back button in the top-left corner.
    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      body: widget.embedded
          ? content
          : Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  top: top + 8,
                  left: AppleMetrics.edgeInset,
                  child: GlassBubble(
                    icon: AppIcons.back,
                    tooltip: 'Back',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
    );
  }
}

/// What ships with the app.
///
/// Stated rather than assumed: a reader looking at a library of things to
/// download should be able to see what they already have without working it
/// out from the absence of a download button.
class _BundledNotice extends StatelessWidget {
  const _BundledNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_outlined, size: 18,
              color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The King James Bible is included with the app and is always '
              'available offline.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collections in a deliberate order: the comparative baseline first, then
/// broad periods, then traditions, then individual authors. Someone opening
/// this for the first time should meet "Creeds & Confessions" before a list of
/// twenty patristic writers.
List<MapEntry<String, List<Collection>>> _grouped(List<Collection> all) {
  const order = {
    CollectionKind.essential: 'Start here',
    CollectionKind.scripture: 'Scripture',
    CollectionKind.era: 'By period',
    CollectionKind.tradition: 'By tradition',
    CollectionKind.author: 'By author',
    CollectionKind.other: 'More',
  };
  final groups = <MapEntry<String, List<Collection>>>[];
  for (final entry in order.entries) {
    final members = all.where((c) => c.kind == entry.key).toList();
    if (members.isNotEmpty) groups.add(MapEntry(entry.value, members));
  }
  return groups;
}

class _PackTile extends StatelessWidget {
  final Collection pack;

  const _PackTile({required this.pack});

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final installed = packs.isInstalled(pack.id);
    final busy = packs.busyId == pack.id;
    // One operation at a time: two concurrent merges would interleave writes
    // to the same tables and index.
    final blocked = packs.busyId != null && !busy;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(pack.name,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (installed)
                  const Icon(Icons.check_circle, size: 20)
                else
                  Text(
                    // What it costs *now*. Zero is common and honest: someone
                    // holding Church Fathers already has everything Augustine
                    // needs, and quoting a download that will not happen would
                    // be a routine small lie.
                    packs.bytesToInstall(pack) == 0
                        ? 'Already downloaded'
                        : formatBytes(packs.bytesToInstall(pack)),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(pack.description,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),

            // The action, at the bottom-right of the cell:
            //   • busy      → an App Store-style progress ring, no button
            //   • installed → Remove
            //   • costs bytes → Download
            //   • already present via another pack (0 bytes) → no button at
            //     all; the header already reads "Already downloaded", and
            //     offering a download that would fetch nothing was the bug.
            if (busy) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: _DownloadRing(
                  // Indeterminate until the first bytes arrive, so the ring does
                  // not sit empty looking stalled while the request connects.
                  value: packs.progress > 0 ? packs.progress : null,
                ),
              ),
            ] else if (installed) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      blocked ? null : () => _confirmRemove(context, packs),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
              ),
            ] else if (packs.bytesToInstall(pack) > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: blocked ? null : () => packs.install(pack),
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Removing is destructive and re-downloading costs the user data, so it is
  /// confirmed rather than immediate.
  Future<void> _confirmRemove(BuildContext context, PackProvider packs) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text('Remove ${pack.name}?'),
        content: const Text(
          'Anything also included in another collection you have downloaded '
          'will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await packs.uninstall(pack);
  }
}

/// The App Store download indicator: a thin ring that fills clockwise around a
/// small centre square as the pack downloads.
///
/// [value] is the fraction complete, or null before the first bytes arrive, when
/// the ring spins as an indeterminate indicator rather than sitting empty.
class _DownloadRing extends StatelessWidget {
  final double? value;

  const _DownloadRing({this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const diameter = 30.0;

    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The faint full track the progress ring is drawn over.
          SizedBox(
            width: diameter,
            height: diameter,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 2.5,
              valueColor:
                  AlwaysStoppedAnimation(scheme.surfaceContainerHighest),
            ),
          ),
          SizedBox(
            width: diameter,
            height: diameter,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 2.5,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(scheme.primary),
            ),
          ),
          // The centre square, the App Store's "downloading" (and tap-to-stop)
          // affordance. Purely indicative here — the download runs to
          // completion — but it is the shape users read as an active download.
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
