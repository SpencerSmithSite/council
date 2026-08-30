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

  /// Whether the reader has ever arranged the sections themselves.
  ///
  /// Needed because the collapsed set alone cannot distinguish "never touched
  /// it" from "deliberately expanded everything" — both are the empty set — and
  /// the two want opposite behaviour on the next launch.
  static const _arrangedKey = 'shelf_sections_arranged';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<Set<int>> pinned() => _readInts(_pinnedKey);
  Future<Set<int>> starred() => _readInts(_starredKey);

  Future<Set<String>> collapsed() async {
    final prefs = await _prefs;
    return (prefs.getStringList(_collapsedKey) ?? const <String>[]).toSet();
  }

  Future<bool> hasArrangedSections() async =>
      (await _prefs).getBool(_arrangedKey) ?? false;

  /// Write the arrangement the shelf is *already showing*.
  ///
  /// These take a whole set rather than toggling one member, because the screen
  /// holds the current arrangement in its own state and applies a change on the
  /// spot. A toggle here would mean reading prefs back off disk to decide what
  /// the new state is, which makes persistence — a platform-channel hop and a
  /// file write — sit in front of the frame that shows the result. Collapsing a
  /// section then visibly waited on a disk write. Now the screen paints first
  /// and these are fired off behind it.
  Future<void> setPinned(Set<int> ids) => _writeInts(_pinnedKey, ids);

  Future<void> setStarred(Set<int> ids) => _writeInts(_starredKey, ids);

  /// Records the collapsed set *and* marks the shelf arranged: reaching here at
  /// all means the reader opened or closed something themselves.
  Future<void> setCollapsed(Set<String> traditions) async {
    final prefs = await _prefs;
    await prefs.setStringList(_collapsedKey, traditions.toList());
    await prefs.setBool(_arrangedKey, true);
  }

  /// Collapse everything, on a shelf the reader has never arranged.
  ///
  /// A dozen tradition sections expanded is a screen of scrolling before the
  /// shape of the library is visible at all; collapsed, the whole of it fits at
  /// once and opening one is a tap. Deliberately *not* marked as arranged: this
  /// is the app's default, not a choice the reader made, so the first time they
  /// expand or collapse anything their preference takes over permanently.
  Future<Set<String>> applyDefaultCollapse(Set<String> traditions) async {
    final prefs = await _prefs;
    await prefs.setStringList(_collapsedKey, traditions.toList());
    return traditions;
  }

  Future<void> _writeInts(String key, Set<int> ids) async {
    final prefs = await _prefs;
    await prefs.setStringList(key, ids.map((e) => e.toString()).toList());
  }

  // SharedPreferences has no int-list type, so the ids are stored as strings.
  Future<Set<int>> _readInts(String key) async {
    final prefs = await _prefs;
    return (prefs.getStringList(key) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
  }

}
