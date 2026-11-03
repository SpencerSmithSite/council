/// How the Flutter app's `shared_preferences` are laid out on Apple platforms.
public enum FlutterPreferences {
    /// The plugin stores every key in `UserDefaults.standard` with this prefix,
    /// so the native app finds the old settings under `flutter.<key>`.
    public static let keyPrefix = "flutter."

    public static func defaultsKey(_ key: String) -> String {
        keyPrefix + key
    }
}
