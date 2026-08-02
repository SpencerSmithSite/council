import 'dart:io';

import 'package:flutter/services.dart';

/// How much free disk space this device has.
///
/// The catalogue reasoned about memory and said nothing about storage, so a
/// reader with 3 GB free could start the 4.9 GB download. It failed loudly
/// rather than silently — the installer errors and the card shows it — but only
/// after the bytes had been fetched, which on a metered connection is a real
/// cost paid for nothing.
///
/// Unlike memory, this is worth *warning* about rather than hiding a model for:
/// a reader can delete photos and try again, but cannot add RAM. So a model too
/// large for the disk stays visible with its download disabled and the numbers
/// shown, rather than disappearing.
class DeviceStorage {
  static const MethodChannel _channel =
      MethodChannel('site.spencersmith.council/device');

  /// Not cached. Free space is the one device fact that changes while the app
  /// is open — often *because* the reader went to free some up — so a stale
  /// answer here would tell them their effort had not worked.
  static Future<int?> freeMb() async {
    if (debugUnknownFree) return null;
    if (debugFreeMb != null) return debugFreeMb;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      return _desktopFreeMb();
    }
    try {
      final mb = await _channel.invokeMethod<int>('freeDiskMb');
      if (mb != null && mb >= 0) return mb;
    } on MissingPluginException {
      // A build predating the channel.
    } catch (_) {
      // Never worth failing a screen over.
    }
    return null;
  }

  /// Read from the OS rather than through a channel, so the Windows C++ runner
  /// and the macOS/Linux embedders need no native code for one number.
  static Future<int?> _desktopFreeMb() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r'(Get-PSDrive -Name (Get-Location).Drive.Name).Free',
        ]);
        final bytes = int.tryParse((r.stdout as String).trim());
        return bytes == null ? null : bytes ~/ (1024 * 1024);
      }
      // `df -Pk .` — POSIX output, so the columns are stable across macOS and
      // Linux. Available blocks are the fourth field of the second line.
      final r = await Process.run('df', ['-Pk', Directory.current.path]);
      final lines = (r.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final fields = lines[1].split(RegExp(r'\s+'));
      if (fields.length < 4) return null;
      final kb = int.tryParse(fields[3]);
      return kb == null ? null : kb ~/ 1024;
    } catch (_) {
      return null;
    }
  }

  /// Whether [requiredMb] can be written, with headroom.
  ///
  /// Permissive when free space cannot be read, for the same reason
  /// `DeviceMemory` is: refusing a download because a probe failed is worse
  /// than letting one fail the way it already did.
  static Future<bool> hasRoomFor(int requiredMb) async {
    final free = await freeMb();
    return free == null || free >= requiredMb + _headroomMb;
  }

  /// Filling a disk to the last megabyte breaks the OS, not just this app, and
  /// the model is not the only thing being written — the download lands as a
  /// file and is then installed.
  static const int _headroomMb = 500;

  /// Test seam. [debugUnknownFree] is separate from a null [debugFreeMb],
  /// and has to be: null merely means "no override", and on a real machine the
  /// next call then reads the actual disk — which is not the same as a device
  /// that could not answer.
  static int? debugFreeMb;
  static bool debugUnknownFree = false;
}
