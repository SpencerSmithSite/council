import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'settings_service.dart';

/// Reactive view over [SettingsService].
///
/// The persisted preferences (theme, font size, citation visibility) are only
/// meaningful if the widget tree rebuilds when they change, so every screen
/// reads them from here rather than calling [SettingsService] directly.
class SettingsProvider extends ChangeNotifier {
  final SettingsService _settings = SettingsService();

  AppThemeChoice _themeChoice = AppThemeChoice.system;
  double _fontScale = 1.0;
  bool _showCitations = true;
  bool _isLoaded = false;
  bool _hasOnboarded = false;

  /// The user's chosen theme — including the platform-following options and
  /// Catppuccin Mocha. The screens read this; `MaterialApp` reads [themeMode]
  /// together with the resolved light/dark themes.
  AppThemeChoice get themeChoice => _themeChoice;

  /// Derived so `MaterialApp` can switch light/dark. A named palette like
  /// Catppuccin pins this to its own brightness.
  ThemeMode get themeMode => _themeChoice.themeMode;

  double get fontScale => _fontScale;
  bool get showCitations => _showCitations;

  /// False on first launch, and only then.
  bool get hasOnboarded => _hasOnboarded;

  /// False until the first load from disk completes.
  bool get isLoaded => _isLoaded;

  /// True when the theme follows the OS rather than an explicit override.
  bool get followsSystemTheme => _themeChoice == AppThemeChoice.system;

  Future<void> completeOnboarding() async {
    _hasOnboarded = true;
    await _settings.setHasOnboarded(true);
    notifyListeners();
  }

  Future<void> load() async {
    _themeChoice = AppThemeChoice.fromName(await _settings.getThemeChoice());
    _fontScale = await _settings.getFontSize();
    _showCitations = await _settings.getShowCitations();
    _hasOnboarded = await _settings.getHasOnboarded();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setThemeChoice(AppThemeChoice choice) async {
    _themeChoice = choice;
    notifyListeners();
    await _settings.setThemeChoice(choice.name);
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
}
