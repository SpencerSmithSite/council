import Foundation

// A port of the palette derivation in lib/src/theme/palette.dart and
// themes.dart (`_palette`), held to shared/golden/themes/derived.json by
// ThemeGoldenTests. Every function keeps the Dart operation order, because the
// container tints and lifted colours are chosen by comparing unrounded
// contrast ratios against thresholds: a different but "equivalent" formula can
// land a hair on the other side of one and pick a different tint.

public enum PaletteDerivation {
    /// The faintest a hairline may be against the surfaces it divides
    /// (`kMinSeparatorContrast`).
    public static let minSeparatorContrast = 1.2

    /// The faintest a secondary label may be, where the theme can afford it
    /// (`kMinSecondaryLabelContrast`).
    public static let minSecondaryLabelContrast = 3.0

    /// WCAG relative-luminance contrast, 1:1 to 21:1 (`contrastRatio`).
    public static func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
        let la = a.luminance, lb = b.luminance
        let hi = la > lb ? la : lb, lo = la > lb ? lb : la
        return (hi + 0.05) / (lo + 0.05)
    }

    /// A container and its foreground: `role` laid over `surface` at low
    /// opacity, with a text colour that stays readable on it (`containerPair`).
    /// The bar is WCAG AA, or 90% of the theme's own body contrast where the
    /// theme itself is below AA.
    public static func containerPair(role: RGBA, surface: RGBA, text: RGBA)
        -> (container: RGBA, on: RGBA)
    {
        let baseline = contrastRatio(text, surface)
        let target = baseline < 4.5 ? baseline * 0.9 : 4.5

        // Strongest tint that still leaves the plain text readable.
        var container = RGBA.alphaBlend(role.withAlpha(0.05), over: surface)
        for amount in [0.20, 0.15, 0.10, 0.05] {
            let candidate = RGBA.alphaBlend(role.withAlpha(amount), over: surface)
            if contrastRatio(text, candidate) >= target {
                container = candidate
                break
            }
        }

        // Then colour the text toward the role, as far as that too stays readable.
        for amount in [0.35, 0.22, 0.12] {
            let tinted = RGBA.alphaBlend(role.withAlpha(amount), over: text)
            if contrastRatio(tinted, container) >= target {
                return (container, tinted)
            }
        }
        return (container, text)
    }

    /// Moves `from` toward `toward` in twentieths until it clears `target`
    /// against every colour in `against`, or as far as it can go (`_lift`).
    static func lift(_ from: RGBA, toward: RGBA, target: Double, against: [RGBA]) -> RGBA {
        func clears(_ c: RGBA) -> Bool {
            against.allSatisfy { contrastRatio(c, $0) >= target }
        }
        if clears(from) { return from }
        for step in 1...20 {
            let blended = RGBA.alphaBlend(toward.withAlpha(Double(step) / 20), over: from)
            if clears(blended) { return blended }
        }
        return toward
    }

    /// A hairline the eye can find against both the cell and the page
    /// (`legibleSeparator`).
    public static func legibleSeparator(_ separator: RGBA, surface: RGBA, bg: RGBA, text: RGBA) -> RGBA {
        lift(separator, toward: text, target: minSeparatorContrast, against: [surface, bg])
    }

    /// A secondary label that stays readable without collapsing into body text
    /// (`legibleSecondaryLabel`). The target scales down with a theme whose own
    /// body text is below the bar.
    public static func legibleSecondaryLabel(_ subtext: RGBA, surface: RGBA, bg: RGBA, text: RGBA) -> RGBA {
        let a = contrastRatio(text, surface), b = contrastRatio(text, bg)
        let body = a < b ? a : b
        let headroom = body * 0.8
        let target = headroom < minSecondaryLabelContrast ? headroom : minSecondaryLabelContrast
        return lift(subtext, toward: text, target: target, against: [surface, bg])
    }

    /// The error colour `_palette` uses when a theme names none.
    public static func defaultError(_ brightness: Brightness) -> RGBA {
        brightness == .dark ? RGBA(argb: 0xFFFF_6B6B) : RGBA(argb: 0xFFD1_1A2A)
    }
}

/// Every colour a theme resolves to at one brightness: Flutter's `AppPalette`
/// (its `ColorScheme` roles plus `groupedBackground`, `separator` and
/// `secondaryLabel`), under the same names so the golden file reads the same
/// on both sides.
public struct ResolvedPalette: Sendable, Hashable {
    public var brightness: Brightness

    public var primary: RGBA
    public var onPrimary: RGBA
    public var secondary: RGBA
    public var onSecondary: RGBA
    public var error: RGBA
    public var onError: RGBA
    public var primaryContainer: RGBA
    public var onPrimaryContainer: RGBA
    public var secondaryContainer: RGBA
    public var onSecondaryContainer: RGBA
    public var errorContainer: RGBA
    public var onErrorContainer: RGBA
    public var surface: RGBA
    public var onSurface: RGBA
    public var onSurfaceVariant: RGBA
    public var surfaceContainerLowest: RGBA
    public var surfaceContainerLow: RGBA
    public var surfaceContainer: RGBA
    public var surfaceContainerHigh: RGBA
    public var surfaceContainerHighest: RGBA
    public var outline: RGBA
    public var outlineVariant: RGBA

    /// The page, behind grouped content.
    public var groupedBackground: RGBA
    /// A row divider, lifted to stay visible.
    public var separator: RGBA
    /// Subtitles, captions, a row's trailing value; lifted to stay legible.
    public var secondaryLabel: RGBA

    /// Expands a theme variant's identifying colours (`_palette` in themes.dart).
    public init(_ v: ThemeVariant, brightness: Brightness) {
        let err = v.error ?? PaletteDerivation.defaultError(brightness)
        let accentPair = PaletteDerivation.containerPair(role: v.accent, surface: v.surface, text: v.text)
        let errPair = PaletteDerivation.containerPair(role: err, surface: v.surface, text: v.text)
        let rule = PaletteDerivation.legibleSeparator(v.separator, surface: v.surface, bg: v.bg, text: v.text)
        let secondaryText = PaletteDerivation.legibleSecondaryLabel(v.subtext, surface: v.surface, bg: v.bg, text: v.text)

        self.brightness = brightness
        primary = v.accent
        onPrimary = v.onAccent
        secondary = v.accent
        onSecondary = v.onAccent
        error = err
        onError = .white
        primaryContainer = accentPair.container
        onPrimaryContainer = accentPair.on
        secondaryContainer = accentPair.container
        onSecondaryContainer = accentPair.on
        errorContainer = errPair.container
        onErrorContainer = errPair.on
        surface = v.surface
        onSurface = v.text
        onSurfaceVariant = secondaryText
        surfaceContainerLowest = v.bg
        surfaceContainerLow = v.surface
        surfaceContainer = v.surface
        surfaceContainerHigh = v.surface2
        surfaceContainerHighest = v.surface2
        outline = rule
        outlineVariant = rule
        groupedBackground = v.bg
        separator = rule
        secondaryLabel = secondaryText
    }

    /// Memberwise, for the platform palette.
    init(brightness: Brightness, primary: RGBA, onPrimary: RGBA, error: RGBA, onError: RGBA,
         accentPair: (container: RGBA, on: RGBA), errorPair: (container: RGBA, on: RGBA),
         surface: RGBA, onSurface: RGBA, onSurfaceVariant: RGBA,
         surfaceContainerLowest: RGBA, surfaceContainerHigh: RGBA, surfaceContainerHighest: RGBA,
         outline: RGBA, groupedBackground: RGBA, separator: RGBA, secondaryLabel: RGBA)
    {
        self.brightness = brightness
        self.primary = primary
        self.onPrimary = onPrimary
        secondary = primary
        onSecondary = onPrimary
        self.error = error
        self.onError = onError
        primaryContainer = accentPair.container
        onPrimaryContainer = accentPair.on
        secondaryContainer = accentPair.container
        onSecondaryContainer = accentPair.on
        errorContainer = errorPair.container
        onErrorContainer = errorPair.on
        self.surface = surface
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
        self.surfaceContainerLowest = surfaceContainerLowest
        surfaceContainerLow = surface
        surfaceContainer = surface
        self.surfaceContainerHigh = surfaceContainerHigh
        self.surfaceContainerHighest = surfaceContainerHighest
        self.outline = outline
        outlineVariant = outline
        self.groupedBackground = groupedBackground
        self.separator = separator
        self.secondaryLabel = secondaryLabel
    }

    // Plain-language names for the views that use them.

    /// The page background (`groupedBackground`).
    public var background: RGBA { groupedBackground }
    /// Body text (`onSurface`).
    public var text: RGBA { onSurface }
    /// The accent, applied as the tint (`primary`).
    public var accent: RGBA { primary }

    /// Every role by its golden-file name, in the golden file's order.
    public var roles: KeyValuePairs<String, RGBA> {
        [
            "primary": primary,
            "onPrimary": onPrimary,
            "secondary": secondary,
            "onSecondary": onSecondary,
            "error": error,
            "onError": onError,
            "primaryContainer": primaryContainer,
            "onPrimaryContainer": onPrimaryContainer,
            "secondaryContainer": secondaryContainer,
            "onSecondaryContainer": onSecondaryContainer,
            "errorContainer": errorContainer,
            "onErrorContainer": onErrorContainer,
            "surface": surface,
            "onSurface": onSurface,
            "onSurfaceVariant": onSurfaceVariant,
            "surfaceContainerLowest": surfaceContainerLowest,
            "surfaceContainerLow": surfaceContainerLow,
            "surfaceContainer": surfaceContainer,
            "surfaceContainerHigh": surfaceContainerHigh,
            "surfaceContainerHighest": surfaceContainerHighest,
            "outline": outline,
            "outlineVariant": outlineVariant,
            "groupedBackground": groupedBackground,
            "separator": separator,
            "secondaryLabel": secondaryLabel,
        ]
    }
}

/// Apple's semantic system colours as the Flutter Apple build transcribes them
/// (`applePalette` in palette.dart).
///
/// The native app's "Default" theme does not paint these: it uses SwiftUI's
/// own semantic colours (`systemGroupedBackground`, `label`, `separator`, the
/// system tint and so on), which are the live versions of the same values and
/// also follow Increase Contrast. The one thing SwiftUI has no semantic colour
/// for is the derived container tint (a banner's background and its text), so
/// Default takes `primaryContainer`/`errorContainer` and their foregrounds from
/// here. The whole palette is pinned in the golden file anyway, so the Default
/// look can be compared against the Flutter Apple build colour for colour.
public enum ApplePlatformPalette {
    public static func palette(_ brightness: Brightness) -> ResolvedPalette {
        let dark = brightness == .dark
        let tint = dark ? RGBA(argb: 0xFF0A_84FF) : RGBA(argb: 0xFF00_7AFF)
        let cell = dark ? RGBA(argb: 0xFF1C_1C1E) : RGBA(argb: 0xFFFF_FFFF)
        let label = dark ? RGBA(argb: 0xFFFF_FFFF) : RGBA(argb: 0xFF00_0000)
        let appleError = dark ? RGBA(argb: 0xFFFF_453A) : RGBA(argb: 0xFFFF_3B30)
        // secondaryLabel is a colour plus an alpha on Apple: #3C3C43 / #EBEBF5 at 60%.
        let secondaryLabel = dark ? RGBA(argb: 0x99EB_EBF5) : RGBA(argb: 0x993C_3C43)
        let separator = dark ? RGBA(argb: 0xFF38_383A) : RGBA(argb: 0xFFC6_C6C8)
        let groupedBg = dark ? RGBA(argb: 0xFF00_0000) : RGBA(argb: 0xFFF2_F2F7)
        let tertiaryDark = RGBA(argb: 0xFF2C_2C2E)

        return ResolvedPalette(
            brightness: brightness,
            primary: tint,
            onPrimary: .white,
            error: appleError,
            onError: .white,
            accentPair: PaletteDerivation.containerPair(role: tint, surface: cell, text: label),
            errorPair: PaletteDerivation.containerPair(role: appleError, surface: cell, text: label),
            surface: cell,
            onSurface: label,
            onSurfaceVariant: secondaryLabel,
            surfaceContainerLowest: dark ? groupedBg : .white,
            surfaceContainerHigh: dark ? tertiaryDark : groupedBg,
            surfaceContainerHighest: dark ? tertiaryDark : RGBA(argb: 0xFFE5_E5EA),
            outline: separator,
            groupedBackground: groupedBg,
            separator: separator,
            secondaryLabel: secondaryLabel
        )
    }
}
