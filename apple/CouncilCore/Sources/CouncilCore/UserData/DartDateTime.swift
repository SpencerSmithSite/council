// Dart's `DateTime.toIso8601String()` and `DateTime.parse`, reproduced
// exactly: the format of every timestamp the Flutter app stores.
//
// Ported from the Dart SDK the Flutter app builds with (3.x):
// sdk/lib/core/date_time.dart for the format and the parse grammar, and
// sdk/lib/_internal/vm_shared/lib/date_patch.dart for how the VM turns a
// local wall-clock time into an instant and back (`_brokenDownDateToValue`,
// `_toLocalTimeOffset`, `_equivalentSeconds`). Test vectors in
// DartDateTimeTests were produced by running the Dart SDK.

import Foundation

/// The timestamps in `council_user.db` and in the `bookmarks` preference.
///
/// The Flutter app writes `DateTime.now().toIso8601String()` everywhere. For a
/// local `DateTime` that is
///
///     yyyy-MM-ddTHH:mm:ss.mmm      when the microseconds part is zero
///     yyyy-MM-ddTHH:mm:ss.mmmuuu   otherwise (the usual case on iOS and macOS,
///                                  where `DateTime.now()` has microseconds)
///
/// in the device's local time **with no offset**; a UTC `DateTime` adds `Z`.
/// Years outside 0…9999 are written `-yyyy` or `±yyyyyy`.
///
/// The native app writes the same local format rather than something more
/// self-describing, because the Dart code orders highlights, notes and
/// conversations with `ORDER BY created_at DESC` / `updated_at DESC` on the
/// TEXT: a row written here with an offset or a `Z` would sort among the
/// Flutter rows by its characters, not its instant. The format sorts as text
/// only while the device stays in one time zone (a note written in New York
/// and one written after flying to London compare by wall clock, as do the two
/// 1:30s of a DST fall-back night); that is inherited from the Flutter app and
/// both apps have to keep agreeing on it. A `.mmm` string sorts before a
/// `.mmmuuu` one with the same milliseconds, which is also its correct order.
///
/// Parsing accepts everything `DateTime.parse` does, including `Z`, numeric
/// offsets, a space instead of `T`, compact `20120227T132700`, a comma before
/// the fraction and out-of-range fields that overflow into the next unit
/// (`2020-01-42` is 11 February), because rows and bookmarks may have been
/// written by any version of the Flutter app, or edited by hand.
///
/// Local times follow the VM exactly, quirks included: a wall time skipped by
/// a DST change resolves as the old offset would have it (2:30 on a
/// spring-forward night is 3:30), a repeated one to its first occurrence, and
/// dates outside 1901–2038 take the offset of an equivalent year in 2008–2037
/// (so no historical local mean time). Both directions use the proleptic
/// Gregorian calendar, as Dart does, so no `Calendar` is involved
/// (Foundation's Gregorian calendar switches to Julian before 1582).
public enum DartDateTime {
    /// `DateTime.toIso8601String()` of `date` as a local time in `timeZone`.
    ///
    /// Truncated to Dart's precision, whole microseconds. The value is rounded
    /// to the nearest microsecond first, so a `Date` that came from
    /// `date(from:)` formats back to the string it was parsed from, despite
    /// `Date` being a binary floating-point number of seconds.
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        // `_localDateInUtcMicros`, then `_computeUpperPart`.
        let local = micros + offset(micros, timeZone) * microsPerSecond
        let days = floorDiv(local, microsPerDay)
        let (year, month, day) = civil(fromDays: days)
        let microOfDay = local - days * microsPerDay
        let secondOfDay = Int(microOfDay / microsPerSecond)
        let millisecond = Int(microOfDay % microsPerSecond / 1000)
        let microsecond = Int(microOfDay % 1000)

        var out = year >= -9999 && year <= 9999 ? fourDigits(year) : sixDigits(year)
        out += "-" + twoDigits(month) + "-" + twoDigits(day)
        out += "T" + twoDigits(secondOfDay / 3600) + ":" + twoDigits(secondOfDay / 60 % 60)
        out += ":" + twoDigits(secondOfDay % 60) + "." + threeDigits(millisecond)
        if microsecond != 0 { out += threeDigits(microsecond) }
        return out
    }

    /// `DateTime.parse(text)`, or nil where Dart would throw a
    /// `FormatException`. A string without a zone designator is a local time
    /// in `timeZone`.
    public static func date(from text: String, timeZone: TimeZone = .current) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        // Every group is at most six ASCII digits (plus a sign for the year).
        func number(_ index: Int) -> Int64 { group(index).flatMap { Int64($0) } ?? 0 }

        let year = number(1), month = number(2), day = number(3)
        let hour = number(4), second = number(6)
        var minute = number(5)
        // `parseMilliAndMicroseconds`: the first six fraction digits count,
        // the rest are ignored, not rounded.
        var fraction: Int64 = 0
        let digits = Array((group(7) ?? "").utf8.prefix(6))
        for index in 0..<6 {
            fraction = fraction * 10 + (index < digits.count ? Int64(digits[index] - 0x30) : 0)
        }

        var isUTC = false
        if group(8) != nil {
            isUTC = true
            if let sign = group(9) {
                let offsetMinutes = number(10) * 60 + number(11)
                minute -= (sign == "-" ? -1 : 1) * offsetMinutes
            }
        }

        // `_brokenDownDateToValue`.
        var monthIndex = month - 1
        var normalisedYear = year
        if monthIndex >= 12 {
            normalisedYear += monthIndex / 12
            monthIndex %= 12
        } else if monthIndex < 0 {
            let realMonth = positiveMod(monthIndex, 12)
            normalisedYear += (monthIndex - realMonth) / 12
            monthIndex = realMonth
        }
        let leap = isLeapYear(normalisedYear) ? 1 : 0
        let days = day - 1 + daysUntilMonth[leap][Int(monthIndex)] + dayFromYear(normalisedYear)
        // Wrapping, because Dart's 64-bit ints wrap: a year past ~292,000
        // overflows, and Dart then accepts whatever in-range instant the
        // wrapped value lands on ("999999-01-01T00:00:00Z" is a date in
        // −169110). Trapping here would turn a corrupt row into a crash.
        var micros = days &* microsPerDay &+ hour &* 3_600 &* microsPerSecond
            &+ minute &* 60 &* microsPerSecond &+ second &* microsPerSecond &+ fraction

        if !isUTC {
            guard micros.magnitude <= UInt64(maxMicros + microsPerDay) else { return nil }
            micros -= toLocalTimeOffset(micros, timeZone)
        }
        guard micros.magnitude <= UInt64(maxMicros) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
    }

    /// Dart's `_parseFormat`, with two changes that keep it meaning what it
    /// means in Dart: `\d` is spelled `[0-9]` (ICU's `\d` matches any Unicode
    /// digit, Dart's only ASCII), and `$` is `\z` (ICU's `$` also matches before
    /// a final newline, Dart's does not).
    private static let pattern = try! NSRegularExpression(pattern:
        #"^([+-]?[0-9]{4,6})-?([0-9][0-9])-?([0-9][0-9])"#
        + #"(?:[ T]([0-9][0-9])(?::?([0-9][0-9])(?::?([0-9][0-9])(?:[.,]([0-9]+))?)?)?"#
        + #"( ?[zZ]| ?([-+])([0-9][0-9])(?::?([0-9][0-9]))?)?)?\z"#)

    // MARK: - The VM's local-time conversion, verbatim

    private static let microsPerSecond: Int64 = 1_000_000
    private static let microsPerDay: Int64 = 86_400_000_000
    private static let microsPerHour: Int64 = 3_600_000_000
    /// `_maxMillisecondsSinceEpoch` (100,000,000 days) in microseconds.
    private static let maxMicros: Int64 = 8_640_000_000_000_000_000

    private static let daysUntilMonth: [[Int64]] = [
        [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334],
        [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335],
    ]

    /// `_timeZoneOffsetInSeconds`: the zone's offset at that instant, looked
    /// up in an equivalent year when it falls outside what 32-bit `time_t`
    /// covers.
    static func offset(_ micros: Int64, _ timeZone: TimeZone) -> Int64 {
        Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(equivalentSeconds(micros)))))
    }

    /// `_toLocalTimeOffset`: the offset (in microseconds) to subtract from a
    /// wall-clock time read as UTC to get the instant it names.
    private static func toLocalTimeOffset(_ micros: Int64, _ timeZone: TimeZone) -> Int64 {
        var offset = Self.offset(micros, timeZone) * microsPerSecond
        if offset != 0 {
            let offset2 = Self.offset(micros - offset, timeZone) * microsPerSecond
            if offset2 != offset {
                let offset3 = Self.offset(micros - offset2, timeZone) * microsPerSecond
                return offset2 <= offset3 ? offset2 : offset3
            }
            offset = offset2
        }
        let offset4 = Self.offset(micros - offset - 2 * microsPerHour, timeZone) * microsPerSecond
        if offset4 > offset {
            if offset4 == offset + 2 * microsPerHour { return offset4 }
            let offset5 = Self.offset(micros - offset4, timeZone) * microsPerSecond
            if offset5 == offset4 { return offset4 }
        }
        return offset
    }

    /// `_equivalentSeconds`.
    private static func equivalentSeconds(_ micros: Int64) -> Int64 {
        var seconds = floorDiv(micros, microsPerSecond)
        if abs(seconds) > 0x7FFF_FFFF {
            let year = yearFromSeconds(seconds)
            seconds += (dayFromYear(equivalentYear(year)) - dayFromYear(year)) * 86_400
        }
        return seconds
    }

    /// `_yearsFromSecondsSinceEpoch` (its fast path and its slow path agree).
    private static func yearFromSeconds(_ seconds: Int64) -> Int64 {
        Int64(civil(fromDays: floorDiv(seconds, 86_400)).year)
    }

    /// `_equivalentYear`: a year in 2008…2035 with the same leap-ness and the
    /// same weekday on 1 January.
    private static func equivalentYear(_ year: Int64) -> Int64 {
        let weekDay = positiveMod(dayFromYear(year) + 4, 7)
        let recentYear = (isLeapYear(year) ? 1956 : 1967) + weekDay * 12
        return 2008 + positiveMod(recentYear - 2008, 28)
    }

    /// `_dayFromYear`: days from 1970-01-01 to 1 January of `year`.
    static func dayFromYear(_ year: Int64) -> Int64 {
        365 * (year - 1970) + floorDiv(year - 1969, 4) - floorDiv(year - 1901, 100) + floorDiv(year - 1601, 400)
    }

    private static func isLeapYear(_ y: Int64) -> Bool {
        y % 4 == 0 && (y % 16 == 0 || y % 100 != 0)
    }

    /// Howard Hinnant's `civil_from_days`, equivalent to `_computeUpperPart`'s
    /// date fields for days since 1970-01-01.
    static func civil(fromDays days: Int64) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        let year = Int(yearOfEra + era * 400) + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// Dart's `~/` rounds toward zero like Swift's `/`; `_flooredDivision`
    /// rounds down.
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Dart's `%`, which is never negative for a positive divisor.
    private static func positiveMod(_ a: Int64, _ b: Int64) -> Int64 {
        let r = a % b
        return r < 0 ? r + b : r
    }

    // MARK: - Dart's padding helpers, verbatim

    private static func fourDigits(_ n: Int) -> String {
        let absN = abs(n)
        let sign = n < 0 ? "-" : ""
        if absN >= 1000 { return "\(n)" }
        if absN >= 100 { return "\(sign)0\(absN)" }
        if absN >= 10 { return "\(sign)00\(absN)" }
        return "\(sign)000\(absN)"
    }

    private static func sixDigits(_ n: Int) -> String {
        let absN = abs(n)
        let sign = n < 0 ? "-" : "+"
        if absN >= 100_000 { return "\(sign)\(absN)" }
        return "\(sign)0\(absN)"
    }

    private static func threeDigits(_ n: Int) -> String {
        if n >= 100 { return "\(n)" }
        if n >= 10 { return "0\(n)" }
        return "00\(n)"
    }

    private static func twoDigits(_ n: Int) -> String {
        n >= 10 ? "\(n)" : "0\(n)"
    }
}
