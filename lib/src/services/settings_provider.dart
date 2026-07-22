import 'package:flutter/material.dart';

import 'settings_service.dart';

/// Reactive view over [SettingsService].
///
/// The persisted preferences (theme, font size, citation visibility) are only
/// meaningful if the widget tree rebuilds when they change, so every screen
/// reads them from here rather than calling [SettingsService] directly.
class SettingsProvider extends ChangeNotifier {
  final SettingsService _settings = SettingsService();

  ThemeMode _themeMode = ThemeMode.system;
  double _fontScale = 1.0;
  bool _showCitations = true;
  bool _isLoaded = false;
  bool _hasOnboarded = false;

  ThemeMode get themeMode => _themeMode;
  double get fontScale => _fontScale;
  bool get showCitations => _showCitations;

  /// False on first launch, and only then.
  bool get hasOnboarded => _hasOnboarded;

  /// False until the first load from disk completes.
  bool get isLoaded => _isLoaded;

  /// True when the theme follows the OS rather than an explicit override.
  bool get followsSystemTheme => _themeMode == ThemeMode.system;

  Future<void> completeOnboarding() async {
    _hasOnboarded = true;
    await _settings.setHasOnboarded(true);
    notifyListeners();
  }

  Future<void> load() async {
    final darkMode = await _settings.getDarkMode();
    _themeMode = _boolToThemeMode(darkMode);
    _fontScale = await _settings.getFontSize();
    _showCitations = await _settings.getShowCitations();
    _hasOnboarded = await _settings.getHasOnboarded();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _settings.setDarkMode(_themeModeToBool(mode));
  }

  Future<void> setFontScale(double scale) async {
    // SettingsService clamps on write; mirror it so the in-memory value and the
    // persisted value can't drift.
    _fontScale = scale.clamp(0.8, 1.5);
    notifyListeners();
    await _settings.setFontSize(_fontScale);
  }

  Future<void> setShowCitations(bool show) async {
    _showCitations = show;
    notifyListeners();
    await _settings.setShowCitations(show);
  }

  Future<void> resetAll() async {
    await _settings.clearAll();
    await load();
  }

  ThemeMode _boolToThemeMode(bool? value) {
    if (value == null) return ThemeMode.system;
    return value ? ThemeMode.dark : ThemeMode.light;
  }

  bool? _themeModeToBool(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return false;
      case ThemeMode.dark:
        return true;
      case ThemeMode.system:
        return null;
    }
  }
}
