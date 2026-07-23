import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/themes.dart';
import 'settings_service.dart';

/// Reactive view over [SettingsService].
///
/// The persisted preferences (theme, font size, citation visibility) are only
/// meaningful if the widget tree rebuilds when they change, so every screen
/// reads them from here rather than calling [SettingsService] directly.
class SettingsProvider extends ChangeNotifier {
  final SettingsService _settings = SettingsService();

  AppThemeMode _themeMode = AppThemeMode.system;
  String _themeId = kDefaultThemeId;
  double _fontScale = 1.0;
  bool _showCitations = true;
  bool _isLoaded = false;
  bool _hasOnboarded = false;

  /// The brightness mode (System / Light / Dark). Paired with [themeId] it fully
  /// describes the appearance. Screens read this; `MaterialApp` reads [themeMode].
  AppThemeMode get appThemeMode => _themeMode;

  /// Derived so `MaterialApp` can switch its `theme`/`darkTheme`.
  ThemeMode get themeMode => _themeMode.themeMode;

  /// The chosen named theme, or [kDefaultThemeId] for the platform-adaptive
  /// Default. `MaterialApp` passes this to `resolveThemes`.
  String get themeId => _themeId;

  double get fontScale => _fontScale;
  bool get showCitations => _showCitations;

  /// False on first launch, and only then.
  bool get hasOnboarded => _hasOnboarded;

  /// False until the first load from disk completes.
  bool get isLoaded => _isLoaded;

  /// True when the theme follows the OS brightness rather than an override.
  bool get followsSystemTheme => _themeMode == AppThemeMode.system;

  Future<void> completeOnboarding() async {
    _hasOnboarded = true;
    await _settings.setHasOnboarded(true);
    notifyListeners();
  }

  Future<void> load() async {
    _themeMode = AppThemeMode.fromName(await _settings.getThemeMode());
    _themeId = await _settings.getThemeId() ?? kDefaultThemeId;
    _fontScale = await _settings.getFontSize();
    _showCitations = await _settings.getShowCitations();
    _hasOnboarded = await _settings.getHasOnboarded();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _settings.setThemeMode(mode.name);
  }

  Future<void> setThemeId(String id) async {
    _themeId = id;
    notifyListeners();
    await _settings.setThemeId(id);
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
