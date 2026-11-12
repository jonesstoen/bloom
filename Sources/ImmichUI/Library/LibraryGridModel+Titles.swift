import Foundation
import ImmichKit

/// Text shown around the grid: the header's date range and month, the footer, video badges.
extension LibraryGridModel {
    /// "23–29 Oct 2026", "29 Sep – 4 Oct 2026" or "4 Oct 2026", in the user's language.
    public nonisolated static func dateRangeTitle(from start: Date, to end: Date, locale: Locale = Localization.locale) -> String {
        let calendar = Asset.localCalendar
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                                    calendar: calendar, timeZone: .gmt))
        }
        let style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                             calendar: calendar, timeZone: .gmt)
        return (start..<end).formatted(style)
    }

    /// "June 2026": month titles (the bucket date is UTC-encoded wall-clock time).
    public nonisolated static func monthTitle(for bucket: TimeBucket, locale: Locale = Localization.locale) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: Asset.localCalendar, timeZone: .gmt)
        style = style.month(.wide).year()
        return bucket.startDate.formatted(style)
    }

    /// "0:07", "1:05", "1:02:03": video duration badge text.
    public nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "1,234 Photos, 56 Videos" for the footer, from the loaded assets (or "N Items" from counts).
    public var footerText: String {
        let counts = footerCounts
        guard counts.allLoaded else { return tr("%@ Items", counts.reported.formatted(.number.locale(Localization.locale))) }
        let photos = counts.photos
        let videos = counts.videos
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append(tr(photos == 1 ? "%@ Photo" : "%@ Photos", photos.formatted(.number.locale(Localization.locale)))) }
        if videos > 0 { parts.append(tr(videos == 1 ? "%@ Video" : "%@ Videos", videos.formatted(.number.locale(Localization.locale)))) }
        return parts.joined(separator: ", ")
    }
}
