import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'palette.dart';

/// A theme the user can pick, independent of the platform.
///
/// [system], [light] and [dark] resolve to the *platform's* look — Apple system
/// colours on a Mac, Fluent on Windows, Material on Android — so "Light" means
/// "the standard light appearance for this device", not one hard-coded scheme.
/// [catppuccinMocha] is the exception: it is the same fixed palette everywhere,
/// because a named community palette is the point of choosing it.
enum AppThemeChoice {
  system,
  light,
  dark,
  catppuccinMocha;

  String get label => switch (this) {
        AppThemeChoice.system => 'System',
        AppThemeChoice.light => 'Light',
        AppThemeChoice.dark => 'Dark',
        AppThemeChoice.catppuccinMocha => 'Catppuccin Mocha',
      };

  /// A one-line description for the picker, so the choice can be understood
  /// without selecting it.
  String get detail => switch (this) {
        AppThemeChoice.system => 'Match the device appearance',
        AppThemeChoice.light => 'Always light',
        AppThemeChoice.dark => 'Always dark',
        AppThemeChoice.catppuccinMocha => 'A warm dark palette, the same on every platform',
      };

  /// Which [ThemeMode] `MaterialApp` should run in for this choice. Catppuccin
  /// is a dark theme, so both slots are filled with it and the mode is fixed to
  /// dark; the OS toggle has nothing to switch between.
  ThemeMode get themeMode => switch (this) {
        AppThemeChoice.system => ThemeMode.system,
        AppThemeChoice.light => ThemeMode.light,
        AppThemeChoice.dark => ThemeMode.dark,
        AppThemeChoice.catppuccinMocha => ThemeMode.dark,
      };

  static AppThemeChoice fromName(String? name) {
    return AppThemeChoice.values.firstWhere(
      (c) => c.name == name,
      orElse: () => AppThemeChoice.system,
    );
  }
}

/// The light and dark [ThemeData] to hand `MaterialApp` for a given choice.
///
/// `MaterialApp` always wants both a `theme` and a `darkTheme` and switches
/// between them by `themeMode`. For the platform-following choices those are the
/// real light and dark appearances; for Catppuccin both are the same fixed
/// theme, so the OS never pulls the app somewhere it did not choose.
class ResolvedThemes {
  final ThemeData light;
  final ThemeData dark;
  const ResolvedThemes(this.light, this.dark);
}

ResolvedThemes resolveThemes(AppThemeChoice choice) {
  final family = PlatformFamily.current();
  if (choice == AppThemeChoice.catppuccinMocha) {
    final theme = _build(catppuccinMochaPalette(), family);
    return ResolvedThemes(theme, theme);
  }
  return ResolvedThemes(
    _build(_paletteFor(family, Brightness.light), family),
    _build(_paletteFor(family, Brightness.dark), family),
  );
}

AppPalette _paletteFor(PlatformFamily family, Brightness brightness) {
  return switch (family) {
    PlatformFamily.apple => applePalette(brightness),
    PlatformFamily.fluent => fluentPalette(brightness),
    PlatformFamily.material => materialPalette(brightness),
  };
}

/// Turns a palette into a fully-themed [ThemeData].
///
/// The platform-specific styling lives here rather than in each screen, so a
/// screen can keep using `Card`, `ListTile` and `Scaffold` and still read as
/// native. Two families are treated specially:
///
/// * **Apple** gets the grouped-table look — a page a shade behind its cells,
///   hairline separators, square-cornered edge-to-edge sections rather than
///   floating rounded cards, and no Material selection pill in the tab bar.
/// * Everything else keeps Material's own conventions, which *are* native on
///   Android and close enough on Fluent.
ThemeData _build(AppPalette palette, PlatformFamily family) {
  final scheme = palette.scheme;
  final apple = family.isApple;

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: palette.groupedBackground,
    // SF on Apple, Roboto on Android, Segoe-ish on Windows — resolved from the
    // target platform rather than shipped uniformly.
    typography: Typography.material2021(platform: defaultTargetPlatform),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
      },
    ),
    dividerTheme: DividerThemeData(
      color: palette.separator,
      // A hairline. Material's default 1.0 reads as a rule; Apple's separators
      // are the thinnest the screen can draw.
      thickness: 0.5,
      space: 0.5,
    ),
  );

  return base.copyWith(
    // Chrome carries the glass on Apple, so nothing underneath may paint an
    // opaque background over it. On other platforms the app bar is a normal
    // surface.
    appBarTheme: AppBarTheme(
      backgroundColor: apple ? Colors.transparent : palette.groupedBackground,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: apple ? 0 : 2,
      centerTitle: apple,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: apple ? Colors.transparent : null,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // The Material selection pill is the loudest "this is Android" tell on an
      // iOS tab bar, which tints the selected item and draws no highlight.
      indicatorColor: apple ? Colors.transparent : null,
      labelTextStyle: apple
          ? WidgetStateProperty.resolveWith((states) {
              final selected = states.contains(WidgetState.selected);
              return TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: selected ? scheme.primary : palette.secondaryLabel,
              );
            })
          : null,
      iconTheme: apple
          ? WidgetStateProperty.resolveWith((states) {
              final selected = states.contains(WidgetState.selected);
              return IconThemeData(
                color: selected ? scheme.primary : palette.secondaryLabel,
              );
            })
          : null,
    ),
    // Cells. On Apple: no elevation, no rounded floating corners by default —
    // the grouped-list widgets round the outer corners of a whole section
    // instead. On other platforms Material's filled card is correct.
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(apple ? 10 : 12),
        side: apple
            ? BorderSide.none
            : BorderSide(color: palette.separator, width: 0.5),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: apple ? scheme.primary : scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
        color: palette.secondaryLabel,
      ),
    ),
    // Adaptive controls draw the Cupertino switch/slider on Apple automatically.
    switchTheme: apple ? null : base.switchTheme,
    dialogTheme: DialogThemeData(
      backgroundColor: apple ? scheme.surface : null,
    ),
    // A segmented / filled selection accent that stays on-brand across palettes.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
    ),
  );
}
