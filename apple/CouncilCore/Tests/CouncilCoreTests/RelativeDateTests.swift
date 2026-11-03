// Covers Reading/RelativeDate.swift, against `formatWhen` in
// lib/src/util/relative_date.dart (which has no Dart test of its own). The
// expectations are what the Dart returns for the same wall-clock times, except
// across a DST change, where the Swift deliberately counts calendar days.

import Foundation
import Testing
@testable import CouncilCore

private let newYork = TimeZone(identifier: "America/New_York")!

/// A wall-clock time in New York.
private func at(_ text: String) -> Date {
    DartDateTime.date(from: text, timeZone: newYork)!
}

/// Tuesday 3 November 2026, mid-afternoon.
private let now = at("2026-11-03T14:22:05")

@Test(arguments: [
    // Today: a 12-hour time, minutes padded, midnight and noon as 12.
    ("2026-11-03T09:05:00", "9:05 am"),
    ("2026-11-03T00:07:00", "12:07 am"),
    ("2026-11-03T12:30:00", "12:30 pm"),
    ("2026-11-03T23:59:59", "11:59 pm"),
    // Later today than `now` is still today.
    ("2026-11-03T18:00:00", "6:00 pm"),
    ("2026-11-02T23:59:00", "Yesterday"),
    ("2026-11-02T00:00:00", "Yesterday"),
    // Sunday 1 November is the fall-back night; still a calendar day.
    ("2026-11-01T01:30:00", "Sunday"),
    ("2026-10-28T08:00:00", "Wednesday"),
    // Seven days back is a date, not a weekday.
    ("2026-10-27T08:00:00", "27 Oct"),
    ("2026-01-01T08:00:00", "1 Jan"),
    ("2025-12-31T23:00:00", "31 Dec 2025"),
    // The future: negative days, under 7, so a weekday, as in the Dart.
    ("2026-11-05T09:00:00", "Thursday"),
])
func relativeDate(_ when: String, _ expected: String) {
    #expect(RelativeDate.format(at(when), now: now, timeZone: newYork) == expected)
}

/// Where the Swift departs from the Dart on purpose: across a spring-forward
/// night the Dart's elapsed-time count calls yesterday "today" and shows a
/// time. Calendar days call it yesterday.
@Test func relativeDateCountsCalendarDaysAcrossDST() {
    let monday = at("2026-03-09T10:00:00")
    #expect(RelativeDate.format(at("2026-03-08T10:00:00"), now: monday, timeZone: newYork) == "Yesterday")
    #expect(RelativeDate.format(at("2026-03-07T10:00:00"), now: monday, timeZone: newYork) == "Saturday")
}
