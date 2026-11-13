import Foundation

/// The kind of file PhotoKit stores for an asset (a mirror of `PHAssetResourceType`, without the import).
public enum DeviceResourceType: String, Sendable, Codable {
    case photo, fullSizePhoto, pairedVideo, fullSizePairedVideo, video, fullSizeVideo, other
}

public struct DeviceResource: Sendable, Hashable {
    public let type: DeviceResourceType
    public let filename: String

    public init(type: DeviceResourceType, filename: String) {
        self.type = type
        self.filename = filename
    }
}

public struct DeviceAsset: Sendable, Hashable {
    public let id: String
    public let isVideo: Bool
    public let creationDate: Date
    public let modificationDate: Date
    public let isFavorite: Bool
    public let duration: TimeInterval
    public let resources: [DeviceResource]

    public init(
        id: String,
        isVideo: Bool,
        creationDate: Date,
        modificationDate: Date,
        isFavorite: Bool,
        duration: TimeInterval,
        resources: [DeviceResource]
    ) {
        self.id = id
        self.isVideo = isVideo
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isFavorite = isFavorite
        self.duration = duration
        self.resources = resources
    }
}

public struct DeviceAlbum: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let count: Int

    public init(id: String, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}

public enum PhotoAccess: Sendable {
    case full, limited, denied
}

public enum PhotoLibraryReadError: Error, Equatable {
    /// The resource lives only in iCloud and the read was made with `allowNetwork == false`.
    case needsNetwork
}

/// Read-only view of the device photo library. Backup never changes the library.
public protocol PhotoLibrarySource: Sendable {
    func authorization() async -> PhotoAccess
    func albums() async -> [DeviceAlbum]
    func assetIDs(inAlbum id: String) async -> Set<String>
    func asset(_ id: String) async -> DeviceAsset?
    /// Streams the resource's bytes to `onData`. Throws `PhotoLibraryReadError.needsNetwork` when the
    /// resource is only in iCloud and `allowNetwork` is false.
    func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @Sendable (Data) -> Void
    ) async throws
}
