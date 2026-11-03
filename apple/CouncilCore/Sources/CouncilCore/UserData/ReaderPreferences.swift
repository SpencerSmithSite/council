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
///
/// To add a setting (font family, line spacing and margins are planned): add
/// its key to `Key` and a row to this table, give it a default, and read it
/// leniently so a missing or mistyped value falls back to the default. Keys
/// the Flutter app also has must keep its name and encoding; a new one needs a
/// name lib/src/services/settings_service.dart doesn't use, since Phase 7
/// copies every Flutter key across.
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else.
public struct ReaderPreferences: Sendable {
    public enum Key {
        public static let fontSize = "font_size"
    }

    public static let defaultFontSize = 1.0
    /// `setFontSize`'s clamp in the Dart.
    public static let fontSizeRange: ClosedRange<Double> = 0.8...1.5

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
        get {
            guard let stored = defaults.object(forKey: Key.fontSize) as? Double, stored.isFinite else {
                return Self.defaultFontSize
            }
            return Self.clamp(stored)
        }
        nonmutating set {
            defaults.set(Self.clamp(newValue.isFinite ? newValue : Self.defaultFontSize), forKey: Key.fontSize)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
