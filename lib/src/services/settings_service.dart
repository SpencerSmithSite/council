import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _darkModeKey = 'dark_mode';
  static const String _fontSizeKey = 'font_size';
  static const String _showCitationsKey = 'show_citations';
  
  Future<SharedPreferences> get _prefs async => await SharedPreferences.getInstance();
  
  /// Get dark mode preference (null = system default)
  Future<bool?> getDarkMode() async {
    final prefs = await _prefs;
    if (!prefs.containsKey(_darkModeKey)) return null;
    return prefs.getBool(_darkModeKey);
  }
  
  /// Set dark mode preference
  Future<void> setDarkMode(bool? enabled) async {
    final prefs = await _prefs;
    if (enabled == null) {
      await prefs.remove(_darkModeKey);
    } else {
      await prefs.setBool(_darkModeKey, enabled);
    }
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
    await prefs.remove(_fontSizeKey);
    await prefs.remove(_showCitationsKey);
  }
}
