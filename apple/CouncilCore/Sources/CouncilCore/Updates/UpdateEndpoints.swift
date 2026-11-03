import Foundation

/// Mirrors `UpdateService` in lib/src/services/updates/update_service.dart.
public enum UpdateEndpoints {
    /// Served from the site, not the GitHub releases API: app releases are
    /// marked pre-release there, so `releases/latest` resolves to the corpus
    /// content releases instead.
    public static let manifestURL = URL(
        string: "https://www.spencersmith.site/council/updates.json"
    )!
}
