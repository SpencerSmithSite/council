import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import '../services/settings_provider.dart';
import '../services/inference/inference_provider.dart';
import 'ai_backend_screen.dart';
import 'library_screen.dart';
import '../services/packs/pack_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _resetAll(BuildContext context) async {
    final settings = context.read<SettingsProvider>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset All Settings?'),
        content: const Text('This will reset all preferences to defaults.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Theme
          const _SectionTitle('Appearance'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.brightness_6),
              title: const Text('Dark Mode'),
              subtitle: const Text('Override system theme'),
              trailing: DropdownButton<ThemeMode>(
                value: settings.themeMode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('System'),
                  ),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('On')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('Off')),
                ],
                onChanged: (mode) {
                  if (mode != null) settings.setThemeMode(mode);
                },
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Font Size
          const _SectionTitle('Reading'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.format_size),
                  title: const Text('Font Size'),
                  subtitle: Text('${settings.fontScale.toStringAsFixed(1)}x'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Slider(
                    value: settings.fontScale,
                    min: 0.8,
                    max: 1.5,
                    divisions: 7,
                    label: '${settings.fontScale.toStringAsFixed(1)}x',
                    onChanged: settings.setFontScale,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Content packs
          const _SectionTitle('Library'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: const Text('Manage content'),
              subtitle: Text(
                context.watch<PackProvider>().installed.isEmpty
                    ? 'Add the church fathers and other collections'
                    : '${context.watch<PackProvider>().installed.length} '
                        'collection(s) installed',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LibraryScreen()),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // AI backend
          const _SectionTitle('AI Chat'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('AI Backend'),
              subtitle: Text(context.watch<InferenceProvider>().backend.displayName),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiBackendScreen()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.format_quote),
              title: const Text('Show Citations'),
              subtitle: const Text('Display source citations in AI responses'),
              value: settings.showCitations,
              onChanged: settings.setShowCitations,
            ),
          ),

          const SizedBox(height: 24),

          // Reset
          FilledButton.tonalIcon(
            onPressed: () => _resetAll(context),
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset All Settings'),
          ),

          const SizedBox(height: 32),

          // About
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

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
