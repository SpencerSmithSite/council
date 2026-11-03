// Port of lib/src/services/read_shelf_service.dart.

import Foundation

/// Per-source UI state for the Read tab: which sources the reader has pinned
/// to the top, which they have starred, and which tradition sections they
/// have collapsed.
///
/// Starring is a source-level favourite, deliberately distinct from the
/// passage-level bookmarks (a whole work vs. a single unit within one), which
/// is why it has its own name and store rather than reusing "bookmark".
///
/// This is small, device-local preference data, how one reader likes their
/// shelf arranged, not corpus content, so it lives in `UserDefaults` beside
/// the other settings rather than in a database. The keys and encodings are
/// the Flutter app's, unprefixed (Phase 7 moves `flutter.<key>` across as is):
///
/// | Key | Type |
/// |---|---|
/// | `shelf_pinned_sources` | `[String]`, source ids as decimal strings |
/// | `shelf_starred_sources` | `[String]`, source ids as decimal strings |
/// | `shelf_collapsed_traditions` | `[String]`, tradition names |
/// | `shelf_sections_arranged` | `Bool` |
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else.
public struct ShelfStore: Sendable {
    public static let pinnedKey = "shelf_pinned_sources"
    public static let starredKey = "shelf_starred_sources"
    public static let collapsedKey = "shelf_collapsed_traditions"
    /// Whether the reader has ever arranged the sections themselves.
    ///
    /// Needed because the collapsed set alone can't distinguish "never touched
    /// it" from "deliberately expanded everything" (both are the empty set),
    /// and the two want opposite behaviour on the next launch.
    public static let arrangedKey = "shelf_sections_arranged"

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func pinned() -> Set<Int> { readInts(Self.pinnedKey) }
    public func starred() -> Set<Int> { readInts(Self.starredKey) }

    public func collapsed() -> Set<String> { Set(readStrings(Self.collapsedKey)) }

    public func hasArrangedSections() -> Bool {
        (defaults.object(forKey: Self.arrangedKey) as? Bool) ?? false
    }

    /// Write the arrangement the shelf is *already showing*.
    ///
    /// These take a whole set rather than toggling one member because the
    /// screen holds the current arrangement in its own state and applies a
    /// change on the spot; a toggle here would mean reading the stored value
    /// back to decide the new state, putting persistence in front of the frame
    /// that shows the result. The screen updates first and records after.
    ///
    /// Written in ascending order: a `Set` has none, and a stable order keeps
    /// the stored value from changing when its contents haven't.
    public func setPinned(_ ids: Set<Int>) { writeInts(Self.pinnedKey, ids) }

    public func setStarred(_ ids: Set<Int>) { writeInts(Self.starredKey, ids) }

    /// Records the collapsed set *and* marks the shelf arranged: reaching here
    /// at all means the reader opened or closed something themselves.
    public func setCollapsed(_ traditions: Set<String>) {
        defaults.set(traditions.sorted(), forKey: Self.collapsedKey)
        defaults.set(true, forKey: Self.arrangedKey)
    }

    /// Collapse everything, on a shelf the reader has never arranged. The
    /// caller checks `hasArrangedSections()` first, as the Read tab does.
    ///
    /// A dozen tradition sections expanded is a screen of scrolling before the
    /// shape of the library is visible at all; collapsed, all of it fits at
    /// once and opening one is a tap. Deliberately *not* marked as arranged:
    /// this is the app's default, not a choice the reader made, so the first
    /// time they expand or collapse anything their preference takes over for
    /// good. Returns `traditions`, as the Dart does.
    @discardableResult
    public func applyDefaultCollapse(_ traditions: Set<String>) -> Set<String> {
        defaults.set(traditions.sorted(), forKey: Self.collapsedKey)
        return traditions
    }

    private func writeInts(_ key: String, _ ids: Set<Int>) {
        defaults.set(ids.sorted().map(String.init), forKey: key)
    }

    /// `UserDefaults` has no int-list type that `shared_preferences` uses, so
    /// the ids are stored as strings and read back with Dart's `int.tryParse`
    /// rules; anything that doesn't parse is skipped, not fatal.
    private func readInts(_ key: String) -> Set<Int> {
        Set(readStrings(key).compactMap(DartInt.tryParse))
    }

    /// The strings in a stored array. Dart's `getStringList` would throw on a
    /// non-string element; skipping it keeps one bad value from costing the
    /// whole shelf arrangement.
    private func readStrings(_ key: String) -> [String] {
        (defaults.array(forKey: key) ?? []).compactMap { $0 as? String }
    }
}

/// Dart's `int.tryParse(source)` with no radix, as the Dart VM implements it.
enum DartInt {
    /// Surrounding whitespace (as `String.trim` defines it) ignored, an
    /// optional sign, then ASCII decimal digits or `0x`/`0X` and hex digits.
    /// Out of 64-bit range is nil, except that hex up to 2^64 − 1 wraps to a
    /// negative number as Dart documents.
    static func tryParse(_ source: String) -> Int? {
        var text = Substring(DartText.trimmed(source))
        var negative = false
        if let first = text.first, first == "+" || first == "-" {
            negative = first == "-"
            text = text.dropFirst()
        }
        guard !text.isEmpty else { return nil }

        if text.count > 2, text.hasPrefix("0x") || text.hasPrefix("0X") {
            let digits = text.dropFirst(2)
            guard digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII),
                  let magnitude = UInt64(digits, radix: 16) else { return nil }
            if negative {
                guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
                return Int(Int64(truncatingIfNeeded: 0 &- magnitude))
            }
            return Int(Int64(bitPattern: magnitude))
        }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int((negative ? "-" : "") + text)
    }
}
