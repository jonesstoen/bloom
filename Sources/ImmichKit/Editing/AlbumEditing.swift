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
    /// Custom services without role metadata cannot establish access to shared albums.
    public func albumsForAdding() async throws -> [Album] {
        try await albums().filter { !$0.isShared }
    }

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
