// Ports of the reading parts of lib/src/services/settings_service.dart:
// `getReadingPosition` / `setReadingPosition` and `getFontSize` /
// `setFontSize`.

import Foundation

/// Where the reader stopped in each work.
///
/// Per source rather than one global position: someone reading Genesis and
/// dipping into Trent should find both where they left them. Stored as a
/// section index (into `Library.sections(ofSource:)`) because ids are only
/// stable within a corpus build, while sections are what the reader is
/// actually navigating. The reader clamps it to the sections it has, so a
/// position saved before a pack change can't point past the end.
///
/// Key `reading_position_<sourceId>`, an integer, as the Flutter app stores
/// it (unprefixed; see `FlutterPreferences`).
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else.
public struct ReadingPositionStore: Sendable {
    public static func key(forSource id: Int) -> String { "reading_position_\(id)" }

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved section index, or 0 if there is none (or it isn't a whole
    /// number, which `getInt` would have refused too).
    public func position(forSource id: Int) -> Int {
        (defaults.object(forKey: Self.key(forSource: id)) as? Int) ?? 0
    }

    public func setPosition(_ index: Int, forSource id: Int) {
        defaults.set(index, forKey: Self.key(forSource: id))
    }
}

/// The typefaces the reading controls offer.
///
/// Stored by `rawValue`, a name of this app's own rather than a PostScript
/// name, so the app can change how a face is loaded (New York is a system
/// design, not a named font) without rewriting what is saved. Every face here
/// ships with both iOS/iPadOS 26 and macOS 26, so the choice carries between
/// a reader's devices.
public enum ReaderFont: String, CaseIterable, Sendable, Identifiable {
    case system
    case newYork = "new_york"
    case iowanOldStyle = "iowan_old_style"
    case palatino
    case georgia
    case charter

    public var id: String { rawValue }
}

/// How much room the reading column leaves at its sides.
public enum ReaderMargins: String, CaseIterable, Sendable, Identifiable {
    case narrow, standard, wide

    public var id: String { rawValue }
}

/// How the reader likes text set: the Books-style reading sheet's settings.
///
/// One place for every reading-typography key, so the sheet, the reader and
/// the Phase 7 migration agree on names and encodings. Each setting is a
/// property backed directly by `UserDefaults` (no cached copy, so two
/// instances never disagree); an `@Observable` model in the app wraps it for
/// SwiftUI.
///
/// | Key | Type | Default | Notes |
/// |---|---|---|---|
/// | `font_size` | `Double` | 1.0 | Multiplier on the body size, clamped to `fontSizeRange`; the Flutter app's key |
/// | `reader_font` | `String` | `system` | A `ReaderFont` raw value; an unknown name reads as the default |
/// | `reader_line_spacing` | `Double` | 1.3 | Multiple of the face's natural line height, clamped to `lineSpacingRange` |
/// | `reader_margins` | `String` | `standard` | A `ReaderMargins` raw value; an unknown name reads as the default |
/// | `reader_justified` | `Bool` | false | Justified (and hyphenated) rather than ragged right |
///
/// To add a setting: add its key to `Key` and a row to this table, give it a
/// default, and read it leniently so a missing or mistyped value falls back to
/// the default. Keys the Flutter app also has must keep its name and encoding;
/// a new one needs a name lib/src/services/settings_service.dart doesn't use,
/// since Phase 7 copies every Flutter key across. The four `reader_` keys are
/// the native app's own: Flutter has no such settings.
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else.
public struct ReaderPreferences: Sendable {
    public enum Key {
        public static let fontSize = "font_size"
        public static let font = "reader_font"
        public static let lineSpacing = "reader_line_spacing"
        public static let margins = "reader_margins"
        public static let justified = "reader_justified"
    }

    public static let defaultFontSize = 1.0
    /// `setFontSize`'s clamp in the Dart.
    public static let fontSizeRange: ClosedRange<Double> = 0.8...1.5

    public static let defaultFont = ReaderFont.system

    /// 1.3 of a face's natural line height (itself about 1.2 of its size) is
    /// close to the 1.6 line height the Flutter reader sets, so a reader moving
    /// across finds the page as open as they left it.
    public static let defaultLineSpacing = 1.3
    /// From solid (the face's own leading) to roughly double-spaced.
    public static let lineSpacingRange: ClosedRange<Double> = 1.0...1.8

    public static let defaultMargins = ReaderMargins.standard
    public static let defaultJustified = false

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The body text size multiplier (1.0 is the default size).
    ///
    /// Clamped on write, as in Dart, and also on read, which Dart doesn't do:
    /// a value from outside the range (only possible by hand) would otherwise
    /// put a slider out of bounds.
    public var fontSize: Double {
        get { double(Key.fontSize, default: Self.defaultFontSize, in: Self.fontSizeRange) }
        nonmutating set { setDouble(newValue, Key.fontSize, default: Self.defaultFontSize, in: Self.fontSizeRange) }
    }

    public var font: ReaderFont {
        get { (defaults.object(forKey: Key.font) as? String).flatMap(ReaderFont.init(rawValue:)) ?? Self.defaultFont }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.font) }
    }

    /// Line height as a multiple of the face's natural line height. Clamped on
    /// read and write, as `fontSize` is.
    public var lineSpacing: Double {
        get { double(Key.lineSpacing, default: Self.defaultLineSpacing, in: Self.lineSpacingRange) }
        nonmutating set {
            setDouble(newValue, Key.lineSpacing, default: Self.defaultLineSpacing, in: Self.lineSpacingRange)
        }
    }

    public var margins: ReaderMargins {
        get {
            (defaults.object(forKey: Key.margins) as? String).flatMap(ReaderMargins.init(rawValue:))
                ?? Self.defaultMargins
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.margins) }
    }

    /// Only a stored boolean (or the numbers 0 and 1, which is how a plist
    /// may hand one back) counts. Any other number, or a string such as
    /// "yes", reads as the default rather than as a guess.
    public var justified: Bool {
        get {
            guard let number = defaults.object(forKey: Key.justified) as? NSNumber,
                  number.doubleValue == 0 || number.doubleValue == 1
            else { return Self.defaultJustified }
            return number.boolValue
        }
        nonmutating set { defaults.set(newValue, forKey: Key.justified) }
    }

    private func double(_ key: String, default fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let stored = defaults.object(forKey: key) as? Double, stored.isFinite else { return fallback }
        return Self.clamp(stored, to: range)
    }

    private func setDouble(_ value: Double, _ key: String, default fallback: Double, in range: ClosedRange<Double>) {
        defaults.set(Self.clamp(value.isFinite ? value : fallback, to: range), forKey: key)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
