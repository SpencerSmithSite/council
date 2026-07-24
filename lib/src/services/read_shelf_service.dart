import 'package:shared_preferences/shared_preferences.dart';

/// Per-source UI state for the Read tab: which sources the reader has pinned to
/// the top, which they have bookmarked, and which tradition sections they have
/// collapsed.
///
/// This is small, device-local preference data — how one reader likes their
/// shelf arranged — not corpus content, so it lives in SharedPreferences
/// alongside the other settings rather than in the database.
class ReadShelfService {
  static const _pinnedKey = 'shelf_pinned_sources';
  static const _savedKey = 'shelf_saved_sources';
  static const _collapsedKey = 'shelf_collapsed_traditions';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<Set<int>> pinned() => _readInts(_pinnedKey);
  Future<Set<int>> saved() => _readInts(_savedKey);

  Future<Set<String>> collapsed() async {
    final prefs = await _prefs;
    return (prefs.getStringList(_collapsedKey) ?? const <String>[]).toSet();
  }

  /// Add [id] to the pinned set if absent, remove it if present. Returns the
  /// new set so the caller can update its state in one step.
  Future<Set<int>> togglePinned(int id) => _toggleInt(_pinnedKey, id);

  Future<Set<int>> toggleSaved(int id) => _toggleInt(_savedKey, id);

  Future<Set<String>> toggleCollapsed(String tradition) async {
    final prefs = await _prefs;
    final set =
        (prefs.getStringList(_collapsedKey) ?? const <String>[]).toSet();
    if (!set.remove(tradition)) set.add(tradition);
    await prefs.setStringList(_collapsedKey, set.toList());
    return set;
  }

  // SharedPreferences has no int-list type, so the ids are stored as strings.
  Future<Set<int>> _readInts(String key) async {
    final prefs = await _prefs;
    return (prefs.getStringList(key) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
  }

  Future<Set<int>> _toggleInt(String key, int id) async {
    final ids = await _readInts(key);
    if (!ids.remove(id)) ids.add(id);
    final prefs = await _prefs;
    await prefs.setStringList(key, ids.map((e) => e.toString()).toList());
    return ids;
  }
}
