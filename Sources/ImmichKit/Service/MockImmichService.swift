import Foundation

/// In-memory `ImmichService` for unit tests and SwiftUI previews. No network.
///
/// Serves either a `MockLibrary` (assets, albums, people, memories; see `MockImmichService.preview`)
/// or a plain list of `assets`, filtered and ordered the way the server does.
/// Thumbnails are placeholder JPEGs drawn in code. Records requests and can simulate latency and failures.
public actor MockImmichService: ImmichService {
    public enum Request: Sendable, Hashable {
        case ping
        case serverVersion
        case timeBuckets
        case timeBucket(String)
        case thumbnail(String, ImageSize)
        case albums
        case album(String)
        case people
        case person(String)
        case personThumbnail(String)
    }

    public private(set) var assets: [Asset] {
        didSet { assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// The fake library backing album and person filters; `nil` when created from plain `assets`.
    public let library: MockLibrary?
    private var assetsByID: [String: Asset]
    public var version: ServerVersion
    /// Delay applied to every request.
    public var latency: Duration
    /// If set, every request throws this error.
    public var failure: ImmichServiceError?
    public private(set) var requests: [Request] = []
    /// Requests that were cancelled while waiting for `latency`.
    public private(set) var cancelledRequests: [Request] = []

    public init(
        assets: [Asset] = [],
        version: ServerVersion = ServerVersion(major: 3, minor: 4, patch: 0, featureLevel: 1),
        latency: Duration = .zero
    ) {
        self.assets = assets
        self.assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.library = nil
        self.version = version
        self.latency = latency
    }

    /// A mock serving `library`: its assets, plus album and person timelines.
    public init(
        library: MockLibrary,
        version: ServerVersion = ServerVersion(major: 3, minor: 4, patch: 0, featureLevel: 1),
        latency: Duration = .zero
    ) {
        self.assets = library.assets
        self.assetsByID = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.library = library
        self.version = version
        self.latency = latency
    }

    /// A mock over `MockLibrary.standard`, for SwiftUI previews.
    public static var preview: MockImmichService { MockImmichService(library: .standard) }

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

    /// A placeholder JPEG drawn in code, shaped like the asset (square for unknown ids).
    public func thumbnail(assetID: String, size: ImageSize) async throws -> Data {
        try await begin(.thumbnail(assetID, size))
        return Self.placeholderData(assetID: assetID, size: size, aspectRatio: assetsByID[assetID]?.aspectRatio ?? 1)
    }

    /// The bytes `thumbnail(assetID:size:)` returns. Deterministic per asset id, size and aspect ratio.
    public static func placeholderData(assetID: String, size: ImageSize, aspectRatio: Double = 1) -> Data {
        PlaceholderImage.jpegData(assetID: assetID, size: size, aspectRatio: aspectRatio)
    }

    // MARK: Albums

    /// The library's albums in library order (empty without a library).
    public func albums(shared: Bool?) async throws -> [Album] {
        try await begin(.albums)
        return (library?.albums ?? [])
            .filter { shared == nil || $0.isShared == shared }
    }

    /// Throws HTTP 400 for an unknown id, as the server does for albums the user cannot access.
    public func album(id: String) async throws -> Album {
        try await begin(.album(id))
        guard let album = library?.albums.first(where: { $0.id == id }) else {
            throw ImmichServiceError.unexpectedStatus(400)
        }
        return album
    }

    // MARK: People

    public func people(withHidden: Bool) async throws -> [Person] {
        try await begin(.people)
        return (library?.people ?? []).filter { withHidden || !$0.isHidden }
    }

    public func person(id: String) async throws -> Person {
        try await begin(.person(id))
        guard let person = library?.people.first(where: { $0.id == id }) else {
            throw ImmichServiceError.unexpectedStatus(400)
        }
        return person
    }

    /// A square placeholder JPEG for known people; HTTP 404 otherwise.
    public func personThumbnail(personID: String) async throws -> Data {
        try await begin(.personThumbnail(personID))
        guard library?.people.contains(where: { $0.id == personID }) == true else {
            throw ImmichServiceError.unexpectedStatus(404)
        }
        return Self.personPlaceholderData(personID: personID)
    }

    /// The bytes `personThumbnail(personID:)` returns.
    public static func personPlaceholderData(personID: String) -> Data {
        PlaceholderImage.jpegData(assetID: "person-" + personID, size: .thumbnail, aspectRatio: 1)
    }

    // MARK: Helpers

    private func begin(_ request: Request) async throws {
        requests.append(request)
        if latency > .zero {
            do {
                try await Task.sleep(for: latency)
            } catch {
                cancelledRequests.append(request)
                throw error
            }
        }
        if let failure { throw failure }
    }

    /// Mirrors the server filters. Album/person filters use `library` and match nothing without one.
    private func filtered(_ options: TimelineOptions) -> [Asset] {
        let albumIDs = options.albumId.map { Set(library?.albumAssetIDs[$0] ?? []) }
        let personIDs = options.personId.map { Set(library?.personAssetIDs[$0] ?? []) }
        return assets.filter { asset in
            if let albumIDs, !albumIDs.contains(asset.id) { return false }
            if let personIDs, !personIDs.contains(asset.id) { return false }
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
