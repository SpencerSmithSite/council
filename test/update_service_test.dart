import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:council/src/services/device_storage.dart';
import 'package:council/src/services/updates/app_version.dart';
import 'package:council/src/services/updates/update_service.dart';

/// Staging goes to a temp directory rather than the real application support
/// directory, which does not exist under `flutter test`.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  final installer = Uint8List.fromList(
      List<int>.generate(64 * 1024, (i) => i % 251));
  final installerSha = sha256.convert(installer).toString();

  String manifestJson({
    String version = '2026.8.2',
    int build = 7,
    String? sha,
  }) =>
      jsonEncode({
        'schema': 1,
        'version': version,
        'build': build,
        'platforms': {
          // Every platform, so this runs the same wherever the suite is run
          // from — the service picks the one it is on.
          for (final id in ['android', 'macos', 'windows', 'linux'])
            id: {
              'kind': 'download',
              'url': 'https://example.com/v$version/Council-$id.bin',
              'bytes': installer.length,
              'sha256': sha ?? installerSha,
            },
          'ios': {
            'kind': 'store',
            'url': 'https://testflight.apple.com/join/JZ1k29YE',
          },
        },
      });

  /// Serves the manifest, and the installer in small pieces so progress has
  /// something to report.
  http.Client serving(String manifest, {List<int>? body, int status = 200}) {
    return MockClient.streaming((request, _) async {
      if (request.url.path.endsWith('updates.json')) {
        return http.StreamedResponse(
            Stream.value(utf8.encode(manifest)), status);
      }
      final bytes = body ?? installer;
      const chunk = 8 * 1024;
      return http.StreamedResponse(
        Stream.fromIterable([
          for (var i = 0; i < bytes.length; i += chunk)
            bytes.sublist(i, (i + chunk).clamp(0, bytes.length)),
        ]),
        200,
        contentLength: bytes.length,
      );
    });
  }

  UpdateService serviceOn(http.Client client, {String current = '2026.8.1'}) {
    final service = UpdateService(client: client)
      ..debugSetCurrentVersion(AppVersion.tryParse(current, build: 6));
    return service;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('council-update-test');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    // The real check shells out to `df`; the question here is not how much
    // room this machine has.
    DeviceStorage.debugFreeMb = 100000;
  });

  tearDown(() async {
    DeviceStorage.debugFreeMb = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('checking', () {
    test('offers a newer release', () async {
      final release = await serviceOn(serving(manifestJson())).check();
      expect(release, isNotNull);
      expect(release!.version.name, '2026.8.2');
    });

    test('says nothing when this build is current', () async {
      final service = serviceOn(serving(manifestJson()), current: '2026.8.2')
        ..debugSetCurrentVersion(AppVersion.tryParse('2026.8.2', build: 7));
      expect(await service.check(), isNull);
    });

    test('says nothing when the published build is older', () async {
      final service = serviceOn(serving(manifestJson(version: '2026.7.27')));
      expect(await service.check(), isNull);
    });

    test('a rebuild of the same day is an update', () async {
      final service = serviceOn(serving(manifestJson(build: 8)))
        ..debugSetCurrentVersion(AppVersion.tryParse('2026.8.2', build: 7));
      expect(await service.check(), isNotNull);
    });

    test('a failed fetch is silent, not an error', () async {
      // This runs unprompted at launch. A reader with no network asked for
      // nothing and should be told nothing.
      expect(await serviceOn(serving('', status: 500)).check(), isNull);
      expect(await serviceOn(serving('not json at all')).check(), isNull);
      expect(await serviceOn(serving('{"version":"nightly"}')).check(), isNull);
    });
  });

  group('downloading', () {
    test('writes the file, reports progress, and keeps it', () async {
      final service = serviceOn(serving(manifestJson()));
      final release = (await service.check())!;

      final seen = <int>[];
      final file = await service.download(release,
          onProgress: (received, total) {
        expect(total, installer.length);
        seen.add(received);
      });

      expect(await file.exists(), isTrue);
      expect(await file.length(), installer.length);
      expect(seen.first, lessThan(installer.length),
          reason: 'progress that starts at the end is not progress — the '
              'model download shipped a bar that was full throughout');
      expect(seen.last, installer.length);
      expect(seen, orderedEquals(List.of(seen)..sort()));
    });

    test('discards a download whose bytes are not the published ones',
        () async {
      // The load-bearing test. What this returns gets executed with the
      // reader's own privileges, so a file that does not hash to the published
      // checksum must not survive, let alone be handed to the OS.
      final tampered = Uint8List.fromList(installer)..[10] ^= 0xFF;
      final service = serviceOn(serving(manifestJson(), body: tampered));
      final release = (await service.check())!;

      await expectLater(
        service.download(release),
        throwsA(isA<UpdateException>().having((e) => e.message, 'message',
            contains('did not match its checksum'))),
      );

      final staged = await service.stagingDirectory();
      expect(await staged.list().isEmpty, isTrue,
          reason: 'a rejected installer must not be left lying about');
    });

    test('refuses to start without room on disk', () async {
      DeviceStorage.debugFreeMb = 1;
      final service = serviceOn(serving(manifestJson()));
      final release = (await service.check())!;
      await expectLater(
        service.download(release),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('free space'))),
      );
    });

    test('a cancelled download leaves nothing behind', () async {
      final service = serviceOn(serving(manifestJson()));
      final release = (await service.check())!;

      // Cancelled part-way, the way a reader does it: the sheet is up, the bar
      // is moving, they change their mind.
      await expectLater(
        service.download(release,
            onProgress: (received, _) {
          if (received >= 8 * 1024) service.cancel();
        }),
        throwsA(isA<UpdateCancelled>()),
      );

      final staged = await service.stagingDirectory();
      expect(await staged.list().isEmpty, isTrue,
          reason: 'half an installer is worse than none');
    });

    test('a cancel from an abandoned attempt does not kill the next one',
        () async {
      final service = serviceOn(serving(manifestJson()));
      final release = (await service.check())!;
      service.cancel();
      // Each download clears the flag as it starts, so pressing Cancel and
      // then Download again works rather than failing instantly.
      expect(await (await service.download(release)).exists(), isTrue);
    });

    test('staging is cleared before each attempt', () async {
      final service = serviceOn(serving(manifestJson()));
      final staged = await service.stagingDirectory();
      // 200 MB of abandoned installer, left by an update that went wrong.
      await File('${staged.path}/Council-old.apk').writeAsBytes([1, 2, 3]);

      final release = (await service.check())!;
      await service.download(release);

      final left = await staged.list().toList();
      expect(left.length, 1);
      expect(left.single.path, endsWith(release.fileName));
    });
  });
}
