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
        case smartSearch(String)
        case metadataSearch
        case searchSuggestions(SearchSuggestionKind)
        case asset(String)
        case original(String)
        case mediaRequest(MediaRequest.Kind, String)
        case mapMarkers
        case memories
        case setFavorite(String, Bool)
        case moveToTrash(String)
        case restoreAssets(String)
        case createAlbum(String)
        case addToAlbum(String)
        case bulkUploadCheck(Int)
        case upload(String)
        case linkLivePhoto(String, String)
    }

    /// Base URL of the media requests the mock hands out. Nothing answers there.
    public static let mediaBaseURL = URL(string: "https://mock.immich.invalid/api")!

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
    public private(set) var smartSearchFailure: ImmichServiceError?
    /// If `true`, authenticated requests throw `.unauthorized` (a wrong API key).
    /// Ping and version still succeed, as they need no key on a real server.
    public var rejectsAPIKey = false
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
    public private(set) var features = ServerFeatures()
    public private(set) var featuresFailure: ImmichServiceError?
    public private(set) var serverChecksums: Set<String> = []
    /// The checksums the mock server already has; `checkBulkUpload` reports these as duplicates.
    public func setServerChecksums(_ checksums: Set<String>) { serverChecksums = checksums }
    public private(set) var trashedChecksums: Set<String> = []
    /// Checksums whose server copy is in the trash: reported as trashed duplicates, even if not in `serverChecksums`.
    public func setTrashedChecksums(_ checksums: Set<String>) { trashedChecksums = checksums }
    public private(set) var rejectedChecksums: Set<String> = []
    /// Checksums the server refuses for a reason other than a duplicate (unsupported format).
    public func setRejectedChecksums(_ checksums: Set<String>) { rejectedChecksums = checksums }
    public private(set) var unansweredChecksums: Set<String> = []
    /// Checksums `checkBulkUpload` leaves out of its answer.
    public func setUnansweredChecksums(_ checksums: Set<String>) { unansweredChecksums = checksums }
    private var bulkUploadChecks = 0
    private var bulkUploadFailure: (error: ImmichServiceError, after: Int)?
    /// Makes `checkBulkUpload` throw `failure`, but only after `calls` calls have succeeded.
    public func setBulkUploadFailure(_ failure: ImmichServiceError?, afterCalls calls: Int = 0) {
        bulkUploadFailure = failure.map { ($0, calls) }
        bulkUploadChecks = 0
    }

    /// Every `uploadAsset` call, failed ones included, in order.
    public private(set) var uploads: [AssetUploadRequest] = []
    /// Every `linkLivePhoto` call, failed ones included, in order.
    public private(set) var links: [(photoID: String, motionID: String)] = []
    private var queuedUploadResults: [AssetUploadResult] = []
    private var uploadedIDs: [String: String] = [:]
    private var uploadCalls = 0
    private var uploadFailure: (error: any Error, after: Int)?
    private var linkFailure: (any Error)?
    private var uploadWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Returns once `uploadAsset` has been called `count` times (failed calls included), so tests can
    /// act while an upload is in flight without polling.
    public func waitForUploads(_ count: Int) async {
        if uploads.count >= count { return }
        await withCheckedContinuation { uploadWaiters.append((count, $0)) }
    }
    /// The next uploads answer with these results, one per call, in order. After that, an upload answers
    /// `.created` with a new UUID, or `.duplicate` with the earlier ID for a checksum uploaded before.
    public func setUploadResults(_ results: [AssetUploadResult]) { queuedUploadResults = results }
    /// Makes `uploadAsset` throw `failure`, but only after `calls` calls have succeeded.
    public func setUploadFailure(_ failure: (any Error)?, afterCalls calls: Int = 0) {
        uploadFailure = failure.map { ($0, calls) }
        uploadCalls = 0
    }
    /// Makes `linkLivePhoto` throw `failure`.
    public func setLinkFailure(_ failure: (any Error)?) { linkFailure = failure }
    public func setServerFeatures(_ features: ServerFeatures) { self.features = features }
    /// Fails only the features request, like a server that no longer serves it.
    public func setServerFeaturesFailure(_ failure: ImmichServiceError?) { featuresFailure = failure }
    /// Fails only smart search, like a server without a working machine-learning service.
    public func setSmartSearchFailure(_ failure: ImmichServiceError?) { smartSearchFailure = failure }
    public private(set) var thumbnailFailure: ImmichServiceError?
    /// Fails only thumbnails and previews, like a server whose previews aren't generated yet
    /// (HTTP 404 "Asset media not found") while the asset itself exists.
    public func setThumbnailFailure(_ failure: ImmichServiceError?) { thumbnailFailure = failure }

    private var trashFailures: Set<String> = []
    public func setTrashFailures(_ ids: Set<String>) { trashFailures = ids }

    private var restoreFailures: Set<String> = []
    public func setRestoreFailures(_ ids: Set<String>) { restoreFailures = ids }

    public func restoreAssets(assetIDs: [String]) async throws -> RestoreResult {
        let ids = try TrashRequestIDs.validated(assetIDs)
        var confirmed: [String] = []
        var failed: [String] = []
        for (offset, id) in ids.enumerated() {
            if Task.isCancelled {
                failed.append(contentsOf: ids[offset...])
                break
            }
            if assetsByID[id]?.isTrashed == false {
                confirmed.append(id)
                continue
            }
            do {
                try await begin(.restoreAssets(id))
                guard !restoreFailures.contains(id), let index = assets.firstIndex(where: { $0.id == id }) else {
                    throw ImmichServiceError.invalidResponse
                }
                assets[index].isTrashed = false
                confirmed.append(id)
            } catch {
                failed.append(id)
            }
        }
        return RestoreResult(confirmedIDs: confirmed, failedIDs: failed)
    }

    public func moveToTrash(assetIDs: [String]) async throws -> TrashResult {
        let ids = try TrashRequestIDs.validated(assetIDs)
        var confirmed: [String] = []
        var failed: [String] = []
        for (offset, id) in ids.enumerated() {
            if Task.isCancelled {
                failed.append(contentsOf: ids[offset...])
                break
            }
            if assetsByID[id]?.isTrashed == true {
                confirmed.append(id)
                continue
            }
            do {
                try await begin(.moveToTrash(id))
                guard !trashFailures.contains(id), let index = assets.firstIndex(where: { $0.id == id }) else {
                    throw ImmichServiceError.invalidResponse
                }
                assets[index].isTrashed = true
                confirmed.append(id)
            } catch {
                failed.append(id)
            }
        }
        return TrashResult(confirmedIDs: confirmed, failedIDs: failed)
    }

    /// Added to every bucket's count, like a server whose bucket counts differ slightly from the
    /// assets it returns for the bucket (e.g. stacks). For testing layout shifts.
    public private(set) var bucketCountOffset = 0
    public func setBucketCountOffset(_ offset: Int) { bucketCountOffset = offset }
    public func setRejectsAPIKey(_ rejects: Bool) { self.rejectsAPIKey = rejects }

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

    /// Not recorded in `requests`, so existing request-order assertions stay unchanged.
    public func serverFeatures() async throws -> ServerFeatures {
        if let featuresFailure { throw featuresFailure }
        return features
    }

    public func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        try await begin(.bulkUploadCheck(items.count))
        bulkUploadChecks += 1
        if let bulkUploadFailure, bulkUploadChecks > bulkUploadFailure.after { throw bulkUploadFailure.error }
        return items.filter { !unansweredChecksums.contains($0.checksum) }.map { item in
            let trashed = trashedChecksums.contains(item.checksum)
            let known = trashed || serverChecksums.contains(item.checksum)
            return BulkUploadCheckResult(
                id: item.id, isDuplicate: known, serverAssetID: known ? (uploadedIDs[item.checksum] ?? "server-\(item.checksum)") : nil, isTrashed: trashed,
                isRejected: !known && rejectedChecksums.contains(item.checksum))
        }
    }

    /// A successful upload adds the checksum to `serverChecksums`, so a later `checkBulkUpload` sees a duplicate.
    public func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult {
        uploads.append(request)
        let reached = uploadWaiters.filter { $0.count <= uploads.count }
        uploadWaiters.removeAll { $0.count <= uploads.count }
        for waiter in reached { waiter.continuation.resume() }
        try await begin(.upload(request.checksum))
        uploadCalls += 1
        if let uploadFailure, uploadCalls > uploadFailure.after { throw uploadFailure.error }
        let result: AssetUploadResult
        if !queuedUploadResults.isEmpty {
            result = queuedUploadResults.removeFirst()
        } else if let id = uploadedIDs[request.checksum] {
            result = AssetUploadResult(id: id, status: .duplicate)
        } else {
            result = AssetUploadResult(id: UUID().uuidString.lowercased(), status: .created)
        }
        uploadedIDs[request.checksum] = uploadedIDs[request.checksum] ?? result.id
        serverChecksums.insert(request.checksum)
        return result
    }

    public func linkLivePhoto(photoID: String, motionID: String) async throws {
        links.append((photoID, motionID))
        try await begin(.linkLivePhoto(photoID, motionID))
        if let linkFailure { throw linkFailure }
    }

    public func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        try await begin(.timeBuckets)
        var counts: [String: (year: Int, month: Int, count: Int)] = [:]
        for asset in filtered(options) {
            let parts = Asset.localCalendar.dateComponents([.year, .month], from: asset.localDateTime)
            let key = TimeBucket.key(year: parts.year!, month: parts.month!)
            counts[key, default: (parts.year!, parts.month!, 0)].count += 1
        }
        let buckets = counts.map {
            TimeBucket(id: $0.key, year: $0.value.year, month: $0.value.month, count: max(0, $0.value.count + bucketCountOffset))
        }
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
        if let thumbnailFailure { throw thumbnailFailure }
        return Self.placeholderData(assetID: assetID, size: size, aspectRatio: assetsByID[assetID]?.aspectRatio ?? 1)
    }

    /// The bytes `thumbnail(assetID:size:)` returns. Deterministic per asset id, size and aspect ratio.
    public static func placeholderData(assetID: String, size: ImageSize, aspectRatio: Double = 1) -> Data {
        PlaceholderImage.jpegData(assetID: assetID, size: size, aspectRatio: aspectRatio)
    }

    // MARK: Albums

    /// The library's albums in library order, then albums created here (empty without a library).
    public func albums(shared: Bool?) async throws -> [Album] {
        try await begin(.albums)
        return allAlbums().filter { shared == nil || $0.isShared == shared }
    }

    /// Mock albums belong to the current user, including the shared examples.
    public func albumsForAdding() async throws -> [Album] {
        try await albums(shared: nil)
    }

    /// Throws HTTP 400 for an unknown id, as the server does for albums the user cannot access.
    public func album(id: String) async throws -> Album {
        try await begin(.album(id))
        guard let album = allAlbums().first(where: { $0.id == id }) else {
            throw ImmichServiceError.unexpectedStatus(400)
        }
        return album
    }

    public func createAlbum(name: String, assetIDs: [String]) async throws -> String {
        let albumName = try AlbumName.validated(name)
        try await begin(.createAlbum(albumName))
        let id = UUID().uuidString.lowercased()
        let now = Date()
        createdAlbums.append(Album(id: id, name: albumName, description: "", assetCount: 0, thumbnailAssetId: nil,
                                   startDate: nil, endDate: nil, createdAt: now, updatedAt: now,
                                   isShared: false, isNewestFirst: true))
        albumAdditions[id] = assetIDs.filter { assetsByID[$0] != nil }
        return id
    }

    public func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult {
        try await begin(.addToAlbum(albumID))
        guard allAlbums().contains(where: { $0.id == albumID }) else { throw ImmichServiceError.unexpectedStatus(400) }
        var inAlbum = Set(albumAssetIDs(albumID))
        var result = AlbumAddResult(addedIDs: [], alreadyInAlbumIDs: [], failedIDs: [])
        for id in assetIDs {
            if assetsByID[id] == nil { result.failedIDs.append(id) }
            else if inAlbum.contains(id) { result.alreadyInAlbumIDs.append(id) }
            else { inAlbum.insert(id); albumAdditions[albumID, default: []].append(id); result.addedIDs.append(id) }
        }
        return result
    }

    /// Albums created here and photos added here, on top of the library's.
    private var createdAlbums: [Album] = []
    private var albumAdditions: [String: [String]] = [:]

    private func albumAssetIDs(_ albumID: String) -> [String] {
        (library?.albumAssetIDs[albumID] ?? []) + (albumAdditions[albumID] ?? [])
    }

    private func allAlbums() -> [Album] {
        ((library?.albums ?? []) + createdAlbums).map { album in
            var album = album
            album.assetCount = Set(albumAssetIDs(album.id)).count
            if album.thumbnailAssetId == nil { album.thumbnailAssetId = albumAssetIDs(album.id).first }
            return album
        }
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

    // MARK: Search

    /// Stand-in for CLIP: an asset matches when a query word occurs in its place, camera, kind
    /// (`photo`/`video`/`live`/`favorite`), file name, album names or people's names. Ranked by the
    /// number of matching words, then newest first. Pages by number, like the server's smart search.
    public func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        try await begin(.smartSearch(query.text))
        if let smartSearchFailure { throw smartSearchFailure }
        let words = Self.words(query.text)
        guard !words.isEmpty else { throw ImmichServiceError.unexpectedStatus(400) }
        let index = searchIndex()
        let scored = searchable(query.filters).compactMap { asset -> (Asset, Int)? in
            let haystack = index[asset.id] ?? ""
            let score = words.filter { haystack.contains($0) }.count
            return score > 0 ? (asset, score) : nil
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.takenAt != rhs.0.takenAt { return lhs.0.takenAt > rhs.0.takenAt }
            return lhs.0.id < rhs.0.id
        }.map(\.0)
        let number: Int
        switch page {
        case .page(let value)?: number = max(1, value)
        case .cursor?: throw ImmichServiceError.unexpectedStatus(400)
        case nil: number = 1
        }
        let (slice, hasMore) = Self.slice(ranked, offset: (number - 1) * Self.clampedSize(size), size: size)
        return SearchResults(assets: slice, total: ranked.count, next: hasMore ? .page(number + 1) : nil)
    }

    /// Filters plus case-insensitive substring matches on file name and description, ordered by date.
    /// Pages by cursor (the offset as a string), like servers from v3.2.0; page numbers work too.
    public func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        try await begin(.metadataSearch)
        let matches = searchable(query.filters)
            .filter { asset in
                if let name = query.originalFileName?.nilIfBlank,
                   asset.originalFileName?.localizedCaseInsensitiveContains(name) != true { return false }
                if let text = query.description?.nilIfBlank,
                   asset.exif?.description?.localizedCaseInsensitiveContains(text) != true { return false }
                return true
            }
            .sorted { query.newestFirst ? $0.takenAt > $1.takenAt : $0.takenAt < $1.takenAt }
        let size = Self.clampedSize(size)
        let offset: Int
        switch page {
        case .cursor(let cursor)?:
            guard let value = Int(cursor), value >= 0 else { throw ImmichServiceError.unexpectedStatus(400) }
            offset = value
        case .page(let number)?: offset = (max(1, number) - 1) * size
        case nil: offset = 0
        }
        let (slice, hasMore) = Self.slice(matches, offset: offset, size: size)
        return SearchResults(assets: slice, total: matches.count, next: hasMore ? .cursor(String(offset + size)) : nil)
    }

    /// Distinct EXIF values from the assets, sorted, narrowed by `context`.
    public func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String] {
        try await begin(.searchSuggestions(kind))
        let values = assets.compactMap { asset -> String? in
            guard !asset.isTrashed, let exif = asset.exif else { return nil }
            if let country = context.country, exif.country != country { return nil }
            if let state = context.state, exif.state != state { return nil }
            if let make = context.make, exif.make != make { return nil }
            if let model = context.model, exif.model != model { return nil }
            let value: String? = switch kind {
            case .country: exif.country
            case .state: exif.state
            case .city: exif.city
            case .cameraMake: exif.make
            case .cameraModel: exif.model
            case .lensModel: exif.lensModel
            }
            return value?.nilIfBlank
        }
        return Set(values).sorted()
    }

    // MARK: Asset detail

    /// The asset with its EXIF; HTTP 400 for an unknown id, as the server answers.
    public func asset(id: String) async throws -> Asset {
        try await begin(.asset(id))
        guard let asset = assetsByID[id] else { throw ImmichServiceError.unexpectedStatus(400) }
        return asset
    }

    /// Updates the favorite flag in the fake library; HTTP 400 for an unknown id.
    public func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset {
        try await begin(.setFavorite(assetID, isFavorite))
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { throw ImmichServiceError.unexpectedStatus(400) }
        assets[index].isFavorite = isFavorite
        return assets[index]
    }

    /// A large placeholder JPEG (the same bytes as the preview) for known assets.
    public func original(assetID: String) async throws -> Data {
        try await begin(.original(assetID))
        guard let asset = assetsByID[assetID] else { throw ImmichServiceError.unexpectedStatus(400) }
        return Self.placeholderData(assetID: assetID, size: .preview, aspectRatio: asset.aspectRatio)
    }

    /// A request under `mediaBaseURL` without headers. HTTP 400 for unknown ids; video playback
    /// works for videos and for the motion part of Live Photos.
    public func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest {
        try await begin(.mediaRequest(kind, assetID))
        let isMotionPart = assets.contains { $0.livePhotoVideoId == assetID }
        guard assetsByID[assetID] != nil || isMotionPart else { throw ImmichServiceError.unexpectedStatus(400) }
        let base = Self.mediaBaseURL.appendingPathComponent("assets").appendingPathComponent(assetID)
        switch kind {
        case .original:
            return MediaRequest(kind: kind, assetID: assetID, url: base.appendingPathComponent("original"))
        case .videoPlayback:
            guard assetsByID[assetID]?.isVideo == true || isMotionPart else {
                throw ImmichServiceError.unexpectedStatus(400)
            }
            return MediaRequest(
                kind: kind, assetID: assetID,
                url: base.appendingPathComponent("video").appendingPathComponent("playback")
            )
        }
    }

    // MARK: Map and memories

    /// Markers for the geotagged assets passing `options`, in asset order.
    public func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] {
        try await begin(.mapMarkers)
        return assets.compactMap { asset in
            guard options.matches(asset), let exif = asset.exif,
                  let latitude = exif.latitude, let longitude = exif.longitude
            else { return nil }
            return MapMarker(id: asset.id, latitude: latitude, longitude: longitude,
                             city: exif.city, state: exif.state, country: exif.country)
        }
    }

    /// The library's memories matching `query` (shown on its day), newest first. Empty without a library.
    public func memories(_ query: MemoryQuery) async throws -> [Memory] {
        try await begin(.memories)
        return (library?.memories ?? [])
            .filter(query.matches)
            .sorted { $0.memoryAt > $1.memoryAt }
    }

    private func searchable(_ filters: SearchFilters) -> [Asset] {
        let albums = (library?.albumAssetIDs ?? [:]).mapValues(Set.init)
        let people = (library?.personAssetIDs ?? [:]).mapValues(Set.init)
        return assets.filter { filters.matches($0, albumAssetIDs: albums, personAssetIDs: people) }
    }

    /// Lower-cased searchable text per asset id.
    private func searchIndex() -> [String: String] {
        var extra: [String: [String]] = [:]
        if let library {
            for album in library.albums {
                for id in library.albumAssetIDs[album.id] ?? [] { extra[id, default: []].append(album.name) }
            }
            for person in library.people where person.isNamed {
                for id in library.personAssetIDs[person.id] ?? [] { extra[id, default: []].append(person.name) }
            }
        }
        var index: [String: String] = [:]
        for asset in assets {
            let exif = asset.exif
            var parts: [String?] = [exif?.city, exif?.state, exif?.country, exif?.make, exif?.model,
                                    exif?.lensModel, exif?.description, asset.originalFileName]
            parts.append(asset.isVideo ? "video movie" : "photo picture image")
            if asset.isLivePhoto { parts.append("live") }
            if asset.isFavorite { parts.append("favorite") }
            parts += (extra[asset.id] ?? []).map(Optional.some)
            index[asset.id] = parts.compactMap { $0?.lowercased() }.joined(separator: " ")
        }
        return index
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func clampedSize(_ size: Int) -> Int { max(1, min(size, 1000)) }

    private static func slice(_ items: [Asset], offset: Int, size: Int) -> ([Asset], Bool) {
        let size = clampedSize(size)
        guard offset < items.count else { return ([], false) }
        let end = min(items.count, offset + size)
        return (Array(items[offset..<end]), end < items.count)
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
        if rejectsAPIKey, request != .ping, request != .serverVersion {
            throw ImmichServiceError.unauthorized
        }
    }

    /// Mirrors the server filters. Album/person filters use `library` and match nothing without one.
    private func filtered(_ options: TimelineOptions) -> [Asset] {
        let albumIDs = options.albumId.map { Set(albumAssetIDs($0)) }
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
