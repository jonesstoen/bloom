import Foundation

extension LiveImmichService {
    public func albumsForAdding() async throws -> [Album] {
        var albums: [Album] = []
        var seen = Set<String>()
        // Ownership is independent of sharing. Two list requests also avoid requiring
        // user-profile access or fetching each album separately just to find its role.
        for owned in [true, false] {
            let output = try await Self.mapErrors {
                try await client.getAllAlbums(query: .init(isOwned: owned))
            }
            switch output {
            case .ok(let ok):
                guard case .json(let dtos) = ok.body else { throw ImmichServiceError.invalidResponse }
                for dto in dtos {
                    // For shared-with-me albums the spec puts the owner first and
                    // the authenticated user second; later editors are other people.
                    let canAdd = owned || (dto.albumUsers.first?.role == .owner
                        && dto.albumUsers.count > 1 && dto.albumUsers[1].role == .editor)
                    if canAdd, seen.insert(dto.id.lowercased()).inserted {
                        albums.append(Album(dto: dto))
                    }
                }
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        }
        return albums
    }

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
