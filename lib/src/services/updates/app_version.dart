/// A Council version: the release date, then the build counter.
///
/// `2026.8.2+7` is the second of August 2026, build 7. Parsing it into numbers
/// rather than comparing the strings is the whole point of this class, because
/// the obvious shortcut is wrong in a way that only shows up later: `'2026.8.2'
/// .compareTo('2026.8.10')` is positive, so a string comparison would decide
/// the tenth is *older* than the second and every reader would stop being
/// offered updates for the rest of that month. The same trap sits at every
/// year boundary — `'2026.12.1'` vs `'2027.1.5'` happens to work, but
/// `'2026.9.1'` vs `'2026.10.1'` does not.
///
/// The date parts are compared first and the build only breaks a tie, so a
/// rebuild of the same day (`+7` → `+8`) is still an update.
class AppVersion implements Comparable<AppVersion> {
  /// The dotted parts, most significant first: year, month, day.
  final List<int> parts;

  /// The counter after the `+`. Zero when a version was written without one —
  /// the manifest states it separately, and a display string like `2026.8.2`
  /// carries no build at all.
  final int build;

  const AppVersion(this.parts, {this.build = 0});

  /// Parses `2026.8.2`, `2026.8.2+7`, or either with a leading `v` (release
  /// tags are written `v2026.8.2`). Returns null on anything else rather than
  /// throwing: this parses two strings the app does not control — a manifest
  /// fetched over the network, and whatever the platform reports as the
  /// installed version — and neither is worth crashing a launch over.
  static AppVersion? tryParse(String? raw, {int? build}) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    if (text.isEmpty) return null;

    var parsedBuild = build ?? 0;
    final plus = text.indexOf('+');
    if (plus >= 0) {
      // An explicit `build` argument wins: package_info_plus reports the
      // version and the build number as two separate fields, and that pair is
      // more trustworthy than anything spliced into the name.
      parsedBuild = build ?? (int.tryParse(text.substring(plus + 1)) ?? 0);
      text = text.substring(0, plus);
    }

    final parts = <int>[];
    for (final segment in text.split('.')) {
      final value = int.tryParse(segment.trim());
      if (value == null || value < 0) return null;
      parts.add(value);
    }
    if (parts.isEmpty) return null;
    return AppVersion(parts, build: parsedBuild);
  }

  @override
  int compareTo(AppVersion other) {
    // Compared over the longer of the two, treating a missing part as zero, so
    // `2026.8` and `2026.8.0` are the same version rather than one being
    // mysteriously older.
    final length =
        parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < length; i++) {
      final mine = i < parts.length ? parts[i] : 0;
      final theirs = i < other.parts.length ? other.parts[i] : 0;
      if (mine != theirs) return mine.compareTo(theirs);
    }
    return build.compareTo(other.build);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  int _at(int i) => i < parts.length ? parts[i] : 0;

  // Padded to a fixed width for the same reason [compareTo] pads: `2026.8` and
  // `2026.8.0` are equal, so they have to hash alike.
  @override
  int get hashCode => Object.hash(_at(0), _at(1), _at(2), build);

  /// The version as a reader sees it, without the build counter.
  String get name => parts.join('.');

  @override
  String toString() => build == 0 ? name : '$name+$build';
}
