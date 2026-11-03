// Port of lib/src/services/bookmark_service.dart.

import Foundation

/// A passage the reader bookmarked.
///
/// `id` is the `contentId`: one bookmark per content unit.
public struct Bookmark: Sendable, Hashable, Identifiable {
    public let contentId: Int
    public let title: String
    /// The source's title, as shown under the bookmark.
    public let source: String
    public let preview: String?
    public let addedAt: Date

    public var id: Int { contentId }

    public init(contentId: Int, title: String, source: String, preview: String?, addedAt: Date) {
        self.contentId = contentId
        self.title = title
        self.source = source
        self.preview = preview
        self.addedAt = addedAt
    }

    /// One stored entry, or nil if it can't be read.
    ///
    /// As strict as the Dart `fromJson` casts, which is what keeps the two
    /// apps agreeing on which entries exist: `contentId` must be a JSON integer
    /// (`3.0` is a double to Dart and fails `as int`), `title` and `source`
    /// strings, `preview` a string, null or absent, and `addedAt` a string
    /// `DateTime.parse` accepts. What matters, as in Dart, is that the failure
    /// is caught around one entry, not around the whole list.
    init?(json entry: OrderedJSON) {
        guard case .int(let contentId)? = entry["contentId"],
              case .string(let title)? = entry["title"],
              case .string(let source)? = entry["source"],
              case .string(let addedAtText)? = entry["addedAt"],
              let addedAt = DartDateTime.date(from: addedAtText)
        else { return nil }
        let preview: String?
        switch entry["preview"] {
        case .string(let text)?: preview = text
        case .null?, nil: preview = nil
        default: return nil
        }
        self.init(contentId: contentId, title: title, source: source, preview: preview, addedAt: addedAt)
    }

    /// The entry as Dart's `jsonEncode(toJson())` writes it: these keys in
    /// this order, `preview` written as `null` rather than left out.
    var json: String {
        let preview = preview.map(DartJSON.quoted) ?? "null"
        return #"{"contentId":\#(contentId),"title":\#(DartJSON.quoted(title)),"#
            + #""source":\#(DartJSON.quoted(source)),"preview":\#(preview),"#
            + #""addedAt":\#(DartJSON.quoted(DartDateTime.string(from: addedAt)))}"#
    }
}

/// The reader's bookmarks, in `UserDefaults`.
///
/// Stored as the Flutter app stores them: key `bookmarks` (no prefix; the
/// Flutter plugin's copy is `flutter.bookmarks`, which Phase 7 moves across
/// unchanged), a JSON **string** holding an array of
/// `{contentId, title, source, preview, addedAt}`, `addedAt` in Dart's local
/// ISO format (`DartDateTime`).
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else. A read-modify-write
/// (`add`, `remove`) racing another on a second thread could lose one of the
/// two changes, exactly as in the Dart; the UI calls these from the main actor.
public struct BookmarkStore: Sendable {
    public static let key = "bookmarks"

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every bookmark, newest first.
    ///
    /// Entry by entry, and deliberately so. The Dart code used to decode the
    /// whole list inside one `try` and return an empty list if anything in it
    /// threw, so a single unreadable entry cost the reader every bookmark they
    /// had, and the next tap on a bookmark icon wrote that empty list back
    /// over the key, which made the loss permanent. One bad entry should cost
    /// one bookmark. (It is dropped for good on the next write, as in Dart.)
    /// A value that isn't a string, isn't JSON or isn't a JSON array reads as
    /// no bookmarks.
    public func bookmarks() -> [Bookmark] {
        guard let text = defaults.object(forKey: Self.key) as? String,
              case .array(let entries)? = try? OrderedJSON.parse(Data(text.utf8))
        else { return [] }
        return entries.compactMap(Bookmark.init(json:)).sorted { $0.addedAt > $1.addedAt }
    }

    public func isBookmarked(_ contentId: Int) -> Bool {
        bookmarks().contains { $0.contentId == contentId }
    }

    public var count: Int { bookmarks().count }

    /// Bookmark a passage, unless it already is.
    public func add(contentId: Int, title: String, source: String, preview: String?) {
        var list = bookmarks()
        guard !list.contains(where: { $0.contentId == contentId }) else { return }
        // Appended after the newest-first list, as the Dart does; order on disk
        // doesn't matter, every read sorts.
        list.append(Bookmark(contentId: contentId, title: title, source: source, preview: preview,
                             addedAt: Date()))
        save(list)
    }

    public func remove(_ contentId: Int) {
        var list = bookmarks()
        list.removeAll { $0.contentId == contentId }
        save(list)
    }

    /// Add or remove; returns whether the passage is now bookmarked.
    @discardableResult
    public func toggle(contentId: Int, title: String, source: String, preview: String?) -> Bool {
        if isBookmarked(contentId) {
            remove(contentId)
            return false
        }
        add(contentId: contentId, title: title, source: source, preview: preview)
        return true
    }

    private func save(_ list: [Bookmark]) {
        defaults.set("[" + list.map(\.json).joined(separator: ",") + "]", forKey: Self.key)
    }
}

/// The parts of Dart's `jsonEncode` the preference stores need.
enum DartJSON {
    /// A string literal as `JsonEncoder` writes it: only `"`, `\`, and
    /// control characters escaped (lowercase hex), everything else, `/` and
    /// non-ASCII included, written as is. (Dart also escapes unpaired
    /// surrogates, which a Swift `String` can't hold.) `JSONEncoder` would
    /// escape `/` and is free to reorder keys, which would still parse but
    /// would make the stored value differ from the Flutter app's for no reason.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00..<0x20: out += "\\u00" + hex(scalar.value, width: 2)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
