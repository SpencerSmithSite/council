import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/settings_provider.dart';
import '../services/inference/inference_provider.dart';
import '../services/updates/update_provider.dart';
import '../widgets/update_sheet.dart';
import '../theme/glass_controls.dart';
import '../theme/inset_group.dart';
import '../theme/themes.dart';
import 'ai_backend_screen.dart';
import 'onboarding_screen.dart';
import 'theme_screen.dart';
import 'browse_screen.dart';
import '../services/packs/pack_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _resetAll(BuildContext context) async {
    final settings = context.read<SettingsProvider>();

    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Reset All Settings?'),
        content: const Text('This will reset all preferences to defaults.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await settings.resetAll();
    }
  }

  /// The name shown on the Theme row: "Default" for the platform-adaptive theme,
  /// otherwise the chosen palette's name.
  static String _themeLabel(String id) =>
      id == kDefaultThemeId ? 'Default' : (namedThemeById(id)?.label ?? 'Default');

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final top = MediaQuery.of(context).padding.top;

    // Full-bleed like the primary screens: a scrolling large title with a
    // floating round back button, rather than a solid bar bolted to the top —
    // the same Apple chrome the Read and Browse tabs use. The scaffold keeps
    // its themed background (this is a pushed route), so the content is never
    // stranded on black.
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: 16 + MediaQuery.of(context).padding.bottom),
              children: [
                const LargeTitle('Settings'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(children: _sections(context, settings)),
                ),
              ],
            ),
          ),
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

  List<Widget> _sections(BuildContext context, SettingsProvider settings) {
    final scheme = Theme.of(context).colorScheme;
    return [
          InsetGroup(
            header: 'Appearance',
            children: [
              ListTile(
                leading: Icon(AppIcons.theme),
                title: const Text('Theme'),
                trailing: _Value(_themeLabel(settings.themeId)),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ThemeScreen()),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          InsetGroup(
            header: 'Reading',
            children: [
              ListTile(
                leading: Icon(AppIcons.fontSize),
                title: const Text('Font Size'),
                trailing: _Value('${settings.fontScale.toStringAsFixed(1)}x',
                    chevron: false),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Slider.adaptive(
                  value: settings.fontScale,
                  min: 0.8,
                  max: 1.5,
                  divisions: 7,
                  label: '${settings.fontScale.toStringAsFixed(1)}x',
                  onChanged: settings.setFontScale,
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          InsetGroup(
            header: 'Library',
            children: [
              ListTile(
                leading: Icon(AppIcons.manageContent),
                title: const Text('Manage content'),
                subtitle: Text(
                  context.watch<PackProvider>().installed.isEmpty
                      ? 'Add the church fathers and other collections'
                      : '${context.watch<PackProvider>().installed.length} '
                          'collection(s) installed',
                ),
                trailing: Icon(AppIcons.chevronRight),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BrowseScreen()),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          InsetGroup(
            header: 'AI Chat',
            footer: 'Citations name the source behind each answer, with its '
                'tradition and provenance.',
            children: [
              ListTile(
                leading: Icon(AppIcons.aiBackend),
                title: const Text('AI Backend'),
                subtitle: Text(
                    context.watch<InferenceProvider>().backend.displayName),
                trailing: Icon(AppIcons.chevronRight),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiBackendScreen()),
                ),
              ),
              SwitchListTile.adaptive(
                secondary: Icon(AppIcons.citations),
                title: const Text('Show Citations'),
                value: settings.showCitations,
                onChanged: settings.setShowCitations,
                // The adaptive switch is a Cupertino switch on Apple, whose
                // "on" track defaults to system green and ignores the palette.
                // Pin it to the theme accent so it matches the chosen theme.
                activeTrackColor: scheme.primary,
              ),
            ],
          ),

          const SizedBox(height: 22),

          const _UpdatesGroup(),

          const SizedBox(height: 28),

          // Two whole-app actions, iOS-style: centred text on their own cells.
          // "Show Onboarding" re-runs the welcome walkthrough; "Reset All
          // Settings" is destructive and drawn in the error colour.
          InsetGroup(
            children: [
              ListTile(
                title: Text(
                  'Show Onboarding',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.primary),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                ),
              ),
              ListTile(
                title: Text(
                  'Reset All Settings',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () => _resetAll(context),
              ),
            ],
          ),

          const SizedBox(height: 32),

          const Center(child: _AboutFooter()),
    ];
  }
}

/// Whether to look for a newer Council, and the version this one is.
///
/// The version was not shown anywhere before, which made every bug report begin
/// with working out which build the reader had.
class _UpdatesGroup extends StatefulWidget {
  const _UpdatesGroup();

  @override
  State<_UpdatesGroup> createState() => _UpdatesGroupState();
}

class _UpdatesGroupState extends State<_UpdatesGroup> {
  @override
  void initState() {
    super.initState();
    // Only reads the installed version; it does not check the network.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<UpdateProvider>().loadCurrentVersion());
  }

  Future<void> _checkNow() async {
    final updates = context.read<UpdateProvider>();
    await updates.check();
    if (!mounted) return;
    if (updates.release != null) {
      await UpdateSheet.show(context);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Council is up to date.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final updates = context.watch<UpdateProvider>();
    final scheme = Theme.of(context).colorScheme;
    final version = updates.currentVersion;

    return InsetGroup(
      header: 'Updates',
      // Named rather than vague: on iOS the app cannot install anything, and
      // saying so here saves a reader wondering why their Mac updates itself
      // and their iPhone sends them to TestFlight.
      footer: Platform.isIOS
          ? 'Council checks for a new version at launch and offers to open '
              'TestFlight. Apps on iPhone and iPad cannot install updates '
              'themselves.'
          : 'Council checks for a new version at launch. Nothing is downloaded '
              'until you say so, and every download is checked against the '
              'published checksum before it is installed.',
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.system_update_outlined),
          title: const Text('Check for updates automatically'),
          value: settings.autoCheckUpdates,
          onChanged: settings.setAutoCheckUpdates,
          // The adaptive switch is a Cupertino switch on Apple, whose "on"
          // track defaults to system green and ignores the palette.
          activeTrackColor: scheme.primary,
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Version'),
          subtitle: Text(version == null
              ? 'Reading…'
              : version.build == 0
                  ? version.name
                  : '${version.name} (build ${version.build})'),
          trailing: updates.busy
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: _checkNow,
                  child: const Text('Check now'),
                ),
        ),
      ],
    );
  }
}

/// Library counts, read from the database rather than hardcoded — the previous
/// hardcoded figures had drifted well out of date.
class _AboutFooter extends StatelessWidget {
  const _AboutFooter();

  @override
  Widget build(BuildContext context) {
    final outlineStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        );

    return Column(
      children: [
        Text(
          'Council',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Christian Theology Research',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FutureBuilder<Map<String, dynamic>>(
          future: context.read<DatabaseService>().getStats(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox(height: 16);
            final stats = snapshot.data!;
            return Text(
              '${stats['sources']} sources • '
              '${stats['content_units']} passages',
              style: outlineStyle,
            );
          },
        ),
      ],
    );
  }
}

/// The trailing value on a settings row — a muted label, followed by a
/// disclosure chevron when the row opens something. This is how iOS shows the
/// current selection inline ("Theme … Dark ›") without a subtitle.
class _Value extends StatelessWidget {
  final String text;

  /// A disclosure chevron follows the value only when the row opens something.
  final bool chevron;

  const _Value(this.text, {this.chevron = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (chevron)
          Icon(AppIcons.chevronRight, size: 20, color: scheme.onSurfaceVariant),
      ],
    );
  }
}
