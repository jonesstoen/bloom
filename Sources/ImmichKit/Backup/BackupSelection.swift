import Foundation

/// Which device albums are backed up: everything in `included`, minus anything in `excluded`.
public struct BackupSelection: Codable, Sendable, Equatable {
    public var included: Set<String>
    public var excluded: Set<String>

    public init(included: Set<String> = [], excluded: Set<String> = []) {
        self.included = included
        self.excluded = excluded
    }

    /// Unknown album IDs contribute nothing.
    public func assetIDs(in source: some PhotoLibrarySource) async -> Set<String> {
        var result: Set<String> = []
        for id in included { result.formUnion(await source.assetIDs(inAlbum: id)) }
        for id in excluded { result.subtract(await source.assetIDs(inAlbum: id)) }
        return result
    }
}
