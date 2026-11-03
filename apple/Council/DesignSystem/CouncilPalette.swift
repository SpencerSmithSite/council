import CouncilCore
import SwiftUI

/// The colours views draw with, for the theme and scheme in effect. Read it
/// from the environment (`@Environment(\.councilPalette)`); `.councilTheme`
/// puts it there.
///
/// For "Default" every colour is the system's own semantic colour, dynamic
/// over light/dark and Increase Contrast, so a view can use `palette.surface`
/// or `palette.secondaryLabel` without caring which theme is chosen. The only
/// exception is the container pairs (a banner's tint and its text), which have
/// no system equivalent and come from the Flutter Apple build's derivation
/// (`ApplePlatformPalette`). `isSystem` tells the few places that *paint*
/// (row backgrounds, page backgrounds) to leave the system's look alone.
struct CouncilPalette: Equatable {
    /// Nil for Default.
    let resolved: ResolvedPalette?
    let brightness: Brightness

    var isSystem: Bool { resolved == nil }

    /// The page, behind grouped content.
    let background: Color
    /// A cell or card resting on the page.
    let surface: Color
    /// A control resting on a cell.
    let surface2: Color
    /// Body text.
    let text: Color
    /// Subtitles, captions, a row's trailing value.
    let secondaryLabel: Color
    /// Row dividers and card outlines.
    let separator: Color
    let accent: Color
    /// Text and icons on a filled accent.
    let onAccent: Color
    let error: Color
    /// A low-key accent-tinted background (status banners) and its text.
    let accentContainer: Color
    let onAccentContainer: Color
    /// A low-key error-tinted background and its text.
    let errorContainer: Color
    let onErrorContainer: Color

    /// The tint to apply, or nil to keep the system tint.
    var customTint: Color? { isSystem ? nil : accent }

    init(_ palette: ResolvedPalette) {
        resolved = palette
        brightness = palette.brightness
        background = Color(rgba: palette.groupedBackground)
        surface = Color(rgba: palette.surface)
        surface2 = Color(rgba: palette.surfaceContainerHigh)
        text = Color(rgba: palette.onSurface)
        secondaryLabel = Color(rgba: palette.secondaryLabel)
        separator = Color(rgba: palette.separator)
        accent = Color(rgba: palette.primary)
        onAccent = Color(rgba: palette.onPrimary)
        error = Color(rgba: palette.error)
        accentContainer = Color(rgba: palette.primaryContainer)
        onAccentContainer = Color(rgba: palette.onPrimaryContainer)
        errorContainer = Color(rgba: palette.errorContainer)
        onErrorContainer = Color(rgba: palette.onErrorContainer)
    }

    /// The Default theme: system semantic colours.
    static func system(_ brightness: Brightness) -> CouncilPalette {
        CouncilPalette(systemFor: brightness)
    }

    private init(systemFor brightness: Brightness) {
        let containers = ApplePlatformPalette.palette(brightness)
        resolved = nil
        self.brightness = brightness
        #if os(iOS)
        background = Color(uiColor: .systemGroupedBackground)
        surface = Color(uiColor: .secondarySystemGroupedBackground)
        surface2 = Color(uiColor: .tertiarySystemGroupedBackground)
        separator = Color(uiColor: .separator)
        // The platform's own accent, not `.accentColor`: that resolves to the
        // nearest `.tint`, so the Default card in the theme picker would show
        // whichever custom theme is active. Default applies no tint and the
        // app has no AccentColor asset, so in the app the two are the same.
        accent = Color(uiColor: .systemBlue)
        #else
        background = Color(nsColor: .windowBackgroundColor)
        surface = Color(nsColor: .controlBackgroundColor)
        surface2 = Color(nsColor: .underPageBackgroundColor)
        separator = Color(nsColor: .separatorColor)
        accent = Color(nsColor: .controlAccentColor)
        #endif
        text = .primary
        secondaryLabel = .secondary
        onAccent = .white
        error = .red
        accentContainer = Color(rgba: containers.primaryContainer)
        onAccentContainer = Color(rgba: containers.onPrimaryContainer)
        errorContainer = Color(rgba: containers.errorContainer)
        onErrorContainer = Color(rgba: containers.onErrorContainer)
    }

    static func == (a: CouncilPalette, b: CouncilPalette) -> Bool {
        a.resolved == b.resolved && a.brightness == b.brightness
    }
}

extension EnvironmentValues {
    /// The palette for the theme and scheme in effect. Defaults to the system
    /// look, so views and previews outside `.councilTheme` still draw.
    @Entry var councilPalette: CouncilPalette = .system(.light)
}
