import 'dart:convert';

/// One downloadable file: a disjoint slice of the corpus.
///
/// Fragments are never shown to the reader. They exist so that a body of text
/// is published exactly once no matter how many collections reference it.
class Fragment {
  final String id;
  final String file;
  final int bytes;
  final String sha256;
  final int sources;
  final int units;
  final int chunks;

  const Fragment({
    required this.id,
    required this.file,
    required this.bytes,
    required this.sha256,
    required this.sources,
    required this.units,
    required this.chunks,
  });

  factory Fragment.fromJson(Map<String, dynamic> json) => Fragment(
        id: json['id'] as String,
        file: json['file'] as String,
        bytes: json['bytes'] as int,
        sha256: json['sha256'] as String,
        sources: json['sources'] as int? ?? 0,
        units: json['units'] as int? ?? 0,
        chunks: json['chunks'] as int? ?? 0,
      );
}

/// How collections are grouped in the library.
enum CollectionKind { essential, era, author, tradition, scripture, other }

CollectionKind _kindOf(String raw) => switch (raw) {
      'essential' => CollectionKind.essential,
      'era' => CollectionKind.era,
      'author' => CollectionKind.author,
      'tradition' => CollectionKind.tradition,
      'scripture' => CollectionKind.scripture,
      _ => CollectionKind.other,
    };

/// What the reader actually chooses.
///
/// A collection owns no text — only a list of fragment ids — which is what
/// lets the same work belong to several. Augustine sits in "Augustine of
/// Hippo", "Church Fathers", "Nicene & Post-Nicene Writers" and "Catholic";
/// were those separate files he would be published four times over and
/// downloaded twice by anyone who took two of them.
class Collection {
  final String id;
  final String name;
  final String description;
  final CollectionKind kind;
  final List<String> fragments;

  const Collection({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    required this.fragments,
  });

  factory Collection.fromJson(Map<String, dynamic> json) => Collection(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        kind: _kindOf(json['kind'] as String? ?? ''),
        fragments: (json['fragments'] as List).cast<String>(),
      );
}

/// The published catalogue, for one specific corpus build.
class PackManifest {
  /// The corpus these fragments were split from.
  ///
  /// Fragments keep the ids they were given in that build, which is what makes
  /// them safe to merge without renumbering. A fragment from a different build
  /// can carry ids the app has already used for different text, so a mismatch
  /// is refused rather than reconciled.
  final int corpusVersion;
  final List<Fragment> fragments;
  final List<Collection> collections;

  const PackManifest({
    required this.corpusVersion,
    required this.fragments,
    required this.collections,
  });

  Fragment? fragment(String id) {
    for (final f in fragments) {
      if (f.id == id) return f;
    }
    return null;
  }

  factory PackManifest.parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    return PackManifest(
      corpusVersion: json['corpusVersion'] as int,
      fragments: (json['fragments'] as List)
          .map((f) => Fragment.fromJson(f as Map<String, dynamic>))
          .toList(),
      collections: (json['collections'] as List)
          .map((c) => Collection.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }

  /// What installing [collection] would actually cost, given what is already
  /// on the device.
  ///
  /// Not a fixed property of the collection: someone who already has "Church
  /// Fathers" pays nothing for "Augustine of Hippo", and the library should
  /// say so rather than quoting a download it will not perform.
  int bytesToInstall(Collection collection, Set<String> installedFragments) {
    var total = 0;
    for (final id in collection.fragments) {
      if (installedFragments.contains(id)) continue;
      total += fragment(id)?.bytes ?? 0;
    }
    return total;
  }
}

String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}

/// Why a pack operation could not complete. Thrown rather than returned so a
/// partial install cannot be mistaken for a successful one.
class PackException implements Exception {
  final String message;
  const PackException(this.message);
  @override
  String toString() => message;
}
