import Foundation

/// Where downloadable packs are published. Mirrors `PackService` in
/// lib/src/services/packs/pack_service.dart.
public enum PackEndpoints {
    /// GitHub Releases: static, free, CDN-backed hosting; no backend needed.
    public static let defaultManifestURL = URL(
        string: "https://github.com/SpencerSmithSite/council/releases/latest/download/manifest.json"
    )!
}
