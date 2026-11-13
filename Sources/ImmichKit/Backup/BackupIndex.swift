import Foundation

public enum PendingReason: String, Codable, Sendable {
    case notChecked, needsUpload, waitingForWiFi
}

public enum BackupState: Codable, Sendable, Equatable {
    case pending(reason: PendingReason)
    case backedUp(serverAssetID: String)
    case failed(reason: String)
}

/// What Bloom knows about one device asset: when it last changed, the checksums of its resources
/// and where it stands.
public struct BackupEntry: Codable, Sendable, Equatable {
    public var modificationDate: Date
    public var checksums: [DeviceResourceType: String]
    public var state: BackupState

    public init(modificationDate: Date, checksums: [DeviceResourceType: String], state: BackupState) {
        self.modificationDate = modificationDate
        self.checksums = checksums
        self.state = state
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

    public func set(_ entry: BackupEntry, for assetID: String) { stored.entries[assetID] = entry }

    public func selection() -> BackupSelection { stored.selection }

    public func setSelection(_ s: BackupSelection) { stored.selection = s }

    /// Retries loading after the file couldn't be read. Replaces the in-memory state.
    public func reload() throws { try load() }

    public func save() throws {
        guard isAvailable else { throw BackupIndexError.unavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: CacheProtection.writingOptions)
    }

    /// Forgets everything and removes the file. Also makes an unavailable index usable again.
    public func clear() {
        stored = Stored()
        try? FileManager.default.removeItem(at: fileURL)
        isAvailable = true
    }

    private func load() throws {
        let result = Self.read(fileURL)
        stored = result.stored
        isAvailable = result.isAvailable
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
