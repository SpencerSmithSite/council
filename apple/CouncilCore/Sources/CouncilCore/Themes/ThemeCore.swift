/// Light or dark: which half of a theme is showing.
public enum Brightness: String, Sendable, Hashable, CaseIterable {
    case light, dark
}

/// The identifying colours of one variant of a theme: what shared/themes.json
/// records. Everything else in a `ResolvedPalette` is derived from these.
public struct ThemeVariant: Sendable, Hashable {
    /// The page, behind grouped content.
    public var bg: RGBA
    /// A cell resting on the page.
    public var surface: RGBA
    /// A control resting on a cell.
    public var surface2: RGBA
    public var text: RGBA
    /// Secondary text, before it is lifted to stay legible.
    public var subtext: RGBA
    /// The theme's own hairline, before it is lifted to stay visible.
    public var separator: RGBA
    public var accent: RGBA
    /// Text and icons drawn on the accent.
    public var onAccent: RGBA
    /// Nil means the derivation's default red for the brightness.
    public var error: RGBA?

    public init(bg: RGBA, surface: RGBA, surface2: RGBA, text: RGBA, subtext: RGBA,
                separator: RGBA, accent: RGBA, onAccent: RGBA, error: RGBA? = nil) {
        self.bg = bg
        self.surface = surface
        self.surface2 = surface2
        self.text = text
        self.subtext = subtext
        self.separator = separator
        self.accent = accent
        self.onAccent = onAccent
        self.error = error
    }
}

/// A named theme with both variants, as listed in shared/themes.json
/// (Flutter's `NamedTheme`, before derivation).
public struct ThemeCore: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var light: ThemeVariant
    public var dark: ThemeVariant

    public init(id: String, label: String, light: ThemeVariant, dark: ThemeVariant) {
        self.id = id
        self.label = label
        self.light = light
        self.dark = dark
    }

    public func variant(_ brightness: Brightness) -> ThemeVariant {
        brightness == .dark ? dark : light
    }

    /// The full palette for one brightness.
    public func palette(_ brightness: Brightness) -> ResolvedPalette {
        ResolvedPalette(variant(brightness), brightness: brightness)
    }
}

/// The theme catalogue. `named` is generated from shared/themes.json into
/// ThemeCatalogue.g.swift by tools/generate_themes.py.
public enum ThemeCatalogue {
    /// The platform look: SwiftUI's own semantic colours and tint. Not in
    /// `named`, because it has no fixed palette (Flutter's `kDefaultThemeId`).
    public static let defaultThemeID = "default"

    /// A named theme by id; nil for "default" or an id this build doesn't know,
    /// both of which mean the platform look (Flutter's `namedThemeById`).
    public static func theme(id: String) -> ThemeCore? {
        named.first { $0.id == id }
    }
}

/// Light, dark, or follow the device (Flutter's `AppThemeMode`). The raw
/// values are what both apps persist under `ThemePreferenceKeys.mode`.
public enum ThemeMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The fixed brightness this mode forces, or nil to follow the device.
    public var brightness: Brightness? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// A stored name back to a mode; anything unrecognised (or missing) is
    /// `.system`, as in Flutter's `AppThemeMode.fromName`.
    public init(storedName: String?) {
        self = storedName.flatMap(ThemeMode.init(rawValue:)) ?? .system
    }
}

/// The preference keys, identical to the Flutter app's `SettingsService` so the
/// Phase 7 migration is a straight copy from `flutter.theme_mode` /
/// `flutter.theme_id` (see `FlutterPreferences`).
public enum ThemePreferenceKeys {
    /// `system` / `light` / `dark`.
    public static let mode = "theme_mode"
    /// A `ThemeCore.id`, or `ThemeCatalogue.defaultThemeID`.
    public static let themeID = "theme_id"
}
