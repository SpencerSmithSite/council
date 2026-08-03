import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:council/src/services/updates/app_version.dart';
import 'package:council/src/services/updates/release_manifest.dart';
import 'package:council/src/services/updates/update_installer.dart';
import 'package:council/src/services/updates/update_service.dart';

/// The update flow, run against the real manifest and the real release.
///
/// The unit tests cover the decisions; these cover the parts that only a device
/// can answer, which in this codebase is where the faults have actually been.
/// Every one of the on-device model bugs compiled, analysed clean and
/// downloaded successfully before failing on hardware, and the pieces here have
/// the same shape: whether the published manifest is reachable and parses,
/// whether a real 200 MB download survives the connection and hashes to what
/// was published, and — the part with no unit-test equivalent at all — whether
/// Android's FileProvider will actually hand the file to the package installer.
/// A wrong authority or a path missing from `update_paths.xml` throws at that
/// last step and nowhere earlier.
///
///     flutter test integration_test/update_flow_test.dart -d emulator-5554
///     flutter test integration_test/update_flow_test.dart -d macos
///
/// The downloading tests move the whole installer over the network, so they
/// carry a raised timeout: the default 30 seconds expires mid-download and
/// reports as a failure indistinguishable from a real one.
const _networkTimeout = Timeout(Duration(minutes: 20));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Old enough that whatever is published is newer.
  final ancient = AppVersion.tryParse('2026.1.1', build: 1)!;

  UpdateService serviceAsOldBuild() =>
      UpdateService()..debugSetCurrentVersion(ancient);

  testWidgets('the published manifest is reachable and describes this platform',
      (tester) async {
    final manifest = await UpdateService().fetchManifest();
    expect(manifest, isNotNull,
        reason: 'nothing else in the update flow can work without this');

    final release = manifest!.forCurrentPlatform();
    expect(release, isNotNull,
        reason: 'no entry for ${ReleaseManifest.currentPlatform}');

    if (release!.delivery == ReleaseDelivery.download) {
      expect(release.sha256, isNotNull);
      expect(release.bytes, greaterThan(0));
      expect(release.url.scheme, 'https');
    }
  }, timeout: _networkTimeout);

  testWidgets('an older build is offered the published release',
      (tester) async {
    final release = await serviceAsOldBuild().check();
    expect(release, isNotNull);
    expect(release!.version > ancient, isTrue);
  }, timeout: _networkTimeout);

  testWidgets('the current build is offered nothing', (tester) async {
    // No override: this is whatever version the running build actually is, so
    // this fails if the shipped version and the published one disagree about
    // which is newer — which is the state that would nag every reader on the
    // latest build forever.
    expect(await UpdateService().check(), isNull);
  }, timeout: _networkTimeout);

  testWidgets('the real installer downloads and matches its published checksum',
      (tester) async {
    final service = serviceAsOldBuild();
    final release = (await service.check())!;
    if (release.delivery != ReleaseDelivery.download) {
      return; // iOS installs through TestFlight; there is nothing to fetch.
    }

    var lastReported = 0;
    final file = await service.download(release, onProgress: (received, _) {
      lastReported = received;
    });

    // Reaching here at all means the sha256 matched: download() deletes and
    // throws otherwise.
    expect(await file.exists(), isTrue);
    expect(await file.length(), release.bytes);
    expect(lastReported, release.bytes);
    expect(file.path, endsWith(release.fileName),
        reason: 'the OS decides what to do with it by its extension');
  }, timeout: _networkTimeout);

  testWidgets('Android hands the download to the package installer',
      (tester) async {
    if (!Platform.isAndroid) return;

    final service = serviceAsOldBuild();
    final release = (await service.check())!;
    final file = await service.download(release);

    final result = await UpdateInstaller.install(file);
    // Printed because the two acceptable outcomes below are not equally
    // informative: only `handedOff` proves the FileProvider produced a URI the
    // installer took, and which one happened depends on whether this device has
    // already allowed the app to install unknown apps.
    //
    //   adb shell appops set site.spencersmith.council \
    //     REQUEST_INSTALL_PACKAGES allow
    debugPrint('install outcome: ${result.outcome} ${result.message ?? ''}');

    // Either outcome proves the native side worked. `needsPermission` means the
    // app is not yet allowed to install unknown apps and was sent to the right
    // settings page; `handedOff` means FileProvider produced a content:// URI
    // for the staged file and the installer accepted it. What must not happen
    // is `failed`, which is what a wrong authority or an uncovered path gives.
    expect(
      result.outcome,
      anyOf(InstallOutcome.handedOff, InstallOutcome.needsPermission),
      reason: result.message ?? '',
    );
  }, timeout: _networkTimeout);

  testWidgets('macOS opens the downloaded disk image', (tester) async {
    if (!Platform.isMacOS) return;

    final service = serviceAsOldBuild();
    final release = (await service.check())!;
    final file = await service.download(release);

    // The question this answers is a sandbox question. The Mac build runs
    // sandboxed, so it cannot usefully spawn `/usr/bin/open`, and the file it
    // has just written is inside its own container rather than anywhere the
    // reader would look. NSWorkspace — which url_launcher goes through — is an
    // out-of-process request to LaunchServices and is allowed to open it
    // anyway. That is the claim; this is the check.
    //
    // It mounts a volume. Afterwards: hdiutil detach /Volumes/Council
    final result = await UpdateInstaller.install(file);
    debugPrint('install outcome: ${result.outcome} ${result.message ?? ''}');
    expect(result.outcome, InstallOutcome.handedOff,
        reason: result.message ?? '');
  }, timeout: _networkTimeout);
}
