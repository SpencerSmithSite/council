import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/services/updates/app_version.dart';

/// Council versions are dates — `2026.8.2+7` — and the whole reason this type
/// exists is that comparing them as strings is wrong in a way that looks fine
/// for most of a month and then silently stops offering anybody an update.
void main() {
  AppVersion v(String s) => AppVersion.tryParse(s)!;

  group('parsing', () {
    test('reads the date parts and the build counter', () {
      final parsed = v('2026.8.2+7');
      expect(parsed.parts, [2026, 8, 2]);
      expect(parsed.build, 7);
      expect(parsed.name, '2026.8.2');
      expect(parsed.toString(), '2026.8.2+7');
    });

    test('accepts a release tag, which is written with a v', () {
      expect(v('v2026.8.2'), v('2026.8.2'));
    });

    test('an explicit build wins over one spliced into the name', () {
      // package_info_plus reports the version and the build as two fields, and
      // that pair is more trustworthy than parsing one string.
      expect(AppVersion.tryParse('2026.8.2+7', build: 9)!.build, 9);
    });

    test('returns null rather than throwing on anything unreadable', () {
      // Both strings this parses come from outside the app — a manifest off the
      // network and whatever the platform reports as installed — so neither is
      // worth crashing a launch over.
      for (final bad in ['', '   ', 'nightly', '2026.x.2', '-1.0', 'v']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
      expect(AppVersion.tryParse(null), isNull);
    });
  });

  group('ordering', () {
    test('the tenth of a month is newer than the second', () {
      // The bug this class exists to prevent: '2026.8.2'.compareTo('2026.8.10')
      // is positive, so a string comparison decides the tenth is older and
      // every reader stops being offered updates for the rest of the month.
      expect('2026.8.2'.compareTo('2026.8.10') > 0, isTrue,
          reason: 'the trap being avoided');
      expect(v('2026.8.10') > v('2026.8.2'), isTrue);
    });

    test('October is newer than September', () {
      expect('2026.9.1'.compareTo('2026.10.1') > 0, isTrue,
          reason: 'the same trap one level up');
      expect(v('2026.10.1') > v('2026.9.1'), isTrue);
    });

    test('a new year is newer', () {
      expect(v('2027.1.5') > v('2026.12.31'), isTrue);
    });

    test('a rebuild of the same day is an update', () {
      expect(v('2026.8.2+8') > v('2026.8.2+7'), isTrue);
    });

    test('the date outranks the build counter', () {
      // A build number alone would be a total order too, but the date is what
      // a reader is shown, so it has to be what decides.
      expect(v('2026.8.3+1') > v('2026.8.2+99'), isTrue);
    });

    test('missing parts count as zero rather than as older', () {
      expect(v('2026.8'), v('2026.8.0'));
      expect(v('2026.8').hashCode, v('2026.8.0').hashCode);
      expect(v('2026.8.1') > v('2026.8'), isTrue);
    });

    test('the same version is not an update', () {
      expect(v('2026.8.2+7') > v('2026.8.2+7'), isFalse);
    });
  });
}
