import Foundation

/// An sRGB colour with straight (non-premultiplied) alpha, as Flutter's
/// `Color` holds one.
///
/// Flutter's `Color` used to be a packed 32-bit integer; since 3.27 it stores
/// four `double` channels in 0...1, and only rounds to 8 bits when something
/// asks for `toARGB32()`. That matters for the derivation ported here: a blend
/// such as `alphaBlend(accent @ 20%, surface)` produces a colour between two
/// 8-bit values, and `containerPair` then compares *that unrounded colour's*
/// contrast against a threshold. Rounding after every blend would change which
/// branch some themes take. So this type keeps doubles, computes exactly what
/// Flutter computes in the same order, and rounds only in `argb32`.
public struct RGBA: Sendable, Hashable {
    public var alpha: Double
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Channels in 0...1, stored as given (Flutter's `Color.from`).
    public init(alpha: Double = 1, red: Double, green: Double, blue: Double) {
        self.alpha = alpha
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A packed `0xAARRGGBB` value (Flutter's `Color(int)`): each channel is
    /// its byte over 255.
    public init(argb: UInt32) {
        self.init(
            alpha: Double((argb >> 24) & 0xFF) / 255,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255
        )
    }

    /// `#RRGGBB` (opaque) or `#AARRGGBB`, the format of shared/themes.json and
    /// the golden files. Nil for anything else.
    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 6 { digits = "FF" + digits }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        self.init(argb: value)
    }

    /// Flutter's `_floatToInt8`: `(x * 255.0).round().clamp(0, 255)`. Dart's
    /// `round()` rounds half away from zero, as does Swift's default.
    private static func byte(_ x: Double) -> UInt32 {
        UInt32(min(max((x * 255.0).rounded(), 0), 255))
    }

    /// The colour rounded to 8 bits per channel, `0xAARRGGBB` (Flutter's
    /// `toARGB32()`).
    public var argb32: UInt32 {
        Self.byte(alpha) << 24 | Self.byte(red) << 16 | Self.byte(green) << 8 | Self.byte(blue)
    }

    /// `#AARRGGBB`, upper case: how the golden file writes colours.
    public var hexARGB: String {
        let hex = String(argb32, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// This colour with a different alpha (Flutter's `withValues(alpha:)`).
    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(alpha: alpha, red: red, green: green, blue: blue)
    }

    /// `foreground` composited over `background`: Flutter's `Color.alphaBlend`,
    /// term for term, so the doubles come out bit-identical.
    public static func alphaBlend(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.alpha
        if alpha == 0 { return background }
        let invAlpha = 1 - alpha
        var backAlpha = background.alpha
        if backAlpha == 1 {
            return RGBA(
                alpha: 1,
                red: alpha * foreground.red + invAlpha * background.red,
                green: alpha * foreground.green + invAlpha * background.green,
                blue: alpha * foreground.blue + invAlpha * background.blue
            )
        }
        backAlpha = backAlpha * invAlpha
        let outAlpha = alpha + backAlpha
        return RGBA(
            alpha: outAlpha,
            red: (foreground.red * alpha + background.red * backAlpha) / outAlpha,
            green: (foreground.green * alpha + background.green * backAlpha) / outAlpha,
            blue: (foreground.blue * alpha + background.blue * backAlpha) / outAlpha
        )
    }

    /// WCAG 2.0 relative luminance (Flutter's `computeLuminance`). Alpha is
    /// ignored, as it is there. Note the 0.03928 knee from WCAG 2.0, which
    /// Flutter keeps rather than sRGB's 0.04045.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public static let white = RGBA(argb: 0xFFFF_FFFF)
    public static let black = RGBA(argb: 0xFF00_0000)
}

extension RGBA: CustomStringConvertible {
    public var description: String { hexARGB }
}
