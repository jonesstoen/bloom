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
    /// Where the uploader stands with retrying a queued item whose last upload or link failed in a way that
    /// trying again can fix. Kept in the index, so a relaunch (in the background too) doesn't start over
    /// and send it again at once. `nil` in indexes written before it existed.
    public var retry: BackupRetryState?

    public init(
        modificationDate: Date,
        checksums: [DeviceResourceType: String],
        state: BackupState,
        serverIDs: [DeviceResourceType: String] = [:],
        needsLink: Bool = false,
        retry: BackupRetryState? = nil
    ) {
        self.modificationDate = modificationDate
        self.checksums = checksums
        self.state = state
        self.serverIDs = serverIDs
        self.needsLink = needsLink
        self.retry = retry
    }

    private enum CodingKeys: String, CodingKey {
        case modificationDate, checksums, state, serverIDs, needsLink, retry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modificationDate = try container.decode(Date.self, forKey: .modificationDate)
        checksums = try container.decode([DeviceResourceType: String].self, forKey: .checksums)
        state = try container.decode(BackupState.self, forKey: .state)
        serverIDs = try container.decodeIfPresent([DeviceResourceType: String].self, forKey: .serverIDs) ?? [:]
        needsLink = try container.decodeIfPresent(Bool.self, forKey: .needsLink) ?? false
        // Leniently: unreadable retry bookkeeping only means the item is tried again sooner.
        retry = (try? container.decodeIfPresent(BackupRetryState.self, forKey: .retry)) ?? nil
    }
}

/// The retry bookkeeping of one queued item (see `BackupUploader.retryDelays`).
public struct BackupRetryState: Codable, Sendable, Equatable {
    /// Failures in a row that retrying could fix.
    public var failures: Int
    /// The item isn't tried again before this.
    public var notBefore: Date
    /// The last failure was no connection to the server: tried again once the network returns.
    public var wasOffline: Bool
    /// The last failure (no connection, 429, 502, 503, 504) holds back every item, not just this one.
    public var holdsRun: Bool

    public init(failures: Int, notBefore: Date, wasOffline: Bool, holdsRun: Bool) {
        self.failures = failures
        self.notBefore = notBefore
        self.wasOffline = wasOffline
        self.holdsRun = holdsRun
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
        /// Uploads handed to the transport whose result isn't recorded yet.
        var jobs: [UploadJob] = []
        /// When an upload last succeeded (see `BackupIndex.lastSuccess`).
        var lastSuccess: Date?

        init() {}

        private enum CodingKeys: String, CodingKey { case entries, selection, jobs, lastSuccess }

        /// `jobs` is absent in indexes written before background uploads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decode([String: BackupEntry].self, forKey: .entries)
            selection = try container.decode(BackupSelection.self, forKey: .selection)
            // Leniently: a job that can't be read is dropped, the entries are not thrown away with it.
            // (Its body file is then unreferenced and cleanup removes it.)
            jobs = ((try? container.decodeIfPresent([Lossy<UploadJob>].self, forKey: .jobs)) ?? nil)?
                .compactMap(\.value) ?? []
            lastSuccess = (try? container.decodeIfPresent(Date.self, forKey: .lastSuccess)) ?? nil
        }

        private struct Lossy<Value: Decodable>: Decodable {
            let value: Value?
            init(from decoder: Decoder) throws {
                value = try? decoder.singleValueContainer().decode(Value.self)
            }
        }
    }

    private let fileURL: URL
    private var stored = Stored()
    /// `false` while the file exists but couldn't be read: the index in memory is then not the one on disk.
    public private(set) var isAvailable = true
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

    /// Every entry that satisfies `isIncluded`, filtered inside the actor. Order is unspecified.
    public func entries(where isIncluded: (BackupEntry) -> Bool) -> [(String, BackupEntry)] {
        stored.entries.filter { isIncluded($0.value) }.map { ($0.key, $0.value) }
    }

    /// Applies `change` to every entry that satisfies `condition`, in one step inside the index.
    public func updateAll(where condition: (BackupEntry) -> Bool, _ change: (inout BackupEntry) -> Void) {
        for (id, entry) in stored.entries where condition(entry) {
            var changed = entry
            change(&changed)
            set(changed, for: id)
        }
    }

    // MARK: - Upload jobs

    /// The uploads handed to the transport whose result isn't recorded yet, oldest first.
    public var jobs: [UploadJob] { stored.jobs }

    /// When the result of an upload that reached the server was last recorded: "Last backup" on the Backup
    /// screen. It lives in the index so it is saved together with the result it dates (one write, no second
    /// file to keep in step) and goes with the account's directory at sign-out. `nil` before the first one.
    public var lastSuccess: Date? { stored.lastSuccess }

    /// Notes that an upload succeeded at `date`. Never moves the time backwards.
    func noteSuccess(at date: Date) {
        guard stored.lastSuccess.map({ $0 < date }) ?? true else { return }
        stored.lastSuccess = date
        hasChanges = true
    }

    public func jobs(for assetID: String) -> [UploadJob] { stored.jobs.filter { $0.assetID == assetID } }

    /// Records a job before it is handed to the transport. Adding the same attempt again changes nothing.
    public func addJob(_ job: UploadJob) {
        guard !stored.jobs.contains(where: { $0.attempt == job.attempt }) else { return }
        stored.jobs.append(job)
        hasChanges = true
    }

    /// Forgets the job of `attempt`. Returns whether there was one.
    @discardableResult
    public func removeJob(attempt: UUID) -> Bool {
        guard let position = stored.jobs.firstIndex(where: { $0.attempt == attempt }) else { return false }
        stored.jobs.remove(at: position)
        hasChanges = true
        return true
    }

    /// Finishes the job of `attempt` in one step: forgets its record and, if the stored entry for its asset
    /// satisfies `condition`, applies `change` to it. Both closures get the job as stored, not as the caller
    /// remembers it. Returns that job, or `nil` when no record of this attempt existed (its result was
    /// recorded before), in which case nothing changes. Doing both inside the index means a save in
    /// between can never persist the removal without the result.
    func complete(
        attempt: UUID, if condition: (UploadJob, BackupEntry) -> Bool, _ change: (UploadJob, inout BackupEntry) -> Void
    ) -> UploadJob? {
        guard let job = stored.jobs.first(where: { $0.attempt == attempt }), removeJob(attempt: attempt) else { return nil }
        update(job.assetID, if: { condition(job, $0) }, { change(job, &$0) })
        return job
    }

    public func selection() -> BackupSelection { stored.selection }

    public func setSelection(_ s: BackupSelection) {
        guard stored.selection != s else { return }
        stored.selection = s
        hasChanges = true
    }

    /// Retries loading after the file couldn't be read. Replaces the in-memory state.
    public func reload() throws { try load() }

    /// Throws `CancellationError` once the index is closed (the account signed out), so nothing recreates
    /// its directory.
    public func save() throws {
        guard !isClosed else { throw CancellationError() }
        guard isAvailable else { throw BackupIndexError.unavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: Self.writingOptions)
        hasChanges = false
        saveCount += 1
    }

    /// A scanner checkpoint; unchanged records need no additional disk write.
    func saveIfChanged() throws {
        guard !isClosed else { throw CancellationError() }
        guard isAvailable else { throw BackupIndexError.unavailable }
        guard hasChanges else { return }
        try save()
    }

    /// Forgets everything and removes the file for good (sign-out): every later save throws
    /// `CancellationError` and writes nothing, so a result or a run that ends after this can't recreate the
    /// account's directory, and nothing more is recorded for the account.
    public func close() {
        isClosed = true
        clear()
    }

    /// Whether `close()` was called.
    public private(set) var isClosed = false

    /// The index is read and written by background wakes while the phone is locked (after its first unlock).
    static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
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
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            #if os(iOS)
            // A file saved before it got this class keeps `.complete` (unreadable while locked) until replaced.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            #endif
            return (stored, true, nil)
        } catch {
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return (Stored(), true, nil)
        }
    }
}
