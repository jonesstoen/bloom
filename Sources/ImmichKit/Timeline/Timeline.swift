import Foundation

/// A lazily loaded timeline: month buckets first, then the assets of each month on demand.
///
/// Call `loadBuckets()` once to get the month skeleton (with counts for sizing placeholders),
/// then `loadMonth(_:)` as months scroll into view. Concurrent loads of the same month share one request.
public actor Timeline {
    public nonisolated let options: TimelineOptions
    private let service: any ImmichService

    /// Months in display order. Unloaded months have `days == nil`.
    public private(set) var months: [TimelineMonth] = []
    public private(set) var hasLoadedBuckets = false

    private var indexByID: [String: Int] = [:]
    private var inFlight: [String: Task<[TimelineDay], any Error>] = [:]
    /// Bumped by `loadBuckets()` so results of loads started before a refresh are discarded.
    private var generation = 0

    public init(service: any ImmichService, options: TimelineOptions = .library) {
        self.service = service
        self.options = options
    }

    /// Fetches the month buckets. On refresh, months whose count did not change keep their loaded assets.
    @discardableResult
    public func loadBuckets() async throws -> [TimelineMonth] {
        let buckets = try await service.timeBuckets(options: options)
        let previous = Dictionary(months.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = buckets.sorted { a, b in
            let lhs = (a.year, a.month), rhs = (b.year, b.month)
            return options.newestFirst ? lhs > rhs : lhs < rhs
        }
        months = sorted.map { bucket in
            if let old = previous[bucket.id], old.bucket.count == bucket.count, old.isLoaded {
                return TimelineMonth(bucket: bucket, days: old.days)
            }
            return TimelineMonth(bucket: bucket)
        }
        indexByID = Dictionary(months.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Loads started before this refresh still return to their callers, but their results are
        // not stored, and new callers start fresh requests.
        generation += 1
        inFlight = [:]
        hasLoadedBuckets = true
        return months
    }

    /// Loads (once) and returns the days of a month. Concurrent callers share a single request.
    @discardableResult
    public func loadMonth(_ bucketID: String) async throws -> [TimelineDay] {
        guard let index = indexByID[bucketID] else { throw TimelineError.unknownBucket(bucketID) }
        if let days = months[index].days { return days }

        if let task = inFlight[bucketID] {
            return try await task.value
        }
        let service = self.service
        let options = self.options
        let task = Task<[TimelineDay], any Error> {
            let assets = try await service.timeBucketAssets(bucketID: bucketID, options: options)
            return TimelineGrouping.days(from: assets, newestFirst: options.newestFirst)
        }
        inFlight[bucketID] = task
        let startedGeneration = generation
        do {
            let days = try await task.value
            if inFlight[bucketID] == task { inFlight[bucketID] = nil }
            if startedGeneration == generation, let index = indexByID[bucketID] {
                months[index].days = days
            }
            return days
        } catch {
            if inFlight[bucketID] == task { inFlight[bucketID] = nil }
            throw error
        }
    }

    /// Loads the months at `indices` (out-of-range indices are ignored), e.g. the visible ones plus a margin.
    public func loadMonths(at indices: some Sequence<Int>) async throws {
        let ids = indices.compactMap { months.indices.contains($0) ? months[$0].id : nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { try await self.loadMonth(id) }
            }
            try await group.waitForAll()
        }
    }

    public func month(_ bucketID: String) -> TimelineMonth? {
        indexByID[bucketID].map { months[$0] }
    }

    public func isLoaded(_ bucketID: String) -> Bool {
        month(bucketID)?.isLoaded ?? false
    }

    /// All loaded assets in display order (unloaded months are skipped).
    public var loadedAssets: [Asset] {
        months.flatMap(\.assets)
    }

    /// Total asset count according to the server's bucket counts.
    public var totalCount: Int {
        months.reduce(0) { $0 + $1.bucket.count }
    }

    /// Forgets loaded assets and buckets (e.g. on logout).
    public func reset() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        months = []
        indexByID = [:]
        generation += 1
        hasLoadedBuckets = false
    }
}

public enum TimelineError: Error, Sendable, Equatable, LocalizedError {
    /// `loadMonth` was called with an id that is not among the loaded buckets.
    case unknownBucket(String)

    public var errorDescription: String? {
        switch self {
        case .unknownBucket(let id): return "The timeline has no month \(id)."
        }
    }
}
