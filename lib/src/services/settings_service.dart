import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  // Legacy keys, read only for migration now.
  //  * `dark_mode` predates named themes — a plain light/dark bool.
  //  * `theme_choice` was the single enum (system/light/dark/catppuccinMocha)
  //    before the mode and the named theme became two independent settings.
  static const String _darkModeKey = 'dark_mode';
  static const String _themeChoiceKey = 'theme_choice';
  // The two current keys: the brightness mode and the named theme.
  static const String _themeModeKey = 'theme_mode';
  static const String _themeIdKey = 'theme_id';
  static const String _fontSizeKey = 'font_size';
  static const String _showCitationsKey = 'show_citations';

  Future<SharedPreferences> get _prefs async => await SharedPreferences.getInstance();

  /// The stored brightness mode name (`system`/`light`/`dark`), or null if never
  /// set. Migrates old installs: the `theme_choice` enum's `catppuccinMocha` was
  /// a dark theme so it maps to `dark`; the pre-theme `dark_mode` bool maps
  /// true → `dark`, false → `light`.
  Future<String?> getThemeMode() async {
    final prefs = await _prefs;
    final stored = prefs.getString(_themeModeKey);
    if (stored != null) return stored;
    final legacy = prefs.getString(_themeChoiceKey);
    if (legacy != null) {
      if (legacy == 'light' || legacy == 'dark') return legacy;
      if (legacy == 'catppuccinMocha') return 'dark';
      return 'system';
    }
    if (prefs.containsKey(_darkModeKey)) {
      return (prefs.getBool(_darkModeKey) ?? false) ? 'dark' : 'light';
    }
    return null;
  }

  /// The stored named-theme id, or null if never set (the provider reads that as
  /// the platform-adaptive Default). The only legacy value that carried a named
  /// palette was `catppuccinMocha`, which becomes the `catppuccin` theme.
  Future<String?> getThemeId() async {
    final prefs = await _prefs;
    final stored = prefs.getString(_themeIdKey);
    if (stored != null) return stored;
    if (prefs.getString(_themeChoiceKey) == 'catppuccinMocha') {
      return 'catppuccin';
    }
    return null;
  }

  Future<void> setThemeMode(String name) async {
    final prefs = await _prefs;
    await prefs.setString(_themeModeKey, name);
    // The legacy keys can only mislead a future migration now that the two
    // string keys are authoritative.
    await prefs.remove(_darkModeKey);
    await prefs.remove(_themeChoiceKey);
  }

  Future<void> setThemeId(String id) async {
    final prefs = await _prefs;
    await prefs.setString(_themeIdKey, id);
    await prefs.remove(_themeChoiceKey);
  }

  /// Get font size multiplier (1.0 = default)
  /// Where the reader stopped in a given work.
  ///
  /// Per source rather than one global position: someone reading Genesis and
  /// dipping into Trent should find both where they left them. Stored as a
  /// section index because ids are stable within a corpus build but sections
  /// are what the reader is actually navigating.
  Future<int> getReadingPosition(int sourceId) async {
    final prefs = await _prefs;
    return prefs.getInt('reading_position_$sourceId') ?? 0;
  }

  Future<void> setReadingPosition(int sourceId, int index) async {
    final prefs = await _prefs;
    await prefs.setInt('reading_position_$sourceId', index);
  }

  Future<double> getFontSize() async {
    final prefs = await _prefs;
    return prefs.getDouble(_fontSizeKey) ?? 1.0;
  }
  
  /// Set font size multiplier
  Future<void> setFontSize(double size) async {
    final prefs = await _prefs;
    await prefs.setDouble(_fontSizeKey, size.clamp(0.8, 1.5));
  }
  
  /// Get show citations preference
  /// Whether the reader has been through first-run setup.
  ///
  /// Stored rather than inferred from an empty library: someone who
  /// deliberately removed every collection should not be walked through setup
  /// again every time they open the app.
  Future<bool> getHasOnboarded() async {
    final prefs = await _prefs;
    return prefs.getBool('has_onboarded') ?? false;
  }

  Future<void> setHasOnboarded(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool('has_onboarded', value);
  }

  Future<bool> getShowCitations() async {
    final prefs = await _prefs;
    return prefs.getBool(_showCitationsKey) ?? true;
  }
  
  /// Set show citations preference
  Future<void> setShowCitations(bool show) async {
    final prefs = await _prefs;
    await prefs.setBool(_showCitationsKey, show);
  }
  
  /// Clear all settings
  Future<void> clearAll() async {
    final prefs = await _prefs;
    await prefs.remove(_darkModeKey);
    await prefs.remove(_themeChoiceKey);
    await prefs.remove(_themeModeKey);
    await prefs.remove(_themeIdKey);
    await prefs.remove(_fontSizeKey);
    await prefs.remove(_showCitationsKey);
  }
}
