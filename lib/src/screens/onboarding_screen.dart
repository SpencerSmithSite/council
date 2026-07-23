import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/packs/pack_manifest.dart';
import '../services/packs/pack_provider.dart';
import '../services/settings_provider.dart';

/// First run: explain what is here, and let the reader choose the rest.
///
/// The app ships with the Bible and nothing else, which is deliberate but
/// invisible — without this, a new reader opens a library of one book with no
/// indication that is not all there is, and the screen that would tell them
/// otherwise is four taps away.
///
/// Nothing is downloaded without being asked for, and skipping is a real
/// option rather than a dark-patterned one: the app works on Scripture alone.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  /// Chosen but not yet downloaded. Collected first and installed on confirm,
  /// so the reader sees the total before committing to it rather than
  /// discovering it one download at a time.
  final Set<String> _chosen = {};
  bool _installing = false;
  String? _currentName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<PackProvider>().refresh();
      if (!mounted) return;
      // Pre-selected because it is the smallest collection that makes a
      // comparative question answerable at all, which is what the app is for.
      final manifest = context.read<PackProvider>().manifest;
      if (manifest != null &&
          manifest.collections.any((c) => c.id == 'creeds-and-confessions')) {
        setState(() => _chosen.add('creeds-and-confessions'));
      }
    });
  }

  int get _totalBytes {
    final packs = context.read<PackProvider>();
    final manifest = packs.manifest;
    if (manifest == null) return 0;

    // Summed over the *union* of fragments rather than per collection.
    // Collections overlap, so adding their advertised sizes would overstate
    // the download — often by a lot.
    final fragments = <String>{};
    for (final collection in manifest.collections) {
      if (_chosen.contains(collection.id)) {
        fragments.addAll(collection.fragments);
      }
    }
    fragments.removeAll(packs.installedFragments);

    var total = 0;
    for (final id in fragments) {
      total += manifest.fragment(id)?.bytes ?? 0;
    }
    return total;
  }

  Future<void> _finish({required bool download}) async {
    final settings = context.read<SettingsProvider>();
    final packs = context.read<PackProvider>();

    if (download && _chosen.isNotEmpty) {
      setState(() => _installing = true);
      final manifest = packs.manifest;
      if (manifest != null) {
        for (final collection in manifest.collections) {
          if (!_chosen.contains(collection.id)) continue;
          setState(() => _currentName = collection.name);
          await packs.install(collection);
        }
      }
    }

    await settings.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final manifest = packs.manifest;
    final theme = Theme.of(context);

    if (_installing) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text('Downloading ${_currentName ?? ''}',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'You can start reading as soon as this finishes.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
              child: Column(
                children: [
                  // The app's mark, so the first screen carries its identity.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset('assets/icon/icon.png',
                        width: 78, height: 78),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome to Council',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The councils, creeds, confessions, and church fathers of '
                    'every tradition — searchable offline, with optional AI '
                    'answers that cite their sources.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  const _IncludedChip(),
                  const SizedBox(height: 22),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Add to your library',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: manifest == null
                  ? Center(
                      child: packs.error != null
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'The catalogue could not be reached. You '
                                    'can add collections later from the '
                                    'Library.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 12),
                                  TextButton(
                                    onPressed: packs.refresh,
                                    child: const Text('Try again'),
                                  ),
                                ],
                              ),
                            )
                          : const CircularProgressIndicator(),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final collection in _offered(manifest))
                          _Choice(
                            collection: collection,
                            bytes: manifest.bytesToInstall(
                                collection, packs.installedFragments),
                            selected: _chosen.contains(collection.id),
                            onChanged: (value) => setState(() => value
                                ? _chosen.add(collection.id)
                                : _chosen.remove(collection.id)),
                          ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                          child: Text(
                            'More collections — individual authors, each '
                            'tradition, other periods — are in the Library.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _chosen.isEmpty
                          ? 'Nothing selected'
                          : '${_chosen.length} selected · '
                              '${formatBytes(_totalBytes)} to download',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _finish(download: false),
                    child: const Text('Skip for now'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _chosen.isEmpty
                        ? null
                        : () => _finish(download: true),
                    child: const Text('Download'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What to offer at first run.
  ///
  /// Not everything. Twenty collections is a decision to defer, not a choice
  /// to make, so this shows the comparative baseline and the broad periods and
  /// leaves authors and individual traditions to the Library.
  List<Collection> _offered(PackManifest manifest) => manifest.collections
      .where((c) =>
          c.kind == CollectionKind.essential ||
          c.kind == CollectionKind.scripture ||
          c.kind == CollectionKind.era)
      .toList();
}

/// What ships with the app, stated plainly and warmly rather than buried in a
/// paragraph — so a reader looking at a library of things to *add* can see what
/// they already have.
class _IncludedChip extends StatelessWidget {
  const _IncludedChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            'King James Bible included — works offline',
            style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final Collection collection;
  final int bytes;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _Choice({
    required this.collection,
    required this.bytes,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      // A chosen collection is tinted and outlined in the accent, so the
      // selection reads at a glance rather than only from the checkbox.
      color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      child: CheckboxListTile(
        value: selected,
        onChanged: (value) => onChanged(value ?? false),
        title: Row(
          children: [
            Expanded(child: Text(collection.name)),
            Text(
              // Zero is a real answer — a collection whose fragments are
              // already present costs nothing to add — but "0 B" reads as a
              // broken size rather than as good news.
              bytes == 0 ? 'Already installed' : formatBytes(bytes),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(collection.description,
              style: Theme.of(context).textTheme.bodySmall),
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }
}
