import 'package:flutter/foundation.dart';

import '../database_service.dart';
import 'pack_manifest.dart';
import 'pack_service.dart';

/// UI state for the content library.
class PackProvider extends ChangeNotifier {
  final PackService _service;

  PackProvider(this._service);

  PackManifest? _manifest;
  Set<String> _installed = {};
  String? _error;
  bool _loading = false;

  /// Pack id currently downloading, and its progress in 0..1.
  String? _busyId;
  double _progress = 0;

  PackManifest? get manifest => _manifest;
  Set<String> get installed => _installed;
  String? get error => _error;
  bool get loading => _loading;
  String? get busyId => _busyId;
  double get progress => _progress;

  bool isInstalled(String id) => _installed.contains(id);

  /// Load what is installed, then what is available.
  ///
  /// Installed packs come from the local database and are shown even when the
  /// network fetch fails: someone offline should still see, and be able to
  /// remove, the content they already have.
  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();

    _installed = await _service.installedIds();
    notifyListeners();

    try {
      _manifest = await _service.fetchManifest();
    } catch (error) {
      _error = 'Could not load the list of available content. $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> install(PackInfo pack) async {
    final manifest = _manifest;
    if (manifest == null || _busyId != null) return;

    _busyId = pack.id;
    _progress = 0;
    _error = null;
    notifyListeners();

    try {
      await _service.install(
        pack,
        corpusVersion: DatabaseService.corpusVersion,
        manifestCorpusVersion: manifest.corpusVersion,
        onProgress: (received, total) {
          if (total <= 0) return;
          final next = received / total;
          // Notifying on every chunk rebuilds the list hundreds of times a
          // second for no visible gain.
          if (next - _progress >= 0.01 || next >= 1) {
            _progress = next;
            notifyListeners();
          }
        },
      );
      _installed = await _service.installedIds();
    } catch (error) {
      _error = '$error';
    } finally {
      _busyId = null;
      _progress = 0;
      notifyListeners();
    }
  }

  Future<void> uninstall(PackInfo pack) async {
    if (_busyId != null) return;
    _busyId = pack.id;
    _error = null;
    notifyListeners();

    try {
      await _service.uninstall(pack.id);
      _installed = await _service.installedIds();
    } catch (error) {
      _error = '$error';
    } finally {
      _busyId = null;
      notifyListeners();
    }
  }
}
