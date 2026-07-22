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
      error: dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
      onError: Colors.white,
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
      error: dark ? const Color(0xFFFF99A4) : const Color(0xFFC42B1C),
      onError: Colors.white,
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

/// Catppuccin Mocha — the same fixed palette on every platform, from
/// catppuccin.com/palette. Mauve is the accent, chosen over Blue because it
/// carries the app's existing purple identity.
class _Mocha {
  static const base = Color(0xFF1E1E2E);
  static const mantle = Color(0xFF181825);
  static const crust = Color(0xFF11111B);
  static const surface0 = Color(0xFF313244);
  static const surface1 = Color(0xFF45475A);
  static const surface2 = Color(0xFF585B70);
  static const text = Color(0xFFCDD6F4);
  static const subtext0 = Color(0xFFA6ADC8);
  static const mauve = Color(0xFFCBA6F7);
  static const red = Color(0xFFF38BA8);
}

AppPalette catppuccinMochaPalette() {
  return const AppPalette(
    groupedBackground: _Mocha.base,
    separator: _Mocha.surface1,
    secondaryLabel: _Mocha.subtext0,
    scheme: ColorScheme(
      brightness: Brightness.dark,
      primary: _Mocha.mauve,
      onPrimary: _Mocha.crust,
      secondary: _Mocha.mauve,
      onSecondary: _Mocha.crust,
      error: _Mocha.red,
      onError: _Mocha.crust,
      // Cells sit one step up from the base page, as Catppuccin's own guidance
      // lays out: base for the window, surface0 for raised panels.
      surface: _Mocha.surface0,
      onSurface: _Mocha.text,
      onSurfaceVariant: _Mocha.subtext0,
      surfaceContainerLowest: _Mocha.crust,
      surfaceContainerLow: _Mocha.mantle,
      surfaceContainer: _Mocha.surface0,
      surfaceContainerHigh: _Mocha.surface1,
      surfaceContainerHighest: _Mocha.surface2,
      outline: _Mocha.surface2,
      outlineVariant: _Mocha.surface1,
    ),
  );
}
