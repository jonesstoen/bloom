import Foundation

/// How the selected items stand. `total == backedUp + pending + deletedOnServer + failed`;
/// `waitingForWiFi` is the part of `pending` that needs an iCloud download the cellular switches don't allow right now.
public struct BackupCounts: Sendable, Equatable {
    public var total, backedUp, pending, failed: Int
    public var deletedOnServer: Int
    public var waitingForWiFi: Int

    public init(total: Int = 0, backedUp: Int = 0, pending: Int = 0, failed: Int = 0, deletedOnServer: Int = 0, waitingForWiFi: Int = 0) {
        self.total = total
        self.backedUp = backedUp
        self.pending = pending
        self.failed = failed
        self.deletedOnServer = deletedOnServer
        self.waitingForWiFi = waitingForWiFi
    }

    mutating func add(_ state: BackupState) { change(state, by: 1) }
    mutating func remove(_ state: BackupState) { change(state, by: -1) }

    private mutating func change(_ state: BackupState, by delta: Int) {
        total += delta
        switch state {
        case .backedUp: backedUp += delta
        case .failed: failed += delta
        case .deletedOnServer: deletedOnServer += delta
        case let .pending(reason):
            pending += delta
            if reason == .waitingForWiFi { waitingForWiFi += delta }
        }
    }
}

/// Finds out which selected photos are already on the server: hashes the resources Bloom would
/// upload (SHA1, base64), asks the server in batches, and records the result in the index.
/// Unchanged items with known checksums are not read again. Never changes the photo library.
public actor BackupScanner {
    /// Checksums per `checkBulkUpload` request.
    static let batchSize = 500
    /// Assets per PhotoKit fetch.
    static let fetchSize = 500
    /// Items between index saves, so an interrupted scan keeps most of its work.
    static let saveInterval = 200

    private let source: any PhotoLibrarySource
    private let service: any ImmichService
    private let index: BackupIndex
    private let network: any NetworkConditions
    private let settings: BackupSettings
    /// The scan in progress; later `scan` calls join it instead of starting a second one.
    private var running: (id: UUID, task: Task<BackupCounts, Error>)?

    public init(
        source: some PhotoLibrarySource,
        service: any ImmichService,
        index: BackupIndex,
        network: any NetworkConditions,
        settings: BackupSettings
    ) {
        self.source = source
        self.service = service
        self.index = index
        self.network = network
        self.settings = settings
    }

    /// An item hashed (now or in an earlier scan) and waiting for the server's answer.
    private struct Hashed {
        let assetID: String
        /// In `BackupResourcePolicy` order: the photo or video first.
        let checksums: [(type: DeviceResourceType, checksum: String)]
        var dictionary: [DeviceResourceType: String] {
            Dictionary(checksums.map { ($0.type, $0.checksum) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Scans the current selection. `progress` gets the counts and the number of items handled so far,
    /// after each item; the total shrinks when selected items turn out to be gone from the library.
    /// Saves changed records every `saveInterval` items, at the end, and when stopped by cancellation or an
    /// error (which is then rethrown). Before the first resource is read it sends one probe request to
    /// the server (a single checksum, result ignored) so that a key without the right permission fails
    /// before any work is done; scans that read nothing send no probe. Throws `BackupIndexError.unavailable` before reading anything
    /// when the index file couldn't be loaded.
    ///
    /// Only one scan runs at a time: a call made while one is running waits for it and returns its
    /// result (its own `progress` is not called). Cancelling the caller that started the scan stops it.
    @discardableResult
    public func scan(progress: @escaping @Sendable (BackupCounts, Int) -> Void) async throws -> BackupCounts {
        if let running { return try await running.task.value }
        let id = UUID()
        let task = Task { try await self.performScan(progress: progress) }
        running = (id, task)
        defer { if running?.id == id { running = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performScan(progress: @Sendable (BackupCounts, Int) -> Void) async throws -> BackupCounts {
        // Fails fast on an unavailable index, so no work is done that couldn't be kept.
        try await index.save()
        let ids = await index.selection().assetIDs(in: source).sorted()

        // A first estimate from the index; corrected per item once its asset is fetched.
        var states: [String: BackupState] = [:]
        var counts = BackupCounts()
        for id in ids {
            let state = await index.entry(for: id)?.state ?? .pending(reason: .notChecked)
            states[id] = state
            counts.add(state)
        }
        func show(_ state: BackupState?, for assetID: String) {
            if let old = states[assetID] { counts.remove(old) }
            states[assetID] = state
            if let state { counts.add(state) }
        }
        func record(_ entry: BackupEntry, for assetID: String) async {
            await index.set(entry, for: assetID)
            show(entry.state, for: assetID)
        }

        var batch: [Hashed] = []
        var batchChecksums = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let items = batch.flatMap { item in
                item.checksums.map { BulkUploadCheckItem(id: Self.checkID(item.assetID, $0.type), checksum: $0.checksum) }
            }
            let results = try await service.checkBulkUpload(items)
            let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for item in batch {
                // The entry may have changed while the server answered: only apply the verdict
                // to the checksums it was given for. It holds what was known before this check.
                guard var entry = await index.entry(for: item.assetID), entry.checksums == item.dictionary else { continue }
                if let (state, serverIDs) = Self.verdict(for: item, results: byID, previous: entry) {
                    entry.state = state
                    entry.serverIDs = serverIDs
                } else if !Self.wasSeenOnServer(entry.state) {
                    entry.state = .pending(reason: .notChecked)
                }
                await record(entry, for: item.assetID)
            }
            batch = []
            batchChecksums = 0
        }
        func enqueue(_ assetID: String, _ resources: [DeviceResource], _ checksums: [DeviceResourceType: String]) async throws {
            let sums = resources.map { (type: $0.type, checksum: checksums[$0.type]!) }
            // A Live Photo's checksums always travel in the same request.
            if batchChecksums + sums.count > Self.batchSize { try await flush() }
            batch.append(Hashed(assetID: assetID, checksums: sums))
            batchChecksums += sums.count
        }

        // Asked once, before the first resource is read: a key that may not check backups fails here
        // instead of after hours of hashing (and iCloud downloads).
        var probed = false
        func probeServer() async throws {
            guard !probed else { return }
            let empty = SHA1Stream().base64()
            _ = try await service.checkBulkUpload([BulkUploadCheckItem(id: "probe", checksum: empty)])
            probed = true
        }

        var handled = 0
        do {
            for start in stride(from: 0, to: ids.count, by: Self.fetchSize) {
                try Task.checkCancellation()
                let chunk = Array(ids[start..<min(start + Self.fetchSize, ids.count)])
                let fetched = await source.assets(chunk)
                let assets = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for id in chunk {
                    try Task.checkCancellation()
                    handled += 1
                    defer { progress(counts, handled) }
                    guard let asset = assets[id] else {
                        show(nil, for: id) // gone from the library: not counted, not failed
                        continue
                    }
                    let entry = await index.entry(for: id)
                    show(Self.state(of: asset, entry: entry), for: id)
                    let resources = BackupResourcePolicy.upload(from: asset.resources)
                    if resources.isEmpty {
                        let reason = Self.noResourcesReason
                        await record(
                            BackupEntry(modificationDate: asset.modificationDate, checksums: [:], state: .failed(reason: reason)),
                            for: id)
                    } else if let entry, Self.isCurrent(entry, for: asset, resources: resources) {
                        // Already hashed: ask the server again, no reads. It may have the file by now,
                        // or have deleted or restored what it had.
                        if Self.isRechecked(entry.state) { try await enqueue(id, resources, entry.checksums) }
                    } else {
                        try await probeServer()
                        let (checksums, state) = try await hash(asset, resources: resources)
                        await record(
                            BackupEntry(modificationDate: asset.modificationDate, checksums: checksums, state: state),
                            for: id)
                        if state == .pending(reason: .notChecked) { try await enqueue(id, resources, checksums) }
                    }
                    if batchChecksums >= Self.batchSize { try await flush() }
                    if handled.isMultiple(of: Self.saveInterval) { try await index.saveIfChanged() }
                }
            }
            try await flush()
        } catch {
            // Keep what was learned: hashed items keep their checksums, so the next scan asks
            // the server without reading them again.
            try? await index.saveIfChanged()
            throw error
        }
        try await index.saveIfChanged()
        return counts
    }

    /// The counts for the current selection, from the index and the assets' modification dates
    /// (fetched in batches, no resources read). Items changed since they were recorded count as pending.
    public func counts() async -> BackupCounts {
        let ids = await index.selection().assetIDs(in: source).sorted()
        var counts = BackupCounts()
        for start in stride(from: 0, to: ids.count, by: Self.fetchSize) {
            let chunk = Array(ids[start..<min(start + Self.fetchSize, ids.count)])
            let dates = await source.modificationDates(chunk)
            for id in chunk {
                guard let date = dates[id] else { continue }
                let entry = await index.entry(for: id)
                counts.add(entry?.modificationDate == date ? entry!.state : .pending(reason: .notChecked))
            }
        }
        return counts
    }

    // MARK: - Helpers

    private static var noResourcesReason: String {
        tr("This item has no photo or video file that Bloom can back up.")
    }

    private static func state(of asset: DeviceAsset, entry: BackupEntry?) -> BackupState {
        if BackupResourcePolicy.upload(from: asset.resources).isEmpty { return .failed(reason: noResourcesReason) }
        guard let entry, entry.modificationDate == asset.modificationDate else { return .pending(reason: .notChecked) }
        return entry.state
    }

    /// The entry describes the asset as it is now, with a checksum for every resource to upload.
    private static func isCurrent(_ entry: BackupEntry, for asset: DeviceAsset, resources: [DeviceResource]) -> Bool {
        entry.modificationDate == asset.modificationDate && resources.allSatisfy { entry.checksums[$0.type] != nil }
    }

    private static func checkID(_ assetID: String, _ type: DeviceResourceType) -> String { "\(assetID)|\(type.rawValue)" }

    /// Hashed items whose checksums are sent to the server again on every scan.
    private static func isRechecked(_ state: BackupState) -> Bool {
        switch state {
        case .pending(reason: .notChecked), .pending(reason: .needsUpload), .backedUp, .deletedOnServer: true
        case .pending(reason: .waitingForWiFi), .failed: false
        }
    }

    /// Bloom has seen the item on the server, so missing copies there mean it was deleted there.
    private static func wasSeenOnServer(_ state: BackupState) -> Bool {
        switch state {
        case .backedUp, .deletedOnServer: true
        case .pending, .failed: false
        }
    }

    /// The new state and per-resource server IDs from the server's answers, given what the entry knew
    /// before the check (option C). A resource was *seen* on the server when the whole item was
    /// (`backedUp` / `deletedOnServer`) or when the entry has a server ID for it (a Live Photo half
    /// found earlier while the other half was missing).
    /// - a copy in the server's trash, or a seen resource gone (`accept`): deleted on the server, with
    ///   the trashed resources and the gone (`accept`) ones listed; this wins over any refusal;
    /// - a resource refused for another reason (unsupported format): no verdict for an item seen on
    ///   the server as a whole, needs upload otherwise (the upload reports the refusal);
    /// - every resource a duplicate, none trashed: backed up, with the photo's (or video's) server ID;
    /// - otherwise (nothing seen is missing, nothing trashed): needs upload.
    /// A Live Photo is on the server only while both resources are. `serverIDs` holds the IDs of the
    /// copies the server has now (trashed ones included); a gone copy's old ID is dropped, as nothing
    /// can be done with it.
    ///
    /// Returns `nil` (no verdict) when an answer or a duplicate's ID is missing, or for the refusal case
    /// above: a refusal says nothing about deletion.
    private static func verdict(
        for item: Hashed, results: [String: BulkUploadCheckResult], previous: BackupEntry
    ) -> (BackupState, [DeviceResourceType: String])? {
        guard let main = item.checksums.first?.type else { return nil }
        let seenItem = wasSeenOnServer(previous.state)
        var trashed: Set<DeviceResourceType> = []
        var gone: Set<DeviceResourceType> = []
        var rejected = false
        var serverIDs: [DeviceResourceType: String] = [:]
        for (type, _) in item.checksums {
            guard let answer = results[checkID(item.assetID, type)] else { return nil }
            if answer.isDuplicate {
                guard let id = answer.serverAssetID else { return nil }
                serverIDs[type] = id
                if answer.isTrashed { trashed.insert(type) }
            } else if answer.isRejected {
                rejected = true
            } else {
                gone.insert(type)
            }
        }
        // Deletion wins over a refusal: a trashed or seen-and-gone half is never uploaded automatically.
        let seenGone = seenItem ? !gone.isEmpty : gone.contains { previous.serverIDs[$0] != nil }
        if !trashed.isEmpty || seenGone {
            return (.deletedOnServer(trashed: trashed, gone: gone), serverIDs)
        }
        if rejected {
            return seenItem ? nil : (.pending(reason: .needsUpload), serverIDs)
        }
        if gone.isEmpty, let id = serverIDs[main] {
            return (.backedUp(serverAssetID: id), serverIDs)
        }
        return (.pending(reason: .needsUpload), serverIDs)
    }

    /// Reads and hashes `resources`. Returns `.pending(.notChecked)` with all checksums on success,
    /// `.pending(.waitingForWiFi)` when a resource is only in iCloud and the network isn't allowed,
    /// `.failed` for other read errors. Cancellation is rethrown.
    private func hash(
        _ asset: DeviceAsset, resources: [DeviceResource]
    ) async throws -> ([DeviceResourceType: String], BackupState) {
        let allowNetwork = settings.allowsNetwork(for: asset, onCellular: await network.isOnCellular)
        var checksums: [DeviceResourceType: String] = [:]
        for resource in resources {
            let sink = HashSink()
            do {
                try await source.read(resource, of: asset.id, allowNetwork: allowNetwork) { sink.update($0) }
            } catch PhotoLibraryReadError.needsNetwork {
                return (checksums, .pending(reason: .waitingForWiFi))
            } catch {
                // Callback-based readers can return their own error when a request is cancelled.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let reason = tr("Couldn't read %@: %@", resource.filename, error.localizedDescription)
                return (checksums, .failed(reason: reason))
            }
            checksums[resource.type] = sink.base64()
        }
        return (checksums, .pending(reason: .notChecked))
    }
}

/// Collects a resource's bytes from PhotoKit's data callback into a SHA1.
private final class HashSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sha = SHA1Stream()

    func update(_ data: Data) { lock.withLock { sha.update(data) } }
    func base64() -> String { lock.withLock { sha.base64() } }
}
