import 'dart:io';

import 'package:flutter/services.dart';

/// How much physical memory this device has.
///
/// Exists because the downloadable-model catalogue declares a `minDeviceRamMb`
/// per model and, until this, nothing read it. The consequence was concrete
/// rather than theoretical: a 2 GB iPhone 8 — which can install Council, since
/// iOS 16 is its ceiling and that is the app's floor — was offered a 2.1 GB
/// model declaring a requirement of 8 GB. It would have downloaded in full and
/// then been killed by the OS on first use, and those older phones are exactly
/// who the downloadable model exists for, since Apple Intelligence covers the
/// new ones.
///
/// Dart cannot read this portably, so it comes from the platform:
/// `ProcessInfo.processInfo.physicalMemory` on Apple, `ActivityManager
/// .MemoryInfo.totalMem` on Android, `sysctl hw.memsize` / `/proc/meminfo` on
/// desktop.
class DeviceMemory {
  static const MethodChannel _channel =
      MethodChannel('site.spencersmith.council/device');

  static int? _cachedMb;
  static bool _debugUnknown = false;

  /// Physical memory in megabytes, or null if it could not be determined.
  ///
  /// Null is deliberately distinct from a small number: an unknown amount must
  /// not be treated as "too little", because hiding every model from a device
  /// that merely failed to answer is worse than offering one it might not run.
  /// Callers should be permissive on null — see [meets].
  static Future<int?> totalMb() async {
    if (_debugUnknown) return null;
    if (_cachedMb != null) return _cachedMb;

    // Desktop needs no channel: the values are readable from the OS directly,
    // and doing it here keeps three native implementations from having to
    // exist for platforms where a shell call is exact.
    if (Platform.isMacOS || Platform.isLinux) {
      final fromHost = await _desktopTotalMb();
      if (fromHost != null) return _cachedMb = fromHost;
    }

    try {
      final mb = await _channel.invokeMethod<int>('totalMemoryMb');
      if (mb != null && mb > 0) return _cachedMb = mb;
    } on MissingPluginException {
      // A platform with no implementation, or a build predating it.
    } catch (_) {
      // Never worth failing a screen over.
    }
    return null;
  }

  static Future<int?> _desktopTotalMb() async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
        final bytes = int.tryParse((r.stdout as String).trim());
        return bytes == null ? null : bytes ~/ (1024 * 1024);
      }
      // /proc/meminfo reports MemTotal in kB.
      final line = await File('/proc/meminfo')
          .readAsLines()
          .then((l) => l.firstWhere((s) => s.startsWith('MemTotal:')));
      final kb = int.tryParse(line.split(RegExp(r'\s+'))[1]);
      return kb == null ? null : kb ~/ 1024;
    } catch (_) {
      return null;
    }
  }

  /// Whether this device has at least [requiredMb].
  ///
  /// Permissive when the amount is unknown, for the reason in [totalMb].
  static Future<bool> meets(int requiredMb) async {
    final mb = await totalMb();
    return mb == null || mb >= requiredMb;
  }

  /// Test seam.
  ///
  /// [unknown] is separate from passing null, and has to be: null merely clears
  /// the cache, and on a desktop host the next call reads the real machine —
  /// which is not the same as a device that could not answer.
  static void debugSetTotalMb(int? mb, {bool unknown = false}) {
    _cachedMb = mb;
    _debugUnknown = unknown;
  }
}
