import Foundation
import ImmichKit

/// Lookups between grid cells, months and assets, rebuilt whenever the months change.
///
/// The grid is one continuous list of cells: the assets of loaded months, and placeholders
/// (sized from the bucket count) for months not loaded yet. These lookups run on every scroll
/// frame, so they are precomputed here instead of using `TimelineMonth.assets`, which flattens
/// the days on every call.
struct GridCellIndex {
    /// Photo and video counts for the footer, gathered in the same pass.
    struct FooterCounts: Equatable {
        var allLoaded = true
        var reported = 0
        var photos = 0
        var videos = 0
    }

    private(set) var months: [TimelineMonth] = []
    /// Per month: its assets (empty until loaded), its first cell and its number of cells.
    private var monthAssets: [[Asset]] = []
    private var monthStarts: [Int] = []
    private var monthCellCounts: [Int] = []
    private var monthIndexByID: [String: Int] = [:]
    private var monthIDByAssetID: [String: String] = [:]
    private var assetIndexInMonth: [String: Int] = [:]

    /// Every loaded asset in grid order, and the position of each in that list (what the
    /// prefetcher works with: it never sees placeholders).
    private(set) var assetIDs: [String] = []
    private(set) var assetPositionByID: [String: Int] = [:]

    /// Number of cells: loaded assets plus placeholders.
    private(set) var cellCount = 0
    private(set) var footerCounts = FooterCounts()

    init() {}

    init(months: [TimelineMonth]) {
        self.months = months
        monthIndexByID = Dictionary(months.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        monthAssets = months.map { $0.isLoaded ? $0.assets : [] }
        monthCellCounts = months.indices.map { months[$0].isLoaded ? monthAssets[$0].count : months[$0].bucket.count }
        var start = 0
        monthStarts = monthCellCounts.map { count in defer { start += count }; return start }
        cellCount = start

        var positions: [String: Int] = [:]
        var monthByAsset: [String: String] = [:]
        var ids: [String] = []
        var videos = 0
        for (month, assets) in zip(months, monthAssets) {
            for (i, asset) in assets.enumerated() {
                positions[asset.id] = i
                if monthByAsset[asset.id] == nil { monthByAsset[asset.id] = month.id }
                ids.append(asset.id)
                if asset.isVideo { videos += 1 }
            }
        }
        assetIndexInMonth = positions
        monthIDByAssetID = monthByAsset
        assetIDs = ids
        assetPositionByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        footerCounts = FooterCounts(allLoaded: months.allSatisfy(\.isLoaded),
                                    reported: months.reduce(0) { $0 + $1.bucket.count },
                                    photos: ids.count - videos, videos: videos)
    }

    /// The position of month `id` in `months`.
    func monthIndex(of id: String) -> Int? { monthIndexByID[id] }

    /// The month (bucket id) containing a loaded asset.
    func monthID(ofAsset assetID: String) -> String? { monthIDByAssetID[assetID] }

    /// The month containing cell `index` and the position within it.
    private func cell(at index: Int) -> (month: Int, offset: Int)? {
        guard index >= 0, index < cellCount else { return nil }
        var low = 0, high = monthStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if monthStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        // Skip empty months that start at the same cell.
        var month = low
        while month < monthCellCounts.count - 1 && monthCellCounts[month] == 0 { month += 1 }
        return (month, index - monthStarts[month])
    }

    /// The identity of cell `index`: the asset's id, or the placeholder slot of an unloaded month.
    func itemID(at index: Int) -> AnyHashable? {
        guard let (month, offset) = cell(at: index) else { return nil }
        if months[month].isLoaded { return AnyHashable(monthAssets[month][offset].id) }
        return AnyHashable(PlaceholderSlot(monthID: months[month].id, index: offset))
    }

    /// The loaded asset in cell `index` (`nil` for placeholders).
    func asset(at index: Int) -> Asset? {
        guard let (month, offset) = cell(at: index), months[month].isLoaded else { return nil }
        return monthAssets[month][offset]
    }

    /// The first cell of month `id`.
    func firstIndex(ofMonth id: String) -> Int? {
        guard let month = monthIndexByID[id], month < monthStarts.count else { return nil }
        return monthStarts[month]
    }

    /// The month of cell `index` (loaded or not).
    func monthID(at index: Int) -> String? {
        guard let (month, _) = cell(at: index) else { return nil }
        return months[month].id
    }

    /// The cell of a loaded asset.
    func index(ofAsset assetID: String) -> Int? {
        guard let monthID = monthIDByAssetID[assetID], let month = monthIndexByID[monthID],
              let offset = assetIndexInMonth[assetID] else { return nil }
        return monthStarts[month] + offset
    }
}

/// The identity of a placeholder cell in an unloaded month: unique across months, so the one
/// continuous grid never repeats an ID.
struct PlaceholderSlot: Hashable {
    let monthID: String
    let index: Int
}
