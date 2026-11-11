import Foundation

/// Identifies one server-rendered image: an asset at a size.
public struct ImageKey: Sendable, Hashable, CustomStringConvertible {
    public var assetID: String
    public var size: ImageSize

    public init(assetID: String, size: ImageSize) {
        self.assetID = assetID
        self.size = size
    }

    /// Stable string used as cache key and file name.
    public var description: String { "\(assetID)-\(size.rawValue)" }
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
    private var inFlight: [ImageKey: Task<Data, any Error>] = [:]
    /// Bumped by `removeAll()` so loads started before it do not repopulate the caches.
    private var generation = 0

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
    public func data(for key: ImageKey) async throws -> Data {
        if let data = memoryData(for: key) { return data }
        if let task = inFlight[key] { return try await task.value }

        let service = self.service
        let disk = self.disk
        let task = Task<Data, any Error> {
            if let disk, let data = await disk.data(for: key.description) {
                return data
            }
            let data = try await service.thumbnail(assetID: key.assetID, size: key.size)
            await disk?.store(data, for: key.description)
            return data
        }
        inFlight[key] = task
        let started = generation
        defer { if started == generation { inFlight[key] = nil } }

        let data = try await task.value
        if started == generation {
            memory.setObject(data as NSData, forKey: key.description as NSString, cost: data.count)
        }
        return data
    }

    public func data(assetID: String, size: ImageSize) async throws -> Data {
        try await data(for: ImageKey(assetID: assetID, size: size))
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
        generation += 1
        inFlight = [:]
        memory.removeAllObjects()
        await disk?.removeAll()
    }
}
