// Covers UserData/DartDateTime.swift. Every vector below was produced by the
// Dart SDK (3.x, the one Flutter 3.47 ships), with TZ set to the zone named:
// `DateTime.parse(input).microsecondsSinceEpoch` and the result's
// `toLocal().toIso8601String()`, and `DateTime.fromMicrosecondsSinceEpoch(n)
// .toIso8601String()`.

import Foundation
import Testing
@testable import CouncilCore

private typealias ParseVector = (input: String, micros: Int64?, local: String?)
private typealias FormatVector = (micros: Int64, local: String)

/// Inputs shared by both zones; their expected values differ.
private let newYorkParse: [ParseVector] = [
    ("2026-11-03T14:22:05.123456", 1793733725123456, "2026-11-03T14:22:05.123456"),
    ("2026-11-03T14:22:05.123", 1793733725123000, "2026-11-03T14:22:05.123"),
    ("2026-11-03T14:22:05.000001", 1793733725000001, "2026-11-03T14:22:05.000001"),
    ("2026-11-03T14:22:05Z", 1793715725000000, "2026-11-03T09:22:05.000"),
    ("2026-11-03 14:22:05.1234567891", 1793733725123456, "2026-11-03T14:22:05.123456"),
    ("2026-11-03T14:22:05,5+05:30", 1793695925500000, "2026-11-03T03:52:05.500"),
    ("20261103T142205", 1793733725000000, "2026-11-03T14:22:05.000"),
    ("20261103", 1793682000000000, "2026-11-03T00:00:00.000"),
    ("+20261103", 1793682000000000, "2026-11-03T00:00:00.000"),
    ("2026-11-03T14Z", 1793714400000000, "2026-11-03T09:00:00.000"),
    ("2026-11-03T14-0130", 1793719800000000, "2026-11-03T10:30:00.000"),
    ("2026-11-03T14:22:05 z", 1793715725000000, "2026-11-03T09:22:05.000"),
    ("2026-11-03T14:22:05 +01", 1793712125000000, "2026-11-03T08:22:05.000"),
    ("2026-11-03T14:22", 1793733720000000, "2026-11-03T14:22:00.000"),
    ("2026-11-03T1422", 1793733720000000, "2026-11-03T14:22:00.000"),
    ("2020-01-42", 1581397200000000, "2020-02-11T00:00:00.000"),
    ("2020-13-01T25:61:61", 1609570921000000, "2021-01-02T02:02:01.000"),
    ("2020-00-00", 1575090000000000, "2019-11-30T00:00:00.000"),
    ("-0004-12-24", -62262500400000000, "-0004-12-24T00:00:00.000"),
    ("-123450101 00:00:00 Z", -451737734400000000, "-012346-12-31T19:00:00.000"),
    ("275760-09-13T00:00:00Z", 8640000000000000000, "+275760-09-12T20:00:00.000"),
    ("275760-09-13T00:00:00.001Z", nil, nil),
    // Spring forward: 2:30 doesn't exist and resolves as 3:30.
    ("2026-03-08T02:30:00", 1772955000000000, "2026-03-08T03:30:00.000"),
    // Fall back: 1:30 happens twice; the first is meant.
    ("2026-11-01T01:30:00", 1793511000000000, "2026-11-01T01:30:00.000"),
    ("2026-03-29T01:30:00", 1774762200000000, "2026-03-29T01:30:00.000"),
    ("2026-10-25T01:30:00", 1792906200000000, "2026-10-25T01:30:00.000"),
    ("2026-04-05T01:45:00", 1775367900000000, "2026-04-05T01:45:00.000"),
    ("2026-10-04T02:15:00", 1791094500000000, "2026-10-04T02:15:00.000"),
    // Outside 1901–2038 the offset comes from an equivalent year: no local
    // mean time (New York's was −4:56:02).
    ("0001-01-01T00:00:00", -62135578800000000, "0001-01-01T00:00:00.000"),
    ("1582-10-10T12:00:00", -12219667200000000, "1582-10-10T12:00:00.000"),
    ("1850-06-01T12:00:00", -3773721600000000, "1850-06-01T12:00:00.000"),
    ("2100-07-01T12:00:00", 4118140800000000, "2100-07-01T12:00:00.000"),
    ("2026-11-03T14:22:05.123456\n", nil, nil),
    ("2026-11-03T14:22:05+1", nil, nil),
    ("2026-11-03X14", nil, nil),
    ("garbage", nil, nil),
    ("2026-1-03", nil, nil),
    ("", nil, nil),
    ("２０２６-11-03", nil, nil),
]

private let newYorkFormat: [FormatVector] = [
    (0, "1969-12-31T19:00:00.000"),
    (1, "1969-12-31T19:00:00.000001"),
    (999, "1969-12-31T19:00:00.000999"),
    (1000, "1969-12-31T19:00:00.001"),
    (1762197725123456, "2025-11-03T14:22:05.123456"),
    (1762197725123000, "2025-11-03T14:22:05.123"),
    (1762197725000000, "2025-11-03T14:22:05.000"),
    (1762197725000999, "2025-11-03T14:22:05.000999"),
    (-1, "1969-12-31T18:59:59.999999"),
    (-62135596800000000, "0000-12-31T19:00:00.000"),
    (-80000000000000000, "-0566-11-25T20:46:40.000"),
    (300000000000000000, "+011476-08-15T01:20:00.000"),
    (1773000000000000, "2026-03-08T16:00:00.000"),
    (1792900000000000, "2026-10-24T23:46:40.000"),
    (-2208988800000000, "1899-12-31T19:00:00.000"),
    (4102444800000000, "2099-12-31T19:00:00.000"),
]

/// Lord Howe Island: +10:30, with a half-hour DST shift, so it catches any
/// assumption that offsets move by whole hours.
private let lordHoweParse: [ParseVector] = [
    ("2026-11-03T14:22:05.123456", 1793676125123456, "2026-11-03T14:22:05.123456"),
    ("2026-11-03T14:22:05Z", 1793715725000000, "2026-11-04T01:22:05.000"),
    ("2026-11-03T14:22:05,5+05:30", 1793695925500000, "2026-11-03T19:52:05.500"),
    ("20261103", 1793624400000000, "2026-11-03T00:00:00.000"),
    ("2026-11-03T14-0130", 1793719800000000, "2026-11-04T02:30:00.000"),
    ("2020-13-01T25:61:61", 1609513321000000, "2021-01-02T02:02:01.000"),
    ("-0004-12-24", -62262558000000000, "-0004-12-24T00:00:00.000"),
    ("-123450101 00:00:00 Z", -451737734400000000, "-012345-01-01T11:00:00.000"),
    ("275760-09-13T00:00:00Z", 8640000000000000000, "+275760-09-13T10:30:00.000"),
    ("2026-04-05T01:45:00", 1775313900000000, "2026-04-05T01:45:00.000"),
    // Inside the half-hour spring-forward gap.
    ("2026-10-04T02:15:00", 1791042300000000, "2026-10-04T02:45:00.000"),
    ("0001-01-01T00:00:00", -62135636400000000, "0001-01-01T00:00:00.000"),
    ("1850-06-01T12:00:00", -3773773800000000, "1850-06-01T12:00:00.000"),
    ("2100-07-01T12:00:00", 4118088600000000, "2100-07-01T12:00:00.000"),
]

private let lordHoweFormat: [FormatVector] = [
    (0, "1970-01-01T10:00:00.000"),
    (1, "1970-01-01T10:00:00.000001"),
    (1762197725123456, "2025-11-04T06:22:05.123456"),
    (1762197725000000, "2025-11-04T06:22:05.000"),
    (-1, "1970-01-01T09:59:59.999999"),
    (-62135596800000000, "0001-01-01T11:00:00.000"),
    (-80000000000000000, "-0566-11-26T12:46:40.000"),
    (300000000000000000, "+011476-08-15T15:50:00.000"),
    (1773000000000000, "2026-03-09T07:00:00.000"),
    (1792900000000000, "2026-10-25T14:46:40.000"),
    (-2208988800000000, "1900-01-01T11:00:00.000"),
    (4102444800000000, "2100-01-01T11:00:00.000"),
]

private func micros(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
}

private func date(_ micros: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
}

@Suite("Dart DateTime format")
struct DartDateTimeTests {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let lordHowe = TimeZone(identifier: "Australia/Lord_Howe")!

    @Test func parsesAsDartDoesInNewYork() {
        check(newYorkParse, in: Self.newYork)
    }

    @Test func parsesAsDartDoesOnLordHowe() {
        check(lordHoweParse, in: Self.lordHowe)
    }

    @Test func formatsAsDartDoesInNewYork() {
        for (value, expected) in newYorkFormat {
            #expect(DartDateTime.string(from: date(value), timeZone: Self.newYork) == expected, "\(value)")
        }
    }

    @Test func formatsAsDartDoesOnLordHowe() {
        for (value, expected) in lordHoweFormat {
            #expect(DartDateTime.string(from: date(value), timeZone: Self.lordHowe) == expected, "\(value)")
        }
    }

    private func check(_ vectors: [ParseVector], in zone: TimeZone) {
        for vector in vectors {
            let parsed = DartDateTime.date(from: vector.input, timeZone: zone)
            #expect(parsed.map(micros) == vector.micros, "\(vector.input.debugDescription)")
            #expect(parsed.map { DartDateTime.string(from: $0, timeZone: zone) } == vector.local,
                    "\(vector.input.debugDescription)")
        }
    }

    /// What the stores rely on: a string written here reads back to a `Date`
    /// that writes the same string, at full microsecond precision.
    @Test func roundTripsEveryMicrosecond() {
        let zone = Self.newYork
        for value: Int64 in [1793733725123456, 1793733725000001, 1793733725999999, 1793733725000000, -1, 1] {
            let text = DartDateTime.string(from: date(value), timeZone: zone)
            let back = DartDateTime.date(from: text, timeZone: zone)
            #expect(back.map(micros) == value, "\(text)")
            #expect(back.map { DartDateTime.string(from: $0, timeZone: zone) } == text)
        }
        // And for whatever `Date()` happens to hold, sub-microsecond noise included.
        let now = Date()
        let text = DartDateTime.string(from: now, timeZone: zone)
        let back = DartDateTime.date(from: text, timeZone: zone)!
        #expect(DartDateTime.string(from: back, timeZone: zone) == text)
        #expect(abs(back.timeIntervalSince(now)) < 0.000_001)
    }

    /// The Dart code sorts these as TEXT; that has to agree with time order
    /// for timestamps written in one zone, including the `.mmm` form Dart uses
    /// when the microseconds are zero.
    @Test func textOrderIsTimeOrder() {
        let values: [Int64] = [1793733725000000, 1793733725000001, 1793733725000999, 1793733725001000,
                               1793733725123000, 1793733725123001, 1793733726000000, 1793820125000000]
        let strings = values.map { DartDateTime.string(from: date($0), timeZone: Self.newYork) }
        #expect(strings == strings.sorted())
        #expect(strings[0] == "2026-11-03T14:22:05.000")
        #expect(strings[1] == "2026-11-03T14:22:05.000001")
    }

    /// Dart's ints wrap, so a six-digit year past the range overflows into
    /// some other in-range instant, which Dart accepts. Matched rather than
    /// trapping; only to `Date`'s precision, which out there (±5e12 s) is
    /// about a millisecond.
    @Test func overflowingYearsWrapAsInDart() {
        let vectors: [(String, Int64?)] = [
            ("999999-01-01T00:00:00Z", -5398734902619103232),
            ("-999999-01-01T00:00:00Z", 5274400550619103232),
            ("999999-01-01", -5398734884619103232),
            ("275761-01-01T00:00:00Z", nil),
            ("2026-01-01T99:99:99Z", 1767588039000000),
        ]
        for (input, expected) in vectors {
            let parsed = DartDateTime.date(from: input, timeZone: Self.newYork).map(micros)
            if let expected, let parsed {
                #expect(abs(parsed - expected) < 2_000, "\(input)")
            } else {
                #expect(parsed == expected, "\(input)")
            }
        }
    }

    @Test func usesTheDeviceZoneByDefault() {
        let now = Date(timeIntervalSince1970: 1_793_733_725.5)
        #expect(DartDateTime.string(from: now) == DartDateTime.string(from: now, timeZone: .current))
        #expect(DartDateTime.date(from: "2026-11-03T14:22:05")
            == DartDateTime.date(from: "2026-11-03T14:22:05", timeZone: .current))
    }
}
