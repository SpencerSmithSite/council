import 'dart:convert';

/// One downloadable body of content, as described by the published manifest.
class PackInfo {
  final String id;
  final String name;
  final String description;
  final String file;
  final int bytes;
  final String sha256;
  final int sources;
  final int units;
  final int chunks;

  const PackInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.file,
    required this.bytes,
    required this.sha256,
    required this.sources,
    required this.units,
    required this.chunks,
  });

  factory PackInfo.fromJson(Map<String, dynamic> json) => PackInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        file: json['file'] as String,
        bytes: json['bytes'] as int,
        sha256: json['sha256'] as String,
        sources: json['sources'] as int? ?? 0,
        units: json['units'] as int? ?? 0,
        chunks: json['chunks'] as int? ?? 0,
      );

  /// Download size, for a UI that is asking someone to spend their data.
  String get sizeLabel {
    const mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).round()} KB';
  }
}

/// The published list of packs, for one specific corpus build.
class PackManifest {
  /// The corpus these packs were split from.
  ///
  /// Packs are a partition of a single build and keep the ids they were given
  /// in it, which is what makes them safe to install without renumbering. A
  /// pack from a different build can carry ids the app has already used for
  /// different text, so a mismatch here is refused rather than reconciled.
  final int corpusVersion;
  final List<PackInfo> packs;

  const PackManifest({required this.corpusVersion, required this.packs});

  factory PackManifest.parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    return PackManifest(
      corpusVersion: json['corpusVersion'] as int,
      packs: (json['packs'] as List)
          .map((p) => PackInfo.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Why a pack could not be installed. Thrown rather than returned so a partial
/// install cannot be mistaken for a successful one.
class PackException implements Exception {
  final String message;
  const PackException(this.message);
  @override
  String toString() => message;
}
