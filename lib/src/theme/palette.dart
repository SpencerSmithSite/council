import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// Which platform's visual language the app should borrow.
///
/// The app is one Flutter codebase, so it draws every pixel itself and inherits
/// nothing from the OS. Looking native therefore means *choosing* a platform's
/// colours and shapes deliberately, and the first decision is which one.
///
/// Linux rides with Windows: both get the Fluent palette, because inventing a
/// third look for a desktop Linux build nobody has asked to differ is cost
/// without benefit.
enum PlatformFamily {
  apple,
  material,
  fluent;

  static PlatformFamily current() {
    if (Platform.isIOS || Platform.isMacOS) return PlatformFamily.apple;
    if (Platform.isAndroid || Platform.isFuchsia) return PlatformFamily.material;
    return PlatformFamily.fluent; // windows, linux
  }

  bool get isApple => this == PlatformFamily.apple;
}

/// A container and its foreground: [role] laid over [surface] at low opacity,
/// with a text colour that stays readable on it.
///
/// Every palette here is hand-built, and a hand-built [ColorScheme] that omits
/// the `*Container` roles does not get sensible ones — Flutter falls each back
/// to its base role, so `errorContainer` becomes the full-strength error red
/// and `secondaryContainer` the full-strength accent. Anything using them as a
/// *background* then shouts: the AI-backend status banner filled its whole card
/// with saturated red, grabbing attention by overriding the theme the reader
/// chose rather than by working within it. A tint is what those roles are for,
/// and it keeps a warning legible and obviously a warning while still reading
/// as Tokyo Night, or Gruvbox, or whatever is selected. The colour that catches
/// the eye moves to the icon and the hairline, which stay at full strength.
///
/// Both halves adapt, and both have to. A fixed 20% tint plus a fixed text
/// blend looked right on Tokyo Night and failed badly elsewhere: on Solarized
/// the accent sits near the text in luminance, so tinting the surface moved the
/// background *toward* the text and dropped a paragraph to 2.7:1. Neither the
/// tint strength nor the text blend can be a constant across twenty palettes
/// whose accents sit in completely different places.
///
/// The bar is WCAG AA, except where the theme itself does not reach it — a few
/// of these community palettes put their own body text below 4.5:1 on their own
/// surfaces, and holding a banner to a standard the rest of the app misses
/// would mean bleaching the tint out for no gain. There the rule is instead to
/// not make it meaningfully worse than the theme already is.
({Color container, Color on}) containerPair(
    Color role, Color surface, Color text) {
  final baseline = contrastRatio(text, surface);
  final target = baseline < 4.5 ? baseline * 0.9 : 4.5;

  // Strongest tint that still leaves the plain text readable.
  var container = Color.alphaBlend(role.withValues(alpha: 0.05), surface);
  for (final amount in const [0.20, 0.15, 0.10, 0.05]) {
    final candidate = Color.alphaBlend(role.withValues(alpha: amount), surface);
    if (contrastRatio(text, candidate) >= target) {
      container = candidate;
      break;
    }
  }

  // Then colour the text toward the role, as far as that too stays readable.
  for (final amount in const [0.35, 0.22, 0.12]) {
    final tinted = Color.alphaBlend(role.withValues(alpha: amount), text);
    if (contrastRatio(tinted, container) >= target) {
      return (container: container, on: tinted);
    }
  }
  return (container: container, on: text);
}

/// WCAG relative-luminance contrast, 1:1 to 21:1.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The faintest a hairline may be against the surfaces it divides.
///
/// Windows draws its own card stroke at 1.19:1 and Apple its separator at
/// 1.45:1, so this sits at the low end of what a platform considers a visible
/// edge rather than at what a design system would prefer. A separator is meant
/// to be the thinnest mark the screen can draw; the bar here only has to rule
/// out the ones that are not drawn at all.
const double kMinSeparatorContrast = 1.2;

/// The faintest a secondary label may be, where the theme can afford it.
///
/// 3:1 is WCAG's floor for large text and for the parts of a control that
/// carry meaning. Body text wants 4.5:1, and deliberately not that here: a
/// subtitle held to the same bar as its own title stops reading as secondary,
/// and the hierarchy is the point of having the colour at all.
const double kMinSecondaryLabelContrast = 3.0;

/// Moves [from] toward [toward] until it clears [target] against every colour
/// in [against], or as far as it can go.
///
/// Blending toward the theme's own text colour, rather than toward black or
/// white, is what keeps the result in the family: a lifted Cobalt2 separator is
/// still a Cobalt2 blue, only one the eye can find.
Color _lift(Color from, Color toward, double target, List<Color> against) {
  bool clears(Color c) =>
      against.every((bg) => contrastRatio(c, bg) >= target);
  if (clears(from)) return from;
  for (var step = 1; step <= 20; step++) {
    final blended =
        Color.alphaBlend(toward.withValues(alpha: step / 20), from);
    if (clears(blended)) return blended;
  }
  return toward;
}

/// A hairline the eye can actually find, against both the cell it divides and
/// the page that cell rests on.
///
/// The community palettes in `themes.dart` name a separator colour, but they
/// are editor themes and the colour is doing a different job there — an indent
/// guide against the editor's own background, not a rule between two list rows
/// that sit a shade in front of it. Four of them landed within a hair of the
/// cell colour once repurposed, Cobalt2 at 1.01:1, which is to say the grouped
/// lists in Settings and Library had no visible row divisions at all.
///
/// Applied only to those palettes, not to the Apple/Fluent/Material ones: there
/// the separator is a transcription of the platform's own value, and matching
/// what Windows actually draws is the whole objective.
Color legibleSeparator(Color separator, Color surface, Color bg, Color text) =>
    _lift(separator, text, kMinSeparatorContrast, [surface, bg]);

/// A secondary label that stays readable without collapsing into body text.
///
/// Same repurposing problem as [legibleSeparator]: a theme's "comment" colour
/// is meant to recede behind code, and several sit near 2.2:1 once they are
/// carrying a settings row's trailing value or a citation's source instead.
///
/// Where a theme's own body text is itself below the bar the target scales down
/// with it, the rule [containerPair] already follows — a few of these palettes
/// are low-contrast by design, and lifting a subtitle past the paragraph above
/// it would be a worse reading experience, not a better one.
Color legibleSecondaryLabel(
    Color subtext, Color surface, Color bg, Color text) {
  final body = [surface, bg]
      .map((b) => contrastRatio(text, b))
      .reduce((a, b) => a < b ? a : b);
  final headroom = body * 0.8;
  final target = headroom < kMinSecondaryLabelContrast
      ? headroom
      : kMinSecondaryLabelContrast;
  return _lift(subtext, text, target, [surface, bg]);
}

/// A resolved set of surface colours for one theme.
///
/// [ColorScheme] alone cannot express the platform looks this app wants,
/// because the native list idioms need *two* background levels that Material
/// collapses into one: the page sits at [groupedBackground] and the cells sit
/// at [surface], and on Apple those are deliberately different shades
/// (`systemGroupedBackground` behind, `secondarySystemGroupedBackground` in
/// front). Carrying them as an explicit pair is what lets a settings screen
/// read as Settings.app rather than as a stack of floating Material cards.
class AppPalette {
  final ColorScheme scheme;

  /// The page background, behind grouped content. On Apple this is a shade
  /// *darker* than the cells in light mode and pure black in dark mode.
  final Color groupedBackground;

  /// A hairline separator, at full opacity. Native separators are a specific
  /// grey, not `onSurface` at low alpha, and getting it wrong is a visible tell.
  final Color separator;

  /// Text that is present but secondary — subtitles, captions, the trailing
  /// value on a settings row.
  final Color secondaryLabel;

  const AppPalette({
    required this.scheme,
    required this.groupedBackground,
    required this.separator,
    required this.secondaryLabel,
  });

  Brightness get brightness => scheme.brightness;
}

/// Apple's semantic system colours, taken from the platform's own values so the
/// app matches Settings, Notes and Messages rather than approximating them.
///
/// The pairs matter: `systemGroupedBackground` is what a grouped table sits on,
/// `secondarySystemGroupedBackground` is the cell. In light mode the page is
/// the grey `#F2F2F7` and the cells are white; in dark mode the page is black
/// and the cells are `#1C1C1E`. Reversing them — white page, grey cells — is
/// the single most common way a cross-platform app looks not-quite-iOS.
class _Apple {
  static const blueLight = Color(0xFF007AFF);
  static const blueDark = Color(0xFF0A84FF);

  static const labelLight = Color(0xFF000000);
  static const labelDark = Color(0xFFFFFFFF);

  // secondaryLabel is defined by Apple as a colour plus an alpha; the opaque
  // equivalents over the respective backgrounds are used here so text stays
  // legible without compositing surprises.
  static const secondaryLabelLight = Color(0x993C3C43); // #3C3C43 @ 60%
  static const secondaryLabelDark = Color(0x99EBEBF5); // #EBEBF5 @ 60%

  static const separatorLight = Color(0xFFC6C6C8);
  static const separatorDark = Color(0xFF38383A);

  static const groupedBgLight = Color(0xFFF2F2F7);
  static const groupedBgDark = Color(0xFF000000);

  static const cellLight = Color(0xFFFFFFFF);
  static const cellDark = Color(0xFF1C1C1E);

  // A third level, for a control resting on a cell (a segmented control, a
  // grouped row's inset field).
  static const tertiaryDark = Color(0xFF2C2C2E);
}

AppPalette applePalette(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final tint = dark ? _Apple.blueDark : _Apple.blueLight;
  final cell = dark ? _Apple.cellDark : _Apple.cellLight;
  final label = dark ? _Apple.labelDark : _Apple.labelLight;
  final appleError =
      dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
  final appleTintPair = containerPair(tint, cell, label);
  final appleErrPair = containerPair(appleError, cell, label);

  return AppPalette(
    groupedBackground: dark ? _Apple.groupedBgDark : _Apple.groupedBgLight,
    separator: dark ? _Apple.separatorDark : _Apple.separatorLight,
    secondaryLabel: dark ? _Apple.secondaryLabelDark : _Apple.secondaryLabelLight,
    scheme: ColorScheme(
      brightness: brightness,
      primary: tint,
      onPrimary: Colors.white,
      secondary: tint,
      onSecondary: Colors.white,
      error: appleError,
      onError: Colors.white,
      // Tints rather than the full-strength fallbacks. See [containerOf].
      primaryContainer: appleTintPair.container,
      onPrimaryContainer: appleTintPair.on,
      secondaryContainer: appleTintPair.container,
      onSecondaryContainer: appleTintPair.on,
      errorContainer: appleErrPair.container,
      onErrorContainer: appleErrPair.on,
      // `surface` is the cell colour, because Material's Card and ListTile paint
      // `surface`, and cells are what they are standing in for.
      surface: cell,
      onSurface: label,
      onSurfaceVariant: dark ? _Apple.secondaryLabelDark : _Apple.secondaryLabelLight,
      surfaceContainerLowest: dark ? _Apple.groupedBgDark : Colors.white,
      surfaceContainerLow: cell,
      surfaceContainer: cell,
      surfaceContainerHigh: dark ? _Apple.tertiaryDark : _Apple.groupedBgLight,
      surfaceContainerHighest: dark ? _Apple.tertiaryDark : const Color(0xFFE5E5EA),
      outline: dark ? _Apple.separatorDark : _Apple.separatorLight,
      outlineVariant: dark ? _Apple.separatorDark : _Apple.separatorLight,
    ),
  );
}

/// Windows 11 / Fluent, shared with Linux. Mica-like page, layered cards, and
/// the system accent blue.
class _Fluent {
  static const accentLight = Color(0xFF005FB8);
  static const accentDark = Color(0xFF60CDFF);

  static const bgLight = Color(0xFFF3F3F3);
  static const bgDark = Color(0xFF202020);

  static const cardLight = Color(0xFFFBFBFB);
  static const cardDark = Color(0xFF2B2B2B);

  static const labelLight = Color(0xFF1A1A1A);
  static const labelDark = Color(0xFFFFFFFF);

  static const secondaryLight = Color(0x99000000);
  static const secondaryDark = Color(0xB3FFFFFF);

  static const strokeLight = Color(0xFFE5E5E5);
  static const strokeDark = Color(0xFF1D1D1D);
}

AppPalette fluentPalette(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final fluentAccent = dark ? _Fluent.accentDark : _Fluent.accentLight;
  final fluentCard = dark ? _Fluent.cardDark : _Fluent.cardLight;
  final fluentLabel = dark ? _Fluent.labelDark : _Fluent.labelLight;
  final fluentError =
      dark ? const Color(0xFFFF99A4) : const Color(0xFFC42B1C);
  final fluentAccentPair =
      containerPair(fluentAccent, fluentCard, fluentLabel);
  final fluentErrPair = containerPair(fluentError, fluentCard, fluentLabel);

  return AppPalette(
    groupedBackground: dark ? _Fluent.bgDark : _Fluent.bgLight,
    separator: dark ? _Fluent.strokeDark : _Fluent.strokeLight,
    secondaryLabel: dark ? _Fluent.secondaryDark : _Fluent.secondaryLight,
    scheme: ColorScheme(
      brightness: brightness,
      primary: dark ? _Fluent.accentDark : _Fluent.accentLight,
      onPrimary: dark ? const Color(0xFF003354) : Colors.white,
      secondary: dark ? _Fluent.accentDark : _Fluent.accentLight,
      onSecondary: dark ? const Color(0xFF003354) : Colors.white,
      error: fluentError,
      onError: Colors.white,
      // Tints rather than the full-strength fallbacks. See [containerOf].
      primaryContainer: fluentAccentPair.container,
      onPrimaryContainer: fluentAccentPair.on,
      secondaryContainer: fluentAccentPair.container,
      onSecondaryContainer: fluentAccentPair.on,
      errorContainer: fluentErrPair.container,
      onErrorContainer: fluentErrPair.on,
      surface: dark ? _Fluent.cardDark : _Fluent.cardLight,
      onSurface: dark ? _Fluent.labelDark : _Fluent.labelLight,
      onSurfaceVariant: dark ? _Fluent.secondaryDark : _Fluent.secondaryLight,
      surfaceContainerLowest: dark ? _Fluent.bgDark : Colors.white,
      surfaceContainerLow: dark ? _Fluent.cardDark : _Fluent.cardLight,
      surfaceContainer: dark ? _Fluent.cardDark : _Fluent.cardLight,
      surfaceContainerHigh: dark ? const Color(0xFF323232) : const Color(0xFFEDEDED),
      surfaceContainerHighest: dark ? const Color(0xFF383838) : const Color(0xFFE5E5E5),
      outline: dark ? _Fluent.strokeDark : _Fluent.strokeLight,
      outlineVariant: dark ? _Fluent.strokeDark : _Fluent.strokeLight,
    ),
  );
}

/// Material 3 baseline — stock Android. Built from the M3 baseline seed rather
/// than hand-tuned, because "standard Android" is precisely what the framework
/// already produces from a seed, and diverging from it would look *less*
/// native, not more.
///
/// Dynamic colour (reading the user's wallpaper palette on Android 12+) would be
/// the truly-native step and is a deliberate later addition; it needs a
/// platform channel this does not yet have.
AppPalette materialPalette(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: brightness,
  );
  return AppPalette(
    scheme: scheme,
    groupedBackground: scheme.surface,
    separator: scheme.outlineVariant,
    secondaryLabel: scheme.onSurfaceVariant,
  );
}
