import Foundation
import ImmichKit

/// When a photo was taken, as the viewer's title shows it, like Photos: "Today", "Yesterday",
/// the weekday within the last week, otherwise the full date.
enum ViewerDateText {
    /// - Parameters:
    ///   - date: the asset's `localDateTime` (wall-clock time encoded as UTC).
    ///   - now: the current wall-clock time, encoded the same way.
    static func day(of date: Date, now: Date = wallClockNow(), locale: Locale = Localization.locale,
                    today: String = tr("Today"), yesterday: String = tr("Yesterday")) -> String {
        let calendar = Asset.localCalendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        switch days {
        case 0: return today
        case 1: return yesterday
        case 2...6:
            let weekday = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).weekday(.wide))
            return weekday.prefix(1).uppercased() + weekday.dropFirst()
        default:
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).day().month(.wide).year())
        }
    }

    /// The phone's current time as wall-clock time encoded as UTC, comparable with `localDateTime`.
    static func wallClockNow() -> Date {
        let now = Date()
        return now.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: now)))
    }
}
