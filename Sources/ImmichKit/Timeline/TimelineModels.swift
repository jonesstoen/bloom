import Foundation

/// One month of the library as reported by `GET /timeline/buckets`.
public struct TimeBucket: Sendable, Hashable, Identifiable, Codable {
    /// The server's bucket key, e.g. `"2024-01-01"`. Sent back unchanged to load the bucket's assets.
    public var id: String
    public var year: Int
    public var month: Int
    /// Number of assets the server reports for this month.
    public var count: Int

    public init(id: String, year: Int, month: Int, count: Int) {
        self.id = id
        self.year = year
        self.month = month
        self.count = count
    }

    /// Builds a bucket from the server key (`"YYYY-MM-DD"` or a full ISO timestamp). `nil` if unparseable.
    public init?(key: String, count: Int) {
        let parts = key.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }
        self.init(id: key, year: year, month: month, count: count)
    }

    /// Key in the spec's `YYYY-MM-DD` form for the first day of `year`/`month`.
    public static func key(year: Int, month: Int) -> String {
        String(format: "%04d-%02d-01", year, month)
    }

    /// First moment of the month on the local wall clock (UTC-encoded, see `Asset.localDateTime`).
    public var startDate: Date {
        Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }
}

/// Which assets a timeline shows and in which order. Maps to the `/timeline/*` query parameters.
public struct TimelineOptions: Sendable, Hashable {
    public enum Visibility: String, Sendable, Hashable, CaseIterable, Codable {
        /// The main library (not archived, hidden or locked).
        case timeline
        case archive
    }

    public var albumId: String?
    public var personId: String?
    /// `true`: favorites only. `nil`: no filter.
    public var isFavorite: Bool?
    /// `true`: trash only. `nil`: server default.
    public var isTrashed: Bool?
    /// `nil` lets the server decide (needed for album timelines, which include archived assets).
    public var visibility: Visibility?
    /// `true` (default): newest month and newest asset first, like Photos.
    public var newestFirst: Bool
    /// Return only the primary asset of each stack.
    public var withStacked: Bool?
    public var withPartners: Bool?
    /// Group and order by the date assets were added to Immich instead of the date taken
    /// ("Sort by Recently Added" in Photos). The mock ignores it (it has no upload dates).
    public var sortsByDateAdded: Bool

    public init(
        albumId: String? = nil,
        personId: String? = nil,
        isFavorite: Bool? = nil,
        isTrashed: Bool? = nil,
        visibility: Visibility? = .timeline,
        newestFirst: Bool = true,
        withStacked: Bool? = true,
        withPartners: Bool? = nil,
        sortsByDateAdded: Bool = false
    ) {
        self.albumId = albumId
        self.personId = personId
        self.isFavorite = isFavorite
        self.isTrashed = isTrashed
        self.visibility = visibility
        self.newestFirst = newestFirst
        self.withStacked = withStacked
        self.withPartners = withPartners
        self.sortsByDateAdded = sortsByDateAdded
    }

    /// The main Library tab.
    public static let library = TimelineOptions()

    public static func album(_ id: String) -> TimelineOptions {
        TimelineOptions(albumId: id, visibility: nil)
    }

    public static func person(_ id: String) -> TimelineOptions {
        TimelineOptions(personId: id)
    }
}

/// The assets taken on one (local) day.
public struct TimelineDay: Sendable, Hashable, Identifiable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var assets: [Asset]

    public init(year: Int, month: Int, day: Int, assets: [Asset]) {
        self.year = year
        self.month = month
        self.day = day
        self.assets = assets
    }

    /// `"2024-03-07"`.
    public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Midnight of the day on the local wall clock (UTC-encoded). Format with a UTC time zone.
    public var date: Date {
        Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

/// One month section of the timeline. `days` is `nil` until its assets are loaded.
public struct TimelineMonth: Sendable, Hashable, Identifiable {
    public var bucket: TimeBucket
    public var days: [TimelineDay]?

    public init(bucket: TimeBucket, days: [TimelineDay]? = nil) {
        self.bucket = bucket
        self.days = days
    }

    public var id: String { bucket.id }
    public var isLoaded: Bool { days != nil }
    /// Loaded assets in display order, or empty if not loaded.
    public var assets: [Asset] { days?.flatMap(\.assets) ?? [] }
    /// The loaded asset count if known, else the server's count (for sizing placeholders).
    public var assetCount: Int { days.map { $0.reduce(0) { $0 + $1.assets.count } } ?? bucket.count }
}

public enum TimelineGrouping {
    /// Groups assets into days by `localDateTime` (UTC calendar). Days and the assets in each day
    /// are sorted newest first when `newestFirst`, else oldest first. Ties keep the input order.
    public static func days(from assets: [Asset], newestFirst: Bool = true) -> [TimelineDay] {
        let calendar = Asset.localCalendar
        var byDay: [DateComponents: [Asset]] = [:]
        for asset in assets {
            let parts = calendar.dateComponents([.year, .month, .day], from: asset.localDateTime)
            byDay[parts, default: []].append(asset)
        }
        let days = byDay.map { parts, assets in
            let sorted = assets.enumerated().sorted { a, b in
                if a.element.takenAt != b.element.takenAt {
                    return newestFirst ? a.element.takenAt > b.element.takenAt : a.element.takenAt < b.element.takenAt
                }
                return a.offset < b.offset
            }.map(\.element)
            return TimelineDay(year: parts.year!, month: parts.month!, day: parts.day!, assets: sorted)
        }
        return days.sorted { newestFirst ? $0.id > $1.id : $0.id < $1.id }
    }
}
