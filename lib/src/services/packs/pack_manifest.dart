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
  /// Informational now. It moves whenever the corpus is rebuilt, which is not
  /// the question the app has to answer before merging — see [idSpace].
  final int corpusVersion;

  /// Which assignment of row ids these fragments belong to.
  ///
  /// Fragments keep the ids they were given when they were built, and that is
  /// what makes them safe to merge without renumbering. What has to hold is
  /// that **no id a fragment carries already means something else on this
  /// device** — not that the fragment and the app were built together.
  ///
  /// Those came to the same thing while packs were gated on [corpusVersion],
  /// and it cost more than it protected: every corpus change, however careful,
  /// was unreachable until the app itself was released again. A rebuild that
  /// only appends leaves every id already in the field meaning exactly what it
  /// meant, so its packs merge safely into an app built against the previous
  /// corpus. `tools/build_packs.py` proves that per build and only advances
  /// this number when a rebuild genuinely reassigns an id.
  final int idSpace;
  final List<Fragment> fragments;
  final List<Collection> collections;

  const PackManifest({
    required this.corpusVersion,
    required this.idSpace,
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
      // Absent from catalogues published before packs were decoupled from app
      // releases. Those all belong to the first id space by definition — it
      // was numbered 1 at the build where the ledger began.
      idSpace: json['idSpace'] as int? ?? 1,
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
