import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/services/updates/release_manifest.dart';

/// The manifest describes files the app downloads and then hands to the
/// operating system to execute. Everything strict in here is strict for that
/// reason.
void main() {
  const sha =
      '03e2015837e4fd29de353dc3db079af3bbdc1bccaf0c76a23b5c6697bbb5d485';

  Map<String, dynamic> manifest({
    Map<String, dynamic>? android,
    Map<String, dynamic>? extra,
  }) =>
      {
        'schema': 1,
        'version': '2026.8.2',
        'build': 7,
        'notes': 'What changed.',
        'url': 'https://www.spencersmith.site/council/download.html',
        'platforms': {
          'android': android ??
              {
                'kind': 'download',
                'url':
                    'https://github.com/SpencerSmithSite/council/releases/download/v2026.8.2/Council-android.apk',
                'bytes': 204610770,
                'sha256': sha,
              },
          if (extra != null) ...extra,
        },
      };

  ReleaseManifest parse(Map<String, dynamic> json) =>
      ReleaseManifest.fromJson(jsonDecode(jsonEncode(json)));

  test('reads a release', () {
    final m = parse(manifest());
    expect(m.version.name, '2026.8.2');
    expect(m.version.build, 7);
    expect(m.notes, 'What changed.');

    final android = m.platforms['android']!;
    expect(android.delivery, ReleaseDelivery.download);
    expect(android.bytes, 204610770);
    expect(android.megabytes, 195);
    expect(android.sha256, sha);
    expect(android.fileName, 'Council-android.apk',
        reason: 'the OS decides what to do with a download by its extension');
  });

  test('a store platform needs no size or checksum', () {
    final m = parse(manifest(extra: {
      'ios': {
        'kind': 'store',
        'url': 'https://testflight.apple.com/join/JZ1k29YE',
      },
    }));
    expect(m.platforms['ios']!.delivery, ReleaseDelivery.store);
    expect(m.platforms['ios']!.sha256, isNull);
  });

  test('a platform inherits the release version, or overrides it', () {
    final m = parse(manifest(extra: {
      'ios': {
        'kind': 'store',
        'url': 'https://testflight.apple.com/join/JZ1k29YE',
        'version': '2026.7.27',
      },
    }));
    expect(m.platforms['android']!.version.name, '2026.8.2');
    expect(m.platforms['ios']!.version.name, '2026.7.27',
        reason: 'a store can lag behind the direct downloads');
  });

  group('refuses anything it cannot verify', () {
    // Each of these drops the platform rather than accepting it, because
    // accepting it means running an unverifiable executable on the reader's
    // machine.
    final rejected = <String, Map<String, dynamic>>{
      'no checksum': {
        'kind': 'download',
        'url': 'https://example.com/v2026.8.2/Council.apk',
        'bytes': 100,
      },
      'a checksum that is not a sha256': {
        'kind': 'download',
        'url': 'https://example.com/v2026.8.2/Council.apk',
        'bytes': 100,
        'sha256': 'deadbeef',
      },
      'no size': {
        'kind': 'download',
        'url': 'https://example.com/v2026.8.2/Council.apk',
        'sha256': sha,
      },
      'plain http': {
        'kind': 'download',
        'url': 'http://example.com/v2026.8.2/Council.apk',
        'bytes': 100,
        'sha256': sha,
      },
      'an unknown delivery kind': {
        'kind': 'torrent',
        'url': 'https://example.com/v2026.8.2/Council.apk',
        'bytes': 100,
        'sha256': sha,
      },
    };

    rejected.forEach((why, entry) {
      test(why, () {
        expect(
          () => parse(manifest(android: entry)),
          throwsFormatException,
          reason: 'the only platform was unusable, so there is no manifest',
        );
      });
    });

    test('an unusable platform does not take the others down with it', () {
      final m = parse(manifest(
        android: rejected['no checksum']!,
        extra: {
          'macos': {
            'kind': 'download',
            'url':
                'https://github.com/SpencerSmithSite/council/releases/download/v2026.8.2/Council-macos.dmg',
            'bytes': 59382899,
            'sha256': sha,
          },
        },
      ));
      expect(m.platforms.containsKey('android'), isFalse);
      expect(m.platforms.containsKey('macos'), isTrue);
    });
  });

  test('a manifest with no version is not a manifest', () {
    final bad = manifest()..remove('version');
    expect(() => parse(bad), throwsFormatException);
  });

  test('the sha256 is matched case-insensitively but stored lower-case', () {
    final m = parse(manifest(android: {
      'kind': 'download',
      'url': 'https://example.com/v2026.8.2/Council.apk',
      'bytes': 100,
      'sha256': sha.toUpperCase(),
    }));
    expect(m.platforms['android']!.sha256, sha);
  });
}
