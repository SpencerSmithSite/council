import 'package:flutter/foundation.dart';

import '../database_service.dart';
import 'pack_catalogue.dart';
import 'pack_manifest.dart';
import 'pack_service.dart';

/// UI state for the content library.
class PackProvider extends ChangeNotifier {
  final PackService _service;

  /// Bundled description of what every pack holds, so the app can say what it
  /// is missing without a network call.
  final PackCatalogue catalogue;

  PackProvider(this._service, this.catalogue);

  /// Load what is already installed.
  ///
  /// Separate from [refresh] because it needs no network: the coverage notice
  /// has to work on first launch, offline, before anyone opens the Library.
  Future<void> loadInstalled() async {
    _installed = await _service.installedCollections();
    _fragments = await _service.installedFragments();
    notifyListeners();
  }

  /// Which uninstalled collections would have helped answer [question].
  ///
  /// The app can only search text it holds, so without this a library missing
  /// the fathers answers a question about the Eucharist from confessions
  /// alone — fluent, well-cited, and drawn from under a tenth of what exists.
  List<PackSuggestion> coverageGapsFor(String question, List<String> tags) =>
      catalogue.suggest(
        question: question,
        queryTags: tags,
        installedFragments: _fragments,
      );

  /// The human-readable name of a pack, for a notice that names it.
  String nameOf(String packId) {
    final bundled = catalogue.packs[packId]?.name;
    if (bundled != null && bundled.isNotEmpty) return bundled;
    return packId;
  }

  PackManifest? _manifest;
  Set<String> _installed = {};
  Set<String> _fragments = {};
  String? _error;
  bool _loading = false;

  /// Pack id currently downloading, and its progress in 0..1.
  String? _busyId;
  double _progress = 0;

  PackManifest? get manifest => _manifest;
  Set<String> get installed => _installed;

  /// Fragments physically present, as opposed to collections the reader chose.
  Set<String> get installedFragments => _fragments;

  /// What this collection would actually cost to add now.
  ///
  /// Zero is a real and common answer: someone holding "Church Fathers"
  /// already has every fragment "Augustine of Hippo" needs, and quoting a
  /// download that will not happen would be a lie the library tells routinely.
  int bytesToInstall(Collection collection) =>
      _manifest?.bytesToInstall(collection, _fragments) ?? 0;
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

    _installed = await _service.installedCollections();
    _fragments = await _service.installedFragments();
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

  Future<void> install(Collection collection) async {
    final manifest = _manifest;
    if (manifest == null || _busyId != null) return;

    _busyId = collection.id;
    _progress = 0;
    _error = null;
    notifyListeners();

    try {
      await _service.install(
        collection,
        manifest,
        corpusVersion: DatabaseService.corpusVersion,
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
      _installed = await _service.installedCollections();
      _fragments = await _service.installedFragments();
    } catch (error) {
      _error = '$error';
    } finally {
      _busyId = null;
      _progress = 0;
      notifyListeners();
    }
  }

  Future<void> uninstall(Collection collection) async {
    if (_busyId != null) return;
    _busyId = collection.id;
    _error = null;
    notifyListeners();

    try {
      await _service.uninstall(collection.id);
      _installed = await _service.installedCollections();
      _fragments = await _service.installedFragments();
    } catch (error) {
      _error = '$error';
    } finally {
      _busyId = null;
      notifyListeners();
    }
  }
}
