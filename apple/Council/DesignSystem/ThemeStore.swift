import CouncilCore
import Foundation
import Observation
import SwiftUI

/// The chosen theme and light/dark mode, persisted, with the resolved palettes.
///
/// Persisted in `UserDefaults` under `theme_id` and `theme_mode`, the same keys
/// and values the Flutter app uses (`ThemePreferenceKeys`), so the Phase 7
/// migration only has to copy `flutter.theme_id` / `flutter.theme_mode` across.
/// An id this build doesn't know is kept as stored (a newer build may know it)
/// and shows the Default look, as in Flutter's `resolveThemes`.
@Observable @MainActor
final class ThemeStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// A `ThemeCore.id`, or `ThemeCatalogue.defaultThemeID`.
    var themeID: String {
        didSet {
            guard themeID != oldValue else { return }
            defaults.set(themeID, forKey: ThemePreferenceKeys.themeID)
            resolve()
        }
    }

    var mode: ThemeMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: ThemePreferenceKeys.mode)
        }
    }

    /// The named theme in effect, or nil for Default (including unknown ids).
    private(set) var theme: ThemeCore?
    private var light: CouncilPalette = .system(.light)
    private var dark: CouncilPalette = .system(.dark)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeID = defaults.string(forKey: ThemePreferenceKeys.themeID) ?? ThemeCatalogue.defaultThemeID
        mode = ThemeMode(storedName: defaults.string(forKey: ThemePreferenceKeys.mode))
        resolve()
    }

    /// True when the platform look is in effect.
    var isDefault: Bool { theme == nil }

    /// The scheme the mode forces, or nil to follow the system.
    var preferredColorScheme: ColorScheme? { mode.brightness?.colorScheme }

    /// The palette to draw with when the window is in `scheme`.
    func palette(for scheme: ColorScheme) -> CouncilPalette {
        scheme == .dark ? dark : light
    }

    /// The derived CouncilCore palette, or nil for Default.
    func resolvedPalette(for scheme: ColorScheme) -> ResolvedPalette? {
        palette(for: scheme).resolved
    }

    private func resolve() {
        theme = ThemeCatalogue.theme(id: themeID)
        if let theme {
            light = CouncilPalette(theme.palette(.light))
            dark = CouncilPalette(theme.palette(.dark))
        } else {
            light = .system(.light)
            dark = .system(.dark)
        }
    }
}

extension ThemeStore {
    /// A store over throwaway defaults, for previews.
    static func preview(themeID: String = ThemeCatalogue.defaultThemeID, mode: ThemeMode = .system) -> ThemeStore {
        let suite = "council.preview.theme"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(themeID, forKey: ThemePreferenceKeys.themeID)
        defaults.set(mode.rawValue, forKey: ThemePreferenceKeys.mode)
        return ThemeStore(defaults: defaults)
    }
}
