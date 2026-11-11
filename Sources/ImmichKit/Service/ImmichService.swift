import Foundation

/// The operations ImmichKit needs from an Immich server.
///
/// `LiveImmichService` talks to a real server; a mock implementation backs tests and previews.
/// More operations are added as features land (timeline, albums, people, search, ...).
public protocol ImmichService: Sendable {
    /// `GET /server/ping`. Returns normally if the server answered `pong`.
    func ping() async throws

    /// `GET /server/version`.
    func serverVersion() async throws -> ServerVersion

    /// `GET /timeline/buckets`: month buckets with asset counts, in `options` order.
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket]

    /// `GET /timeline/bucket`: the assets in one month bucket, in `options` order.
    /// - Parameter bucketID: `TimeBucket.id` as returned by `timeBuckets(options:)`.
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset]

    /// `GET /assets/{id}/thumbnail?size=…`: encoded image bytes (JPEG/WebP) for a grid thumbnail or a preview.
    func thumbnail(assetID: String, size: ImageSize) async throws -> Data

    // MARK: Albums

    /// `GET /albums`: the user's albums (owned and shared with them).
    /// - Parameter shared: `true` only shared albums, `false` only unshared ones, `nil` all.
    func albums(shared: Bool?) async throws -> [Album]

    /// `GET /albums/{id}`: one album's metadata. Its assets come from the timeline with `.album(id)`.
    func album(id: String) async throws -> Album

    // MARK: People

    /// `GET /people` (all pages): recognized people, in server order (most assets first).
    /// - Parameter withHidden: include people the user has hidden.
    func people(withHidden: Bool) async throws -> [Person]

    /// `GET /people/{id}`.
    func person(id: String) async throws -> Person

    /// `GET /people/{id}/thumbnail`: encoded image bytes of the person's face crop.
    func personThumbnail(personID: String) async throws -> Data

    // MARK: Search

    /// `POST /search/smart`: assets ranked by CLIP similarity to `query.text`, best match first.
    /// - Parameters:
    ///   - page: `nil` for the first page, then the previous result's `next`.
    ///   - size: results per page (server maximum 1000).
    func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults

    /// `POST /search/metadata`: assets matching the filters (date range, place, camera, ...), by date.
    func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults

    /// `GET /search/suggestions`: known values for a filter field (server order, without empty or duplicate values).
    func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String]
}

extension ImmichService {
    /// Default page size for searches.
    public static var searchPageSize: Int { 100 }

    /// The first page of a smart search for `text`.
    public func smartSearch(_ text: String, filters: SearchFilters = SearchFilters()) async throws -> SearchResults {
        try await smartSearch(SmartSearchQuery(text: text, filters: filters), page: nil, size: Self.searchPageSize)
    }

    /// The first page of a metadata search.
    public func metadataSearch(_ query: MetadataSearchQuery) async throws -> SearchResults {
        try await metadataSearch(query, page: nil, size: Self.searchPageSize)
    }

    /// Suggestions without narrowing context.
    public func searchSuggestions(_ kind: SearchSuggestionKind) async throws -> [String] {
        try await searchSuggestions(kind, context: SearchSuggestionContext())
    }
}

extension ImmichService {
    /// All albums, owned and shared.
    public func albums() async throws -> [Album] {
        try await albums(shared: nil)
    }

    /// Visible (not hidden) people.
    public func people() async throws -> [Person] {
        try await people(withHidden: false)
    }

    /// Every asset matching `options`: loads the month buckets, then all buckets concurrently.
    /// Returned in `options` order. For large timelines prefer the lazy `Timeline` actor.
    public func allAssets(options: TimelineOptions) async throws -> [Asset] {
        let buckets = try await timeBuckets(options: options)
        let ids = buckets.map(\.id)
        let perBucket = try await withThrowingTaskGroup(of: (Int, [Asset]).self) { group in
            // Bounded concurrency so a big album does not open dozens of requests at once.
            let maxConcurrent = 4
            var results = [[Asset]](repeating: [], count: ids.count)
            for (index, id) in ids.enumerated() {
                if index >= maxConcurrent, let (done, assets) = try await group.next() {
                    results[done] = assets
                }
                group.addTask { (index, try await self.timeBucketAssets(bucketID: id, options: options)) }
            }
            while let (done, assets) = try await group.next() {
                results[done] = assets
            }
            return results
        }
        return perBucket.flatMap { $0 }
    }

    /// The assets in an album (including archived ones, as the server returns them).
    public func albumAssets(albumID: String, newestFirst: Bool = true) async throws -> [Asset] {
        var options = TimelineOptions.album(albumID)
        options.newestFirst = newestFirst
        return try await allAssets(options: options)
    }

    /// The assets showing a person, newest first.
    public func personAssets(personID: String) async throws -> [Asset] {
        try await allAssets(options: .person(personID))
    }
}

/// Server-rendered image sizes used by the UI. The original file has its own endpoint.
public enum ImageSize: String, Sendable, Hashable, CaseIterable, Codable {
    /// Small square-ish image for grids (`thumbnail`, ~250 px).
    case thumbnail
    /// Large image for the viewer (`preview`, ~1440 px).
    case preview
}

/// Server release version, independent of the generated API types.
public struct ServerVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: Int?
    /// Only reported by newer servers; `nil` if the server does not send it.
    public var featureLevel: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil, featureLevel: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.featureLevel = featureLevel
    }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if let prerelease { text += "-rc\(prerelease)" }
        return text
    }
}

/// Errors surfaced by `ImmichService` implementations. Never contains the API key.
public enum ImmichServiceError: Error, Sendable, Equatable, LocalizedError {
    /// The server URL could not be turned into an API base URL.
    case invalidServerURL
    /// The server rejected the API key (HTTP 401/403).
    case unauthorized
    /// The server answered with an unexpected HTTP status.
    case unexpectedStatus(Int)
    /// The response body did not have the expected shape.
    case invalidResponse
    /// The request did not reach the server (offline, DNS, TLS, timeout, ...).
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The server URL is not valid."
        case .unauthorized:
            return "The server rejected the API key."
        case .unexpectedStatus(let status):
            return "The server answered with HTTP status \(status)."
        case .invalidResponse:
            return "The server sent a response that is not an Immich API response. Check the server URL."
        case .network(let message):
            return "Could not reach the server: \(message)"
        }
    }
}
