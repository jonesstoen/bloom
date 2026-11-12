import Foundation
import ImmichKit
import Observation

/// A snapshot of the memory photos captured in one local calendar year.
public struct MemoryStoryYear: Identifiable, Sendable, Hashable {
    public let year: Int
    public let assets: [Asset]
    public var id: Int { year }

    public init(year: Int, assets: [Asset]) {
        self.year = year
        self.assets = assets
    }
}

@MainActor @Observable
public final class MemoryStoryModel {
    public let years: [MemoryStoryYear]
    public private(set) var yearIndex: Int
    public private(set) var assetIndex = 0
    public private(set) var isFinished: Bool

    public init(years: [MemoryStoryYear], startingYear: Int? = nil) {
        let snapshot = years.filter { !$0.assets.isEmpty }.sorted { $0.year > $1.year }
        self.years = snapshot
        yearIndex = snapshot.firstIndex { $0.year == startingYear } ?? 0
        isFinished = snapshot.isEmpty
    }

    public var currentYear: MemoryStoryYear? {
        years.indices.contains(yearIndex) ? years[yearIndex] : nil
    }

    public var currentAsset: Asset? {
        guard let year = currentYear, year.assets.indices.contains(assetIndex) else { return nil }
        return year.assets[assetIndex]
    }

    public var canGoPrevious: Bool {
        currentAsset != nil && (isFinished || yearIndex > 0 || assetIndex > 0)
    }

    public func next() {
        guard !isFinished, let year = currentYear else { return }
        if assetIndex + 1 < year.assets.count {
            assetIndex += 1
        } else if yearIndex + 1 < years.count {
            yearIndex += 1
            assetIndex = 0
        } else {
            isFinished = true
        }
    }

    public func previous() {
        guard canGoPrevious else { return }
        if isFinished {
            isFinished = false
        } else if assetIndex > 0 {
            assetIndex -= 1
        } else {
            yearIndex -= 1
            assetIndex = years[yearIndex].assets.count - 1
        }
    }

    public func selectYear(_ year: Int) {
        guard let index = years.firstIndex(where: { $0.year == year }) else { return }
        yearIndex = index
        assetIndex = 0
        isFinished = false
    }

    /// Use only assets supplied by Memories. Birthday metadata need not describe their years.
    public static func groupedYears(from memories: [Memory]) -> [MemoryStoryYear] {
        var seen: Set<String> = []
        var grouped: [Int: [Asset]] = [:]
        for memory in memories {
            for asset in memory.assets where seen.insert(asset.id).inserted {
                let year = Asset.localCalendar.component(.year, from: asset.localDateTime)
                grouped[year, default: []].append(asset)
            }
        }
        return grouped.keys.sorted(by: >).map { year in
            let assets = grouped[year, default: []].sorted {
                if $0.takenAt != $1.takenAt { return $0.takenAt < $1.takenAt }
                if $0.localDateTime != $1.localDateTime { return $0.localDateTime < $1.localDateTime }
                return $0.id < $1.id
            }
            return MemoryStoryYear(year: year, assets: assets)
        }
    }
}
