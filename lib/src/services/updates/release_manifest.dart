import 'dart:io';

import 'app_version.dart';

/// How a platform gets a new version.
enum ReleaseDelivery {
  /// The app fetches the installer itself and hands it to the OS. Every
  /// platform Council ships as a direct download: Android, macOS, Windows and
  /// Linux.
  download,

  /// The app can only send the reader somewhere — TestFlight or the App Store
  /// on iOS, where an app may not install anything, itself included.
  store,
}

/// What one platform's current release is, as published in `updates.json`.
class PlatformRelease {
  /// `android`, `ios`, `macos`, `windows` or `linux` — the same names
  /// [ReleaseManifest.currentPlatform] produces.
  final String platform;
  final ReleaseDelivery delivery;
  final Uri url;
  final AppVersion version;

  /// Exact size, so a download can show real progress and be checked against
  /// free disk before it starts. Null for a store release, where the size is
  /// Apple's business rather than ours.
  final int? bytes;

  /// Lower-case hex sha256 of the installer. Null only for a store release.
  ///
  /// Required for anything downloaded, and this is deliberately not lenient:
  /// what is downloaded gets executed with the reader's own privileges, so a
  /// release the app cannot verify is one it declines to install rather than
  /// one it installs hopefully.
  final String? sha256;

  const PlatformRelease({
    required this.platform,
    required this.delivery,
    required this.url,
    required this.version,
    this.bytes,
    this.sha256,
  });

  /// Size in whole megabytes, for showing a reader what they are about to pull
  /// down. Zero when unknown.
  int get megabytes => bytes == null ? 0 : bytes! ~/ (1024 * 1024);

  /// The file the download should be written as, taken from the URL so a
  /// `.dmg` stays a `.dmg` — the OS decides what to do with it by extension,
  /// and a downloaded installer named without one opens nothing.
  String get fileName {
    final segments = url.pathSegments;
    final last = segments.isEmpty ? '' : segments.last;
    return last.isEmpty ? 'Council-update' : last;
  }
}

/// The published state of every platform, fetched from the site.
///
/// Exists because Council is a direct download on four of its five platforms —
/// no Play Store, no Mac App Store, no package manager — so nothing tells a
/// reader a new build exists. Before this, they found out by happening to visit
/// the download page again, which for most people means never.
class ReleaseManifest {
  /// The release-wide version. A platform may override it, for when one store
  /// is behind the rest.
  final AppVersion version;

  /// One line on what changed, shown when an update is offered. Null when the
  /// release did not bother to say.
  final String? notes;

  /// The download page, for a reader who would rather do it by hand.
  final Uri? page;

  final Map<String, PlatformRelease> platforms;

  const ReleaseManifest({
    required this.version,
    required this.platforms,
    this.notes,
    this.page,
  });

  /// The manifest key for the platform this build is running on, or null on a
  /// platform with no releases (web, and anything Flutter adds later).
  static String? get currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return null;
  }

  PlatformRelease? forCurrentPlatform() {
    final id = currentPlatform;
    return id == null ? null : platforms[id];
  }

  /// Throws [FormatException] on anything it cannot trust.
  ///
  /// Strict on purpose. A malformed manifest that parses into something
  /// half-populated would present a reader with an update offer that fails at
  /// the last step, or — worse, for the checksum — one that skips verification
  /// because the field happened to be missing.
  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    final build = json['build'];
    final version = AppVersion.tryParse(
      json['version'] as String?,
      build: build is int ? build : null,
    );
    if (version == null) {
      throw const FormatException('The update manifest has no usable version.');
    }

    final raw = json['platforms'];
    if (raw is! Map) {
      throw const FormatException('The update manifest lists no platforms.');
    }

    final platforms = <String, PlatformRelease>{};
    raw.forEach((key, value) {
      if (value is! Map) return;
      final id = key.toString();
      final entry = value.cast<String, dynamic>();

      final delivery = switch (entry['kind']) {
        'download' => ReleaseDelivery.download,
        'store' => ReleaseDelivery.store,
        // An unrecognised kind is dropped rather than fatal, so adding a new
        // delivery route later does not stop older builds from checking at all.
        _ => null,
      };
      if (delivery == null) return;

      final url = Uri.tryParse(entry['url'] as String? ?? '');
      // Only https. This URL ends up as an executable on the reader's machine.
      if (url == null || url.scheme != 'https' || url.host.isEmpty) return;

      final bytes = entry['bytes'];
      final sha = (entry['sha256'] as String?)?.toLowerCase();
      if (delivery == ReleaseDelivery.download) {
        if (bytes is! int || bytes <= 0) return;
        if (sha == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return;
      }

      platforms[id] = PlatformRelease(
        platform: id,
        delivery: delivery,
        url: url,
        version: AppVersion.tryParse(entry['version'] as String?,
                build: entry['build'] is int ? entry['build'] as int : null) ??
            version,
        bytes: bytes is int ? bytes : null,
        sha256: sha,
      );
    });

    if (platforms.isEmpty) {
      throw const FormatException(
          'The update manifest has no platform this build could use.');
    }

    final pageUrl = Uri.tryParse(json['url'] as String? ?? '');
    return ReleaseManifest(
      version: version,
      notes: (json['notes'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['notes'] as String).trim(),
      page: pageUrl != null && pageUrl.hasScheme ? pageUrl : null,
      platforms: platforms,
    );
  }
}
