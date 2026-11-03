import CouncilCore
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// How the reader likes passages set: size, face, line spacing, margins and
/// justification, persisted through `ReaderPreferences`.
///
/// One per process, created by `CouncilApp` and put in the environment beside
/// `ThemeStore`, so the reading controls change every window's text at once
/// and the change shows live behind the sheet. Each property writes straight
/// through to `UserDefaults`; nothing is cached anywhere else, so a relaunch
/// reads back exactly what was last set.
///
/// The theme is not here: it is the app's theme (`ThemeStore`), which the
/// reading controls write too, as Books' theme buttons do.
@Observable @MainActor
final class ReaderStyle {
    @ObservationIgnored private let preferences: ReaderPreferences

    /// Multiplier on the Dynamic Type body size (`font_size`, 0.8–1.5), so the
    /// reader still follows the system text size and only nudges it.
    /// Callers keep it inside `ReaderPreferences.fontSizeRange` (`shrink` and
    /// `grow` do); `ReaderPreferences` clamps what it stores regardless.
    var fontSize: Double {
        didSet { if fontSize != oldValue { preferences.fontSize = fontSize } }
    }

    var font: ReaderFont {
        didSet { if font != oldValue { preferences.font = font } }
    }

    /// Multiple of the face's natural line height.
    var lineSpacing: Double {
        didSet { if lineSpacing != oldValue { preferences.lineSpacing = lineSpacing } }
    }

    var margins: ReaderMargins {
        didSet { if margins != oldValue { preferences.margins = margins } }
    }

    var justified: Bool {
        didSet { if justified != oldValue { preferences.justified = justified } }
    }

    init(defaults: UserDefaults = .standard) {
        let preferences = ReaderPreferences(defaults: defaults)
        self.preferences = preferences
        fontSize = preferences.fontSize
        font = preferences.font
        lineSpacing = preferences.lineSpacing
        margins = preferences.margins
        justified = preferences.justified
    }

    /// The size steps the "A" buttons move through: Books-sized steps, kept
    /// inside `ReaderPreferences.fontSizeRange`.
    static let fontSizeStep = 0.1

    var canShrink: Bool { fontSize > ReaderPreferences.fontSizeRange.lowerBound + 0.001 }
    var canGrow: Bool { fontSize < ReaderPreferences.fontSizeRange.upperBound - 0.001 }

    func shrink() { fontSize = Self.sized(fontSize - Self.fontSizeStep) }
    func grow() { fontSize = Self.sized(fontSize + Self.fontSizeStep) }

    /// Rounded to the step, so repeated taps land on 1.0 again rather than on
    /// 0.9999999, and kept in range.
    private static func sized(_ value: Double) -> Double {
        let range = ReaderPreferences.fontSizeRange
        return min(max((value * 10).rounded() / 10, range.lowerBound), range.upperBound)
    }

    /// Everything the passage text view needs to set type, as a value it can
    /// compare against what it last drew.
    var typography: ReaderTypography {
        ReaderTypography(font: font, scale: fontSize, lineSpacing: lineSpacing, justified: justified)
    }

    /// The reading column's side padding.
    var horizontalMargin: CGFloat {
        switch margins {
        case .narrow: 12
        case .standard: 24
        case .wide: 48
        }
    }
}

extension ReaderStyle {
    /// A style over throwaway defaults, for previews.
    static func preview() -> ReaderStyle {
        let suite = "council.preview.reader"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return ReaderStyle(defaults: defaults)
    }
}

/// The reading typography as a plain value: the face, the size multiplier, the
/// line spacing and the alignment.
struct ReaderTypography: Equatable {
    var font: ReaderFont = ReaderPreferences.defaultFont
    var scale: Double = ReaderPreferences.defaultFontSize
    var lineSpacing: Double = ReaderPreferences.defaultLineSpacing
    var justified: Bool = ReaderPreferences.defaultJustified

    #if os(iOS)
    typealias PlatformFont = UIFont
    #else
    typealias PlatformFont = NSFont
    #endif

    /// The body size before the reader's multiplier.
    ///
    /// On iOS and iPadOS that is the Dynamic Type body size for `sizeCategory`,
    /// so the reader follows the system setting. The Mac has no Dynamic Type
    /// and its 13-point body is UI text, too small to read a chapter in; 16
    /// points is the reading size the Flutter app set there (Material's
    /// `bodyLarge`) and close to Books' default.
    static func baseSize(_ dynamicType: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        #else
        return 16
        #endif
    }

    /// The face at `size`, in `weight`. Named faces that fail to load (none
    /// should: each ships with iOS and macOS 26) fall back to the system face
    /// rather than to nothing.
    static func platformFont(_ font: ReaderFont, size: CGFloat, bold: Bool = false) -> PlatformFont {
        let weight: PlatformFont.Weight = bold ? .bold : .regular
        let system = PlatformFont.systemFont(ofSize: size, weight: weight)
        switch font {
        case .system:
            return system
        case .newYork:
            // New York is the system's serif design, not a font with a name an
            // app can ask for.
            #if os(iOS)
            guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
            return UIFont(descriptor: descriptor, size: size)
            #else
            guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
            return NSFont(descriptor: descriptor, size: size) ?? system
            #endif
        default:
            let name = bold ? font.boldPostScriptName : font.postScriptName
            return PlatformFont(name: name, size: size) ?? system
        }
    }

    /// The body face at the reader's size for `dynamicType`.
    func bodyFont(_ dynamicType: DynamicTypeSize) -> PlatformFont {
        Self.platformFont(font, size: Self.baseSize(dynamicType) * scale)
    }

    /// The face for a section title: the reading face, larger, so a heading
    /// reads as part of the page it heads (as in Books) rather than as UI.
    func titleFont(_ dynamicType: DynamicTypeSize) -> Font {
        let size = Self.baseSize(dynamicType) * scale * 1.35
        switch font {
        case .system: return .system(size: size, weight: .bold)
        case .newYork: return .system(size: size, weight: .bold, design: .serif)
        default: return .custom(font.boldPostScriptName, fixedSize: size)
        }
    }
}

extension ReaderFont {
    /// Shown in the reading controls, each name set in its own face.
    var label: String {
        switch self {
        case .system: "System"
        case .newYork: "New York"
        case .iowanOldStyle: "Iowan Old Style"
        case .palatino: "Palatino"
        case .georgia: "Georgia"
        case .charter: "Charter"
        }
    }

    /// The regular face's PostScript name, the same on iOS and macOS. Unused
    /// for System and New York, which are system designs.
    var postScriptName: String {
        switch self {
        case .system, .newYork: ""
        case .iowanOldStyle: "IowanOldStyle-Roman"
        case .palatino: "Palatino-Roman"
        case .georgia: "Georgia"
        case .charter: "Charter-Roman"
        }
    }

    var boldPostScriptName: String {
        switch self {
        case .system, .newYork: ""
        case .iowanOldStyle: "IowanOldStyle-Bold"
        case .palatino: "Palatino-Bold"
        case .georgia: "Georgia-Bold"
        case .charter: "Charter-Bold"
        }
    }

    /// The face as a SwiftUI font at the body size, for the picker's labels.
    var previewFont: Font {
        switch self {
        case .system: .body
        case .newYork: .system(.body, design: .serif)
        default: .custom(postScriptName, size: 17, relativeTo: .body)
        }
    }
}

extension ReaderMargins {
    var label: String {
        switch self {
        case .narrow: "Narrow"
        case .standard: "Standard"
        case .wide: "Wide"
        }
    }
}
