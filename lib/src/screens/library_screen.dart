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
              for (final pack in manifest.packs) _PackTile(pack: pack),
            if (manifest != null && manifest.packs.isEmpty)
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

class _PackTile extends StatelessWidget {
  final PackInfo pack;

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
                  Text(pack.sizeLabel,
                      style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: 6),
            Text(pack.description,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text('${pack.sources} works · ${pack.units} passages',
                style: Theme.of(context).textTheme.labelSmall),
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
        content: Text(
          'This deletes ${pack.units} passages from your library. You can '
          'download it again later (${pack.sizeLabel}).',
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
