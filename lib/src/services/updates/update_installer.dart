import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'release_manifest.dart';

/// What happened when a verified download was handed over.
enum InstallOutcome {
  /// The operating system took it: an installer, a mounted disk image or a
  /// package prompt is now in front of the reader.
  handedOff,

  /// Android will not install anything until this app is allowed to. Its
  /// settings page has been opened; the reader grants it and taps Install
  /// again.
  needsPermission,

  /// Nothing here can start an installation, so the file was left somewhere
  /// findable and its folder opened. This is Linux, where replacing a running
  /// AppImage from inside itself is not something to attempt.
  saved,

  /// The hand-off failed. [InstallResult.message] says how.
  failed,
}

class InstallResult {
  final InstallOutcome outcome;

  /// Where the file ended up, for telling a reader who has to finish by hand.
  final String? path;
  final String? message;

  const InstallResult(this.outcome, {this.path, this.message});
}

/// Hands a downloaded, checksum-verified installer to the operating system.
///
/// Deliberately the end of the app's involvement. No platform here lets a
/// running application replace itself in place — Windows cannot overwrite a
/// loaded executable, a mounted AppImage cannot be rewritten under itself, and
/// Android and macOS both route installation through the OS on purpose — so
/// the honest design is to fetch, prove, hand over, and get out of the way.
class UpdateInstaller {
  /// Android alone needs native code, because the install intent needs a
  /// content:// URI from a FileProvider and an activity to start it from.
  static const MethodChannel _channel =
      MethodChannel('site.spencersmith.council/updates');

  /// Never call this with a file that has not been through
  /// `UpdateService.download`, which is what proves the bytes are the ones
  /// published. Everything below runs the file.
  static Future<InstallResult> install(File file) async {
    try {
      if (Platform.isAndroid) return await _android(file);
      if (Platform.isMacOS) return await _macos(file);
      if (Platform.isWindows) return await _windows(file);
      if (Platform.isLinux) return await _linux(file);
      return InstallResult(InstallOutcome.failed,
          path: file.path,
          message: 'Updates are installed elsewhere on this platform.');
    } catch (e) {
      return InstallResult(InstallOutcome.failed,
          path: file.path, message: '$e');
    }
  }

  /// Opens TestFlight or the App Store. iOS only — an iOS app cannot install
  /// anything, itself least of all.
  static Future<bool> openStore(PlatformRelease release) async {
    try {
      return await launchUrl(release.url,
          mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open the store page: $e');
      return false;
    }
  }

  /// The package installer, via an intent the native side raises.
  ///
  /// Android will refuse outright unless the app holds
  /// REQUEST_INSTALL_PACKAGES *and* the reader has allowed it to install
  /// unknown apps, which is a per-app switch buried in Settings. The native
  /// side checks and opens that page rather than letting the intent fail
  /// silently, which is what it does otherwise — no dialog, no error, nothing.
  static Future<InstallResult> _android(File file) async {
    final answer =
        await _channel.invokeMethod<String>('install', {'path': file.path});
    return switch (answer) {
      'installing' => InstallResult(InstallOutcome.handedOff, path: file.path),
      'permission' =>
        InstallResult(InstallOutcome.needsPermission, path: file.path),
      _ => InstallResult(InstallOutcome.failed,
          path: file.path,
          message: 'Android would not open the installer ($answer).'),
    };
  }

  /// Mounts the disk image, leaving the reader with the usual drag-to-
  /// Applications window.
  ///
  /// Through url_launcher rather than `open`, because the Mac build is
  /// sandboxed: spawning `/usr/bin/open` from inside the sandbox is not
  /// reliable, whereas url_launcher goes through NSWorkspace, which is an
  /// out-of-process request to LaunchServices and is allowed. `open` remains as
  /// a fallback for the unsandboxed case rather than as the first choice.
  static Future<InstallResult> _macos(File file) async {
    final uri = Uri.file(file.path);
    try {
      if (await launchUrl(uri)) {
        return InstallResult(InstallOutcome.handedOff, path: file.path);
      }
    } catch (e) {
      debugPrint('NSWorkspace would not open the disk image: $e');
    }
    final result = await Process.run('open', [file.path]);
    if (result.exitCode == 0) {
      return InstallResult(InstallOutcome.handedOff, path: file.path);
    }
    return InstallResult(InstallOutcome.failed,
        path: file.path, message: 'Could not open the disk image.');
  }

  /// Starts the installer and detaches from it.
  ///
  /// Detached matters: the installer has to outlive this process, because it
  /// cannot overwrite Council's own executable while Council is running. The
  /// caller quits immediately afterwards, which is why the button that leads
  /// here says so.
  static Future<InstallResult> _windows(File file) async {
    await Process.start(file.path, const [],
        mode: ProcessStartMode.detached);
    return InstallResult(InstallOutcome.handedOff, path: file.path);
  }

  /// Marks the AppImage executable and opens the folder holding it.
  ///
  /// Not an installation, and not pretending to be one. A running AppImage is a
  /// mounted image of the very file that would have to be replaced, so
  /// overwriting it from inside itself corrupts the running process. Leaving
  /// the new one ready to run, with the folder open, is the honest outcome —
  /// and the reason this returns [InstallOutcome.saved] rather than
  /// [InstallOutcome.handedOff], so the UI can say what is left to do.
  static Future<InstallResult> _linux(File file) async {
    await Process.run('chmod', ['+x', file.path]);
    final directory = p.dirname(file.path);
    // Best effort. A headless or minimal desktop may have no xdg-open, and the
    // path shown in the UI is enough to find it either way.
    try {
      await Process.run('xdg-open', [directory]);
    } catch (_) {}
    return InstallResult(InstallOutcome.saved, path: file.path);
  }
}
