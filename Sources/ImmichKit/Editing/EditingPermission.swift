import Foundation
import os

/// Whether Bloom may change the library on the server (favorites, trash, restore, albums).
/// Off until the user turns on Allow Changes, so trying Bloom on a library can't change it.
/// Read by `EditGuardedService` on every write, so a change takes effect at once.
public final class EditingPermission: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    public init(isAllowed: Bool) {
        state = OSAllocatedUnfairLock(initialState: isAllowed)
    }

    public var isAllowed: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Wraps a service and refuses every write while `permission` is off; reads pass through.
/// The UI also hides edit controls then, but this is what guarantees nothing is written.
public struct EditGuardedService: ImmichService {
    public let base: any ImmichService
    public let permission: EditingPermission

    public init(base: any ImmichService, permission: EditingPermission) {
        self.base = base
        self.permission = permission
    }

    private func checkEditing() throws {
        guard permission.isAllowed else { throw ImmichServiceError.editingOff }
    }

    // MARK: Writes

    public func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset {
        try checkEditing()
        return try await base.setFavorite(assetID: assetID, isFavorite: isFavorite)
    }

    public func moveToTrash(assetIDs: [String]) async throws -> TrashResult {
        try checkEditing()
        return try await base.moveToTrash(assetIDs: assetIDs)
    }

    public func restoreAssets(assetIDs: [String]) async throws -> RestoreResult {
        try checkEditing()
        return try await base.restoreAssets(assetIDs: assetIDs)
    }

    public func createAlbum(name: String, assetIDs: [String]) async throws -> String {
        try checkEditing()
        return try await base.createAlbum(name: name, assetIDs: assetIDs)
    }

    public func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult {
        try checkEditing()
        return try await base.addAssets(toAlbum: albumID, assetIDs: assetIDs)
    }

    // MARK: Reads

    public func ping() async throws { try await base.ping() }
    public func serverVersion() async throws -> ServerVersion { try await base.serverVersion() }
    public func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        try await base.timeBuckets(options: options)
    }
    public func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] {
        try await base.timeBucketAssets(bucketID: bucketID, options: options)
    }
    public func thumbnail(assetID: String, size: ImageSize) async throws -> Data {
        try await base.thumbnail(assetID: assetID, size: size)
    }
    public func albums(shared: Bool?) async throws -> [Album] { try await base.albums(shared: shared) }
    public func album(id: String) async throws -> Album { try await base.album(id: id) }
    public func people(withHidden: Bool) async throws -> [Person] { try await base.people(withHidden: withHidden) }
    public func person(id: String) async throws -> Person { try await base.person(id: id) }
    public func personThumbnail(personID: String) async throws -> Data { try await base.personThumbnail(personID: personID) }
    public func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        try await base.smartSearch(query, page: page, size: size)
    }
    public func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        try await base.metadataSearch(query, page: page, size: size)
    }
    public func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String] {
        try await base.searchSuggestions(kind, context: context)
    }
    public func asset(id: String) async throws -> Asset { try await base.asset(id: id) }
    public func original(assetID: String) async throws -> Data { try await base.original(assetID: assetID) }
    public func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest {
        try await base.mediaRequest(kind, assetID: assetID)
    }
    public func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] { try await base.mapMarkers(options) }
    public func memories(_ query: MemoryQuery) async throws -> [Memory] { try await base.memories(query) }
}
