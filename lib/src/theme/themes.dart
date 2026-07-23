import 'package:flutter/material.dart';

import 'palette.dart';

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
  return AppPalette(
    groupedBackground: bg,
    separator: separator,
    secondaryLabel: subtext,
    scheme: ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      error: error ?? (dark ? const Color(0xFFFF6B6B) : const Color(0xFFD11A2A)),
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: subtext,
      // Lowest is the page itself (behind the cells); the higher levels step up
      // toward controls and chips.
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface2,
      surfaceContainerHighest: surface2,
      outline: separator,
      outlineVariant: separator,
    ),
  );
}

/// The full theme catalogue, in the order the user gave. "Default" is prepended
/// by the picker; everything below is a fixed community palette.
final List<NamedTheme> kNamedThemes = [
  // Tokyo Night — Night (dark) + Day (light).
  NamedTheme(
    id: 'tokyonight',
    label: 'Tokyo Night',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF1A1B26),
      surface: const Color(0xFF24283B),
      surface2: const Color(0xFF414868),
      text: const Color(0xFFC0CAF5),
      subtext: const Color(0xFF787C99),
      separator: const Color(0xFF292E42),
      accent: const Color(0xFF7AA2F7),
      onAccent: const Color(0xFF1A1B26),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFE1E2E7),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFD5D6DB),
      text: const Color(0xFF343B58),
      subtext: const Color(0xFF6172B0),
      separator: const Color(0xFFCBCED9),
      accent: const Color(0xFF2E7DE9),
      onAccent: Colors.white,
    ),
  ),

  // Everforest — medium dark + medium light.
  NamedTheme(
    id: 'everforest',
    label: 'Everforest',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF2D353B),
      surface: const Color(0xFF343F44),
      surface2: const Color(0xFF3D484D),
      text: const Color(0xFFD3C6AA),
      subtext: const Color(0xFF859289),
      separator: const Color(0xFF4A555B),
      accent: const Color(0xFFA7C080),
      onAccent: const Color(0xFF2D353B),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFDF6E3),
      surface: const Color(0xFFF4F0D9),
      surface2: const Color(0xFFEDEADA),
      text: const Color(0xFF5C6A72),
      subtext: const Color(0xFF829181),
      separator: const Color(0xFFE0DCC7),
      accent: const Color(0xFF8DA101),
      onAccent: const Color(0xFFFDF6E3),
    ),
  ),

  // Ayu — dark + light.
  NamedTheme(
    id: 'ayu',
    label: 'Ayu',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF0B0E14),
      surface: const Color(0xFF0F131A),
      surface2: const Color(0xFF1C212B),
      text: const Color(0xFFBFBDB6),
      subtext: const Color(0xFF565B66),
      separator: const Color(0xFF1C212B),
      accent: const Color(0xFFFFB454),
      onAccent: const Color(0xFF0B0E14),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFCFCFC),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFF0F0F0),
      text: const Color(0xFF5C6166),
      subtext: const Color(0xFF8A9199),
      separator: const Color(0xFFE7E8E9),
      accent: const Color(0xFFFF9940),
      onAccent: const Color(0xFF5C6166),
    ),
  ),

  // Catppuccin — Latte (light) + Mocha (dark).
  NamedTheme(
    id: 'catppuccin',
    label: 'Catppuccin',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF1E1E2E),
      surface: const Color(0xFF313244),
      surface2: const Color(0xFF45475A),
      text: const Color(0xFFCDD6F4),
      subtext: const Color(0xFFA6ADC8),
      separator: const Color(0xFF45475A),
      accent: const Color(0xFFCBA6F7),
      onAccent: const Color(0xFF11111B),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFEFF1F5),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFCCD0DA),
      text: const Color(0xFF4C4F69),
      subtext: const Color(0xFF6C6F85),
      separator: const Color(0xFFBCC0CC),
      accent: const Color(0xFF8839EF),
      onAccent: Colors.white,
    ),
  ),

  // Catppuccin Macchiato — Latte (light) + Macchiato (dark).
  NamedTheme(
    id: 'catppuccin-macchiato',
    label: 'Catppuccin Macchiato',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF24273A),
      surface: const Color(0xFF363A4F),
      surface2: const Color(0xFF494D64),
      text: const Color(0xFFCAD3F5),
      subtext: const Color(0xFFA5ADCB),
      separator: const Color(0xFF494D64),
      accent: const Color(0xFFC6A0F6),
      onAccent: const Color(0xFF181926),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFEFF1F5),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFCCD0DA),
      text: const Color(0xFF4C4F69),
      subtext: const Color(0xFF6C6F85),
      separator: const Color(0xFFBCC0CC),
      accent: const Color(0xFF8839EF),
      onAccent: Colors.white,
    ),
  ),

  // Gruvbox — medium dark + medium light.
  NamedTheme(
    id: 'gruvbox',
    label: 'Gruvbox',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF282828),
      surface: const Color(0xFF3C3836),
      surface2: const Color(0xFF504945),
      text: const Color(0xFFEBDBB2),
      subtext: const Color(0xFFA89984),
      separator: const Color(0xFF504945),
      accent: const Color(0xFFFE8019),
      onAccent: const Color(0xFF282828),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFBF1C7),
      surface: const Color(0xFFF2E5BC),
      surface2: const Color(0xFFEBDBB2),
      text: const Color(0xFF3C3836),
      subtext: const Color(0xFF7C6F64),
      separator: const Color(0xFFD5C4A1),
      accent: const Color(0xFFD65D0E),
      onAccent: const Color(0xFFFBF1C7),
    ),
  ),

  // Kanagawa — Wave (dark) + Lotus (light).
  NamedTheme(
    id: 'kanagawa',
    label: 'Kanagawa',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF1F1F28),
      surface: const Color(0xFF2A2A37),
      surface2: const Color(0xFF363646),
      text: const Color(0xFFDCD7BA),
      subtext: const Color(0xFF727169),
      separator: const Color(0xFF363646),
      accent: const Color(0xFF7E9CD8),
      onAccent: const Color(0xFF1F1F28),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF2ECBC),
      surface: const Color(0xFFE7DBA0),
      surface2: const Color(0xFFE5DDB0),
      text: const Color(0xFF545464),
      subtext: const Color(0xFF8A8980),
      separator: const Color(0xFFDCD5AC),
      accent: const Color(0xFF4D699B),
      onAccent: Colors.white,
    ),
  ),

  // Nord — Polar Night (dark) + Snow Storm (light).
  NamedTheme(
    id: 'nord',
    label: 'Nord',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF2E3440),
      surface: const Color(0xFF3B4252),
      surface2: const Color(0xFF434C5E),
      text: const Color(0xFFECEFF4),
      subtext: const Color(0xFF8FBCBB),
      separator: const Color(0xFF434C5E),
      accent: const Color(0xFF88C0D0),
      onAccent: const Color(0xFF2E3440),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFECEFF4),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFE5E9F0),
      text: const Color(0xFF2E3440),
      subtext: const Color(0xFF4C566A),
      separator: const Color(0xFFD8DEE9),
      accent: const Color(0xFF5E81AC),
      onAccent: Colors.white,
    ),
  ),

  // Matrix — green-on-black, with a synthesised light "terminal paper".
  NamedTheme(
    id: 'matrix',
    label: 'Matrix',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF000000),
      surface: const Color(0xFF0A0F0A),
      surface2: const Color(0xFF10210F),
      text: const Color(0xFF00FF41),
      subtext: const Color(0xFF00B32C),
      separator: const Color(0xFF014D01),
      accent: const Color(0xFF00FF41),
      onAccent: const Color(0xFF000000),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFE8F5E9),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFD3ECD5),
      text: const Color(0xFF0B3D0B),
      subtext: const Color(0xFF2E7D32),
      separator: const Color(0xFFC3E3C6),
      accent: const Color(0xFF1B5E20),
      onAccent: Colors.white,
    ),
  ),

  // One Dark + One Light.
  NamedTheme(
    id: 'one-dark',
    label: 'One Dark',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF282C34),
      surface: const Color(0xFF2C313C),
      surface2: const Color(0xFF3B4048),
      text: const Color(0xFFABB2BF),
      subtext: const Color(0xFF828997),
      separator: const Color(0xFF3B4048),
      accent: const Color(0xFF61AFEF),
      onAccent: const Color(0xFF282C34),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFAFAFA),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEAEAEB),
      text: const Color(0xFF383A42),
      subtext: const Color(0xFF6A6B73),
      separator: const Color(0xFFDBDBDC),
      accent: const Color(0xFF4078F2),
      onAccent: Colors.white,
    ),
  ),

  // Dracula — dark + Alucard (light).
  NamedTheme(
    id: 'dracula',
    label: 'Dracula',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF282A36),
      surface: const Color(0xFF343746),
      surface2: const Color(0xFF44475A),
      text: const Color(0xFFF8F8F2),
      subtext: const Color(0xFF9AA4CC),
      separator: const Color(0xFF44475A),
      accent: const Color(0xFFBD93F9),
      onAccent: const Color(0xFF282A36),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFFFBEB),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFF0ECD7),
      text: const Color(0xFF1F1F1F),
      subtext: const Color(0xFF6C664B),
      separator: const Color(0xFFE5E0C8),
      accent: const Color(0xFF644AC9),
      onAccent: Colors.white,
    ),
  ),

  // Solarized Dark.
  NamedTheme(
    id: 'solarized-dark',
    label: 'Solarized Dark',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF002B36),
      surface: const Color(0xFF073642),
      surface2: const Color(0xFF094552),
      text: const Color(0xFF93A1A1),
      subtext: const Color(0xFF839496),
      separator: const Color(0xFF094552),
      accent: const Color(0xFF268BD2),
      onAccent: const Color(0xFF002B36),
    ),
    // The light half of Solarized is Solarized Light — the same hues, flipped.
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFDF6E3),
      surface: const Color(0xFFEEE8D5),
      surface2: const Color(0xFFE6DFC4),
      text: const Color(0xFF657B83),
      subtext: const Color(0xFF93A1A1),
      separator: const Color(0xFFDDD6C1),
      accent: const Color(0xFF268BD2),
      onAccent: Colors.white,
    ),
  ),

  // Solarized Light — kept distinct because the user listed both; its dark half
  // is Solarized Dark, so choosing it and flipping to dark lands where you'd
  // expect.
  NamedTheme(
    id: 'solarized-light',
    label: 'Solarized Light',
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFDF6E3),
      surface: const Color(0xFFEEE8D5),
      surface2: const Color(0xFFE6DFC4),
      text: const Color(0xFF657B83),
      subtext: const Color(0xFF93A1A1),
      separator: const Color(0xFFDDD6C1),
      accent: const Color(0xFF268BD2),
      onAccent: Colors.white,
    ),
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF002B36),
      surface: const Color(0xFF073642),
      surface2: const Color(0xFF094552),
      text: const Color(0xFF93A1A1),
      subtext: const Color(0xFF839496),
      separator: const Color(0xFF094552),
      accent: const Color(0xFF268BD2),
      onAccent: const Color(0xFF002B36),
    ),
  ),

  // Monokai — classic dark + a synthesised light.
  NamedTheme(
    id: 'monokai',
    label: 'Monokai',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF272822),
      surface: const Color(0xFF2D2E28),
      surface2: const Color(0xFF3E3D32),
      text: const Color(0xFFF8F8F2),
      subtext: const Color(0xFFA59F85),
      separator: const Color(0xFF3E3D32),
      accent: const Color(0xFFF92672),
      onAccent: Colors.white,
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFAFAFA),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFF0F0F0),
      text: const Color(0xFF272822),
      subtext: const Color(0xFF75715E),
      separator: const Color(0xFFE0E0E0),
      accent: const Color(0xFFE5187A),
      onAccent: Colors.white,
    ),
  ),

  // GitHub Dark.
  NamedTheme(
    id: 'github-dark',
    label: 'GitHub Dark',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF0D1117),
      surface: const Color(0xFF161B22),
      surface2: const Color(0xFF21262D),
      text: const Color(0xFFE6EDF3),
      subtext: const Color(0xFF8B949E),
      separator: const Color(0xFF30363D),
      accent: const Color(0xFF58A6FF),
      onAccent: const Color(0xFF0D1117),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF6F8FA),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEAEEF2),
      text: const Color(0xFF1F2328),
      subtext: const Color(0xFF656D76),
      separator: const Color(0xFFD0D7DE),
      accent: const Color(0xFF0969DA),
      onAccent: Colors.white,
    ),
  ),

  // GitHub Light — listed separately; its dark half is GitHub Dark.
  NamedTheme(
    id: 'github-light',
    label: 'GitHub Light',
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF6F8FA),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEAEEF2),
      text: const Color(0xFF1F2328),
      subtext: const Color(0xFF656D76),
      separator: const Color(0xFFD0D7DE),
      accent: const Color(0xFF0969DA),
      onAccent: Colors.white,
    ),
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF0D1117),
      surface: const Color(0xFF161B22),
      surface2: const Color(0xFF21262D),
      text: const Color(0xFFE6EDF3),
      subtext: const Color(0xFF8B949E),
      separator: const Color(0xFF30363D),
      accent: const Color(0xFF58A6FF),
      onAccent: const Color(0xFF0D1117),
    ),
  ),

  // Material Theme — Palenight (dark) + Lighter (light).
  NamedTheme(
    id: 'material-palenight',
    label: 'Material Palenight',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF292D3E),
      surface: const Color(0xFF333747),
      surface2: const Color(0xFF444267),
      text: const Color(0xFFA6ACCD),
      subtext: const Color(0xFF676E95),
      separator: const Color(0xFF444267),
      accent: const Color(0xFF82AAFF),
      onAccent: const Color(0xFF292D3E),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFAFAFA),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEEEEEE),
      text: const Color(0xFF546E7A),
      subtext: const Color(0xFF90A4AE),
      separator: const Color(0xFFE7EAEC),
      accent: const Color(0xFF6182B8),
      onAccent: Colors.white,
    ),
  ),

  // Night Owl (dark) + Light Owl (light).
  NamedTheme(
    id: 'night-owl',
    label: 'Night Owl',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF011627),
      surface: const Color(0xFF0B2942),
      surface2: const Color(0xFF1D3B53),
      text: const Color(0xFFD6DEEB),
      subtext: const Color(0xFF637777),
      separator: const Color(0xFF1D3B53),
      accent: const Color(0xFF82AAFF),
      onAccent: const Color(0xFF011627),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF0F0F0),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEAEAEA),
      text: const Color(0xFF403F53),
      subtext: const Color(0xFF7A8181),
      separator: const Color(0xFFD9D9D9),
      accent: const Color(0xFF288ED7),
      onAccent: Colors.white,
    ),
  ),

  // Rosé Pine — Main (dark) + Dawn (light).
  NamedTheme(
    id: 'rose-pine',
    label: 'Rosé Pine',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF191724),
      surface: const Color(0xFF1F1D2E),
      surface2: const Color(0xFF26233A),
      text: const Color(0xFFE0DEF4),
      subtext: const Color(0xFF908CAA),
      separator: const Color(0xFF26233A),
      accent: const Color(0xFFC4A7E7),
      onAccent: const Color(0xFF191724),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFAF4ED),
      surface: const Color(0xFFFFFAF3),
      surface2: const Color(0xFFF2E9E1),
      text: const Color(0xFF575279),
      subtext: const Color(0xFF797593),
      separator: const Color(0xFFEBE0D6),
      accent: const Color(0xFF907AA9),
      onAccent: Colors.white,
    ),
  ),

  // Nightfox — Nightfox (dark) + Dayfox (light).
  NamedTheme(
    id: 'nightfox',
    label: 'Nightfox',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF192330),
      surface: const Color(0xFF212E3F),
      surface2: const Color(0xFF2B3B51),
      text: const Color(0xFFCDCECF),
      subtext: const Color(0xFF71839B),
      separator: const Color(0xFF29394F),
      accent: const Color(0xFF719CD6),
      onAccent: const Color(0xFF192330),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF6F2EE),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFE7DED4),
      text: const Color(0xFF352C24),
      subtext: const Color(0xFF534C45),
      separator: const Color(0xFFE4DCD4),
      accent: const Color(0xFF2848A9),
      onAccent: Colors.white,
    ),
  ),

  // Horizon — dark + light.
  NamedTheme(
    id: 'horizon',
    label: 'Horizon',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF1C1E26),
      surface: const Color(0xFF232530),
      surface2: const Color(0xFF2E303E),
      text: const Color(0xFFD5D8DA),
      subtext: const Color(0xFF6C6F93),
      separator: const Color(0xFF2E303E),
      accent: const Color(0xFFE95678),
      onAccent: Colors.white,
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFDF0ED),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFFADAD1),
      text: const Color(0xFF1A1C23),
      subtext: const Color(0xFF94667E),
      separator: const Color(0xFFF9D5C9),
      accent: const Color(0xFFE95379),
      onAccent: Colors.white,
    ),
  ),

  // Cobalt2 — dark; a light counterpart trades the yellow-on-blue (illegible on
  // white) for a strong blue accent while keeping the deep-blue identity.
  NamedTheme(
    id: 'cobalt2',
    label: 'Cobalt2',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF193549),
      surface: const Color(0xFF1B3A4B),
      surface2: const Color(0xFF204D63),
      text: const Color(0xFFFFFFFF),
      subtext: const Color(0xFF9FB6C9),
      separator: const Color(0xFF0D3A58),
      accent: const Color(0xFFFFC600),
      onAccent: const Color(0xFF193549),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF0F4F8),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFDBE6EF),
      text: const Color(0xFF193549),
      subtext: const Color(0xFF4B6B82),
      separator: const Color(0xFFCDD9E3),
      accent: const Color(0xFF0B5CAD),
      onAccent: Colors.white,
    ),
  ),

  // JetBrains Darcula (dark) + IntelliJ Light.
  NamedTheme(
    id: 'darcula',
    label: 'Darcula',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF2B2B2B),
      surface: const Color(0xFF3C3F41),
      surface2: const Color(0xFF4E5254),
      text: const Color(0xFFA9B7C6),
      subtext: const Color(0xFF808080),
      separator: const Color(0xFF323232),
      accent: const Color(0xFFCC7832),
      onAccent: const Color(0xFF2B2B2B),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFF7F7F7),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFEDEDED),
      text: const Color(0xFF2B2B2B),
      subtext: const Color(0xFF808080),
      separator: const Color(0xFFEBEBEB),
      accent: const Color(0xFF3574F0),
      onAccent: Colors.white,
    ),
  ),

  // VS Code High Contrast — Dark + Light. Bright borders are the point.
  NamedTheme(
    id: 'dark-high-contrast',
    label: 'High Contrast',
    dark: _palette(
      brightness: Brightness.dark,
      bg: const Color(0xFF000000),
      surface: const Color(0xFF0C0C0C),
      surface2: const Color(0xFF1A1A1A),
      text: const Color(0xFFFFFFFF),
      subtext: const Color(0xFFD4D4D4),
      separator: const Color(0xFF6FC3DF),
      accent: const Color(0xFF3794FF),
      onAccent: const Color(0xFF000000),
    ),
    light: _palette(
      brightness: Brightness.light,
      bg: const Color(0xFFFFFFFF),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFF2F2F2),
      text: const Color(0xFF000000),
      subtext: const Color(0xFF292929),
      separator: const Color(0xFF005FB8),
      accent: const Color(0xFF0F4A85),
      onAccent: Colors.white,
    ),
  ),
];

/// Look up a named theme by id, or null when the id is "default" or unknown.
NamedTheme? namedThemeById(String id) {
  for (final t in kNamedThemes) {
    if (t.id == id) return t;
  }
  return null;
}
