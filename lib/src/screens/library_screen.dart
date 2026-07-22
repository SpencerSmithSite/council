import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/packs/pack_manifest.dart';
import '../services/packs/pack_provider.dart';

/// Add and remove bodies of source material.
///
/// The app ships the creeds, councils and confessions — the material that
/// answers "what does this tradition actually teach" — and everything else is
/// downloaded on request. That keeps the install at 2.6 MB of content instead
/// of 54 MB, most of which any given reader never opens.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<PackProvider>().refresh(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final manifest = packs.manifest;

    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: RefreshIndicator(
        onRefresh: packs.refresh,
        child: ListView(
          children: [
            if (packs.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  packs.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (packs.loading && manifest == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (manifest != null)
              for (final group in _grouped(manifest.collections)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(group.key,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                for (final collection in group.value)
                  _PackTile(pack: collection),
              ],
            if (manifest != null && manifest.collections.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('No additional content is published yet.'),
              ),
          ],
        ),
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

            if (busy && !installed) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                // Indeterminate until the first bytes arrive, so the bar does
                // not sit at zero looking stalled while the request connects.
                value: packs.progress > 0 ? packs.progress : null,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: installed
                  ? TextButton.icon(
                      onPressed: blocked || busy
                          ? null
                          : () => _confirmRemove(context, packs),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove'),
                    )
                  : FilledButton.tonalIcon(
                      onPressed:
                          blocked || busy ? null : () => packs.install(pack),
                      icon: const Icon(Icons.download),
                      label: Text(busy ? 'Installing…' : 'Download'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Removing is destructive and re-downloading costs the user data, so it is
  /// confirmed rather than immediate.
  Future<void> _confirmRemove(BuildContext context, PackProvider packs) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await packs.uninstall(pack);
  }
}
