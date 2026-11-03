// Port of lib/src/util/relative_date.dart (`formatWhen`).

import Foundation

/// A date a reader can place at a glance, for the Notes lists.
///
/// A time today, a weekday this week, a date beyond that. Deliberately not
/// "3 days ago": relative phrasing reads well in a feed and badly in a list
/// someone is scanning for the thing they wrote on Sunday. English and
/// lower-case "am"/"pm" exactly as the Dart writes them, so the two apps show
/// a note's date the same way.
///
/// One deliberate difference from the Dart: the days between two dates are
/// counted as calendar days. The Dart takes `today.difference(day).inDays`
/// between two local midnights, which is elapsed time truncated to whole
/// 24-hour days, so across a spring-forward night (a 23-hour day) yesterday
/// comes out as 0 days and is shown as a time, and two days ago as
/// "Yesterday". That is a bug in the Dart, not a choice; the intent, which
/// the doc comment states, is calendar days.
public enum RelativeDate {
    public static func format(_ when: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let difference = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: when), to: calendar.startOfDay(for: now)).day ?? 0
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: when)
        let hour24 = parts.hour ?? 0
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1

        if difference == 0 {
            let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
            let minute = parts.minute ?? 0
            return "\(hour):\(minute < 10 ? "0" : "")\(minute) \(hour24 < 12 ? "am" : "pm")"
        }
        if difference == 1 { return "Yesterday" }
        // Negative (a date in the future, from a clock that has since been
        // corrected) falls in here too, as it does in the Dart.
        if difference < 7 { return weekdays[(parts.weekday ?? 1) - 1] }
        if year == calendar.component(.year, from: now) { return "\(day) \(months[month - 1])" }
        return "\(day) \(months[month - 1]) \(year)"
    }

    /// In `Calendar`'s weekday order, which starts on Sunday (Dart's starts on
    /// Monday; only the indexing differs).
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
