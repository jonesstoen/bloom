import Foundation
import ImmichKit

/// The Years and Months views: months grouped by year, and the highlights picked for each.
extension LibraryGridModel {
    /// A year in the Years view: its months in grid order and its number of items.
    public struct YearGroup: Identifiable, Sendable, Hashable {
        public let year: Int
        public let monthIDs: [String]
        public let count: Int
        public var id: Int { year }
    }

    /// One tile in the Months view: a day of the month with a representative photo.
    public struct DayTile: Identifiable, Sendable, Hashable {
        public let id: String
        /// Day of the month, shown as "8." on the tile.
        public let day: Int
        public let cover: Asset
    }

    /// Months grouped by year, in the grid's order.
    public nonisolated static func years(of months: [TimelineMonth]) -> [YearGroup] {
        var groups: [YearGroup] = []
        for month in months {
            if let last = groups.last, last.year == month.bucket.year {
                groups[groups.count - 1] = YearGroup(year: last.year, monthIDs: last.monthIDs + [month.id],
                                                     count: last.count + month.bucket.count)
            } else {
                groups.append(YearGroup(year: month.bucket.year, monthIDs: [month.id], count: month.bucket.count))
            }
        }
        return groups
    }

    public var years: [YearGroup] { Self.years(of: months) }

    /// The month's highlights for the Months view: a selection of its best days and their layout.
    /// Empty until the month is loaded.
    public func monthPlan(ofMonth id: String) -> MonthHighlights.Plan {
        guard let month = month(id: id), let days = month.days else { return MonthHighlights.Plan(tiles: [], layout: .row) }
        return MonthHighlights.plan(days: days, seed: MonthHighlights.seed(monthID: id, dayNumber: highlightDay))
    }

    /// The month's cover: the photo of its featured tile, so a year opens Months at that photo.
    /// `nil` until the month is loaded.
    public func coverAsset(ofMonth id: String) -> Asset? {
        monthPlan(ofMonth: id).featured?.cover
    }

    /// The month whose featured photo is the year's cover: one of the year's best months,
    /// taking turns daily. Until all its months are loaded, its most recent month.
    public func coverMonthID(ofYear year: YearGroup) -> String? {
        let newest = newestFirst ? year.monthIDs.first : year.monthIDs.last
        let loaded = year.monthIDs.compactMap { month(id: $0) }.filter(\.isLoaded)
        guard loaded.count == year.monthIDs.count, !loaded.isEmpty else { return newest }
        let ranked = loaded.compactMap { month -> (id: String, score: Int)? in
            guard let cover = coverAsset(ofMonth: month.id) else { return nil }
            let good = month.assets.filter { MonthHighlights.score($0) > 0 }.count
            return (month.id, MonthHighlights.score(cover) * 1000 + good)
        }
        .sorted { $0.score > $1.score }
        let top = ranked.prefix(3)
        guard !top.isEmpty else { return newest }
        let pick = MonthHighlights.mix(MonthHighlights.seed(monthID: "\(year.year)", dayNumber: highlightDay), 0) % UInt64(top.count)
        return top[top.startIndex + Int(pick)].id
    }
}
