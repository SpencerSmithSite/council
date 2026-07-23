import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'palette.dart';
import 'themes.dart';

/// The brightness axis of the theme system — one of two the user controls.
///
/// This decides light vs dark (or follow the device); the *named theme*
/// (`themeId`, see [resolveThemes]) decides which light and which dark. Keeping
/// them separate is what lets every theme, including "Default", honour a single
/// Light/Dark/System switch.
enum AppThemeMode {
  system,
  light,
  dark;

  String get label => switch (this) {
        AppThemeMode.system => 'System',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };

  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  static AppThemeMode fromName(String? name) {
    return AppThemeMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => AppThemeMode.system,
    );
  }
}

/// The light and dark [ThemeData] to hand `MaterialApp` for a chosen theme.
///
/// `MaterialApp` always wants both a `theme` and a `darkTheme` and switches
/// between them by `themeMode`. Every theme fills both: "Default" with the
/// platform's own light and dark looks, a named theme with its two palettes.
class ResolvedThemes {
  final ThemeData light;
  final ThemeData dark;
  const ResolvedThemes(this.light, this.dark);
}

/// Build the light and dark [ThemeData] for a theme id.
///
/// [kDefaultThemeId] (or any unknown id) resolves to the platform-adaptive
/// look — Apple system colours on a Mac, Fluent on Windows, Material on Android.
/// Any other id is a fixed community palette from [kNamedThemes], the same on
/// every platform. Either way the platform *shapes* (Apple's grouped glass, etc)
/// are kept via [_build]; only the colours change.
ResolvedThemes resolveThemes(String themeId) {
  final family = PlatformFamily.current();
  final named = namedThemeById(themeId);
  if (named == null) {
    return ResolvedThemes(
      _build(_paletteFor(family, Brightness.light), family),
      _build(_paletteFor(family, Brightness.dark), family),
    );
  }
  return ResolvedThemes(
    _build(named.light, family),
    _build(named.dark, family),
  );
}

AppPalette _paletteFor(PlatformFamily family, Brightness brightness) {
  return switch (family) {
    PlatformFamily.apple => applePalette(brightness),
    PlatformFamily.fluent => fluentPalette(brightness),
    PlatformFamily.material => materialPalette(brightness),
  };
}

/// The raw [AppPalette] a theme would use at a given brightness — the colours
/// only, without building a whole [ThemeData]. The theme picker uses it to paint
/// a live preview swatch of each option in the mode currently in effect.
AppPalette previewPalette(String themeId, Brightness brightness) {
  final named = namedThemeById(themeId);
  if (named != null) {
    return brightness == Brightness.dark ? named.dark : named.light;
  }
  return _paletteFor(PlatformFamily.current(), brightness);
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
