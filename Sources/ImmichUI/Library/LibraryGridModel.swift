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
    /// Columns in the grid (3 like Photos on iPhone; task 17 makes this pinchable).
    public var columnCount: Int = 3

    @ObservationIgnored public let timeline: Timeline
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored public let prefetcher: Prefetcher
    @ObservationIgnored public let images: ThumbnailImageCache

    @ObservationIgnored private var monthIndexByID: [String: Int] = [:]
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
    public nonisolated var newestFirst: Bool { timeline.options.newestFirst }

    /// Total number of assets according to the server's bucket counts.
    public var totalCount: Int { months.reduce(0) { $0 + $1.bucket.count } }

    public var isEmpty: Bool { phase == .loaded && months.allSatisfy { $0.bucket.count == 0 } }

    // MARK: Loading

    /// Loads the month skeleton, then the months at the end the grid starts at
    /// (the newest ones). Calling it again refreshes the buckets.
    public func load() async {
        if months.isEmpty { phase = .loading }
        do {
            let loaded = try await timeline.loadBuckets()
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
        do {
            try await timeline.loadMonth(id)
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
        guard let range = Self.visibleRange(of: visibleIDs, in: assetIndexByID) else {
            lastVisibleRange = nil
            updates.yield(.cancel)
            return
        }
        guard range != lastVisibleRange else { return }
        lastVisibleRange = range
        updates.yield(.visible(range))
    }

    private func apply(_ newMonths: [TimelineMonth]) {
        months = newMonths
        monthIndexByID = Dictionary(newMonths.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = newMonths.flatMap { $0.assets.map(\.id) }
        guard ids != flatAssetIDs else { return }
        flatAssetIDs = ids
        assetIndexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        updates.yield(.assets(ids))
        // Indices shifted, so report the visible range again.
        lastVisibleRange = nil
        reportVisibleRange()
    }

    // MARK: Formatting

    /// "June 2026": month titles for section headers (the bucket date is UTC-encoded wall-clock time).
    public nonisolated static func monthTitle(for bucket: TimeBucket, locale: Locale = .current) -> String {
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
        guard loaded else { return "\(totalCount.formatted()) Items" }
        let assets = months.flatMap(\.assets)
        let videos = assets.filter(\.isVideo).count
        let photos = assets.count - videos
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append("\(photos.formatted()) \(photos == 1 ? "Photo" : "Photos")") }
        if videos > 0 { parts.append("\(videos.formatted()) \(videos == 1 ? "Video" : "Videos")") }
        return parts.joined(separator: ", ")
    }
}
