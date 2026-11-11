import Foundation

/// Identifies one server-rendered image: an asset at a size, or a person's face thumbnail.
public struct ImageKey: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// `GET /assets/{id}/thumbnail?size=…`
        case asset
        /// `GET /people/{id}/thumbnail` (`size` is ignored).
        case person
    }

    public var kind: Kind
    /// Asset id, or person id for `.person`.
    public var assetID: String
    public var size: ImageSize

    public init(assetID: String, size: ImageSize) {
        self.kind = .asset
        self.assetID = assetID
        self.size = size
    }

    /// The face thumbnail of a person.
    public static func person(_ personID: String) -> ImageKey {
        var key = ImageKey(assetID: personID, size: .thumbnail)
        key.kind = .person
        return key
    }

    /// Stable string used as cache key and file name.
    public var description: String {
        switch kind {
        case .asset: "\(assetID)-\(size.rawValue)"
        case .person: "person-\(assetID)"
        }
    }
}

/// Loads thumbnail and preview images with a two-level cache.
///
/// Lookup order: memory (`NSCache`, cost = byte count) → disk (`DiskImageCache`) → network
/// (`ImmichService.thumbnail`). Concurrent requests for the same key share one network request.
/// Returns encoded image data (JPEG/WebP); decoding happens in the UI layer.
public actor ImageLoader {
    private let service: any ImmichService
    private let disk: DiskImageCache?
    private let memory = NSCache<NSString, NSData>()
    private struct InFlight {
        let id: UUID
        let task: Task<Data, any Error>
        /// Callers still interested in the result (not cancelled).
        var waiters: Set<UUID>
    }

    /// Running fetches. `removeAll()` empties this, so loads started before it do not repopulate the caches.
    private var inFlight: [ImageKey: InFlight] = [:]

    /// - Parameters:
    ///   - disk: `nil` disables the disk cache (memory only).
    ///   - memoryCostLimit: approximate byte budget for the in-memory cache.
    public init(
        service: any ImmichService,
        disk: DiskImageCache? = DiskImageCache(),
        memoryCostLimit: Int = 64 * 1024 * 1024
    ) {
        self.service = service
        self.disk = disk
        memory.totalCostLimit = memoryCostLimit
    }

    /// Returns the image data from memory, disk or the server, in that order.
    ///
    /// Concurrent callers for the same key share one fetch. Cancelling a caller only cancels the
    /// shared fetch once every caller waiting for it has been cancelled (used by `Prefetcher`).
    public func data(for key: ImageKey) async throws -> Data {
        if let data = memoryData(for: key) { return data }

        let waiter = UUID()
        let entry: InFlight
        if var existing = inFlight[key] {
            existing.waiters.insert(waiter)
            inFlight[key] = existing
            entry = existing
        } else {
            let service = self.service
            let disk = self.disk
            let task = Task<Data, any Error> {
                if let disk, let data = await disk.data(for: key.description) {
                    return data
                }
                try Task.checkCancellation()
                let data = switch key.kind {
                case .asset: try await service.thumbnail(assetID: key.assetID, size: key.size)
                case .person: try await service.personThumbnail(personID: key.assetID)
                }
                await disk?.store(data, for: key.description)
                return data
            }
            entry = InFlight(id: UUID(), task: task, waiters: [waiter])
            inFlight[key] = entry
        }

        // A cancelled caller still waits for the shared result if other callers keep it alive.
        let result = await withTaskCancellationHandler {
            await entry.task.result
        } onCancel: {
            Task { await self.waiterCancelled(key: key, entryID: entry.id, waiter: waiter) }
        }

        let isCurrent = inFlight[key]?.id == entry.id
        if isCurrent { inFlight[key] = nil }
        let data = try result.get()
        if isCurrent {
            memory.setObject(data as NSData, forKey: key.description as NSString, cost: data.count)
        }
        return data
    }

    /// Removes a cancelled caller; cancels the shared fetch when nobody is waiting for it anymore.
    private func waiterCancelled(key: ImageKey, entryID: UUID, waiter: UUID) {
        guard var entry = inFlight[key], entry.id == entryID else { return }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    public func data(assetID: String, size: ImageSize) async throws -> Data {
        try await data(for: ImageKey(assetID: assetID, size: size))
    }

    /// A person's face thumbnail, cached like asset thumbnails.
    public func personData(personID: String) async throws -> Data {
        try await data(for: .person(personID))
    }

    /// Memory-only lookup, for showing an image synchronously without a placeholder flash.
    public func memoryData(for key: ImageKey) -> Data? {
        memory.object(forKey: key.description as NSString) as Data?
    }

    /// `true` while a request for `key` is running.
    public func isLoading(_ key: ImageKey) -> Bool {
        inFlight[key] != nil
    }

    /// Drops the memory cache (e.g. on a memory warning). The disk cache stays.
    public func clearMemory() {
        memory.removeAllObjects()
    }

    /// Drops memory and disk caches. Running loads still return to their callers but are not cached.
    public func removeAll() async {
        inFlight = [:]
        memory.removeAllObjects()
        await disk?.removeAll()
    }
}
