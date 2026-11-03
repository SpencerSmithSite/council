import CouncilCore
import SwiftUI

extension Color {
    /// A CouncilCore colour as a fixed sRGB SwiftUI colour. Fixed, not dynamic:
    /// a theme's light and dark variants are resolved separately in
    /// CouncilCore, and `ThemeStore` picks the one for the current scheme.
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension Brightness {
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}
