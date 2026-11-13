import CryptoKit
import Foundation

/// Best-effort, account-scoped timeline cache. All encoding and file access stays on this actor.
/// Pass a dedicated directory; `invalidate()` deletes it and permanently closes this instance.
public actor TimelineSnapshotStore {
    public nonisolated let directory: URL
    public nonisolated let byteLimit: Int
    /// A save must retain the revision from the generation that produced its snapshot.
    public private(set) var revision: UInt64 = 0
    private var isInvalidated = false
    private let files = FileManager.default

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let options: TimelineOptions
        let months: [TimelineMonth]
    }

    public init(directory: URL, byteLimit: Int = 32 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
    }

    public func load(options: TimelineOptions) -> [TimelineMonth]? {
        guard !isInvalidated, !Task.isCancelled, let url = fileURL(options: options) else { return nil }
        trim()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= byteLimit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read at most the statted size, plus an EOF check, even if a file changes underneath us.
        guard let data = try? read(handle, size: size),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == 1, snapshot.options == options,
              TimelineSnapshotValidation.isValid(snapshot.months) else {
            try? files.removeItem(at: url)
            return nil
        }
        try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return snapshot.months
    }

    private func read(_ handle: FileHandle, size: Int) throws -> Data? {
        let data = try handle.read(upToCount: size) ?? Data()
        let extra = try handle.read(upToCount: 1)
        return data.count == size && (extra?.isEmpty ?? true) ? data : nil
    }

    public func save(months: [TimelineMonth], options: TimelineOptions, expectedRevision: UInt64? = nil) {
        guard expectedRevision == nil || expectedRevision == revision,
              !isInvalidated, !Task.isCancelled, byteLimit > 0, TimelineSnapshotValidation.isValid(months),
              let url = fileURL(options: options),
              let data = try? JSONEncoder().encode(Snapshot(schemaVersion: 1, options: options, months: months)),
              data.count <= byteLimit else { return }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: CacheProtection.writingOptions)
            try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            trim(keeping: url)
        } catch {
            // A cache failure must never prevent the network-backed library from working.
        }
    }

    /// Removes every sort/filter partition without closing this store. Old queued saves cannot
    /// recreate them when they supply the revision captured with their original snapshot.
    /// Deliberately runs even in a cancelled task: the server may already have accepted a write.
    @discardableResult
    public func clearAll() -> UInt64 {
        revision &+= 1
        try? files.removeItem(at: directory)
        return revision
    }

    /// Serialized with writes (there are no suspension points during file operations).
    public func invalidate() {
        isInvalidated = true
        try? files.removeItem(at: directory)
    }

    private func fileURL(options: TimelineOptions) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(options) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json", isDirectory: false)
    }

    private func trim(keeping retainedURL: URL? = nil) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            if size > byteLimit {
                try? files.removeItem(at: url)
            } else {
                entries.append((url, size, values.contentModificationDate ?? .distantPast))
            }
        }
        // Accumulate only retained bytes, so arbitrary on-disk file sizes cannot overflow a sum.
        var remaining = byteLimit
        entries.sort {
            if ($0.url == retainedURL) != ($1.url == retainedURL) { return $0.url == retainedURL }
            return $0.date > $1.date
        }
        for entry in entries {
            if entry.size <= remaining { remaining -= entry.size }
            else { try? files.removeItem(at: entry.url) }
        }
    }
}

/// Shared with Timeline.restore so invalid cached data never reaches grid/date indexing.
enum TimelineSnapshotValidation {
    static func isValid(_ months: [TimelineMonth]) -> Bool {
        guard months.count <= 2_400 else { return false }
        var monthIDs: Set<String> = []
        var bucketDates: Set<String> = []
        var assetIDs: Set<String> = []
        var count = 0
        var dayCount = 0
        for month in months {
            let bucket = month.bucket
            guard !bucket.id.isEmpty, bucket.id.utf8.count <= 512,
                  (1...9999).contains(bucket.year), (1...12).contains(bucket.month),
                  bucket.count >= 0, bucket.count <= TimeBucket.maxAssets - count,
                  monthIDs.insert(bucket.id).inserted,
                  bucketDates.insert("\(bucket.year)-\(bucket.month)").inserted else { return false }
            count += bucket.count
            var dayIDs: Set<String> = []
            for day in month.days ?? [] {
                dayCount += 1
                guard dayCount <= 200_000, validDate(year: day.year, month: day.month, day: day.day),
                      dayIDs.insert(day.id).inserted else { return false }
                for asset in day.assets {
                    guard !asset.id.isEmpty, asset.id.utf8.count <= 512,
                          assetIDs.count < 200_000, assetIDs.insert(asset.id).inserted,
                          asset.takenAt.timeIntervalSinceReferenceDate.isFinite,
                          asset.localDateTime.timeIntervalSinceReferenceDate.isFinite else { return false }
                    let parts = Asset.localCalendar.dateComponents([.year, .month, .day], from: asset.localDateTime)
                    guard parts.year == day.year, parts.month == day.month, parts.day == day.day else { return false }
                }
            }
        }
        // Bucket counts may differ from loaded counts (stacking), and Recently Added buckets
        // legitimately contain days from other capture months. Neither is cache corruption.
        return true
    }

    private static func validDate(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let parts = Asset.localCalendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day
    }
}
