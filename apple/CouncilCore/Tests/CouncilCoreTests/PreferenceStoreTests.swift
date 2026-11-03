// Covers UserData/BookmarkStore.swift, ShelfStore.swift and
// ReaderPreferences.swift. The bookmark cases are
// test/bookmark_service_test.dart's, the shelf cases
// test/read_shelf_service_test.dart's; the fixtures are values exactly as
// shared_preferences on Apple platforms stores them (Phase 7 copies them
// across unchanged, minus the `flutter.` prefix).

import Foundation
import Testing
@testable import CouncilCore

/// A throwaway `UserDefaults` suite per test.
final class TestDefaults {
    let name = "CouncilCoreTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

/// A stored entry as Dart's `jsonEncode(bookmark.toJson())` writes it.
private func good(_ id: Int, _ title: String, _ day: String) -> String {
    #"{"contentId":\#(id),"title":"\#(title)","source":"The Confessions","preview":null,"addedAt":"2026-09-\#(day)T12:00:00.000"}"#
}

@Suite struct BookmarkStoreTests {
    let suite = TestDefaults()
    var store: BookmarkStore { BookmarkStore(defaults: suite.defaults) }

    func storeRaw(_ json: String) { suite.defaults.set(json, forKey: "bookmarks") }

    @Test func aWellFormedListIsReadBackNewestFirst() {
        storeRaw("[\(good(1, "Book I", "01")),\(good(2, "Book II", "02"))]")
        #expect(store.bookmarks().map(\.title) == ["Book II", "Book I"])
        #expect(store.bookmarks().first?.id == 2)
        #expect(store.count == 2)
    }

    /// One unreadable entry must cost one bookmark. Each kind of damage the
    /// Dart casts reject, among good entries.
    @Test func oneMalformedEntryCostsOneBookmark() {
        storeRaw("""
            [\(good(1, "Book I", "01")),
             {"contentId":2.0,"title":"Book II","source":"The Confessions","addedAt":"2026-09-02T12:00:00.000"},
             {"contentId":4,"title":"Book IV"},
             {"contentId":5,"title":"Book V","source":"x","preview":7,"addedAt":"2026-09-05T12:00:00.000"},
             {"contentId":6,"title":"Book VI","source":"x","addedAt":"yesterday"},
             {"contentId":"7","title":"Book VII","source":"x","addedAt":"2026-09-07T12:00:00.000"},
             "not an object", 42, null,
             \(good(3, "Book III", "03"))]
            """)
        #expect(store.bookmarks().map(\.title) == ["Book III", "Book I"])
    }

    @Test func previewMayBeAbsentNullOrAString() {
        storeRaw("""
            [{"contentId":1,"title":"a","source":"s","addedAt":"2026-09-01T12:00:00.000"},
             {"contentId":2,"title":"b","source":"s","preview":null,"addedAt":"2026-09-02T12:00:00.000"},
             {"contentId":3,"title":"c","source":"s","preview":"In the beginning","addedAt":"2026-09-03T12:00:00.000Z"}]
            """)
        #expect(store.bookmarks().map(\.preview) == ["In the beginning", nil, nil])
    }

    @Test func addingDoesNotOverwriteTheOnesItCouldRead() {
        storeRaw(#"[\#(good(1, "Book I", "01")),{"contentId":2.0,"title":"Book II","source":"x","addedAt":"y"}]"#)
        store.add(contentId: 9, title: "Book IX", source: "The Confessions", preview: nil)
        #expect(Set(store.bookmarks().map(\.title)) == ["Book I", "Book IX"])
    }

    @Test func notAListOrNotJSONOrNotAStringIsNoBookmarks() {
        storeRaw(#"{"not":"a list"}"#)
        #expect(store.bookmarks().isEmpty)
        storeRaw("{{{")
        #expect(store.bookmarks().isEmpty)
        suite.defaults.set(["contentId": 1], forKey: "bookmarks")
        #expect(store.bookmarks().isEmpty)
        suite.defaults.removeObject(forKey: "bookmarks")
        #expect(store.bookmarks().isEmpty)
    }

    @Test func addRemoveAndToggle() {
        store.add(contentId: 1, title: "Genesis 1", source: "KJV", preview: "In the beginning")
        store.add(contentId: 1, title: "Genesis 1 again", source: "KJV", preview: nil)
        #expect(store.count == 1, "no duplicate")
        #expect(store.bookmarks().first?.title == "Genesis 1")
        #expect(store.isBookmarked(1))

        #expect(store.toggle(contentId: 2, title: "Genesis 2", source: "KJV", preview: nil))
        #expect(store.isBookmarked(2))
        #expect(!store.toggle(contentId: 2, title: "Genesis 2", source: "KJV", preview: nil))
        #expect(!store.isBookmarked(2))

        store.remove(1)
        #expect(store.count == 0)
        #expect(suite.defaults.string(forKey: "bookmarks") == "[]")
    }

    /// The value written is what `jsonEncode` would write: same keys, same
    /// order, `preview` as an explicit null, `/` and non-ASCII unescaped, and
    /// `addedAt` in Dart's local format.
    @Test func writesWhatDartWrites() throws {
        store.add(contentId: 23558, title: "Genesis 1", source: "KJV/1611 \"Authorised\"", preview: nil)
        let stored = try #require(suite.defaults.string(forKey: "bookmarks"))
        let added = try #require(store.bookmarks().first?.addedAt)
        let stamp = DartDateTime.string(from: added)
        #expect(stored == #"[{"contentId":23558,"title":"Genesis 1","source":"KJV/1611 \"Authorised\"","preview":null,"addedAt":"\#(stamp)"}]"#)
        #expect(stamp.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}(\d{3})?/) != nil)
    }

    /// Dart's `jsonEncode` output for this title, from the SDK.
    @Test func escapesStringsAsDartDoes() {
        let title = "a/b \"q\" \\ \n\t\u{01}\u{7f} é 😀 \u{2028}"
        #expect(DartJSON.quoted(title) == "\"a/b \\\"q\\\" \\\\ \\n\\t\\u0001\u{7f} é 😀 \u{2028}\"")
        #expect(DartJSON.quoted("\u{08}\u{0C}\r\u{1F}") == #""\b\f\r\u001f""#)
    }

    @Test func roundTripsThroughItsOwnFormat() {
        store.add(contentId: 1, title: "Ἐν ἀρχῇ\nἦν ὁ λόγος", source: "Nestle 1904", preview: "John 1:1 \u{1}")
        let bookmark = store.bookmarks().first
        #expect(bookmark?.title == "Ἐν ἀρχῇ\nἦν ὁ λόγος")
        #expect(bookmark?.preview == "John 1:1 \u{1}")
    }
}

@Suite struct ShelfStoreTests {
    let suite = TestDefaults()
    var shelf: ShelfStore { ShelfStore(defaults: suite.defaults) }

    @Test func aNewShelfHasNotBeenArranged() {
        #expect(!shelf.hasArrangedSections())
        #expect(shelf.pinned().isEmpty)
        #expect(shelf.starred().isEmpty)
        #expect(shelf.collapsed().isEmpty)
    }

    @Test func theDefaultCollapseDoesNotCountAsArranging() {
        #expect(shelf.applyDefaultCollapse(["Catholic", "Reformed"]) == ["Catholic", "Reformed"])
        #expect(shelf.collapsed() == ["Catholic", "Reformed"])
        #expect(!shelf.hasArrangedSections())
    }

    @Test func openingASectionIsArranging() {
        shelf.applyDefaultCollapse(["Catholic", "Reformed"])
        shelf.setCollapsed(["Reformed"])
        #expect(shelf.collapsed() == ["Reformed"])
        #expect(shelf.hasArrangedSections())
    }

    @Test func expandingEverythingSticks() {
        shelf.applyDefaultCollapse(["Catholic", "Reformed"])
        shelf.setCollapsed([])
        #expect(shelf.collapsed().isEmpty)
        #expect(shelf.hasArrangedSections())
    }

    @Test func pinningAndStarringAreIndependent() {
        shelf.setPinned([970])
        shelf.setStarred([41])
        #expect(shelf.pinned() == [970])
        #expect(shelf.starred() == [41])
        shelf.setPinned([])
        #expect(shelf.pinned().isEmpty)
        #expect(shelf.starred() == [41])
    }

    @Test func storesWhatTheFlutterAppStores() {
        shelf.setPinned([970, 3, 41])
        shelf.setCollapsed(["Reformed", "Catholic"])
        #expect(suite.defaults.array(forKey: "shelf_pinned_sources") as? [String] == ["3", "41", "970"])
        #expect(suite.defaults.array(forKey: "shelf_collapsed_traditions") as? [String] == ["Catholic", "Reformed"])
        #expect(suite.defaults.object(forKey: "shelf_sections_arranged") as? Bool == true)
    }

    /// Ids are strings; whatever `int.tryParse` refuses is skipped, and the
    /// rest survive.
    @Test func idsReadAsDartParsesThem() {
        suite.defaults.set(["970", " 41 ", "+5", "0x1F", "junk", "", "12abc", "1_000", "3.0", "٣",
                            "9223372036854775808", "-2", "970"],
                           forKey: "shelf_pinned_sources")
        #expect(shelf.pinned() == [970, 41, 5, 31, -2])
        suite.defaults.set(["7", 8, Data([1]), "9"] as [Any], forKey: "shelf_starred_sources")
        #expect(shelf.starred() == [7, 9])
        suite.defaults.set("970", forKey: "shelf_starred_sources")
        #expect(shelf.starred().isEmpty)
    }

    /// The VM's `int.tryParse`, case by case, from the SDK.
    @Test(arguments: [
        (" 12 ", 12), ("0x1F", 31), ("0X1F", 31), ("+5", 5), ("-0x10", -16), ("\t7\n", 7), ("00042", 42),
        ("\u{FEFF}5", 5), ("\u{A0}12\u{A0}", 12), ("0x1f ", 31),
        ("-9223372036854775808", Int.min), ("9223372036854775807", Int.max),
        ("0x8000000000000000", Int.min), ("0xFFFFFFFFFFFFFFFF", -1), ("-0x8000000000000000", Int.min),
    ] as [(String, Int)])
    func parsesIntsAsDart(_ text: String, _ expected: Int) {
        #expect(DartInt.tryParse(text) == expected)
    }

    @Test(arguments: ["1_000", "12abc", "", " ", "0x", "- 5", "+-5", "1 2", "\u{200B}5", "0b101", "1e3",
                      "١٢", "9223372036854775808", "0x10000000000000000", "-0xFFFFFFFFFFFFFFFF"])
    func refusesWhatDartRefuses(_ text: String) {
        #expect(DartInt.tryParse(text) == nil)
    }

    @Test func collapsedSkipsNonStrings() {
        suite.defaults.set(["Catholic", 3, "Reformed"] as [Any], forKey: "shelf_collapsed_traditions")
        #expect(shelf.collapsed() == ["Catholic", "Reformed"])
    }
}

@Suite struct ReaderPreferenceTests {
    let suite = TestDefaults()

    @Test func readingPositionsArePerSource() {
        let positions = ReadingPositionStore(defaults: suite.defaults)
        #expect(positions.position(forSource: 970) == 0)
        positions.setPosition(42, forSource: 970)
        positions.setPosition(3, forSource: 12)
        #expect(positions.position(forSource: 970) == 42)
        #expect(positions.position(forSource: 12) == 3)
        #expect(suite.defaults.object(forKey: "reading_position_970") as? Int == 42)
    }

    @Test func aStoredPositionThatIsNotAWholeNumberIsIgnored() {
        suite.defaults.set("12", forKey: "reading_position_1")
        suite.defaults.set(2.5, forKey: "reading_position_2")
        let positions = ReadingPositionStore(defaults: suite.defaults)
        #expect(positions.position(forSource: 1) == 0)
        #expect(positions.position(forSource: 2) == 0)
    }

    @Test func fontSizeDefaultsClampsAndUsesTheFlutterKey() {
        let preferences = ReaderPreferences(defaults: suite.defaults)
        #expect(preferences.fontSize == 1.0)
        preferences.fontSize = 1.25
        #expect(preferences.fontSize == 1.25)
        #expect(suite.defaults.object(forKey: "font_size") as? Double == 1.25)
        preferences.fontSize = 4
        #expect(suite.defaults.double(forKey: "font_size") == 1.5)
        preferences.fontSize = 0.1
        #expect(preferences.fontSize == 0.8)
        preferences.fontSize = .nan
        #expect(preferences.fontSize == 1.0)
    }

    @Test func fontSizeReadsWhatFlutterWrote() {
        suite.defaults.set(1.1, forKey: "font_size")
        #expect(ReaderPreferences(defaults: suite.defaults).fontSize == 1.1)
        suite.defaults.set(1, forKey: "font_size") // an NSNumber integer
        #expect(ReaderPreferences(defaults: suite.defaults).fontSize == 1.0)
        suite.defaults.set(9.0, forKey: "font_size")
        #expect(ReaderPreferences(defaults: suite.defaults).fontSize == 1.5)
        suite.defaults.set("big", forKey: "font_size")
        #expect(ReaderPreferences(defaults: suite.defaults).fontSize == 1.0)
    }
}
