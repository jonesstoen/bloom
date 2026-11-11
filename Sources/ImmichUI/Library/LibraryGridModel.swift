import Foundation
import ImmichKit
import Observation

/// State behind `LibraryGridView`: the month skeleton of a `Timeline`, lazily loaded months,
/// and the visible range reported to a `Prefetcher`.
///
/// The grid shows every month as a section right away (sized from the bucket counts with
/// placeholder cells), and loads a month's assets when one of its cells appears, together with
/// its neighbours. Visible cells report themselves so the prefetcher can load thumbnails ahead.
@MainActor
@Observable
public final class LibraryGridModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Months in display order. Unloaded months have `days == nil`.
    public private(set) var months: [TimelineMonth] = []
    public private(set) var phase: Phase = .idle
    /// Five columns by default; the Library tab remembers the user's choice.
    public var density: GridDensity = .five
    public var columnCount: Int { density.rawValue }
    public var visibleAnchorID: String? {
        visibleIDs.min { (assetIndexByID[$0] ?? .max) < (assetIndexByID[$1] ?? .max) }
    }
    /// The visible asset in the middle of the visible range: the anchor that stays in place
    /// when the grid density changes, so a pinch keeps what you are looking at on screen.
    public var visibleCenterID: String? {
        let sorted = visibleIDs.compactMap { id in assetIndexByID[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2].0
    }

    /// Replaced when the sort or filter changes (`setOptions`).
    @ObservationIgnored public private(set) var timeline: Timeline
    /// The current sort and filter options.
    public private(set) var options: TimelineOptions
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored public let prefetcher: Prefetcher
    @ObservationIgnored public let images: ThumbnailImageCache

    /// Title of the month in the middle of the screen ("November 2026"), for the header subtitle.
    public private(set) var visibleMonthTitle: String?
    /// The dates of the photos on screen ("23–29 Oct 2026"), like the Library header in Photos.
    public private(set) var visibleDateRangeTitle: String?
    @ObservationIgnored private var screenRange: ClosedRange<Int>?

    @ObservationIgnored private var monthIndexByID: [String: Int] = [:]
    @ObservationIgnored private var monthIDByAssetID: [String: String] = [:]
    /// Index of each loaded asset in the flat list sent to the prefetcher.
    @ObservationIgnored private(set) var assetIndexByID: [String: Int] = [:]
    @ObservationIgnored private(set) var flatAssetIDs: [String] = []
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var loadingMonths: Set<String> = []
    @ObservationIgnored private(set) var lastVisibleRange: Range<Int>?

    private enum PrefetchUpdate: Sendable {
        case assets([String])
        case visible(Range<Int>)
        case cancel
    }

    /// Updates go through one stream so the prefetcher sees them in order.
    @ObservationIgnored private let updates: AsyncStream<PrefetchUpdate>.Continuation

    /// - Parameters:
    ///   - options: defaults to the library, oldest month first with the newest at the bottom like Photos.
    ///   - loader: shared image loader; defaults to one with a disk cache.
    public init(
        service: any ImmichService,
        options: TimelineOptions = TimelineOptions(newestFirst: false),
        loader: ImageLoader? = nil,
        prefetch: Prefetcher.Configuration = Prefetcher.Configuration(),
        images: ThumbnailImageCache? = nil
    ) {
        let loader = loader ?? ImageLoader(service: service)
        let prefetcher = Prefetcher(loader: loader, size: .thumbnail, configuration: prefetch)
        self.timeline = Timeline(service: service, options: options)
        self.options = options
        self.newestFirst = options.newestFirst
        self.service = service
        self.loader = loader
        self.prefetcher = prefetcher
        self.images = images ?? ThumbnailImageCache()

        let (stream, continuation) = AsyncStream<PrefetchUpdate>.makeStream()
        self.updates = continuation
        Task {
            for await update in stream {
                switch update {
                case .assets(let ids): await prefetcher.setAssets(ids)
                case .visible(let range): await prefetcher.visibleRangeChanged(range)
                case .cancel: await prefetcher.cancelAll()
                }
            }
        }
    }

    deinit {
        updates.yield(.cancel)
        updates.finish()
    }

    /// `false` (default): oldest first, so the grid starts scrolled to the bottom.
    public nonisolated let newestFirst: Bool

    /// Total number of assets according to the server's bucket counts.
    public var totalCount: Int { months.reduce(0) { $0 + $1.bucket.count } }

    public var isEmpty: Bool { phase == .loaded && months.allSatisfy { $0.bucket.count == 0 } }

    /// Only expose contiguous loaded months, so paging never jumps across an unloaded gap.
    public func viewerAssets(around assetID: String) -> [Asset] {
        guard let index = months.firstIndex(where: { $0.assets.contains(where: { $0.id == assetID }) }) else { return [] }
        var lower = index
        var upper = index
        while lower > 0 && months[lower - 1].isLoaded { lower -= 1 }
        while upper + 1 < months.count && months[upper + 1].isLoaded { upper += 1 }
        return months[lower...upper].flatMap(\.assets)
    }

    // MARK: Loading

    /// Loads the month skeleton, then the months at the end the grid starts at
    /// (the newest ones). Calling it again refreshes the buckets.
    public func load() async {
        if months.isEmpty { phase = .loading }
        let timeline = self.timeline
        do {
            let loaded = try await timeline.loadBuckets()
            guard timeline === self.timeline else { return }
            apply(loaded)
            phase = .loaded
        } catch is CancellationError {
            if months.isEmpty { phase = .idle }
            return
        } catch {
            if months.isEmpty { phase = .failed(error.localizedDescription) }
            return
        }
        let start = newestFirst ? Array(months.prefix(2)) : Array(months.suffix(2))
        await withTaskGroup(of: Void.self) { group in
            for month in start {
                group.addTask { await self.loadMonth(month.id) }
            }
        }
    }

    /// Loads the month if needed. Failures leave the placeholders and are retried on the next appear.
    public func loadMonth(_ id: String) async {
        guard let index = monthIndexByID[id], !months[index].isLoaded, !loadingMonths.contains(id) else { return }
        loadingMonths.insert(id)
        defer { loadingMonths.remove(id) }
        let timeline = self.timeline
        do {
            try await timeline.loadMonth(id)
            // Ignore months of a timeline replaced by a new sort or filter meanwhile.
            guard timeline === self.timeline else { return }
            apply(await timeline.months)
        } catch {
            // Keep placeholders; the next appear retries.
        }
    }

    /// A cell (asset or placeholder) of month `id` appeared: load it and its neighbours.
    public func monthAppeared(_ id: String) {
        guard let index = monthIndexByID[id] else { return }
        let ids = [index, index - 1, index + 1]
            .filter { months.indices.contains($0) && !months[$0].isLoaded && !loadingMonths.contains(months[$0].id) }
            .map { months[$0].id }
        for monthID in ids {
            Task { await loadMonth(monthID) }
        }
    }


    // MARK: Grid cells

    /// Per month, cached when months change: its assets (empty until loaded), its first cell and
    /// its number of cells. Cell lookups run on every scroll frame, so they must not rebuild
    /// the asset lists (`TimelineMonth.assets` flattens the days on every call).
    @ObservationIgnored private var monthAssets: [[Asset]] = []
    @ObservationIgnored private var monthStarts: [Int] = []
    @ObservationIgnored private var monthCellCounts: [Int] = []
    @ObservationIgnored private var assetIndexInMonth: [String: Int] = [:]

    /// Number of cells in the grid: loaded assets, plus placeholders for months not loaded yet.
    public private(set) var gridItemCount = 0

    /// The month containing grid cell `index` and the position within it.
    private func cell(at index: Int) -> (month: Int, offset: Int)? {
        guard index >= 0, index < gridItemCount else { return nil }
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

    /// The scroll ID of grid cell `index`: the asset's id, or the placeholder slot of an unloaded
    /// month, so the grid can scroll to any cell.
    public func gridItemID(atGridIndex index: Int) -> AnyHashable? {
        guard let (month, offset) = cell(at: index) else { return nil }
        if months[month].isLoaded { return AnyHashable(monthAssets[month][offset].id) }
        return AnyHashable(PlaceholderSlots.Slot(monthID: months[month].id, index: offset))
    }

    /// The asset in grid cell `index`, or `nil` when that cell is a placeholder.
    public func assetID(atGridIndex index: Int) -> String? { gridAsset(atGridIndex: index)?.id }

    /// The loaded asset in grid cell `index` (`nil` for placeholders).
    public func gridAsset(atGridIndex index: Int) -> Asset? {
        guard let (month, offset) = cell(at: index), months[month].isLoaded else { return nil }
        return monthAssets[month][offset]
    }

    /// The grid cell of a loaded asset.
    public func gridIndex(ofAsset assetID: String) -> Int? {
        guard let monthID = monthIDByAssetID[assetID], let month = monthIndexByID[monthID],
              let offset = assetIndexInMonth[assetID] else { return nil }
        return monthStarts[month] + offset
    }

    private func rebuildCellIndex() {
        monthAssets = months.map { $0.isLoaded ? $0.assets : [] }
        monthCellCounts = months.indices.map { months[$0].isLoaded ? monthAssets[$0].count : months[$0].bucket.count }
        var start = 0
        monthStarts = monthCellCounts.map { count in defer { start += count }; return start }
        gridItemCount = start
        var positions: [String: Int] = [:]
        for assets in monthAssets { for (i, asset) in assets.enumerated() { positions[asset.id] = i } }
        assetIndexInMonth = positions
    }

    // MARK: Years and months

    /// A year in the Years view: its months in grid order and its number of items.
    public struct YearGroup: Identifiable, Sendable, Hashable {
        public let year: Int
        public let monthIDs: [String]
        public let count: Int
        public var id: Int { year }
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

    public func month(id: String) -> TimelineMonth? {
        monthIndexByID[id].map { months[$0] }
    }

    /// One tile in the Months view: a day of the month with a representative photo.
    public struct DayTile: Identifiable, Sendable, Hashable {
        public let id: String
        /// Day of the month, shown as "8." on the tile.
        public let day: Int
        public let cover: Asset
    }

    /// Today's rotation for highlights (days since 1970). Tests set it to fixed days.
    public var highlightDay = MonthHighlights.dayNumber(Date())

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

    /// Set by the Months and Years views; the grid scrolls to this month's first cell and clears it.
    public var pendingScrollMonthID: String?
    /// Set by a day tile in Months; the grid centres this asset and clears it.
    public var pendingScrollAssetID: String?

    /// The scroll ID of the first cell of month `id` (an asset, or a placeholder slot).
    public func firstGridID(ofMonth id: String) -> AnyHashable? {
        guard let month = month(id: id) else { return nil }
        if month.isLoaded, let first = month.assets.first { return AnyHashable(first.id) }
        return month.bucket.count > 0 ? AnyHashable(PlaceholderSlots.Slot(monthID: id, index: 0)) : nil
    }



    /// Whether every month's assets are loaded (the Months view needs their final heights).
    public var allMonthsLoaded: Bool { !months.isEmpty && months.allSatisfy(\.isLoaded) }

    /// Loads every month not loaded yet, a few at a time, and applies them once at the end
    /// (applying after each month would rebuild the grid ~100 times). Cached by the timeline,
    /// so this happens once per session.
    public func loadAllMonths() async {
        let timeline = self.timeline
        let ids = months.filter { !$0.isLoaded && !loadingMonths.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        loadingMonths.formUnion(ids)
        defer { loadingMonths.subtract(ids) }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { try? await timeline.loadMonth(id) }
            }
            for _ in 0..<6 { add() }
            while await group.next() != nil { add() }
        }
        guard timeline === self.timeline else { return }
        apply(await timeline.months)
    }

    /// A loaded asset moved to another grid cell because months before it changed size.
    public struct GridShift: Equatable, Sendable {
        public let anchorID: String
        public let oldIndex: Int
        public let newIndex: Int
        let id: Int
    }

    /// Set when the asset in the middle of the screen moved to another cell; the grid scrolls
    /// to keep it where it was.
    public private(set) var gridShift: GridShift?
    @ObservationIgnored private var shiftCounter = 0


    /// The month (bucket id) containing a loaded asset.
    public func monthID(ofAsset assetID: String) -> String? { monthIDByAssetID[assetID] }

    /// Loads month `id` and up to `radius` months on each side, concurrently.
    public func loadMonths(around id: String, radius: Int) async {
        guard let index = monthIndexByID[id] else { return }
        let ids = months[max(0, index - radius)...min(months.count - 1, index + radius)].map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for monthID in ids { group.addTask { await self.loadMonth(monthID) } }
        }
    }

    /// The viewer moved to `assetID`: make sure its month (and neighbours) are loaded.
    public func assetShownInViewer(_ assetID: String) {
        if let monthID = monthIDByAssetID[assetID] { monthAppeared(monthID) }
    }

    /// Switches sort or filter (e.g. Recently Added, Favorites) and reloads. The grid's order
    /// (`newestFirst`) stays as it was created.
    public func setOptions(_ newOptions: TimelineOptions) async {
        var newOptions = newOptions
        newOptions.newestFirst = newestFirst
        guard newOptions != options else { return }
        options = newOptions
        timeline = Timeline(service: service, options: newOptions)
        stopPrefetching()
        loadingMonths = []
        visibleMonthTitle = nil
        visibleDateRangeTitle = nil
        screenRange = nil
        apply([])
        phase = .idle
        await load()
    }

    // MARK: Visibility and prefetching

    public func assetAppeared(_ id: String) {
        visibleIDs.insert(id)
        reportVisibleRange()
    }

    public func assetDisappeared(_ id: String) {
        visibleIDs.remove(id)
        reportVisibleRange()
    }

    /// Stops prefetching, e.g. when the grid disappears.
    public func stopPrefetching() {
        visibleIDs = []
        lastVisibleRange = nil
        updates.yield(.cancel)
    }

    /// The flat index range spanned by the visible cells, or `nil` if none are visible.
    static func visibleRange(of ids: Set<String>, in indexByID: [String: Int]) -> Range<Int>? {
        let indices = ids.compactMap { indexByID[$0] }
        guard let low = indices.min(), let high = indices.max() else { return nil }
        return low..<(high + 1)
    }

    private func reportVisibleRange() {
        updateVisibleMonthTitle()
        guard let range = Self.visibleRange(of: visibleIDs, in: assetIndexByID) else {
            lastVisibleRange = nil
            updates.yield(.cancel)
            return
        }
        guard range != lastVisibleRange else { return }
        lastVisibleRange = range
        updates.yield(.visible(range))
    }

    /// The grid cells on screen changed (computed by the grid from its scroll position).
    public func screenRangeChanged(_ range: ClosedRange<Int>) {
        guard range != screenRange else { return }
        screenRange = range
        updateDateRangeTitle()
    }

    private func updateDateRangeTitle() {
        guard let range = screenRange else { return }
        // Grid order is chronological: the first and last loaded photos on screen bound it.
        let first = range.lazy.compactMap { self.gridAsset(atGridIndex: $0) }.first
        let last = range.reversed().lazy.compactMap { self.gridAsset(atGridIndex: $0) }.first
        guard let first, let last else { return }
        let dates = [first.localDateTime, last.localDateTime]
        let title = Self.dateRangeTitle(from: dates.min()!, to: dates.max()!)
        if title != visibleDateRangeTitle { visibleDateRangeTitle = title }
    }

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


    private func updateVisibleMonthTitle() {
        guard let id = visibleCenterID, let monthID = monthIDByAssetID[id],
              let index = monthIndexByID[monthID] else { return }
        let title = Self.monthTitle(for: months[index].bucket)
        if title != visibleMonthTitle { visibleMonthTitle = title }
    }

    private func apply(_ newMonths: [TimelineMonth]) {
        // A loaded month can hold a few more or fewer items than its placeholder count, which
        // moves every cell after it. Remember where the photo in the middle of the screen was,
        // so the grid can keep it in place (it opened in 2024 after a background load).
        let anchor = visibleCenterID
        let oldIndex = anchor.flatMap(gridIndex(ofAsset:))
        months = newMonths
        monthIndexByID = Dictionary(newMonths.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildCellIndex()
        monthIDByAssetID = Dictionary(
            newMonths.flatMap { month in month.assets.map { ($0.id, month.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = newMonths.flatMap { $0.assets.map(\.id) }
        guard ids != flatAssetIDs else { return }
        flatAssetIDs = ids
        assetIndexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        updates.yield(.assets(ids))
        updateDateRangeTitle()
        if let anchor, let oldIndex, let newIndex = gridIndex(ofAsset: anchor), newIndex != oldIndex {
            shiftCounter += 1
            gridShift = GridShift(anchorID: anchor, oldIndex: oldIndex, newIndex: newIndex, id: shiftCounter)
        }
        // Indices shifted, so report the visible range again.
        lastVisibleRange = nil
        reportVisibleRange()
    }

    // MARK: Formatting

    /// "June 2026": month titles for section headers (the bucket date is UTC-encoded wall-clock time).
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
        let loaded = months.allSatisfy(\.isLoaded)
        guard loaded else { return tr("%@ Items", totalCount.formatted(.number.locale(Localization.locale))) }
        let assets = months.flatMap(\.assets)
        let videos = assets.filter(\.isVideo).count
        let photos = assets.count - videos
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append(tr(photos == 1 ? "%@ Photo" : "%@ Photos", photos.formatted(.number.locale(Localization.locale)))) }
        if videos > 0 { parts.append(tr(videos == 1 ? "%@ Video" : "%@ Videos", videos.formatted(.number.locale(Localization.locale)))) }
        return parts.joined(separator: ", ")
    }
}
