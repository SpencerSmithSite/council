import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:council/src/services/device_storage.dart';
import 'package:council/src/services/updates/app_version.dart';
import 'package:council/src/services/updates/release_manifest.dart';
import 'package:council/src/services/updates/update_provider.dart';
import 'package:council/src/services/updates/update_service.dart';
import 'package:council/src/widgets/update_sheet.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  final installer =
      Uint8List.fromList(List<int>.generate(40 * 1024, (i) => i % 251));
  final installerSha = sha256.convert(installer).toString();

  /// The platform the suite is running on, since that is the entry the service
  /// will pick out of the manifest.
  final hostId = ReleaseManifest.currentPlatform!;

  String manifestJson({String kind = 'download'}) => jsonEncode({
        'version': '2026.8.9',
        'build': 12,
        'platforms': {
          hostId: {
            'kind': kind,
            'url': kind == 'store'
                ? 'https://testflight.apple.com/join/JZ1k29YE'
                : 'https://example.com/v2026.8.9/Council.bin',
            if (kind == 'download') ...{
              'bytes': installer.length,
              'sha256': installerSha,
            },
          },
        },
      });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('council-sheet-test');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    DeviceStorage.debugFreeMb = 100000;
  });

  tearDown(() async {
    DeviceStorage.debugFreeMb = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A provider whose network is a stream the test drives by hand, so the sheet
  /// can be looked at part-way through a download.
  ({UpdateProvider provider, StreamController<List<int>> body}) harness({
    String manifest = '',
    List<int>? payload,
  }) {
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((request, _) async {
      if (request.url.path.endsWith('updates.json')) {
        return http.StreamedResponse(
            Stream.value(utf8.encode(manifest)), 200);
      }
      return http.StreamedResponse(body.stream, 200,
          contentLength: payload?.length ?? installer.length);
    });

    final service = UpdateService(client: client)
      ..debugSetCurrentVersion(AppVersion.tryParse('2026.8.2', build: 7));
    return (provider: UpdateProvider(service: service), body: body);
  }

  Widget wrap(UpdateProvider provider) => MaterialApp(
        home: ChangeNotifierProvider<UpdateProvider>.value(
          value: provider,
          child: const Scaffold(body: UpdateSheet()),
        ),
      );

  /// Everything here writes real files and hashes them, and `testWidgets` runs
  /// inside a fake clock that never lets real I/O finish — so the work has to
  /// happen in [WidgetTester.runAsync] and the rendering afterwards.
  Future<void> real(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
    await tester.pump();
  }

  testWidgets('offers the new version, with what it will cost', (tester) async {
    final h = harness(manifest: manifestJson());
    await real(tester, () => h.provider.check());
    await tester.pumpWidget(wrap(h.provider));

    expect(find.text('Council 2026.8.9 is available'), findsOneWidget);
    expect(find.text('You have 2026.8.2.'), findsOneWidget);
    // The size is stated up front rather than after the download begins: on a
    // phone this can be a couple of hundred megabytes of someone's data.
    expect(find.textContaining('MB'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

  });

  testWidgets('nothing downloads until it is asked to', (tester) async {
    final h = harness(manifest: manifestJson());
    await real(tester, () => h.provider.check());
    await tester.pumpWidget(wrap(h.provider));

    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: 'the check is automatic; the download is a decision');
    expect(h.provider.stage, UpdateStage.available);

  });

  testWidgets('the bar shows how far along it actually is', (tester) async {
    final h = harness(manifest: manifestJson());
    await real(tester, () => h.provider.check());
    await tester.pumpWidget(wrap(h.provider));

    late Future<void> downloading;
    await real(tester, () async {
      downloading = h.provider.download();
      h.body.add(installer.sublist(0, 10 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    // A quarter of the way in. The model download shipped a bar drawn full
    // from the first frame to the last, which is the bug this proves is not
    // repeated here.
    expect(bar.value, closeTo(0.25, 0.01));
    expect(find.text('Downloading… 25%'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await real(tester, () async {
      h.body.add(installer.sublist(10 * 1024));
      await h.body.close();
      await downloading;
    });

    expect(find.text('Install'), findsOneWidget);
    expect(h.provider.stage, UpdateStage.ready);
  });

  testWidgets('a download that fails its checksum says so, and offers a retry',
      (tester) async {
    final h = harness(manifest: manifestJson());
    await real(tester, () => h.provider.check());
    await tester.pumpWidget(wrap(h.provider));

    await real(tester, () async {
      final downloading = h.provider.download();
      h.body.add(Uint8List.fromList(installer)..[3] ^= 0xFF);
      await h.body.close();
      await downloading;
    });

    expect(find.textContaining('did not match its checksum'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Install'), findsNothing,
        reason: 'an installer that cannot be verified is never offered');
  });

  testWidgets('a store platform is sent to TestFlight instead', (tester) async {
    final h = harness(manifest: manifestJson(kind: 'store'));
    await real(tester, () => h.provider.check());
    await tester.pumpWidget(wrap(h.provider));

    expect(find.text('Open TestFlight'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    expect(h.provider.goesToStore, isTrue);

  });
}
