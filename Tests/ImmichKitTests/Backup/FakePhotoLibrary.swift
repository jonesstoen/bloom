import Foundation
@testable import ImmichKit

/// Dictionary-backed photo library for tests. Never touches PhotoKit.
final class FakePhotoLibrary: PhotoLibrarySource, @unchecked Sendable {
    struct ReadCall: Equatable {
        let resource: DeviceResource
        let assetID: String
        let allowNetwork: Bool
    }

    private let lock = NSLock()
    private var _access: PhotoAccess
    private var _albums: [DeviceAlbum] = []
    private var _albumAssets: [String: Set<String>] = [:]
    private var _assets: [String: DeviceAsset] = [:]
    private var _data: [DeviceResource: [Data]] = [:]
    private var _iCloudOnly: Set<DeviceResource> = []
    private var _failures: [DeviceResource: Error] = [:]
    private var _reads: [ReadCall] = []

    init(access: PhotoAccess = .full) { _access = access }

    // Configuration

    func addAlbum(id: String, title: String, assetIDs: Set<String>) {
        lock.withLock {
            _albums.append(DeviceAlbum(id: id, title: title, count: assetIDs.count))
            _albumAssets[id] = assetIDs
        }
    }

    func addAsset(_ asset: DeviceAsset) { lock.withLock { _assets[asset.id] = asset } }

    func setData(_ chunks: [Data], for resource: DeviceResource) { lock.withLock { _data[resource] = chunks } }

    /// The resource exists only in iCloud: reading with `allowNetwork == false` throws `.needsNetwork`.
    func markICloudOnly(_ resource: DeviceResource) { lock.withLock { _ = _iCloudOnly.insert(resource) } }

    /// Make reads of this resource fail with `error`, regardless of `allowNetwork`.
    func failReads(of resource: DeviceResource, with error: Error) { lock.withLock { _failures[resource] = error } }

    var reads: [ReadCall] { lock.withLock { _reads } }

    // PhotoLibrarySource

    func authorization() async -> PhotoAccess { lock.withLock { _access } }
    func albums() async -> [DeviceAlbum] { lock.withLock { _albums } }
    func assetIDs(inAlbum id: String) async -> Set<String> { lock.withLock { _albumAssets[id] ?? [] } }
    func asset(_ id: String) async -> DeviceAsset? { lock.withLock { _assets[id] } }

    func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @Sendable (Data) -> Void
    ) async throws {
        let (failure, iCloudOnly, chunks): (Error?, Bool, [Data]) = lock.withLock {
            _reads.append(ReadCall(resource: resource, assetID: assetID, allowNetwork: allowNetwork))
            return (_failures[resource], _iCloudOnly.contains(resource), _data[resource] ?? [])
        }
        if let failure { throw failure }
        if iCloudOnly && !allowNetwork { throw PhotoLibraryReadError.needsNetwork }
        for chunk in chunks { onData(chunk) }
    }
}
