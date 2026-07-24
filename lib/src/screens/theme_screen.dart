import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_provider.dart';
import '../theme/app_theme.dart';
import '../theme/inset_group.dart';
import '../theme/palette.dart';
import '../theme/glass_controls.dart';
import '../theme/themes.dart';

/// The theme picker: a brightness mode on top, then the catalogue of themes.
///
/// The two controls are independent — the segmented mode says light or dark (or
/// follow the device), and the list says *which* light and dark. Each row paints
/// a live preview of that theme in the mode currently selected above, so the
/// list restyles itself the moment the mode changes and the choice can be made
/// by eye rather than by name.
class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  /// The brightness the swatches should preview: the fixed choice, or — when the
  /// mode follows the system — whatever the device is showing right now.
  Brightness _previewBrightness(BuildContext context, AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.light => Brightness.light,
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final brightness = _previewBrightness(context, settings.appThemeMode);

    // Default first, then the named catalogue in the order it was defined.
    final options = <({String id, String label})>[
      (id: kDefaultThemeId, label: 'Default'),
      for (final t in kNamedThemes) (id: t.id, label: t.label),
    ];

    final top = MediaQuery.of(context).padding.top;

    // Full-bleed like the Settings and Library screens it is pushed from: a
    // scrolling large title with a floating round back button, and the content
    // in grouped inset sections rather than under a solid app bar.
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: 16 + MediaQuery.of(context).padding.bottom),
              children: [
                const LargeTitle('Theme'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InsetGroup(
                        header: 'Appearance',
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: double.infinity,
                              child: SegmentedButton<AppThemeMode>(
                                segments: const [
                                  ButtonSegment(
                                      value: AppThemeMode.system,
                                      label: Text('System')),
                                  ButtonSegment(
                                      value: AppThemeMode.light,
                                      label: Text('Light')),
                                  ButtonSegment(
                                      value: AppThemeMode.dark,
                                      label: Text('Dark')),
                                ],
                                selected: {settings.appThemeMode},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) =>
                                    settings.setThemeMode(s.first),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      InsetGroup(
                        header: 'Theme',
                        children: [
                          for (final option in options)
                            _ThemeOptionTile(
                              label: option.label,
                              palette: previewPalette(option.id, brightness),
                              selected: settings.themeId == option.id,
                              onTap: () => settings.setThemeId(option.id),
                            ),
                        ],
                      ),
                    ],
                  ),
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
}

/// One row in the theme list: a live swatch, the name, and a check when chosen.
class _ThemeOptionTile extends StatelessWidget {
  final String label;
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOptionTile({
    required this.label,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        child: Row(
          children: [
            _ThemeSwatch(palette: palette),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
              ),
            ),
            if (selected)
              Icon(AppIcons.check, color: scheme.primary, size: 22),
          ],
        ),
      ),
    );
  }
}

/// A miniature of the app in a theme: the page colour behind a cell that holds
/// an accent dot and two text bars. Small, but every colour that defines a theme
/// is present, so two themes are told apart at a glance.
class _ThemeSwatch extends StatelessWidget {
  final AppPalette palette;
  const _ThemeSwatch({required this.palette});

  @override
  Widget build(BuildContext context) {
    final scheme = palette.scheme;
    return Container(
      width: 62,
      height: 46,
      decoration: BoxDecoration(
        color: palette.groupedBackground,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: palette.separator, width: 1),
      ),
      padding: const EdgeInsets.all(6),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Container(
              height: 3,
              width: 22,
              decoration: BoxDecoration(
                color: palette.secondaryLabel,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
