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

    /// `GET /server/features`: which optional features (faces, smart search, ...) are on.
    func serverFeatures() async throws -> ServerFeatures

    /// `POST /assets/bulk-upload-check`: which of these checksums the server already has.
    /// Needs the `asset.upload` permission. Callers send batches.
    func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult]

    /// `POST /assets`: uploads one file (multipart, streamed from `request.fileURL`). A file the server
    /// already has comes back as `.duplicate` with the existing asset's ID. Needs the `asset.upload` permission.
    /// Throws `BackupUploadError.rejected` when the server refuses the file for good.
    func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult

    /// `PUT /assets/{photoID}` with only `livePhotoVideoId`: ties an uploaded motion video to its photo.
    func linkLivePhoto(photoID: String, motionID: String) async throws

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

    /// Albums owned by this user or shared with them as an editor. This is a read;
    /// actual additions still require Allow Changes and server authorization.
    func albumsForAdding() async throws -> [Album]

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

    // MARK: Asset detail

    /// `GET /assets/{id}`: the full asset, including `exif`.
    func asset(id: String) async throws -> Asset

    /// `GET /assets/{id}/original`: the original file's bytes. Loads the whole file into memory,
    /// so for videos and large files prefer `mediaRequest(.original, assetID:)`.
    func original(assetID: String) async throws -> Data

    /// An authenticated request for the original file or the video stream, e.g. for `AVPlayer`.
    /// Does not contact the server.
    func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest

    // MARK: Map and memories

    /// `GET /map/markers`: one marker per geotagged asset.
    func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker]

    /// `GET /memories`: memories matching `query`, newest first.
    func memories(_ query: MemoryQuery) async throws -> [Memory]

    /// Marks or unmarks an asset as a favorite (`PUT /assets/{id}`). Returns the updated asset.
    func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset

    /// Hides an asset from the main timeline (`visibility: archive`) or returns it (`timeline`)
    /// with `PUT /assets/{id}`. Returns the updated asset.
    func setHidden(assetID: String, hidden: Bool) async throws -> Asset

    /// Moves only these assets to Immich trash. Never performs permanent deletion.
    /// Call only after an explicit user confirmation; partial/uncertain failures are returned.
    func moveToTrash(assetIDs: [String]) async throws -> TrashResult

    /// Restores only these specific assets from trash, after explicit confirmation.
    func restoreAssets(assetIDs: [String]) async throws -> RestoreResult

    /// Creates an album (`POST /albums`), requesting these initial assets. Returns only
    /// the new album's id, not a receipt for inclusion of the requested assets.
    /// Requirements, not just extension methods: the UI holds `any ImmichService`, and an
    /// extension-only method would always dispatch to the refusing default.
    func createAlbum(name: String, assetIDs: [String]) async throws -> String

    /// Adds assets to an album (`PUT /albums/{id}/assets`).
    func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult
}

extension ImmichService {
    /// Services that can't tell assume every feature is on, so nothing is reported as off.
    public func serverFeatures() async throws -> ServerFeatures { ServerFeatures() }

    /// Services that can't ask the server don't claim to.
    public func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        throw ImmichServiceError.unexpectedStatus(501)
    }

    /// Services that can't upload don't claim to.
    public func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult {
        throw ImmichServiceError.unexpectedStatus(501)
    }

    public func linkLivePhoto(photoID: String, motionID: String) async throws {
        throw ImmichServiceError.unexpectedStatus(501)
    }

    /// Existing custom/read-only services do not acquire write access implicitly.
    public func restoreAssets(assetIDs: [String]) async throws -> RestoreResult {
        throw ImmichServiceError.invalidResponse
    }

    /// Custom read-only services fail closed unless they explicitly implement trash support.
    public func moveToTrash(assetIDs: [String]) async throws -> TrashResult {
        throw TrashError.unavailable
    }

    /// Markers for the main timeline (not archived).
    public func mapMarkers() async throws -> [MapMarker] {
        try await mapMarkers(MapMarkerOptions())
    }

    /// The memories to show on `date`'s local day ("On this day" and birthdays), newest year first.
    public func memories(on date: Date = Date(), calendar: Calendar = .current) async throws -> [Memory] {
        try await memories(.shown(on: date, calendar: calendar))
            .filter { !$0.assets.isEmpty }
            .sorted { $0.year > $1.year }
    }

    /// The video request for `asset`: its own stream for a video, the motion part for a Live Photo,
    /// `nil` for a still image.
    public func playbackRequest(for asset: Asset) async throws -> MediaRequest? {
        if asset.isVideo { return try await mediaRequest(.videoPlayback, assetID: asset.id) }
        if let motionID = asset.livePhotoVideoId { return try await mediaRequest(.videoPlayback, assetID: motionID) }
        return nil
    }
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
    /// The request did not reach the server (offline, DNS, TLS, timeout, ...). `code` is the transport's
    /// `URLError` code when there was one: `isConnectivityFailure` tells "no connection" from e.g. TLS by it.
    case network(String, code: URLError.Code? = nil)
    /// A change to the library was refused because Allow Changes is off (`EditingPermission`).
    case editingOff
    /// Refused to send the API key over plain http to a host outside the user's own network.
    case insecureConnection

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return tr("The server URL is not valid.")
        case .unauthorized:
            return tr("The server rejected the API key.")
        case .unexpectedStatus(let status):
            return tr("The server answered with HTTP status %lld.", Int64(status))
        case .invalidResponse:
            return tr("The server sent a response that is not an Immich API response. Check the server URL.")
        case .network(let message, _):
            return tr("Could not reach the server: %@", message)
        case .insecureConnection:
            return tr("Bloom only uses http on your own network or Tailscale. Use https for this server.")
        case .editingOff:
            return tr("Bloom is set to view only. Turn on Allow Changes in the account menu to change your library.")
        }
    }
}
