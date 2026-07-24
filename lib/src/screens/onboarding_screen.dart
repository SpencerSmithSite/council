import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/inference/inference_provider.dart';
import '../services/packs/pack_manifest.dart';
import '../services/packs/pack_provider.dart';
import '../services/settings_provider.dart';
import 'ai_backend_screen.dart';

/// First run (and, from Settings, any run): three swipeable steps that hand the
/// reader the three choices the app is built around — which Scripture, which
/// bodies of tradition, and whether any AI is involved at all.
///
/// The app ships with the King James Bible and nothing else, which is
/// deliberate but invisible. Nothing here is downloaded without being asked
/// for, and every step can be skipped: the app works on Scripture alone, fully
/// offline, with no AI.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 3;

  final _pageController = PageController();
  int _index = 0;

  /// Collections chosen across steps 1–2 but not yet downloaded. Collected
  /// first and installed on finish, so the reader sees the total before
  /// committing rather than discovering it one download at a time.
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

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// The download total for everything chosen so far, over the *union* of their
  /// fragments — collections overlap, so summing their advertised sizes would
  /// overstate it.
  int get _totalBytes {
    final packs = context.read<PackProvider>();
    final manifest = packs.manifest;
    if (manifest == null) return 0;

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
    final navigator = Navigator.of(context);

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
    // Pushed from Settings ("Show Onboarding") → pop back to it. Shown as the
    // first-run home → there is nothing to pop, and completing onboarding flips
    // the app to the main screen on its own.
    if (mounted && navigator.canPop()) navigator.pop();
  }

  void _next() {
    if (_index < _pageCount - 1) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else {
      _finish(download: true);
    }
  }

  void _back() {
    if (_index > 0) {
      _pageController.previousPage(
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _BiblesPage(
                    chosen: _chosen,
                    onChanged: _onChoiceChanged,
                  ),
                  _StartHerePage(
                    chosen: _chosen,
                    onChanged: _onChoiceChanged,
                  ),
                  const _AiPage(),
                ],
              ),
            ),
            _BottomBar(
              index: _index,
              pageCount: _pageCount,
              selectedCount: _chosen.length,
              totalBytes: _totalBytes,
              onBack: _back,
              onNext: _next,
              onSkip: () => _finish(download: false),
            ),
          ],
        ),
      ),
    );
  }

  void _onChoiceChanged(String id, bool selected) {
    setState(() => selected ? _chosen.add(id) : _chosen.remove(id));
  }
}

/// Step 1 — Scripture. The King James is already here; these are the other
/// public-domain translations, offered but never forced.
class _BiblesPage extends StatelessWidget {
  final Set<String> chosen;
  final void Function(String id, bool selected) onChanged;

  const _BiblesPage({required this.chosen, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final manifest = packs.manifest;
    final bibles = manifest == null
        ? const <Collection>[]
        : manifest.collections
            .where((c) => c.kind == CollectionKind.scripture)
            .toList();

    return _Page(
      icon: Icons.menu_book_outlined,
      title: 'Start with Scripture',
      subtitle:
          'The King James Bible is already installed and works offline. Add any '
          'of these other public-domain translations if you like — or move on, '
          'and add them later from the Library.',
      child: _Body(
        manifest: manifest,
        error: packs.error,
        onRetry: packs.refresh,
        children: [
          const _IncludedChip(),
          const SizedBox(height: 12),
          for (final collection in bibles)
            _Choice(
              collection: collection,
              bytes:
                  manifest!.bytesToInstall(collection, packs.installedFragments),
              selected: chosen.contains(collection.id),
              onChanged: (v) => onChanged(collection.id, v),
            ),
          if (bibles.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No additional translations are published yet.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Step 2 — the bodies of tradition. Creeds & Confessions is recommended as the
/// starting point because it is the smallest set that can answer a question
/// comparing two traditions.
class _StartHerePage extends StatelessWidget {
  final Set<String> chosen;
  final void Function(String id, bool selected) onChanged;

  const _StartHerePage({required this.chosen, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final packs = context.watch<PackProvider>();
    final manifest = packs.manifest;
    final offered = manifest == null
        ? const <Collection>[]
        : manifest.collections
            .where((c) =>
                c.kind == CollectionKind.essential ||
                c.kind == CollectionKind.era)
            .toList();

    return _Page(
      icon: Icons.auto_stories_outlined,
      title: 'Build your library',
      subtitle:
          'The councils, creeds, confessions and church fathers. Start with '
          'Creeds & Confessions — the rest of the collections are always in the '
          'Library.',
      child: _Body(
        manifest: manifest,
        error: packs.error,
        onRetry: packs.refresh,
        children: [
          for (final collection in offered)
            _Choice(
              collection: collection,
              bytes:
                  manifest!.bytesToInstall(collection, packs.installedFragments),
              selected: chosen.contains(collection.id),
              recommended: collection.id == 'creeds-and-confessions',
              onChanged: (v) => onChanged(collection.id, v),
            ),
        ],
      ),
    );
  }
}

/// Step 3 — how answers are generated. Search-only is the default and a
/// first-class choice; the other two send a question somewhere, so they are
/// opt-in and say so.
class _AiPage extends StatelessWidget {
  const _AiPage();

  @override
  Widget build(BuildContext context) {
    final inference = context.watch<InferenceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final selected = inference.backendId;

    return _Page(
      icon: Icons.auto_awesome_outlined,
      title: 'Answers, your way',
      subtitle:
          'Council is a searchable library first. AI is optional — and you '
          'choose where it runs. Nothing leaves your device unless you add a '
          'cloud key.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          _AiOption(
            id: 'none',
            title: 'No AI — search only',
            subtitle: 'Browse and search everything offline. Nothing is '
                'generated and nothing leaves your device.',
            icon: Icons.menu_book_outlined,
            selected: selected == 'none',
          ),
          const SizedBox(height: 10),
          _AiOption(
            id: 'ollama',
            title: 'Ollama',
            subtitle: 'A model on this machine or one you reach over your '
                'network — private, and set up in a moment.',
            icon: Icons.dns_outlined,
            selected: selected == 'ollama',
          ),
          const SizedBox(height: 10),
          _AiOption(
            id: 'cloud',
            title: 'Your own API key',
            subtitle: 'Claude, ChatGPT, Gemini or Grok, billed to your own '
                'account. Questions are sent to that provider.',
            icon: Icons.vpn_key_outlined,
            selected: selected == 'cloud',
          ),
          if (selected != 'none') ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiBackendScreen()),
                ),
                icon: const Icon(Icons.settings_outlined),
                label: Text(selected == 'ollama'
                    ? 'Set up the Ollama connection'
                    : 'Add your API key'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'You can change this any time in Settings. Search-only stays '
                  'fully offline; the cloud option is governed by that '
                  "provider's own privacy and data-retention terms.",
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The frame every step shares: an icon, a title and a subtitle, then the
/// step's own scrolling content.
class _Page extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  const _Page({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 34, color: theme.colorScheme.primary),
              const SizedBox(height: 14),
              Text(title,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(subtitle,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Wraps a step's list with the loading and error states of the pack catalogue,
/// so a step that offers downloads degrades gracefully when it can't be reached.
class _Body extends StatelessWidget {
  final PackManifest? manifest;
  final String? error;
  final Future<void> Function() onRetry;
  final List<Widget> children;

  const _Body({
    required this.manifest,
    required this.error,
    required this.onRetry,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (manifest == null) {
      return Center(
        child: error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'The catalogue could not be reached. You can add '
                      'collections later from the Library.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: onRetry, child: const Text('Try again')),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: children,
    );
  }
}

/// The bottom navigation shared by every step: the page dots, a Back/Skip on
/// the left, and Next / Get started on the right.
class _BottomBar extends StatelessWidget {
  final int index;
  final int pageCount;
  final int selectedCount;
  final int totalBytes;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _BottomBar({
    required this.index,
    required this.pageCount,
    required this.selectedCount,
    required this.totalBytes,
    required this.onBack,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = index == pageCount - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectedCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '$selectedCount selected · ${formatBytes(totalBytes)} to '
                'download',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Row(
            children: [
              // Back on the left once past the first step, otherwise the page
              // dots sit alone.
              if (index > 0)
                IconButton(
                  tooltip: 'Back',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              _Dots(index: index, count: pageCount),
              const Spacer(),
              TextButton(
                onPressed: onSkip,
                child: const Text('Skip'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onNext,
                child: Text(isLast ? 'Get started' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The little page-indicator bubbles: the active step is a wider accent pill.
class _Dots extends StatelessWidget {
  final int index;
  final int count;

  const _Dots({required this.index, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == index
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// What ships with the app, stated plainly and warmly — so a reader looking at
/// a library of things to *add* can see what they already have.
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
          Flexible(
            child: Text(
              'King James Bible included — works offline',
              style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
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
  final bool recommended;
  final ValueChanged<bool> onChanged;

  const _Choice({
    required this.collection,
    required this.bytes,
    required this.selected,
    required this.onChanged,
    this.recommended = false,
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
            if (recommended) ...[
              _StartHereBadge(),
              const SizedBox(width: 8),
            ],
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

/// The "Start here" badge on the recommended first collection.
class _StartHereBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Start here',
        style: TextStyle(
            color: scheme.onPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A selectable AI-backend option on the final step — a radio-style card bound
/// to the inference provider.
class _AiOption extends StatelessWidget {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;

  const _AiOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      child: ListTile(
        onTap: () => context.read<InferenceProvider>().setBackend(id),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? scheme.primary : null,
        ),
      ),
    );
  }
}
