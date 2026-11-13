#if canImport(Photos)
import Foundation
import Photos
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// `PhotoLibrarySource` on top of PhotoKit. Read-only by design: no change requests and no
/// `performChanges` anywhere in this type. Not exercised by unit tests (needs a real library).
public struct PhotoKitLibrarySource: PhotoLibrarySource {
    public init() {}

    public func authorization() async -> PhotoAccess {
        Self.access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotoAccess {
        Self.access(for: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func access(for status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notDetermined
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
        Self.phAsset(id).map(Self.deviceAsset)
    }

    /// One PhotoKit fetch for all `ids`; unknown ones are left out.
    public func assets(_ ids: [String]) async -> [DeviceAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [DeviceAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(Self.deviceAsset(asset)) }
        return assets
    }

    /// One PhotoKit fetch, without looking up resources.
    public func modificationDates(_ ids: [String]) async -> [String: Date] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var dates: [String: Date] = [:]
        dates.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in dates[asset.localIdentifier] = Self.modificationDate(asset) }
        return dates
    }

    private static func modificationDate(_ asset: PHAsset) -> Date {
        asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0)
    }

    private static func deviceAsset(_ asset: PHAsset) -> DeviceAsset {
        let resources = PHAssetResource.assetResources(for: asset).map {
            DeviceResource(
                type: Self.type($0.type), filename: $0.originalFilename, uniformTypeIdentifier: $0.uniformTypeIdentifier)
        }
        return DeviceAsset(
            id: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            creationDate: asset.creationDate ?? Date(timeIntervalSince1970: 0),
            modificationDate: modificationDate(asset),
            isFavorite: asset.isFavorite,
            duration: asset.duration,
            resources: resources
        )
    }

    public func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard let asset = Self.phAsset(assetID),
              let phResource = PHAssetResource.assetResources(for: asset).first(where: {
                  Self.type($0.type) == resource.type && $0.originalFilename == resource.filename
              })
        else { throw CocoaError(.fileNoSuchFile) }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let request = RequestBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = PHAssetResourceManager.default().requestData(
                    for: phResource,
                    options: options,
                    dataReceivedHandler: { onData($0) },
                    completionHandler: { error in
                        if let error {
                            continuation.resume(throwing: Self.map(error))
                        } else {
                            continuation.resume()
                        }
                    }
                )
                request.set(id)
                // The task may have been cancelled before the ID was stored; onCancel then saw nothing.
                if Task.isCancelled { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        } onCancel: {
            if let id = request.value { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }

    /// One element per library change. The observer is registered while the stream is alive and
    /// unregistered when it ends.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = LibraryChangeObserver(continuation)
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        }
    }

    /// A JPEG from what is on the device already: `.fastFormat`, no network.
    public func thumbnailData(_ id: String, pixelSide: Int) async -> Data? {
        guard let asset = Self.phAsset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let side = CGFloat(pixelSide)
        let once = ResumeOnce()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options
            ) { image, _ in
                guard once.claim() else { return }
                continuation.resume(returning: image.flatMap(Self.jpegData))
            }
        }
    }

    #if os(iOS)
    private static func jpegData(_ image: UIImage) -> Data? { image.jpegData(compressionQuality: 0.8) }
    #elseif os(macOS)
    private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
    #else
    private static func jpegData(_ image: Any) -> Data? { nil }
    #endif

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

/// Forwards each library change to the stream. Holds nothing but the continuation.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    func photoLibraryDidChange(_ changeInstance: PHChange) { continuation.yield() }
}

/// Lets only the first caller through, so a continuation is resumed once even if PhotoKit calls back twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
#endif
