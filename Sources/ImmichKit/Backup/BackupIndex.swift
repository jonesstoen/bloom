import Foundation

public enum PendingReason: String, Codable, Sendable {
    case notChecked, needsUpload, waitingForWiFi
}

public enum BackupState: Codable, Sendable, Equatable {
    case pending(reason: PendingReason)
    case backedUp(serverAssetID: String)
    case failed(reason: String)
    /// The server had these copies once and no longer does: `trashed` halves are in the server's
    /// trash (restorable), `gone` halves are deleted for good. Nothing is uploaded or restored
    /// for an item in this state without the user's action.
    case deletedOnServer(trashed: Set<DeviceResourceType>, gone: Set<DeviceResourceType>)
}

/// What Bloom knows about one device asset: when it last changed, the checksums of its resources
/// and where it stands.
public struct BackupEntry: Codable, Sendable, Equatable {
    public var modificationDate: Date
    public var checksums: [DeviceResourceType: String]
    public var state: BackupState
    /// The server asset ID of each resource Bloom knows to be on the server. Empty in indexes
    /// written before Phase 2 and filled in by the next re-check.
    public var serverIDs: [DeviceResourceType: String]
    /// A Live Photo whose photo and motion video may not be joined on the server yet: set by the
    /// uploader before it sends anything of a Live Photo and cleared once they are. While set, a scan
    /// that finds both halves on the server keeps the item queued so the uploader links them.
    /// `false` in indexes written before it existed.
    public var needsLink: Bool

    public init(
        modificationDate: Date,
        checksums: [DeviceResourceType: String],
        state: BackupState,
        serverIDs: [DeviceResourceType: String] = [:],
        needsLink: Bool = false
    ) {
        self.modificationDate = modificationDate
        self.checksums = checksums
        self.state = state
        self.serverIDs = serverIDs
        self.needsLink = needsLink
    }

    private enum CodingKeys: String, CodingKey {
        case modificationDate, checksums, state, serverIDs, needsLink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modificationDate = try container.decode(Date.self, forKey: .modificationDate)
        checksums = try container.decode([DeviceResourceType: String].self, forKey: .checksums)
        state = try container.decode(BackupState.self, forKey: .state)
        serverIDs = try container.decodeIfPresent([DeviceResourceType: String].self, forKey: .serverIDs) ?? [:]
        needsLink = try container.decodeIfPresent(Bool.self, forKey: .needsLink) ?? false
    }
}

public enum BackupIndexError: Error, Sendable {
    /// The index file exists but couldn't be read, so saving would overwrite it.
    case unavailable
}

/// Per-account record of backup state, kept in one JSON file so checksums survive relaunches.
/// Changes stay in memory until `save()`; the scanner saves in batches.
public actor BackupIndex {
    private struct Stored: Codable {
        var entries: [String: BackupEntry] = [:]
        var selection = BackupSelection()
    }

    private let fileURL: URL
    private var stored = Stored()
    private var isAvailable = true
    private var hasChanges = false
    /// Writes of the file so far, for tests that check how often the index is saved.
    private(set) var saveCount = 0

    /// Loads `index.json` from `directory`. A missing file starts empty; a corrupt one is moved
    /// aside to `index.json.corrupt` and the index starts empty; a file that exists but can't be
    /// read (for instance while the device is locked) makes the index unavailable until `reload()`
    /// succeeds, so a later `save()` can't overwrite it with a partial index.
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("index.json")
        let result = Self.read(fileURL)
        stored = result.stored
        isAvailable = result.isAvailable
    }

    public func entry(for assetID: String) -> BackupEntry? { stored.entries[assetID] }

    /// Up to `limit` entries among `ids` that satisfy `isIncluded`, filtered inside the actor so
    /// callers don't make one hop per ID. Order is unspecified.
    public func entries(
        where isIncluded: (BackupEntry) -> Bool, in ids: Set<String>, limit: Int
    ) -> [(String, BackupEntry)] {
        guard limit > 0 else { return [] }
        var result: [(String, BackupEntry)] = []
        for id in ids {
            guard let entry = stored.entries[id], isIncluded(entry) else { continue }
            result.append((id, entry))
            if result.count == limit { break }
        }
        return result
    }

    public func set(_ entry: BackupEntry, for assetID: String) {
        guard stored.entries[assetID] != entry else { return }
        stored.entries[assetID] = entry
        hasChanges = true
    }

    /// Writes `entry` only if the stored entry for `assetID` still has modification date `date` and
    /// `checksums`, i.e. describes the version the caller worked on, checked and written in one step.
    /// Returns whether it wrote; `false` also when there is no entry.
    @discardableResult
    public func set(
        _ entry: BackupEntry, for assetID: String,
        ifModificationDate date: Date, checksums: [DeviceResourceType: String]
    ) -> Bool {
        update(assetID, ifModificationDate: date, checksums: checksums) { $0 = entry }
    }

    /// Applies `change` to the stored entry for `assetID`, inside the index, if it still has modification
    /// date `date` and `checksums` (the version the caller worked on). Returns whether it did.
    @discardableResult
    public func update(
        _ assetID: String, ifModificationDate date: Date, checksums: [DeviceResourceType: String],
        _ change: (inout BackupEntry) -> Void
    ) -> Bool {
        update(assetID, if: { $0.modificationDate == date && $0.checksums == checksums }, change) != nil
    }

    /// Applies `change` to the stored entry for `assetID`, inside the index, if `condition` holds for it:
    /// checked and written in one step. Returns the entry as written, `nil` when there is no entry or the
    /// condition doesn't hold.
    @discardableResult
    public func update(
        _ assetID: String, if condition: (BackupEntry) -> Bool, _ change: (inout BackupEntry) -> Void
    ) -> BackupEntry? {
        guard var entry = stored.entries[assetID], condition(entry) else { return nil }
        change(&entry)
        set(entry, for: assetID)
        return entry
    }

    public func selection() -> BackupSelection { stored.selection }

    public func setSelection(_ s: BackupSelection) {
        guard stored.selection != s else { return }
        stored.selection = s
        hasChanges = true
    }

    /// Retries loading after the file couldn't be read. Replaces the in-memory state.
    public func reload() throws { try load() }

    public func save() throws {
        guard isAvailable else { throw BackupIndexError.unavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: CacheProtection.writingOptions)
        hasChanges = false
        saveCount += 1
    }

    /// A scanner checkpoint; unchanged records need no additional disk write.
    func saveIfChanged() throws {
        guard isAvailable else { throw BackupIndexError.unavailable }
        guard hasChanges else { return }
        try save()
    }

    /// Forgets everything and removes the file. Also makes an unavailable index usable again.
    public func clear() {
        stored = Stored()
        hasChanges = false
        try? FileManager.default.removeItem(at: fileURL)
        isAvailable = true
    }

    private func load() throws {
        let result = Self.read(fileURL)
        stored = result.stored
        isAvailable = result.isAvailable
        hasChanges = false
        if let error = result.error { throw error }
    }

    private nonisolated static func read(_ fileURL: URL) -> (stored: Stored, isAvailable: Bool, error: Error?) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return (Stored(), true, nil)
        } catch {
            return (Stored(), false, error)
        }
        do {
            return (try JSONDecoder().decode(Stored.self, from: data), true, nil)
        } catch {
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return (Stored(), true, nil)
        }
    }
}
