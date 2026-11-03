import 'package:flutter/material.dart';

import 'palette.dart';

part 'themes.g.dart';

/// A named colour theme that carries *both* a light and a dark palette.
///
/// This is the second axis of the theme system. The first — [AppThemeMode] in
/// `app_theme.dart` — decides light vs dark (or follow the system); a
/// [NamedTheme] decides *which* light and *which* dark. "Default" is the one
/// exception: it isn't in this catalogue because it follows the platform's own
/// palette (Apple / Fluent / Material) rather than a fixed community scheme, and
/// is resolved specially in `resolveThemes`.
///
/// Every theme here defines a full light and dark palette so the brightness
/// toggle always has something to switch between, even for schemes that were
/// originally dark-only — those get a tasteful light counterpart built from the
/// same accent so the family reads as one theme in two moods.
class NamedTheme {
  final String id;
  final String label;
  final AppPalette light;
  final AppPalette dark;

  const NamedTheme({
    required this.id,
    required this.label,
    required this.light,
    required this.dark,
  });
}

/// The id of the platform-adaptive "Default" theme — not in [kNamedThemes]
/// because it has no fixed palette; it follows the device's own look.
const String kDefaultThemeId = 'default';

/// Expand a handful of core colours into a full [AppPalette].
///
/// A theme is famous for a background, a text colour and an accent; the dozen
/// container levels a `ColorScheme` wants are mechanical from those. Defining
/// each theme by its few identifying colours — rather than hand-filling a
/// `ColorScheme` twenty-four times — is what keeps the catalogue readable and
/// the palettes consistent with one another.
AppPalette _palette({
  required Brightness brightness,
  required Color bg, // page / grouped background
  required Color surface, // a cell resting on the page
  required Color surface2, // a control resting on a cell
  required Color text,
  required Color subtext,
  required Color separator,
  required Color accent,
  required Color onAccent,
  Color? error,
}) {
  final dark = brightness == Brightness.dark;
  final err =
      error ?? (dark ? const Color(0xFFFF6B6B) : const Color(0xFFD11A2A));
  final accentPair = containerPair(accent, surface, text);
  final errPair = containerPair(err, surface, text);
  // The identifying colours above are transcribed from editor themes, where a
  // separator guides indentation and a subtext colour recedes behind code. Here
  // they divide list rows and carry a row's trailing value, and a few of them
  // are illegible at that job — so they are held to a floor the same way the
  // container roles are derived rather than taken as given.
  final rule = legibleSeparator(separator, surface, bg, text);
  final secondary = legibleSecondaryLabel(subtext, surface, bg, text);
  return AppPalette(
    groupedBackground: bg,
    separator: rule,
    secondaryLabel: secondary,
    scheme: ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      error: err,
      onError: Colors.white,
      // Tints of this theme's own accent and error, rather than the
      // full-strength fallbacks Flutter would supply. See [containerOf].
      primaryContainer: accentPair.container,
      onPrimaryContainer: accentPair.on,
      secondaryContainer: accentPair.container,
      onSecondaryContainer: accentPair.on,
      errorContainer: errPair.container,
      onErrorContainer: errPair.on,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: secondary,
      // Lowest is the page itself (behind the cells); the higher levels step up
      // toward controls and chips.
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface2,
      surfaceContainerHighest: surface2,
      outline: rule,
      outlineVariant: rule,
    ),
  );
}

// The catalogue itself, `kNamedThemes`, is generated from shared/themes.json
// (the single source of truth both this app and the native Apple app read)
// into themes.g.dart by tools/generate_themes.py. It is a part of this
// library so it can call the private [_palette] above.

/// Look up a named theme by id, or null when the id is "default" or unknown.
NamedTheme? namedThemeById(String id) {
  for (final t in kNamedThemes) {
    if (t.id == id) return t;
  }
  return null;
}
