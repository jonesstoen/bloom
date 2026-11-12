import Foundation
import ImmichKit
import Observation

/// State behind `LibraryGridView`: the month skeleton of a `Timeline`, lazily loaded months,
/// and the visible range reported to a `Prefetcher`.
///
/// The grid shows every month right away (sized from the bucket counts with placeholder cells)
/// and loads a month's assets when one of its cells appears, together with its neighbours.
///
/// Split across files: cell lookups live in `GridCellIndex`, prefetching in `PrefetchFeed`,
/// confirmed writes in `LocalLibraryEdits`; the extensions hold trash and restore
/// (`+Editing`), the Years and Months views (`+Overviews`) and display text (`+Titles`).
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
    /// Number of cells in the grid: loaded assets, plus placeholders for months not loaded yet.
    public private(set) var gridItemCount = 0
    /// Observed separately from the cell index so the footer updates when the counts change.
    private(set) var footerCounts = GridCellIndex.FooterCounts()

    /// Replaced when the sort or filter changes (`setOptions`) and after writes.
    @ObservationIgnored public internal(set) var timeline: Timeline
    /// The current sort and filter options.
    public private(set) var options: TimelineOptions
    /// `false` (default): oldest first, so the grid starts scrolled to the bottom.
    public nonisolated let newestFirst: Bool
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored public let prefetcher: Prefetcher
    @ObservationIgnored public let images: ThumbnailImageCache

    /// Title of the month in the middle of the screen ("November 2026"), for the header subtitle.
    public private(set) var visibleMonthTitle: String?
    /// The dates of the photos on screen ("23–29 Oct 2026"), like the Library header in Photos.
    public private(set) var visibleDateRangeTitle: String?
    @ObservationIgnored private var screenRange: ClosedRange<Int>?

    /// Today's rotation for highlights (days since 1970). Tests set it to fixed days.
    public var highlightDay = MonthHighlights.dayNumber(Date())
    /// Set by the Months and Years views; the grid scrolls to this month's first cell and clears it.
    public var pendingScrollMonthID: String?
    /// Set by a day tile in Months; the grid centres this asset and clears it.
    public var pendingScrollAssetID: String?

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

    @ObservationIgnored private var cells = GridCellIndex()
    @ObservationIgnored private let feed: PrefetchFeed

    // State shared with the trash and restore extension (`+Editing`).
    public internal(set) var isTrashing = false
    public internal(set) var isRestoring = false
    /// Invalidates other session views that may still contain pre-mutation asset snapshots.
    public internal(set) var trashRevision = 0
    /// Refreshes session content without replacing the active Recently Deleted navigation.
    public internal(set) var restoreRevision = 0
    @ObservationIgnored var edits = LocalLibraryEdits()
    /// After a write with an unknown outcome the grid keeps showing what it had, but that is
    /// not a cache: nothing is saved or reused until a fresh server load replaces it.
    @ObservationIgnored var needsFreshTrashLoad = false
    @ObservationIgnored var loadingMonths: Set<String> = []
    /// Bumped by every load and write; work that finishes for an older generation is dropped.
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored let snapshotStore: TimelineSnapshotStore?
    @ObservationIgnored var snapshotRevision: UInt64 = 0
    @ObservationIgnored var didAttemptRestore = false
    @ObservationIgnored var snapshotSave: Task<Void, Never>?

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
        self.feed = PrefetchFeed(prefetcher: prefetcher)
    }

    deinit {
        snapshotSave?.cancel()
        feed.finish()
    }

    public var isMutating: Bool { isTrashing || isRestoring }
    public var needsMutationRefresh: Bool { needsFreshTrashLoad }

    /// Total number of assets according to the server's bucket counts.
    public var totalCount: Int { months.reduce(0) { $0 + $1.bucket.count } }

    public var isEmpty: Bool { phase == .loaded && months.allSatisfy { $0.bucket.count == 0 } }

    /// Whether every month's assets are loaded (the Months view needs their final heights).
    public var allMonthsLoaded: Bool { !months.isEmpty && months.allSatisfy(\.isLoaded) }

    public func month(id: String) -> TimelineMonth? {
        cells.monthIndex(of: id).map { months[$0] }
    }

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

    func load(reconcilingTrash: Bool, restoring: Bool = false) async {
        guard !isTrashing, !isRestoring || restoring else { return }
        loadGeneration += 1
        let generation = loadGeneration
        snapshotSave?.cancel()
        loadingMonths = []
        let hasEdits = !edits.favoriteOverrides.isEmpty
            || (reconcilingTrash && (!edits.trashedIDs.isEmpty || !edits.restoredIDs.isEmpty || needsFreshTrashLoad))
        if hasEdits {
            // An explicit refresh reconciles local writes with later external changes. A fresh
            // timeline cannot return a pre-write in-memory snapshot.
            timeline = Timeline(service: service, options: options)
            edits.favoriteOverrides = [:]
            if reconcilingTrash {
                edits.trashedIDs = []
                edits.restoredIDs = []
            }
            // Nor may it bring back the disk copy of those old flags.
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
            await restoreSnapshot(into: timeline, generation: generation)
        }
        guard isCurrent(timeline, generation), !Task.isCancelled else { return }
        do {
            let loaded = try await timeline.loadBuckets(preservingLoadedMonths: snapshotStore != nil)
            guard isCurrent(timeline, generation), !Task.isCancelled else { return }
            apply(loaded)
            // The grid is now server-backed (possibly unloaded placeholders), so nothing of an
            // uncertain earlier presentation can leak into a later disk save.
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
        await loadStartAndRevalidate(timeline: timeline, generation: generation, restoring: restoring)
    }

    /// Shows the months saved on disk while the server is asked for fresh ones.
    private func restoreSnapshot(into timeline: Timeline, generation: Int) async {
        let cached = await snapshotStore?.load(options: timeline.options)
        guard isCurrent(timeline, generation), !Task.isCancelled else { return }
        didAttemptRestore = true
        guard let cached, await timeline.restore(cached), isCurrent(timeline, generation) else { return }
        let snapshot = await timeline.months
        guard isCurrent(timeline, generation) else { return }
        // Even a cancelled refresh can keep this usable local presentation.
        apply(snapshot)
        phase = .loaded
    }

    /// Loads the months the grid opens at, then revalidates every month restored from disk:
    /// six requests at a time, publishing the newest batch at once and the rest at the end
    /// (publishing every batch would rebuild the grid each time).
    private func loadStartAndRevalidate(timeline: Timeline, generation: Int, restoring: Bool) async {
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
              let index = cells.monthIndex(of: id), !months[index].isLoaded, !loadingMonths.contains(id) else { return }
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

    /// Loads month `id` and up to `radius` months on each side, concurrently.
    public func loadMonths(around id: String, radius: Int) async {
        guard let index = cells.monthIndex(of: id) else { return }
        let ids = months[max(0, index - radius)...min(months.count - 1, index + radius)].map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for monthID in ids { group.addTask { await self.loadMonth(monthID) } }
        }
    }

    /// Loads every month not loaded yet, a few at a time, and applies them once at the end
    /// (applying after each month would rebuild the grid ~100 times). Cached by the timeline,
    /// so this happens once per session.
    public func loadAllMonths() async {
        // After a write with an unknown outcome the old presentation stays visible, while its
        // replacement timeline has no buckets yet. Only load() can reconcile it.
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

    /// A cell (asset or placeholder) of month `id` appeared: load it and its neighbours.
    public func monthAppeared(_ id: String) {
        guard let index = cells.monthIndex(of: id) else { return }
        let ids = [index, index - 1, index + 1]
            .filter { months.indices.contains($0) && !months[$0].isLoaded && !loadingMonths.contains(months[$0].id) }
            .map { months[$0].id }
        for monthID in ids {
            Task { await loadMonth(monthID) }
        }
    }

    /// The viewer moved to `assetID`: make sure its month (and neighbours) are loaded.
    public func assetShownInViewer(_ assetID: String) {
        if let monthID = cells.monthID(ofAsset: assetID) { monthAppeared(monthID) }
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
        edits.favoriteOverrides = [:]
        stopPrefetching()
        loadingMonths = []
        visibleMonthTitle = nil
        visibleDateRangeTitle = nil
        screenRange = nil
        apply([])
        phase = .idle
        // Changing the sort or filter must not bring back confirmed removals. Only an explicit
        // refresh may reconcile those with an external restore.
        await load(reconcilingTrash: false)
    }

    func isCurrent(_ timeline: Timeline, _ generation: Int) -> Bool {
        timeline === self.timeline && generation == loadGeneration
    }

    private func applySnapshot(from timeline: Timeline, generation: Int) async -> Bool {
        let snapshot = await timeline.months
        guard isCurrent(timeline, generation), !Task.isCancelled else { return false }
        apply(snapshot)
        return true
    }

    // MARK: Disk snapshot

    /// Coalesces neighbouring month completions into one save; scrolling never saves.
    func scheduleSnapshotSave() {
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

    // MARK: Grid cells

    /// The identity of grid cell `index`: the asset's id, or the placeholder slot of an unloaded month.
    public func gridItemID(atGridIndex index: Int) -> AnyHashable? { cells.itemID(at: index) }

    /// The loaded asset in grid cell `index` (`nil` for placeholders).
    public func gridAsset(atGridIndex index: Int) -> Asset? { cells.asset(at: index) }

    /// The first grid cell of month `id`.
    public func firstGridIndex(ofMonth id: String) -> Int? { cells.firstIndex(ofMonth: id) }

    /// The month of grid cell `index` (loaded or not).
    public func gridMonthID(atGridIndex index: Int) -> String? { cells.monthID(at: index) }

    /// The grid cell of a loaded asset.
    public func gridIndex(ofAsset assetID: String) -> Int? { cells.index(ofAsset: assetID) }

    /// The month (bucket id) containing a loaded asset.
    public func monthID(ofAsset assetID: String) -> String? { cells.monthID(ofAsset: assetID) }

    /// Shows `source` with the local edits applied, rebuilding the cell index, and keeps the
    /// photo in the middle of the screen in place when cells before it moved.
    func apply(_ source: [TimelineMonth]) {
        let newMonths = edits.applied(to: source, options: options)
        // A loaded month can hold a few more or fewer items than its placeholder count, which
        // moves every cell after it. Remember where the photo in the middle of the screen was,
        // so the grid can keep it in place.
        let anchor = visibleCenterID
        let oldIndex = anchor.flatMap(gridIndex(ofAsset:))
        let newIDs = Set(newMonths.flatMap { $0.assets.map(\.id) })
        // If the centre photo itself was removed, keep its nearest remaining neighbour.
        var replacement: (id: String, index: Int)?
        if let anchor, let oldIndex, !newIDs.contains(anchor) {
            replacement = cells.assetIDs.compactMap { id -> (id: String, index: Int)? in
                guard newIDs.contains(id), let index = gridIndex(ofAsset: id) else { return nil }
                return (id, index)
            }.min { left, right in
                let lhs = abs(left.index - oldIndex), rhs = abs(right.index - oldIndex)
                return lhs == rhs ? left.index < right.index : lhs < rhs
            }
        }
        let oldAssetIDs = cells.assetIDs
        months = newMonths
        cells = GridCellIndex(months: newMonths)
        gridItemCount = cells.cellCount
        if footerCounts != cells.footerCounts { footerCounts = cells.footerCounts }
        guard cells.assetIDs != oldAssetIDs else { return }
        feed.setAssets(cells.assetIDs)
        feed.keepVisible(newIDs)
        updateDateRangeTitle()
        if let id = replacement?.id ?? anchor, let old = replacement?.index ?? oldIndex,
           let new = gridIndex(ofAsset: id), new != old || replacement != nil {
            shiftCounter += 1
            gridShift = GridShift(anchorID: id, oldIndex: old, newIndex: new, id: shiftCounter)
        }
        // Positions changed, so report the visible range again.
        reportVisibleRange(force: true)
    }

    // MARK: Visibility and prefetching

    /// The visible asset in the middle of the visible range: the anchor that stays in place
    /// when the grid density changes, so a pinch keeps what you are looking at on screen.
    public var visibleCenterID: String? {
        let positions = cells.assetPositionByID
        let sorted = feed.visibleIDs.compactMap { id in positions[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2].0
    }

    /// The range last sent to the prefetcher, `nil` when no loaded asset is visible.
    var lastVisibleRange: Range<Int>? { feed.lastVisibleRange }

    public func assetAppeared(_ id: String) {
        feed.appeared(id)
        reportVisibleRange()
    }

    public func assetDisappeared(_ id: String) {
        feed.disappeared(id)
        reportVisibleRange()
    }

    /// Stops prefetching, e.g. when the grid disappears.
    public func stopPrefetching() {
        feed.cancel()
    }

    private func reportVisibleRange(force: Bool = false) {
        updateVisibleMonthTitle()
        feed.report(positions: cells.assetPositionByID, force: force)
    }

    /// The grid cells on screen changed (reported by the grid from its layout).
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

    private func updateVisibleMonthTitle() {
        guard let id = visibleCenterID, let monthID = cells.monthID(ofAsset: id),
              let index = cells.monthIndex(of: monthID) else { return }
        let title = Self.monthTitle(for: months[index].bucket)
        if title != visibleMonthTitle { visibleMonthTitle = title }
    }
}
