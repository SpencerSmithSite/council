// Port of lib/src/theme/highlight_colours.dart (`HighlightColour`; the
// selection wash is derived from the theme's accent and belongs to the UI).

/// The colours a reader can mark a passage with.
///
/// Stored by `id` rather than by value, so the palette can be re-tuned — or
/// given a proper dark-mode treatment, as it is here — without rewriting every
/// highlight already saved on the device. The Flutter app wrote these same ids
/// into `council_user.db`, which the native app reads in place.
///
/// The light values are the muted, paper-like washes a marker leaves on a
/// page; the dark values are much deeper, because a pastel behind light text on
/// a dark background destroys the contrast the text depends on.
public enum HighlightColour: String, CaseIterable, Sendable, Identifiable {
    case yellow, green, blue, pink, purple

    /// Persisted in the database. Never change these.
    public var id: String { rawValue }

    /// Shown to the reader, and read out by assistive technology.
    public var label: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    public var light: RGBA {
        switch self {
        case .yellow: RGBA(argb: 0xFFFB_E7A8)
        case .green: RGBA(argb: 0xFFC8_E6C3)
        case .blue: RGBA(argb: 0xFFC2_DDF5)
        case .pink: RGBA(argb: 0xFFF6_CCD8)
        case .purple: RGBA(argb: 0xFFDC_CDF2)
        }
    }

    public var dark: RGBA {
        switch self {
        case .yellow: RGBA(argb: 0xFF6B_571B)
        case .green: RGBA(argb: 0xFF2C_4F2A)
        case .blue: RGBA(argb: 0xFF1F_3F5C)
        case .pink: RGBA(argb: 0xFF5C_2434)
        case .purple: RGBA(argb: 0xFF3E_2C5C)
        }
    }

    /// The colour for a light or dark appearance (Dart's `resolve`).
    public func resolve(dark isDark: Bool) -> RGBA {
        isDark ? dark : light
    }

    /// The stored id back to a colour, tolerating ids this build does not know
    /// — a highlight saved by a later version should still render as
    /// *something* rather than disappear. Compared by code unit, as Dart's
    /// `==` does, rather than by canonical equivalence.
    public static func fromID(_ id: String?) -> HighlightColour {
        guard let id else { return .yellow }
        return allCases.first { DartText.equal($0.id, id) } ?? .yellow
    }
}
