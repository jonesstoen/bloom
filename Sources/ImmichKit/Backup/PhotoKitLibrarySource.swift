#if canImport(Photos)
import Foundation
import Photos

/// `PhotoLibrarySource` on top of PhotoKit. Read-only by design: no change requests and no
/// `performChanges` anywhere in this type. Not exercised by unit tests (needs a real library).
public struct PhotoKitLibrarySource: PhotoLibrarySource {
    public init() {}

    public func authorization() async -> PhotoAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        default: .denied
        }
    }

    public func albums() async -> [DeviceAlbum] {
        var result: [DeviceAlbum] = []

        let smartSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary, // Recents
            .smartAlbumFavorites,
            .smartAlbumScreenshots,
            .smartAlbumVideos,
            .smartAlbumLivePhotos,
        ]
        for subtype in smartSubtypes {
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            collections.enumerateObjects { collection, _, _ in
                result.append(Self.deviceAlbum(collection))
            }
        }

        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        user.enumerateObjects { collection, _, _ in
            result.append(Self.deviceAlbum(collection))
        }
        return result
    }

    public func assetIDs(inAlbum id: String) async -> Set<String> {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
        guard let collection = collections.firstObject else { return [] }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var ids: Set<String> = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    public func asset(_ id: String) async -> DeviceAsset? {
        guard let asset = Self.phAsset(id) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).map {
            DeviceResource(type: Self.type($0.type), filename: $0.originalFilename)
        }
        let epoch = Date(timeIntervalSince1970: 0)
        return DeviceAsset(
            id: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            creationDate: asset.creationDate ?? epoch,
            modificationDate: asset.modificationDate ?? asset.creationDate ?? epoch,
            isFavorite: asset.isFavorite,
            duration: asset.duration,
            resources: resources
        )
    }

    public func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @Sendable (Data) -> Void
    ) async throws {
        guard let asset = Self.phAsset(assetID),
              let phResource = PHAssetResource.assetResources(for: asset).first(where: {
                  Self.type($0.type) == resource.type && $0.originalFilename == resource.filename
              })
        else { throw CocoaError(.fileNoSuchFile) }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let request = RequestBox()

        try await withoutActuallyEscaping(onData) { escapingOnData in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let id = PHAssetResourceManager.default().requestData(
                        for: phResource,
                        options: options,
                        dataReceivedHandler: { escapingOnData($0) },
                        completionHandler: { error in
                            if let error {
                                continuation.resume(throwing: Self.map(error))
                            } else {
                                continuation.resume()
                            }
                        }
                    )
                    request.set(id)
                }
            } onCancel: {
                if let id = request.value { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        }
    }

    // MARK: - Helpers

    private static func deviceAlbum(_ collection: PHAssetCollection) -> DeviceAlbum {
        let estimate = collection.estimatedAssetCount
        let count = estimate == NSNotFound
            ? PHAsset.fetchAssets(in: collection, options: nil).count
            : estimate
        return DeviceAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count)
    }

    private static func phAsset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    static func type(_ type: PHAssetResourceType) -> DeviceResourceType {
        switch type {
        case .photo: .photo
        case .fullSizePhoto: .fullSizePhoto
        case .pairedVideo: .pairedVideo
        case .fullSizePairedVideo: .fullSizePairedVideo
        case .video: .video
        case .fullSizeVideo: .fullSizeVideo
        default: .other
        }
    }

    /// With `isNetworkAccessAllowed == false`, an iCloud-only resource fails with
    /// `PHPhotosError.networkAccessRequired` (code 3164 in `PHPhotosErrorDomain`).
    static func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.networkAccessRequired.rawValue {
            return PhotoLibraryReadError.needsNetwork
        }
        return error
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID?
    var value: PHAssetResourceDataRequestID? { lock.withLock { id } }
    func set(_ new: PHAssetResourceDataRequestID) { lock.withLock { id = new } }
}
#endif
