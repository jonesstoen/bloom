import Foundation

/// The kind of file PhotoKit stores for an asset (a mirror of `PHAssetResourceType`, without the import).
public enum DeviceResourceType: String, Sendable, Codable {
    case photo, fullSizePhoto, pairedVideo, fullSizePairedVideo, video, fullSizeVideo, other
}

public struct DeviceResource: Sendable, Hashable {
    public let type: DeviceResourceType
    /// PhotoKit's original filename of this resource (for an edit, something like `FullSizeRender.jpg`).
    public let filename: String
    /// The file's uniform type identifier (`public.heic`, `com.apple.quicktime-movie`), when known.
    public let uniformTypeIdentifier: String?

    public init(type: DeviceResourceType, filename: String, uniformTypeIdentifier: String? = nil) {
        self.type = type
        self.filename = filename
        self.uniformTypeIdentifier = uniformTypeIdentifier
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
    /// The user hasn't been asked yet.
    case notDetermined
}

public enum PhotoLibraryReadError: Error, Equatable {
    /// The resource lives only in iCloud and the read was made with `allowNetwork == false`.
    case needsNetwork
}

/// Read-only view of the device photo library. Backup never changes the library.
public protocol PhotoLibrarySource: Sendable {
    func authorization() async -> PhotoAccess
    /// Asks the user if they haven't decided yet; returns the resulting access.
    func requestAuthorization() async -> PhotoAccess
    func albums() async -> [DeviceAlbum]
    func assetIDs(inAlbum id: String) async -> Set<String>
    func asset(_ id: String) async -> DeviceAsset?
    /// The assets among `ids` that still exist, fetched together (order not guaranteed).
    func assets(_ ids: [String]) async -> [DeviceAsset]
    /// The modification dates of the assets among `ids` that still exist, without reading resources.
    func modificationDates(_ ids: [String]) async -> [String: Date]
    /// Streams the resource's bytes to `onData`. Throws `PhotoLibraryReadError.needsNetwork` when the
    /// resource is only in iCloud and `allowNetwork` is false.
    func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws
    /// One element per change of the photo library, for as long as the stream is iterated.
    /// The element carries no details; callers rescan.
    func changes() -> AsyncStream<Void>
    /// A small JPEG of the asset from what is already on the device (never downloads from iCloud),
    /// or nil when there is none. `pixelSide` is the target size of the longer side, in pixels.
    func thumbnailData(_ id: String, pixelSide: Int) async -> Data?
    /// The assets inserted or changed since `token` (an archived change token returned by an earlier call),
    /// and the token to pass next time. `ids == nil` means the changes can't be told (no token yet, an
    /// expired or unreadable one, or a library without persistent changes): scan everything. The returned
    /// token is that of the last change read (pass it next time to get the changes after it); when the
    /// changes can't be told, it is the library's current token, read before the caller's full scan, so
    /// whatever changes during that scan is found next time. It is nil when the library has none. Deleted
    /// assets are not listed (the scanner drops them on a full scan).
    func changedAssetIDs(since token: Data?) async -> (ids: Set<String>?, token: Data?)
}

extension PhotoLibrarySource {
    /// Without persistent changes: always a full scan.
    public func changedAssetIDs(since token: Data?) async -> (ids: Set<String>?, token: Data?) { (nil, nil) }
}
