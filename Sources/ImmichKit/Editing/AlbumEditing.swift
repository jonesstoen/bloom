import Foundation

/// What happened to each photo when adding to an album (`PUT /albums/{id}/assets`).
public struct AlbumAddResult: Sendable, Equatable {
    public var addedIDs: [String]
    /// Already in the album (the server's `duplicate`): not an error.
    public var alreadyInAlbumIDs: [String]
    /// Refused or not reported back by the server.
    public var failedIDs: [String]

    public init(addedIDs: [String], alreadyInAlbumIDs: [String], failedIDs: [String]) {
        self.addedIDs = addedIDs
        self.alreadyInAlbumIDs = alreadyInAlbumIDs
        self.failedIDs = failedIDs
    }
}

extension ImmichService {
    /// Services that can't edit albums (test doubles) refuse; the live and mock services override.
    public func createAlbum(name: String, assetIDs: [String]) async throws -> String {
        throw ImmichServiceError.unexpectedStatus(501)
    }

    public func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult {
        throw ImmichServiceError.unexpectedStatus(501)
    }
}

enum AlbumName {
    /// Trimmed; an empty name is refused before anything is sent.
    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImmichServiceError.invalidResponse }
        return trimmed
    }
}

extension LiveImmichService {
    /// `POST /albums` (201 Created). Returns the new album's id.
    public func createAlbum(name: String, assetIDs: [String]) async throws -> String {
        let albumName = try AlbumName.validated(name)
        let ids = assetIDs.isEmpty ? [] : try TrashRequestIDs.validated(assetIDs)
        let body = try JSONSerialization.data(withJSONObject: ["albumName": albumName, "assetIds": ids])
        let data = try await rawRequest(method: .post, path: "/albums", json: body, operationID: "createAlbum",
                                        maxBytes: 4 * 1024 * 1024, acceptedStatuses: [200, 201])
        struct Created: Decodable { let id: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data), !created.id.isEmpty else {
            throw ImmichServiceError.invalidResponse
        }
        return created.id
    }

    /// `PUT /albums/{id}/assets`. Photos missing from the server's answer count as failed.
    public func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult {
        let ids = try TrashRequestIDs.validated(assetIDs)
        let body = try JSONSerialization.data(withJSONObject: ["ids": ids])
        let data = try await rawPUT(path: "/albums/\(Self.pathComponent(albumID))/assets", json: body,
                                    operationID: "addAssetsToAlbum", maxBytes: 4 * 1024 * 1024)
        struct Item: Decodable { let id: String; let success: Bool; let error: String? }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { throw ImmichServiceError.invalidResponse }
        let byID = Dictionary(items.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result = AlbumAddResult(addedIDs: [], alreadyInAlbumIDs: [], failedIDs: [])
        for id in ids {
            switch byID[id.lowercased()] {
            case let item? where item.success: result.addedIDs.append(id)
            case let item? where item.error == "duplicate": result.alreadyInAlbumIDs.append(id)
            default: result.failedIDs.append(id)
            }
        }
        return result
    }
}
