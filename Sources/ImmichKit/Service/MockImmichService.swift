import Foundation

/// In-memory `ImmichService` for unit tests and SwiftUI previews. No network.
///
/// Serves whatever `assets` it was given; filters and orders them the way the server does.
/// Records requests and can simulate latency and failures.
public actor MockImmichService: ImmichService {
    public enum Request: Sendable, Hashable {
        case ping
        case serverVersion
        case timeBuckets
        case timeBucket(String)
    }

    public var assets: [Asset]
    public var version: ServerVersion
    /// Delay applied to every request.
    public var latency: Duration
    /// If set, every request throws this error.
    public var failure: ImmichServiceError?
    public private(set) var requests: [Request] = []

    public init(
        assets: [Asset] = [],
        version: ServerVersion = ServerVersion(major: 3, minor: 4, patch: 0, featureLevel: 1),
        latency: Duration = .zero
    ) {
        self.assets = assets
        self.version = version
        self.latency = latency
    }

    public func setAssets(_ assets: [Asset]) { self.assets = assets }
    public func setLatency(_ latency: Duration) { self.latency = latency }
    public func setFailure(_ failure: ImmichServiceError?) { self.failure = failure }

    public func requestCount(_ request: Request) -> Int {
        requests.filter { $0 == request }.count
    }

    // MARK: ImmichService

    public func ping() async throws {
        try await begin(.ping)
    }

    public func serverVersion() async throws -> ServerVersion {
        try await begin(.serverVersion)
        return version
    }

    public func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        try await begin(.timeBuckets)
        var counts: [String: (year: Int, month: Int, count: Int)] = [:]
        for asset in filtered(options) {
            let parts = Asset.localCalendar.dateComponents([.year, .month], from: asset.localDateTime)
            let key = TimeBucket.key(year: parts.year!, month: parts.month!)
            counts[key, default: (parts.year!, parts.month!, 0)].count += 1
        }
        let buckets = counts.map { TimeBucket(id: $0.key, year: $0.value.year, month: $0.value.month, count: $0.value.count) }
        return buckets.sorted { options.newestFirst ? $0.id > $1.id : $0.id < $1.id }
    }

    public func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] {
        try await begin(.timeBucket(bucketID))
        guard let bucket = TimeBucket(key: bucketID, count: 0) else {
            throw ImmichServiceError.unexpectedStatus(400)
        }
        let calendar = Asset.localCalendar
        return filtered(options)
            .filter {
                let parts = calendar.dateComponents([.year, .month], from: $0.localDateTime)
                return parts.year == bucket.year && parts.month == bucket.month
            }
            .sorted { options.newestFirst ? $0.takenAt > $1.takenAt : $0.takenAt < $1.takenAt }
    }

    // MARK: Helpers

    private func begin(_ request: Request) async throws {
        requests.append(request)
        if latency > .zero { try await Task.sleep(for: latency) }
        if let failure { throw failure }
    }

    /// Mirrors the server filters. Album/person filters need data the mock does not model yet, so they match nothing.
    private func filtered(_ options: TimelineOptions) -> [Asset] {
        assets.filter { asset in
            if options.albumId != nil || options.personId != nil { return false }
            if let isFavorite = options.isFavorite, asset.isFavorite != isFavorite { return false }
            if asset.isTrashed != (options.isTrashed ?? false) { return false }
            switch options.visibility {
            case .timeline?: if asset.isArchived { return false }
            case .archive?: if !asset.isArchived { return false }
            case nil: break
            }
            return true
        }
    }
}
