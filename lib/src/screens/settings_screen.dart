import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/settings_provider.dart';
import '../services/inference/inference_provider.dart';
import '../theme/app_theme.dart';
import '../theme/glass_controls.dart';
import '../theme/inset_group.dart';
import 'ai_backend_screen.dart';
import 'library_screen.dart';
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

  Future<void> _pickTheme(
      BuildContext context, SettingsProvider settings) async {
    final chosen = await showModalBottomSheet<AppThemeChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<AppThemeChoice>(
          groupValue: settings.themeChoice,
          onChanged: (value) => Navigator.pop(context, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in AppThemeChoice.values)
                RadioListTile<AppThemeChoice>(
                  value: choice,
                  title: Text(choice.label),
                  subtitle: Text(choice.detail),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) await settings.setThemeChoice(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        // A normal pushed route with its own nav bar, so a plain bottom inset
        // for the home indicator is all it needs.
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          InsetGroup(
            header: 'Appearance',
            children: [
              ListTile(
                leading: Icon(AppIcons.theme),
                title: const Text('Theme'),
                trailing: _Value(settings.themeChoice.label),
                onTap: () => _pickTheme(context, settings),
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
                  MaterialPageRoute(builder: (_) => const LibraryScreen()),
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
              ),
            ],
          ),

          const SizedBox(height: 28),

          // A destructive action, styled as iOS renders one: centred, in the
          // error colour, on its own cell rather than as a filled button.
          InsetGroup(
            children: [
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
        ],
      ),
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
