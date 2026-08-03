import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_version.dart';
import 'release_manifest.dart';
import 'update_installer.dart';
import 'update_service.dart';

/// Where an update has got to.
enum UpdateStage {
  /// Nothing known yet, or the last check found nothing.
  idle,
  checking,

  /// A newer release exists and is waiting to be accepted.
  available,
  downloading,

  /// Downloaded and verified, waiting to be handed to the OS.
  ready,

  /// Handed over — the installer, the disk image or the store page is up.
  handedOff,
  failed,
}

/// The app's knowledge of whether it is out of date.
///
/// Reactive because two places need the same answer and must not each go and
/// ask: the sheet raised at launch, and the Settings row that says which
/// version is installed and lets someone check on demand.
class UpdateProvider extends ChangeNotifier {
  final UpdateService _service;

  UpdateProvider({UpdateService? service})
      : _service = service ?? UpdateService();

  UpdateStage _stage = UpdateStage.idle;
  PlatformRelease? _release;
  AppVersion? _current;
  File? _downloaded;
  String? _error;
  int _received = 0;
  int _total = 0;

  /// True once the launch check has run, so it runs once per launch and not
  /// again on every rebuild of the screen that triggers it.
  bool _checkedThisLaunch = false;

  UpdateStage get stage => _stage;

  /// The newer release, when there is one.
  PlatformRelease? get release => _release;

  /// The installed version, for display. Null until first read.
  AppVersion? get currentVersion => _current;

  String? get error => _error;

  /// Where a verified download is waiting.
  File? get downloadedFile => _downloaded;

  /// True while a check or a download is in flight.
  bool get busy =>
      _stage == UpdateStage.checking || _stage == UpdateStage.downloading;

  /// Download progress from 0 to 1, or null when the total size is not yet
  /// known — an indeterminate bar is the honest thing to show then, and this is
  /// exactly the mistake the model download made by drawing a full bar
  /// throughout.
  double? get progress {
    if (_stage != UpdateStage.downloading) return null;
    if (_total <= 0) return null;
    return (_received / _total).clamp(0.0, 1.0);
  }

  int get receivedBytes => _received;
  int get totalBytes => _total;

  /// True when this platform hands off to a store rather than installing.
  bool get goesToStore => _release?.delivery == ReleaseDelivery.store;

  Future<void> loadCurrentVersion() async {
    if (_current != null) return;
    _current = await _service.currentVersion();
    notifyListeners();
  }

  /// The once-per-launch check.
  ///
  /// Silent about everything except finding something: no spinner, no error,
  /// nothing on a device with no network. It was not asked for, so it must not
  /// interrupt.
  Future<void> checkOnLaunch({required bool enabled}) async {
    if (_checkedThisLaunch || !enabled) return;
    _checkedThisLaunch = true;
    await check(quiet: true);
  }

  /// [quiet] suppresses the checking state and any error, for the launch check.
  /// A reader who pressed "Check for updates" gets both.
  Future<void> check({bool quiet = false}) async {
    if (busy) return;
    if (!quiet) {
      _stage = UpdateStage.checking;
      _error = null;
      notifyListeners();
    }

    _current ??= await _service.currentVersion();
    final found = await _service.check();

    _release = found;
    _stage = found == null ? UpdateStage.idle : UpdateStage.available;
    notifyListeners();
  }

  /// Fetches the update and verifies it. On a store platform this is not the
  /// route — see [openStore].
  Future<void> download() async {
    final release = _release;
    if (release == null || busy) return;

    _stage = UpdateStage.downloading;
    _error = null;
    _received = 0;
    _total = release.bytes ?? 0;
    notifyListeners();

    try {
      _downloaded = await _service.download(release, onProgress: (got, total) {
        _received = got;
        if (total > 0) _total = total;
        notifyListeners();
      });
      _stage = UpdateStage.ready;
    } on UpdateCancelled {
      // Their own doing: back to the offer, with nothing said about it.
      _stage = UpdateStage.available;
      _received = 0;
    } on UpdateException catch (e) {
      _error = e.message;
      _stage = UpdateStage.failed;
    } catch (e) {
      _error = '$e';
      _stage = UpdateStage.failed;
    }
    notifyListeners();
  }

  void cancelDownload() => _service.cancel();

  /// Hands the verified file to the operating system.
  ///
  /// Returns what happened so the screen can say the right thing — on Windows
  /// the app has to quit for the installer to be able to replace it, and on
  /// Linux there is nothing to hand off to at all.
  Future<InstallResult?> install() async {
    final file = _downloaded;
    if (file == null) return null;

    final result = await UpdateInstaller.install(file);
    if (result.outcome == InstallOutcome.failed) {
      _error = result.message;
      _stage = UpdateStage.failed;
    } else {
      _stage = UpdateStage.handedOff;
    }
    notifyListeners();
    return result;
  }

  /// iOS: TestFlight or the App Store.
  Future<bool> openStore() async {
    final release = _release;
    if (release == null) return false;
    final opened = await UpdateInstaller.openStore(release);
    if (opened) {
      _stage = UpdateStage.handedOff;
      notifyListeners();
    }
    return opened;
  }

  /// Puts the offer away for this launch. It comes back next time, since the
  /// app is still out of date — but nagging twice in one sitting is not how to
  /// make that point.
  void dismiss() {
    if (_stage == UpdateStage.available || _stage == UpdateStage.failed) {
      _stage = UpdateStage.idle;
      _release = null;
      _error = null;
      notifyListeners();
    }
  }
}
