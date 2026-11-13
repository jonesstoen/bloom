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
    private var _accessAfterRequest: PhotoAccess
    private var _authorizationRequests = 0
    private var _albums: [DeviceAlbum] = []
    private var _albumAssets: [String: Set<String>] = [:]
    private var _assets: [String: DeviceAsset] = [:]
    private var _data: [DeviceResource: [Data]] = [:]
    private var _iCloudOnly: Set<DeviceResource> = []
    private var _failures: [DeviceResource: Error] = [:]
    private var _reads: [ReadCall] = []
    private var _delivered: [DeviceResource: Int] = [:]
    private var _singleLookups = 0
    private var _batchLookups: [Int] = []
    private var _dateLookups: [Int] = []

    /// `accessAfterRequest` is what the user answers when asked (used when `access` is `.notDetermined`).
    init(access: PhotoAccess = .full, accessAfterRequest: PhotoAccess = .full) {
        _access = access
        _accessAfterRequest = accessAfterRequest
    }

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

    /// How many times the user was asked for access.
    var authorizationRequests: Int { lock.withLock { _authorizationRequests } }
    func setAccessAfterRequest(_ access: PhotoAccess) { lock.withLock { _accessAfterRequest = access } }

    var reads: [ReadCall] { lock.withLock { _reads } }
    /// Chunks of `resource` handed to `onData` so far, over all reads.
    func deliveredChunks(of resource: DeviceResource) -> Int { lock.withLock { _delivered[resource] ?? 0 } }
    /// Calls to `asset(_:)`.
    var singleLookups: Int { lock.withLock { _singleLookups } }
    /// The number of IDs in each `assets(_:)` call.
    var batchLookups: [Int] { lock.withLock { _batchLookups } }
    /// The number of IDs in each `modificationDates(_:)` call.
    var dateLookups: [Int] { lock.withLock { _dateLookups } }

    // PhotoLibrarySource

    func authorization() async -> PhotoAccess { lock.withLock { _access } }
    func requestAuthorization() async -> PhotoAccess {
        lock.withLock {
            _authorizationRequests += 1
            if _access == .notDetermined { _access = _accessAfterRequest }
            return _access
        }
    }
    func albums() async -> [DeviceAlbum] { lock.withLock { _albums } }
    func assetIDs(inAlbum id: String) async -> Set<String> { lock.withLock { _albumAssets[id] ?? [] } }
    func asset(_ id: String) async -> DeviceAsset? {
        lock.withLock { _singleLookups += 1; return _assets[id] }
    }
    func assets(_ ids: [String]) async -> [DeviceAsset] {
        lock.withLock { _batchLookups.append(ids.count); return ids.compactMap { _assets[$0] } }
    }
    func modificationDates(_ ids: [String]) async -> [String: Date] {
        lock.withLock {
            _dateLookups.append(ids.count)
            var dates: [String: Date] = [:]
            for id in ids { if let asset = _assets[id] { dates[id] = asset.modificationDate } }
            return dates
        }
    }

    func read(
        _ resource: DeviceResource,
        of assetID: String,
        allowNetwork: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        let (failure, iCloudOnly, chunks): (Error?, Bool, [Data]) = lock.withLock {
            _reads.append(ReadCall(resource: resource, assetID: assetID, allowNetwork: allowNetwork))
            return (_failures[resource], _iCloudOnly.contains(resource), _data[resource] ?? [])
        }
        if let failure { throw failure }
        if iCloudOnly && !allowNetwork { throw PhotoLibraryReadError.needsNetwork }
        // Like PhotoKit after `cancelDataRequest`: no more data once the read is cancelled.
        for chunk in chunks {
            try Task.checkCancellation()
            onData(chunk)
            lock.withLock { _delivered[resource, default: 0] += 1 }
        }
    }
}
