import 'package:shared_preferences/shared_preferences.dart';

/// Per-source UI state for the Read tab: which sources the reader has pinned to
/// the top, which they have starred, and which tradition sections they have
/// collapsed.
///
/// Starring is a source-level favourite, deliberately distinct from the
/// passage-level bookmarks (a whole work vs. a single unit within one), which
/// is why it has its own name and store rather than reusing "bookmark".
///
/// This is small, device-local preference data — how one reader likes their
/// shelf arranged — not corpus content, so it lives in SharedPreferences
/// alongside the other settings rather than in the database.
class ReadShelfService {
  static const _pinnedKey = 'shelf_pinned_sources';
  static const _starredKey = 'shelf_starred_sources';
  static const _collapsedKey = 'shelf_collapsed_traditions';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<Set<int>> pinned() => _readInts(_pinnedKey);
  Future<Set<int>> starred() => _readInts(_starredKey);

  Future<Set<String>> collapsed() async {
    final prefs = await _prefs;
    return (prefs.getStringList(_collapsedKey) ?? const <String>[]).toSet();
  }

  /// Add [id] to the pinned set if absent, remove it if present. Returns the
  /// new set so the caller can update its state in one step.
  Future<Set<int>> togglePinned(int id) => _toggleInt(_pinnedKey, id);

  Future<Set<int>> toggleStarred(int id) => _toggleInt(_starredKey, id);

  Future<Set<String>> toggleCollapsed(String tradition) async {
    final prefs = await _prefs;
    final set =
        (prefs.getStringList(_collapsedKey) ?? const <String>[]).toSet();
    if (!set.remove(tradition)) set.add(tradition);
    await prefs.setStringList(_collapsedKey, set.toList());
    return set;
  }

  /// Replace the whole collapsed set — used by the Read page's collapse-all /
  /// expand-all control.
  Future<Set<String>> setCollapsed(Set<String> traditions) async {
    final prefs = await _prefs;
    await prefs.setStringList(_collapsedKey, traditions.toList());
    return traditions;
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
