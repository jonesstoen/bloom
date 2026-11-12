import Foundation
import ImmichKit

/// What VoiceOver reads for the photo or video in the viewer: "Photo, 11 November 2025, Oslo".
enum ViewerAccessibility {
    static func label(for asset: Asset, place: String?, locale: Locale = Localization.locale) -> String {
        let kind = asset.isVideo ? tr("Video") : asset.isLivePhoto ? tr("Live Photo") : tr("Photo")
        let date = asset.localDateTime.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale,
                                                                  calendar: Asset.localCalendar, timeZone: .gmt))
        return ([kind, date] + [place].compactMap { $0 }).joined(separator: ", ")
    }
}
