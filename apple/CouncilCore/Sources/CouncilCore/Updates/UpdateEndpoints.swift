import Foundation

/// Mirrors the constants of `UpdateService` in
/// lib/src/services/updates/update_service.dart.
public enum UpdateEndpoints {
    /// Served from the site, not the GitHub releases API: app releases are
    /// marked pre-release there, so `releases/latest` resolves to the corpus
    /// content releases instead, and there is no stable "latest" URL for the
    /// app to follow. A static file is also one request with no rate limit,
    /// which matters when every launch makes it.
    public static let manifestURL = URL(
        string: "https://www.spencersmith.site/council/updates.json"
    )!

    /// Short, and deliberately so (Dart's `checkTimeout`). The check runs at
    /// launch: one that can't be answered quickly is abandoned quietly rather
    /// than kept alive on the chance the network comes back. Also how long a
    /// download may take to *start*.
    public static let checkTimeout: Duration = .seconds(12)

    /// How long a download may go without a byte before it is called stalled
    /// (Dart's `chunkTimeout`). Per chunk, not for the whole file: it fires on
    /// a connection that stops moving, not on one that is merely slow.
    public static let chunkTimeout: Duration = .seconds(120)
}

/// Where the update check keeps its setting.
///
/// `auto_check_updates`, a Bool, unprefixed as the app's other preferences
/// are (see `FlutterPreferences`; Phase 7 copies `flutter.auto_check_updates`
/// across). On by default, and the default is the point (Dart's
/// `SettingsService.getAutoCheckUpdates`): the Mac app is a direct download, so
/// nothing else tells a reader a new build exists, and off by default would
/// leave most installs on whatever version they first downloaded.
///
/// `Sendable` although `UserDefaults` isn't marked so: it is documented as
/// thread-safe, and this holds nothing else.
public struct UpdatePreferences: Sendable {
    public static let autoCheckKey = "auto_check_updates"

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var autoCheck: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }
}
