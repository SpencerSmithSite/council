import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../device_storage.dart';
import 'app_version.dart';
import 'release_manifest.dart';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

/// Thrown when the reader stops a download. Separate from [UpdateException] so
/// the UI can go quiet instead of showing an error for something they asked
/// for.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Finds out whether a newer Council exists, fetches it, and proves it is
/// genuine before anything is run.
///
/// Council is a direct download on four of its five platforms, so nothing —
/// no Play Store, no Mac App Store, no apt — ever tells a reader that a new
/// build is out. They found out by revisiting the download page, which mostly
/// means they did not find out.
class UpdateService {
  /// Served from the site rather than the GitHub releases API: app releases are
  /// marked pre-release, so `releases/latest` in that repository resolves to
  /// the corpus content releases instead, and there is no stable "latest" URL
  /// for the app to follow. A static file is also one request with no rate
  /// limit, which matters when every launch makes it.
  static const String manifestUrl =
      'https://www.spencersmith.site/council/updates.json';

  /// Short, and deliberately so. This runs at launch: a check that cannot be
  /// answered quickly should be abandoned quietly rather than kept alive on the
  /// chance the network comes back.
  static const Duration checkTimeout = Duration(seconds: 12);

  /// Generous by comparison — the Android package is nearly 200 MB, which is a
  /// long time on a slow connection but not a stalled one. The timeout is per
  /// chunk, so it fires on a connection that stops moving, not on one that is
  /// merely slow.
  static const Duration chunkTimeout = Duration(minutes: 2);

  final http.Client _client;

  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  AppVersion? _currentOverride;
  bool _cancelled = false;

  /// The version this build is, read from the platform rather than from
  /// `pubspec.yaml`, since the pubspec is not shipped.
  Future<AppVersion> currentVersion() async {
    if (_currentOverride != null) return _currentOverride!;
    final info = await PackageInfo.fromPlatform();
    return AppVersion.tryParse(
          info.version,
          build: int.tryParse(info.buildNumber),
        ) ??
        // A version the platform reports in some shape this cannot read would
        // otherwise make every release look newer, and offer an update
        // forever. Treating it as impossibly new means the app says nothing.
        const AppVersion([99999]);
  }

  /// Test seam: what the running build claims to be.
  @visibleForTesting
  void debugSetCurrentVersion(AppVersion? version) =>
      _currentOverride = version;

  /// The published manifest, or null when it could not be fetched or made
  /// sense of.
  ///
  /// Never throws. This runs unprompted at launch, and a reader with no network
  /// — or a site being redeployed — should see nothing at all rather than an
  /// error about a thing they did not ask for.
  Future<ReleaseManifest?> fetchManifest() async {
    try {
      final response = await _client
          .get(Uri.parse(manifestUrl))
          .timeout(checkTimeout);
      if (response.statusCode != 200) return null;
      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return ReleaseManifest.fromJson(decoded);
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// The release to offer, or null when this build is current, the platform
  /// publishes no releases, or the check failed.
  Future<PlatformRelease?> check() async {
    final manifest = await fetchManifest();
    if (manifest == null) return null;
    final release = manifest.forCurrentPlatform();
    if (release == null) return null;
    return release.version > await currentVersion() ? release : null;
  }

  /// Where a downloaded installer is staged.
  ///
  /// Inside the app's own support directory on every platform, rather than the
  /// reader's Downloads folder, because the app deletes what it finds there
  /// between attempts — a 200 MB file left behind by an abandoned update is its
  /// own bug — and it must never be in a position to delete something a reader
  /// put there themselves. On Android it is also the one location the app can
  /// write and then grant the installer access to without asking for storage
  /// permission.
  Future<Directory> stagingDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'updates'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Removes anything staged by an earlier attempt.
  Future<void> clearStaging() async {
    try {
      final dir = await stagingDirectory();
      await for (final entry in dir.list()) {
        if (entry is File) await entry.delete();
      }
    } catch (_) {
      // Housekeeping. Never worth failing an update over.
    }
  }

  void cancel() => _cancelled = true;

  /// Fetches [release] and returns the verified file.
  ///
  /// Throws [UpdateException] if anything is wrong with the download, and
  /// [UpdateCancelled] if the reader stopped it. The file it returns has been
  /// checked against the manifest's sha256 — no caller should ever run one that
  /// has not.
  Future<File> download(
    PlatformRelease release, {
    void Function(int received, int total)? onProgress,
  }) async {
    _cancelled = false;

    if (release.delivery != ReleaseDelivery.download) {
      throw const UpdateException('This platform installs updates elsewhere.');
    }

    // Asked before the bytes rather than after: the model download taught this
    // exact lesson, where a full fetch failed at the install step on a device
    // that never had room for it, having spent the reader's data getting there.
    if (!await DeviceStorage.hasRoomFor(release.megabytes)) {
      throw UpdateException(
        'There is not enough free space for the ${release.megabytes} MB '
        'download. Free some up and try again.',
      );
    }

    await clearStaging();
    final destination =
        File(p.join((await stagingDirectory()).path, release.fileName));

    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', release.url))
          .timeout(checkTimeout);
    } on TimeoutException {
      throw const UpdateException(
          'Could not start the download: the connection timed out.');
    } catch (e) {
      throw UpdateException('Could not start the download: $e');
    }
    if (response.statusCode != 200) {
      throw UpdateException('Download failed (HTTP ${response.statusCode}).');
    }

    // Streamed to disk rather than buffered. Holding 200 MB in memory on a
    // phone to write it out again afterwards is avoidable.
    final total = response.contentLength ?? release.bytes ?? 0;
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(chunkTimeout)) {
        if (_cancelled) throw const UpdateCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } on TimeoutException {
      await sink.close();
      await _discard(destination);
      throw const UpdateException('The download stalled and was stopped.');
    } on UpdateCancelled {
      await sink.close();
      await _discard(destination);
      rethrow;
    } catch (e) {
      await sink.close();
      await _discard(destination);
      throw UpdateException('The download failed: $e');
    }
    await sink.close();

    await _verify(release, destination);
    return destination;
  }

  /// Rejects anything whose bytes are not the ones the manifest published.
  ///
  /// The strictest step here, and the reason the manifest carries a checksum at
  /// all: what this returns is handed to the operating system and executed with
  /// the reader's own privileges. A truncated download, a proxy serving
  /// something else, an interrupted connection resumed against a different
  /// file — none of them should reach the point of being run, and the app has
  /// no way to tell them apart from a genuine installer except this.
  Future<void> _verify(PlatformRelease release, File file) async {
    final expected = release.sha256;
    if (expected == null) {
      await _discard(file);
      throw const UpdateException(
          'That release was published without a checksum, so it was not '
          'installed.');
    }

    final digest = (await sha256.bind(file.openRead()).first).toString();
    if (digest != expected) {
      await _discard(file);
      throw const UpdateException(
        'The download did not match its checksum and was discarded. Check '
        'your connection and try again.',
      );
    }
  }

  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Already gone, or unwritable. Either way there is nothing to do.
    }
  }
}
