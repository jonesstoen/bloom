import Foundation
import ImmichKit

/// Picks the highlights for the Months and Years views, like Photos: a selection of a month's
/// best days (not all of them), each shown with its best photo, in a layout that varies.
///
/// Photos ranks by image analysis; Immich's timeline doesn't send that, so this scores what it
/// does send: Live Photos are almost always camera shots (high), favorites count extra, and
/// screenshots (the iPhone screen's shape, never Live Photos) and videos are avoided.
/// Choices rotate once a day (`seed`), and are stable within a day, so Years, Months and All
/// agree on the same photo.
public enum MonthHighlights {
    /// How a month's tiles are laid out.
    public enum Layout: Equatable, Sendable {
        /// Every tile in one row (1–3 days).
        case row
        /// The featured day as a wide tile, then a row of three (4 tiles).
        case wideTop
        /// A large featured square with two small tiles stacked beside it, then a row of three
        /// (6 tiles). `featuredOnLeft` alternates between months and days.
        case feature(featuredOnLeft: Bool)
    }

    public struct Plan: Equatable, Sendable {
        /// Tiles in display order. For `.wideTop` and `.feature` the first is the featured tile.
        public let tiles: [LibraryGridModel.DayTile]
        public let layout: Layout
        public var featured: LibraryGridModel.DayTile? { tiles.first }
    }

    /// A photo's worth as a highlight.
    public nonisolated static func score(_ asset: Asset) -> Int {
        if asset.isVideo { return -2 }
        var score = 1
        if asset.livePhotoVideoId != nil { score += 3 }
        if asset.isFavorite { score += 3 }
        if isLikelyScreenshot(asset) { score -= 6 }
        return score
    }

    /// iPhone screenshots have the screen's shape (about 9:19.5, either way round) and are never
    /// Live Photos; camera photos are 3:4, 9:16, 1:1 or panoramas.
    public nonisolated static func isLikelyScreenshot(_ asset: Asset) -> Bool {
        guard !asset.isVideo, asset.livePhotoVideoId == nil else { return false }
        let ratio = asset.aspectRatio
        return (0.44...0.48).contains(ratio) || (2.08...2.27).contains(ratio)
    }

    /// The day's best photo; among equally good ones the seed picks, so it rotates daily.
    public nonisolated static func bestPhoto(of assets: [Asset], seed: UInt64) -> Asset? {
        guard let best = assets.map(score).max() else { return nil }
        let candidates = assets.filter { score($0) == best }
        return candidates[Int(seed % UInt64(candidates.count))]
    }

    /// The plan for one month's days (in grid order). `seed` varies per month and per day.
    public nonisolated static func plan(days: [TimelineDay], seed: UInt64) -> Plan {
        let tiles: [(tile: LibraryGridModel.DayTile, score: Int, index: Int)] = days.enumerated().compactMap { index, day in
            let daySeed = mix(seed, UInt64(day.day))
            guard let photo = bestPhoto(of: day.assets, seed: daySeed) else { return nil }
            // A day's worth: its best photo, plus a little for how many good photos it has.
            let good = day.assets.filter { score($0) > 0 }.count
            let total = score(photo) * 10 + min(good, 30)
            return (LibraryGridModel.DayTile(id: day.id, day: day.day, cover: photo), total, index)
        }
        guard tiles.count > 3 else { return Plan(tiles: tiles.map(\.tile), layout: .row) }

        let photoCount = days.reduce(0) { $0 + $1.assets.count }
        let wanted = tiles.count >= 6 && photoCount >= 30 ? 6 : 4
        // Best days first; ties broken by the seed so equal days take turns.
        let ranked = tiles.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return mix(seed, UInt64($0.index)) < mix(seed, UInt64($1.index))
        }
        let chosen = Array(ranked.prefix(wanted))
        let featured = chosen[0]
        let others = chosen.dropFirst().sorted { $0.index < $1.index }.map(\.tile)
        let layout: Layout = wanted == 4 ? .wideTop : .feature(featuredOnLeft: mix(seed, 7) % 2 == 0)
        return Plan(tiles: [featured.tile] + others, layout: layout)
    }

    /// Seed for a month on a given day: changes daily, differs between months.
    public nonisolated static func seed(monthID: String, dayNumber: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a: stable across launches, unlike hashValue
        for byte in monthID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return mix(hash, UInt64(bitPattern: Int64(dayNumber)))
    }

    /// Days since 1970 (UTC) for `date`: the rotation period.
    public nonisolated static func dayNumber(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// SplitMix64-style mixing of two values.
    nonisolated static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a &+ (b &* 0x9e37_79b9_7f4a_7c15) &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
