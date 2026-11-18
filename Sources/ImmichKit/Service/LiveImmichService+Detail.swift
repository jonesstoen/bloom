import Foundation
import ImmichAPI
import OpenAPIRuntime

extension LiveImmichService {
    // MARK: Asset detail

    /// `PUT /assets/{id}` with only `isFavorite`. Sent raw so the filter list of generated
    /// operations stays read-only; the response is decoded with the same lenient asset decoder.
    public func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset {
        let body = try JSONSerialization.data(withJSONObject: ["isFavorite": isFavorite])
        _ = try await rawPUT(path: "/assets/\(Self.pathComponent(assetID))", json: body, operationID: "updateAsset")
        return try await asset(id: assetID)
    }

    /// `PUT /assets/{id}` with only `visibility`: `archive` hides the asset from the timeline,
    /// `timeline` returns it. Raw for the same reason as `setFavorite`.
    public func setHidden(assetID: String, hidden: Bool) async throws -> Asset {
        let body = try JSONSerialization.data(withJSONObject: ["visibility": hidden ? "archive" : "timeline"])
        _ = try await rawPUT(path: "/assets/\(Self.pathComponent(assetID))", json: body, operationID: "updateAsset")
        return try await asset(id: assetID)
    }

    public func asset(id: String) async throws -> Asset {
        do {
            let output = try await Self.mapErrors { try await client.getAssetInfo(path: .init(id: id)) }
            switch output {
            case .ok(let ok):
                guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
                return Asset(dto: dto)
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            // Older servers omit asset fields the v3.4.0 spec requires (`isEdited`, `visibility`, ...).
            let data = try await rawGET(path: "/assets/\(Self.pathComponent(id))", operationID: Operations.GetAssetInfo.id)
            return try LenientDetail.asset(from: data)
        }
    }

    /// Largest original accepted by `original(assetID:)`. Stream bigger files with `mediaRequest`.
    static let maxOriginalBytes = 512 * 1024 * 1024

    public func original(assetID: String) async throws -> Data {
        let output = try await Self.mapErrors { try await client.downloadAsset(path: .init(id: assetID)) }
        switch output {
        case .ok(let ok):
            guard case .binary(let body) = ok.body else { throw ImmichServiceError.invalidResponse }
            return try await Self.mapErrors { try await Data(collecting: body, upTo: Self.maxOriginalBytes) }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    public func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest {
        guard !assetID.isEmpty else { throw ImmichServiceError.invalidResponse }
        guard credentials.protectsAPIKey else { throw ImmichServiceError.insecureConnection }
        // The ID is escaped like every other path segment: these requests carry the API key.
        let suffix = switch kind {
        case .original: "original"
        case .videoPlayback: "video/playback"
        }
        guard let url = URL(string: credentials.apiBaseURL.absoluteString + "/assets/\(Self.pathComponent(assetID))/\(suffix)") else {
            throw ImmichServiceError.invalidResponse
        }
        return MediaRequest(
            kind: kind, assetID: assetID, url: url,
            headers: [APIKeyMiddleware.headerName.canonicalName: credentials.apiKey]
        )
    }

    // MARK: Map

    public func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] {
        let query = Operations.GetMapMarkers.Input.Query(
            fileCreatedAfter: options.takenAfter, fileCreatedBefore: options.takenBefore,
            isArchived: options.includeArchived, isFavorite: options.isFavorite,
            withPartners: options.withPartners, withSharedAlbums: options.withSharedAlbums
        )
        let output = try await Self.mapErrors { try await client.getMapMarkers(query: query) }
        switch output {
        case .ok(let ok):
            guard case .json(let dtos) = ok.body else { throw ImmichServiceError.invalidResponse }
            return dtos.map(MapMarker.init(dto:))
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    // MARK: Memories

    public func memories(_ query: MemoryQuery) async throws -> [Memory] {
        let input = Operations.SearchMemories.Input.Query(
            _for: query.dayString, isSaved: query.isSaved,
            _type: query.kind.flatMap { Components.Schemas.MemoryType(rawValue: $0.rawValue) }
        )
        do {
            let output = try await Self.mapErrors { try await client.searchMemories(query: input) }
            switch output {
            case .ok(let ok):
                guard case .json(let dtos) = ok.body else { throw ImmichServiceError.invalidResponse }
                return dtos.map(Memory.init(dto:))
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            // Older servers send assets without `isEdited`/`visibility`; newer ones may add memory types.
            var items: [URLQueryItem] = []
            if let day = query.dayString { items.append(URLQueryItem(name: "for", value: day)) }
            if let isSaved = query.isSaved { items.append(URLQueryItem(name: "isSaved", value: String(isSaved))) }
            if let kind = query.kind { items.append(URLQueryItem(name: "type", value: kind.rawValue)) }
            var components = URLComponents()
            components.path = "/memories"
            components.queryItems = items.isEmpty ? nil : items
            let path = components.string ?? "/memories"
            let data = try await rawGET(path: path, operationID: Operations.SearchMemories.id)
            return try LenientDetail.memories(from: data)
        }
    }
}
