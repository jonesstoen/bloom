import Foundation

/// Byte-limited, least-recently-used file cache for encoded image data.
///
/// One file per key in `directory`. The index (size and last access per file) is built lazily from the
/// directory on first use, so entries survive app launches. When the total size goes over `byteLimit`,
/// the least recently used files are deleted until it fits again.
public actor DiskImageCache {
    public nonisolated let directory: URL
    public nonisolated let byteLimit: Int

    private struct Entry {
        var size: Int
        var lastAccess: Date
    }

    private var entries: [String: Entry] = [:]
    private var didLoadIndex = false
    /// Strictly increasing access times, so ordering is deterministic even within one clock tick.
    private var lastStamp = Date.distantPast
    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - directory: created if missing. Use `defaultDirectory` in the app.
    ///   - byteLimit: total size the cache trims down to.
    public init(directory: URL = DiskImageCache.defaultDirectory, byteLimit: Int = 500 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    /// `<Caches>/ImmichKit/Images`. The system may purge it when storage is low.
    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ImmichKit/Images", isDirectory: true)
    }

    /// Total size of all cached files in bytes.
    public var totalBytes: Int {
        loadIndexIfNeeded()
        return entries.values.reduce(0) { $0 + $1.size }
    }

    public func contains(_ key: String) -> Bool {
        loadIndexIfNeeded()
        return entries[key] != nil
    }

    /// Returns the cached data and marks the entry as recently used.
    public func data(for key: String) -> Data? {
        loadIndexIfNeeded()
        guard entries[key] != nil else { return nil }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            entries[key] = nil
            return nil
        }
        let now = nextStamp()
        entries[key]?.lastAccess = now
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return data
    }

    /// Stores data for `key`, then evicts least recently used entries over the byte limit.
    /// Data larger than the whole limit is not stored.
    public func store(_ data: Data, for key: String) {
        loadIndexIfNeeded()
        guard data.count <= byteLimit else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: CacheProtection.writingOptions)
        } catch {
            return
        }
        entries[key] = Entry(size: data.count, lastAccess: nextStamp())
        trim(keeping: key)
    }

    public func remove(_ key: String) {
        loadIndexIfNeeded()
        entries[key] = nil
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    public func removeAll() {
        entries = [:]
        didLoadIndex = true
        try? fileManager.removeItem(at: directory)
    }

    // MARK: Private

    private func trim(keeping key: String) {
        var total = entries.values.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }
        let oldestFirst = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (candidate, entry) in oldestFirst where total > byteLimit && candidate != key {
            entries[candidate] = nil
            try? fileManager.removeItem(at: fileURL(for: candidate))
            total -= entry.size
        }
    }

    private func nextStamp() -> Date {
        let now = Date()
        lastStamp = now > lastStamp ? now : lastStamp.addingTimeInterval(0.001)
        return lastStamp
    }

    private func loadIndexIfNeeded() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let key = Self.key(forFileName: url.lastPathComponent) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            entries[key] = Entry(size: values.fileSize ?? 0, lastAccess: modified)
            if modified > lastStamp { lastStamp = modified }
        }
        trim(keeping: "")
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key), isDirectory: false)
    }

    /// Keys are percent-encoded so any string maps to a safe, reversible file name.
    static func fileName(for key: String) -> String {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? key
        return encoded + ".img"
    }

    static func key(forFileName name: String) -> String? {
        guard name.hasSuffix(".img") else { return nil }
        return String(name.dropLast(4)).removingPercentEncoding
    }

    private static let safeCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_")
        return set
    }()
}
