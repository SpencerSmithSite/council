// Ports the rest of lib/src/services/settings_service.dart: `show_citations`
// and `clearAll`. The theme keys are `ThemePreferenceKeys`, the reading keys
// `ReaderPreferences.Key`, the AI keys `InferenceSettings.Key`.

import Foundation

/// The app-wide preferences that have no store of their own, and what "Reset
/// All Settings" clears.
///
/// Keys are the Flutter app's, unprefixed (see `FlutterPreferences`), so
/// Phase 7 carries a reader's choices across.
public enum AppSettings {
    /// Whether answers list their sources underneath. A `Bool`, true when
    /// absent: `getShowCitations` in the Dart.
    public static let showCitationsKey = "show_citations"
    public static let defaultShowCitations = true

    /// Whether to look for a newer build at launch. Owned by the updates
    /// section; named here only so a reset clears it, as Dart's `clearAll`
    /// does.
    public static let autoCheckUpdatesKey = "auto_check_updates"

    /// Exactly what `SettingsService.clearAll` removes, legacy theme keys
    /// included (`dark_mode`, `theme_choice`), so a reset leaves the same
    /// preferences behind in both apps.
    public static let flutterResetKeys: [String] = [
        "dark_mode",
        "theme_choice",
        ThemePreferenceKeys.mode,
        ThemePreferenceKeys.themeID,
        ReaderPreferences.Key.fontSize,
        showCitationsKey,
        autoCheckUpdatesKey,
    ]

    /// The native app's own settings, which Flutter doesn't have: the
    /// reading controls' face, spacing, margins and justification. Settings,
    /// not data, so a reset clears them with `font_size` beside them.
    public static let nativeResetKeys: [String] = [
        ReaderPreferences.Key.font,
        ReaderPreferences.Key.lineSpacing,
        ReaderPreferences.Key.margins,
        ReaderPreferences.Key.justified,
    ]

    /// Every key a reset removes.
    public static var resetKeys: [String] { flutterResetKeys + nativeResetKeys }

    /// Removes every setting in `resetKeys`, leaving everything the reader
    /// made untouched: bookmarks, reading positions, the shelf's arrangement,
    /// recent searches, onboarding, and the AI backend and its configuration
    /// (which Dart's `clearAll` leaves alone too; the cloud keys are in the
    /// Keychain regardless). Callers holding a setting in memory reload it.
    public static func clearAll(in defaults: UserDefaults = .standard) {
        for key in resetKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
