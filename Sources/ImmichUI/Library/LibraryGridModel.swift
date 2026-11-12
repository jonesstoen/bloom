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
    public private(set) var isTrashing = false
    public private(set) var isRestoring = false
    public var isMutating: Bool { isTrashing || isRestoring }
    public var needsMutationRefresh: Bool { needsFreshTrashLoad }
    /// Invalidates other session views that may still contain pre-mutation asset snapshots.
    public private(set) var trashRevision = 0
    /// Refreshes session content without replacing the active Recently Deleted navigation.
    public private(set) var restoreRevision = 0
    private struct FooterCounts: Equatable {
        var allLoaded = true
        var reported = 0
        var photos = 0
        var videos = 0
    }
    private var footerCounts = FooterCounts()
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
    /// Confirmed writes override snapshots still cached inside the current timeline.
    @ObservationIgnored private var favoriteOverrides: [String: Bool] = [:]
    @ObservationIgnored private var confirmedTrashedIDs: Set<String> = []
    @ObservationIgnored private var confirmedRestoredIDs: Set<String> = []
    /// An uncertain write keeps its error presentation, but that presentation is not a cache.
    @ObservationIgnored private var needsFreshTrashLoad = false
    @ObservationIgnored private let snapshotStore: TimelineSnapshotStore?
    @ObservationIgnored private var snapshotRevision: UInt64 = 0
    @ObservationIgnored private var didAttemptRestore = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var snapshotSave: Task<Void, Never>?

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
        images: ThumbnailImageCache? = nil,
        snapshotStore: TimelineSnapshotStore? = nil
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
        self.snapshotStore = snapshotStore

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
        snapshotSave?.cancel()
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
        await load(reconcilingTrash: true)
    }

    private func load(reconcilingTrash: Bool, restoring: Bool = false) async {
        guard !isTrashing, !isRestoring || restoring else { return }
        loadGeneration += 1
        let generation = loadGeneration
        snapshotSave?.cancel()
        loadingMonths = []
        if !favoriteOverrides.isEmpty || (reconcilingTrash && (!confirmedTrashedIDs.isEmpty || !confirmedRestoredIDs.isEmpty || needsFreshTrashLoad)) {
            // Explicit refresh reconciles local writes with later external favorite/restore
            // changes. A fresh actor cannot return a pre-write in-memory snapshot.
            timeline = Timeline(service: service, options: options)
            favoriteOverrides = [:]
            if reconcilingTrash {
                confirmedTrashedIDs = []
                confirmedRestoredIDs = []
            }
            loadingMonths = []
            // An explicit refresh must not resurrect the disk copy of those old flags.
            didAttemptRestore = true
        }
        if months.isEmpty { phase = .loading }
        let timeline = self.timeline
        if let snapshotStore {
            let revision = await snapshotStore.revision
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            snapshotRevision = revision
        }
        if !didAttemptRestore {
            let cached = await snapshotStore?.load(options: timeline.options)
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            didAttemptRestore = true
            if let cached {
                let restored = await timeline.restore(cached)
                guard isCurrent(timeline, generation) else { return }
                if restored {
                    let snapshot = await timeline.months
                    guard isCurrent(timeline, generation) else { return }
                    // Even a cancelled refresh can retain this usable local presentation.
                    apply(snapshot)
                    phase = .loaded
                }
            }
        }
        guard isCurrent(timeline, generation), !Task.isCancelled else { return }
        do {
            let loaded = try await timeline.loadBuckets(preservingLoadedMonths: snapshotStore != nil)
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            apply(loaded)
            // The replacement is now server-backed (possibly unloaded bucket placeholders),
            // so none of the uncertain old presentation can leak into a later disk save.
            needsFreshTrashLoad = false
            phase = .loaded
        } catch is CancellationError {
            guard isCurrent(timeline, generation) else { return }
            if months.isEmpty && phase != .loaded { phase = .idle }
            return
        } catch {
            guard isCurrent(timeline, generation) else { return }
            if months.isEmpty && phase != .loaded { phase = .failed(error.localizedDescription) }
            return
        }
        // Revalidate every retained month, including same-count replacements and Favorites.
        // Six requests at a time bounds traffic. Publish the newest batch promptly, then
        // the final snapshot once, avoiding a full grid/index rebuild for every older batch.
        let recentFirst = newestFirst ? months : Array(months.reversed())
        let retained = snapshotStore == nil ? [] : recentFirst.filter(\.isLoaded).map(\.id)
        let start = newestFirst ? Array(months.prefix(2)) : Array(months.suffix(2))
        await withTaskGroup(of: Void.self) { group in
            for month in start where !month.isLoaded {
                group.addTask { await self.loadMonth(month.id, restoring: restoring) }
            }
        }
        for offset in stride(from: 0, to: retained.count, by: 6) {
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            let batch = Array(retained[offset..<min(offset + 6, retained.count)])
            loadingMonths.formUnion(batch)
            await withTaskGroup(of: Void.self) { group in
                for id in batch { group.addTask { _ = try? await timeline.refreshMonth(id) } }
            }
            if isCurrent(timeline, generation) { loadingMonths.subtract(batch) }
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            if offset == 0 || offset + 6 >= retained.count {
                guard await applySnapshot(from: timeline, generation: generation) else { return }
            }
        }
        guard isCurrent(timeline, generation), !Task.isCancelled else { return }
        snapshotSave?.cancel()
        await persistSnapshot(timeline: timeline, generation: generation)
    }

    /// Loads the month if needed. Failures leave the placeholders and are retried on the next appear.
    public func loadMonth(_ id: String) async {
        await loadMonth(id, restoring: false)
    }

    private func loadMonth(_ id: String, restoring: Bool) async {
        guard !isTrashing, !isRestoring || restoring, !needsFreshTrashLoad,
              let index = monthIndexByID[id], !months[index].isLoaded, !loadingMonths.contains(id) else { return }
        let timeline = self.timeline
        let generation = loadGeneration
        loadingMonths.insert(id)
        defer { if isCurrent(timeline, generation) { loadingMonths.remove(id) } }
        do {
            try await timeline.loadMonth(id)
            guard await applySnapshot(from: timeline, generation: generation) else { return }
            scheduleSnapshotSave()
        } catch {
            // Keep placeholders; the next appear retries.
        }
    }

    private func isCurrent(_ timeline: Timeline, _ generation: Int) -> Bool {
        timeline === self.timeline && generation == loadGeneration
    }

    private func applySnapshot(from timeline: Timeline, generation: Int) async -> Bool {
        let snapshot = await timeline.months
        guard isCurrent(timeline, generation), !Task.isCancelled else { return false }
        apply(snapshot)
        return true
    }

    /// Coalesce neighbouring month completions; scrolling/visibility changes never encode data.
    private func scheduleSnapshotSave() {
        guard snapshotStore != nil else { return }
        snapshotSave?.cancel()
        let timeline = self.timeline
        let generation = loadGeneration
        snapshotSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            await self.persistSnapshot(timeline: timeline, generation: generation)
        }
    }

    private func persistSnapshot(timeline: Timeline, generation: Int) async {
        guard let snapshotStore, !isMutating, !needsFreshTrashLoad,
              isCurrent(timeline, generation), !Task.isCancelled else { return }
        // Capture options and the already merged presentation together before hopping actors.
        let snapshot = months
        let options = timeline.options
        let revision = snapshotRevision
        await snapshotStore.save(months: snapshot, options: options, expectedRevision: revision)
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
        var assetCount = 0
        var videoCount = 0
        for assets in monthAssets {
            assetCount += assets.count
            for (i, asset) in assets.enumerated() {
                positions[asset.id] = i
                if asset.isVideo { videoCount += 1 }
            }
        }
        assetIndexInMonth = positions
        // Reuse the index pass rather than flattening the library whenever the footer renders.
        let counts = FooterCounts(allLoaded: months.allSatisfy(\.isLoaded),
                                  reported: months.reduce(0) { $0 + $1.bucket.count },
                                  photos: assetCount - videoCount, videos: videoCount)
        if footerCounts != counts { footerCounts = counts }
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
        // An unknown write deliberately leaves the old presentation visible, while its
        // replacement Timeline has no authoritative buckets. Only load() can reconcile it.
        guard !isMutating, !needsFreshTrashLoad else { return }
        let timeline = self.timeline
        let generation = loadGeneration
        let ids = months.filter { !$0.isLoaded && !loadingMonths.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        loadingMonths.formUnion(ids)
        defer { if isCurrent(timeline, generation) { loadingMonths.subtract(ids) } }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { _ = try? await timeline.loadMonth(id) }
            }
            for _ in 0..<6 { add() }
            while await group.next() != nil { add() }
        }
        guard await applySnapshot(from: timeline, generation: generation) else { return }
        snapshotSave?.cancel()
        await persistSnapshot(timeline: timeline, generation: generation)
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
        guard !isMutating else { return }
        var newOptions = newOptions
        newOptions.newestFirst = newestFirst
        guard newOptions != options else { return }
        snapshotSave?.cancel()
        didAttemptRestore = false
        options = newOptions
        timeline = Timeline(service: service, options: newOptions)
        favoriteOverrides = [:]
        stopPrefetching()
        loadingMonths = []
        visibleMonthTitle = nil
        visibleDateRangeTitle = nil
        screenRange = nil
        apply([])
        phase = .idle
        // Changing a partition must not discard confirmed removals. Only an explicit refresh
        // may reconcile those with an external restore.
        await load(reconcilingTrash: false)
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

    /// The service only moves items to trash. Results with uncertain outcomes still invalidate
    /// old snapshots, but only confirmed IDs disappear from this presentation.
    public func moveToTrash(_ assets: [Asset]) async throws -> TrashResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard !assets.isEmpty, options.isTrashed != true, !assets.contains(where: \.isTrashed) else {
            return TrashResult(confirmedIDs: [], failedIDs: [])
        }
        isTrashing = true
        defer { isTrashing = false }
        // Stop pre-write callbacks at once. Cancelling a task alone does not stop a service
        // response or an already enqueued actor operation from completing later.
        loadGeneration += 1
        loadingMonths = []
        snapshotSave?.cancel()
        if let snapshotStore {
            // Invalidate before sending a write so a force-quit after server acceptance cannot
            // leave the pre-write disk cache available on the next launch. New saves are
            // blocked by isTrashing, and queued saves retain the previous revision.
            snapshotRevision = await snapshotStore.clearAll()
        }
        var seen: Set<String> = []
        let ids = assets.map(\.id).filter { seen.insert($0).inserted }
        do {
            let result = try await service.moveToTrash(assetIDs: ids)
            let requested = Set(ids)
            guard Set(result.confirmedIDs).isSubset(of: requested),
                  Set(result.failedIDs).isSubset(of: requested),
                  Set(result.confirmedIDs).isDisjoint(with: result.failedIDs),
                  Set(result.confirmedIDs + result.failedIDs) == requested else {
                throw ImmichServiceError.invalidResponse
            }
            // Do not check Task.isCancelled here: confirmed server writes must reach local
            // presentation/cache invalidation even if the viewer has already disappeared.
            await applyTrashOutcome(confirmedIDs: Set(result.confirmedIDs), uncertain: !result.failedIDs.isEmpty)
            return result
        } catch {
            // A failure may follow an accepted write. Retain selection/presentation, but never
            // restore or persist this old presentation until a fresh server load replaces it.
            await applyTrashOutcome(confirmedIDs: [], uncertain: true)
            throw error
        }
    }

    private func applyTrashOutcome(confirmedIDs: Set<String>, uncertain: Bool) async {
        confirmedTrashedIDs.formUnion(confirmedIDs)
        needsFreshTrashLoad = needsFreshTrashLoad || uncertain
        apply(months)
        let replacement = Timeline(service: service, options: options)
        timeline = replacement
        didAttemptRestore = true
        let generation = loadGeneration
        let snapshot = months
        trashRevision += 1
        if !needsFreshTrashLoad {
            // The already filtered current partition is safe, but every other sort/filter
            // partition was discarded because it may contain one of the same IDs.
            _ = await replacement.restore(snapshot)
            guard isCurrent(replacement, generation) else { return }
            scheduleSnapshotSave()
        }
    }

    /// Restores the exact confirmed selection from Recently Deleted. The root supplies its
    /// main-library action so both presentations share one write and one session busy period.
    public func restoreFromTrash(
        _ assets: [Asset],
        perform: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil
    ) async throws -> RestoreResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard options.isTrashed == true, !assets.isEmpty, assets.allSatisfy(\.isTrashed) else {
            return RestoreResult(confirmedIDs: [], failedIDs: [])
        }
        isRestoring = true
        defer {
            isRestoring = false
            restoreRevision += 1
            if !needsFreshTrashLoad { scheduleSnapshotSave() }
        }
        let previouslyUncertain = needsFreshTrashLoad
        await prepareRestore()
        var seen: Set<String> = []
        let targets = assets.filter { seen.insert($0.id).inserted }
        do {
            let result: RestoreResult
            if let perform {
                result = try await perform(targets)
            } else {
                result = try await service.restoreAssets(assetIDs: targets.map(\.id))
            }
            try validateRestoreResult(result, requested: Set(targets.map(\.id)))
            // Cancellation cannot undo an acknowledged server write. Keep all confirmed
            // removals even if the originating viewer/task disappeared during the request.
            confirmedRestoredIDs.formUnion(result.confirmedIDs)
            needsFreshTrashLoad = previouslyUncertain || !result.failedIDs.isEmpty
            apply(months)
            if !needsFreshTrashLoad {
                // A fully known removal can seed this partition. Failed/unknown outcomes
                // retain their UI and selection, but are never persisted as authoritative.
                _ = await timeline.restore(months)
            }
            return result
        } catch {
            needsFreshTrashLoad = true
            throw error
        }
    }

    /// Performs the session-owned restore, then reloads the current library partition while
    /// busy remains true. Asset capture dates cannot reconstruct Recently Added ordering.
    public func restoreToLibrary(_ assets: [Asset]) async throws -> RestoreResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard options.isTrashed != true, !assets.isEmpty, assets.allSatisfy(\.isTrashed) else {
            return RestoreResult(confirmedIDs: [], failedIDs: [])
        }
        isRestoring = true
        defer {
            isRestoring = false
            restoreRevision += 1
            if !needsFreshTrashLoad { scheduleSnapshotSave() }
        }
        await prepareRestore()
        var seen: Set<String> = []
        let ids = assets.map(\.id).filter { seen.insert($0).inserted }
        do {
            let result = try await service.restoreAssets(assetIDs: ids)
            try validateRestoreResult(result, requested: Set(ids))
            confirmedTrashedIDs.subtract(result.confirmedIDs)
            // load() swallows refresh failures, so a safe confirmed result is never lost
            // merely because the follow-up read failed or its task was cancelled.
            await load(reconcilingTrash: false, restoring: true)
            return result
        } catch {
            // A transport error can follow server acceptance. Keep old UI only as a
            // presentation until fresh buckets replace it; never reseed it into the cache.
            await load(reconcilingTrash: false, restoring: true)
            throw error
        }
    }

    private func prepareRestore() async {
        loadGeneration += 1
        loadingMonths = []
        snapshotSave?.cancel()
        timeline = Timeline(service: service, options: options)
        didAttemptRestore = true
        needsFreshTrashLoad = true
        if let snapshotStore {
            // Clear every account partition before the write, including queued saves with
            // their old revision. A force quit cannot revive a pre-restore disk snapshot.
            snapshotRevision = await snapshotStore.clearAll()
        }
    }

    private func validateRestoreResult(_ result: RestoreResult, requested: Set<String>) throws {
        let confirmed = Set(result.confirmedIDs)
        let failed = Set(result.failedIDs)
        guard confirmed.isSubset(of: requested), failed.isSubset(of: requested),
              confirmed.isDisjoint(with: failed), confirmed.union(failed) == requested else {
            throw ImmichServiceError.invalidResponse
        }
    }

    private func removingTrashedAssets(from source: [TimelineMonth]) -> [TimelineMonth] {
        let removedIDs = options.isTrashed == true ? confirmedRestoredIDs : confirmedTrashedIDs
        guard !removedIDs.isEmpty else { return source }
        return source.map { original in
            guard let days = original.days else { return original }
            var month = original
            var removed = false
            month.days = days.compactMap { originalDay in
                var day = originalDay
                day.assets = originalDay.assets.filter { asset in
                    guard removedIDs.contains(asset.id) else { return true }
                    removed = true
                    return false
                }
                return day.assets.isEmpty ? nil : day
            }
            // For a changed loaded month, use its actual remaining grid items. A retained
            // bucket count can belong to a newer response than the days it accompanies.
            if removed { month.bucket.count = month.assetCount }
            return month
        }
    }

    /// Apply a batch once, retaining all timeline metadata and updating derived grid indices.
    func applyFavoriteUpdates(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        for asset in assets { favoriteOverrides[asset.id] = asset.isFavorite }
        apply(months)
        scheduleSnapshotSave()
    }

    private func mergingFavoriteUpdates(into source: [TimelineMonth]) -> [TimelineMonth] {
        guard !favoriteOverrides.isEmpty else { return source }
        return source.map { original in
            guard let days = original.days else { return original }
            var month = original
            month.days = days.compactMap { originalDay in
                var day = originalDay
                day.assets = originalDay.assets.compactMap { originalAsset in
                    var asset = originalAsset
                    if let favorite = favoriteOverrides[asset.id] { asset.isFavorite = favorite }
                    if options.isFavorite == true, !asset.isFavorite { return nil }
                    return asset
                }
                return day.assets.isEmpty ? nil : day
            }
            if options.isFavorite == true { month.bucket.count = month.assetCount }
            return month
        }
    }

    private func apply(_ source: [TimelineMonth]) {
        let newMonths = removingTrashedAssets(from: mergingFavoriteUpdates(into: source))
        // A loaded month can hold a few more or fewer items than its placeholder count, which
        // moves every cell after it. Remember where the photo in the middle of the screen was,
        // so the grid can keep it in place (it opened in 2024 after a background load).
        let anchor = visibleCenterID
        let oldIndex = anchor.flatMap(gridIndex(ofAsset:))
        // If filtering removes the center itself, keep its nearest surviving neighbour.
        let newIDs = Set(newMonths.flatMap { $0.assets.map(\.id) })
        let replacement: (id: String, index: Int)?
        if let anchor, let oldIndex, !newIDs.contains(anchor) {
            replacement = flatAssetIDs.compactMap { id -> (id: String, index: Int)? in
                guard newIDs.contains(id), let index = gridIndex(ofAsset: id) else { return nil }
                return (id, index)
            }.min { left, right in
                let lhs = abs(left.index - oldIndex), rhs = abs(right.index - oldIndex)
                return lhs == rhs ? left.index < right.index : lhs < rhs
            }
        } else {
            replacement = nil
        }
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
        visibleIDs.formIntersection(newIDs)
        updateDateRangeTitle()
        let retainedAnchor = replacement?.id ?? anchor
        let retainedOldIndex = replacement?.index ?? oldIndex
        if let retainedAnchor, let retainedOldIndex,
           let newIndex = gridIndex(ofAsset: retainedAnchor),
           newIndex != retainedOldIndex || replacement != nil {
            shiftCounter += 1
            gridShift = GridShift(anchorID: retainedAnchor, oldIndex: retainedOldIndex, newIndex: newIndex, id: shiftCounter)
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
