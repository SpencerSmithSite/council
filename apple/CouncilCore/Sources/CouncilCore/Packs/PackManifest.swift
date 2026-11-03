// Ported from lib/src/services/packs/pack_manifest.dart.

import Foundation

/// One downloadable file: a disjoint slice of the corpus.
///
/// Fragments are never shown to the reader. They exist so that a body of text
/// is published exactly once no matter how many collections reference it.
public struct PackFragment: Equatable, Sendable, Decodable {
    public let id: String
    public let file: String
    /// Size of the compressed file. Drives progress and size display only; it
    /// is never compared with what was downloaded.
    public let bytes: Int
    /// SHA-256 of the compressed `.gz` bytes, lowercase hex.
    public let sha256: String
    public let sources: Int
    public let units: Int
    public let chunks: Int

    public init(id: String, file: String, bytes: Int, sha256: String, sources: Int = 0, units: Int = 0, chunks: Int = 0) {
        self.id = id
        self.file = file
        self.bytes = bytes
        self.sha256 = sha256
        self.sources = sources
        self.units = units
        self.chunks = chunks
    }

    private enum CodingKeys: String, CodingKey { case id, file, bytes, sha256, sources, units, chunks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        bytes = try c.decode(Int.self, forKey: .bytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        sources = try c.decodeIfPresent(Int.self, forKey: .sources) ?? 0
        units = try c.decodeIfPresent(Int.self, forKey: .units) ?? 0
        chunks = try c.decodeIfPresent(Int.self, forKey: .chunks) ?? 0
    }
}

/// How collections are grouped in the library.
public enum CollectionKind: String, Sendable, CaseIterable {
    case essential, era, author, tradition, scripture, other

    /// Anything unrecognised, or absent, is `other`, so a newer catalogue
    /// with a new grouping still loads.
    public init(raw: String) {
        self = CollectionKind(rawValue: raw) ?? .other
    }
}

/// What the reader actually chooses.
///
/// A collection owns no text — only a list of fragment ids — which is what
/// lets the same work belong to several. Augustine sits in "Augustine of
/// Hippo", "Church Fathers", "Nicene & Post-Nicene Writers" and "Catholic";
/// were those separate files he would be published four times over and
/// downloaded twice by anyone who took two of them.
///
/// (`Collection` in Dart; renamed because Swift's standard library owns that
/// name.)
public struct PackCollection: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let description: String
    public let kind: CollectionKind
    public let fragments: [String]

    public init(id: String, name: String, description: String = "", kind: CollectionKind = .other, fragments: [String]) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.fragments = fragments
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, kind, fragments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = CollectionKind(raw: try c.decodeIfPresent(String.self, forKey: .kind) ?? "")
        fragments = try c.decode([String].self, forKey: .fragments)
    }
}

/// The published catalogue, for one specific corpus build.
public struct PackManifest: Equatable, Sendable, Decodable {
    /// The corpus these fragments were split from.
    ///
    /// Informational now. It moves whenever the corpus is rebuilt, which is not
    /// the question the app has to answer before merging — see `idSpace`.
    public let corpusVersion: Int

    /// Which assignment of row ids these fragments belong to.
    ///
    /// Fragments keep the ids they were given when they were built, and that is
    /// what makes them safe to merge without renumbering. What has to hold is
    /// that **no id a fragment carries already means something else on this
    /// device** — not that the fragment and the app were built together.
    ///
    /// Those came to the same thing while packs were gated on `corpusVersion`,
    /// and it cost more than it protected: every corpus change, however careful,
    /// was unreachable until the app itself was released again. A rebuild that
    /// only appends leaves every id already in the field meaning exactly what it
    /// meant, so its packs merge safely into an app built against the previous
    /// corpus. `tools/build_packs.py` proves that per build and only advances
    /// this number when a rebuild genuinely reassigns an id.
    public let idSpace: Int

    /// Which embedding model produced the vectors in these packs.
    ///
    /// Vectors from two models are not comparable — the similarity between them
    /// is noise, not a weaker signal — so a pack built with a different model
    /// than this app encodes queries with must be refused. The failure it
    /// prevents is silent: every count and checksum would still be correct and
    /// retrieval would simply start returning irrelevant passages.
    ///
    /// Nil on catalogues published before this was recorded, which all belong
    /// to the original model by definition.
    public let embeddingModel: String?

    public let fragments: [PackFragment]
    public let collections: [PackCollection]

    public init(
        corpusVersion: Int,
        idSpace: Int,
        embeddingModel: String? = nil,
        fragments: [PackFragment],
        collections: [PackCollection]
    ) {
        self.corpusVersion = corpusVersion
        self.idSpace = idSpace
        self.embeddingModel = embeddingModel
        self.fragments = fragments
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey { case corpusVersion, idSpace, embeddingModel, fragments, collections }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        corpusVersion = try c.decode(Int.self, forKey: .corpusVersion)
        // Absent from catalogues published before packs were decoupled from app
        // releases. Those all belong to the first id space by definition — it
        // was numbered 1 at the build where the ledger began.
        idSpace = try c.decodeIfPresent(Int.self, forKey: .idSpace) ?? 1
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        fragments = try c.decode([PackFragment].self, forKey: .fragments)
        collections = try c.decode([PackCollection].self, forKey: .collections)
    }

    /// Parse a published `manifest.json`.
    ///
    /// Throws on anything malformed rather than yielding an empty catalogue:
    /// nothing would render as "no content is published yet", which is
    /// indistinguishable from a healthy empty library.
    public static func parse(_ body: Data) throws -> PackManifest {
        try JSONDecoder().decode(PackManifest.self, from: body)
    }

    public static func parse(_ body: String) throws -> PackManifest {
        try parse(Data(body.utf8))
    }

    /// Whether these packs' vectors can be used by an app encoding queries with
    /// `localModel`. Older catalogues carry no identity and are trusted, because
    /// they predate any model change.
    public func embeddingsCompatible(with localModel: String) -> Bool {
        embeddingModel == nil || embeddingModel == localModel
    }

    /// The first fragment with this id, as Dart's linear search returns.
    public func fragment(_ id: String) -> PackFragment? {
        fragments.first { $0.id == id }
    }

    /// The collection with this id, if the catalogue lists it.
    public func collection(_ id: String) -> PackCollection? {
        collections.first { $0.id == id }
    }

    /// What installing `collection` would actually cost, given what is already
    /// on the device.
    ///
    /// Not a fixed property of the collection: someone who already has "Church
    /// Fathers" pays nothing for "Augustine of Hippo", and the library should
    /// say so rather than quoting a download it will not perform.
    public func bytesToInstall(_ collection: PackCollection, installedFragments: Set<String>) -> Int {
        var total = 0
        for id in collection.fragments where !installedFragments.contains(id) {
            total += fragment(id)?.bytes ?? 0
        }
        return total
    }

    /// A size as the library shows it: "10.0 MB", "41 KB", "512 B".
    ///
    /// `formatBytes` in Dart. One decimal place for megabytes, whole kilobytes
    /// rounded half away from zero, as Dart's `toStringAsFixed(1)` and
    /// `round()` do.
    public static func formatBytes(_ bytes: Int) -> String {
        let mb = 1024 * 1024
        if bytes >= mb { return String(format: "%.1f MB", Double(bytes) / Double(mb)) }
        if bytes >= 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return "\(bytes) B"
    }
}
