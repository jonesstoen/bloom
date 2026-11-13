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

/// Per-account record of backup state, kept in one JSON file so checksums survive relaunches.
/// Changes stay in memory until `save()`; the scanner saves in batches.
public actor BackupIndex {
    private struct Stored: Codable {
        var entries: [String: BackupEntry] = [:]
        var selection = BackupSelection()
    }

    private let fileURL: URL
    private var stored: Stored

    /// Loads `index.json` from `directory` if present. A missing or unreadable file starts empty.
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    public func entry(for assetID: String) -> BackupEntry? { stored.entries[assetID] }

    public func set(_ entry: BackupEntry, for assetID: String) { stored.entries[assetID] = entry }

    public func selection() -> BackupSelection { stored.selection }

    public func setSelection(_ s: BackupSelection) { stored.selection = s }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: CacheProtection.writingOptions)
    }

    /// Forgets everything and removes the file.
    public func clear() {
        stored = Stored()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
