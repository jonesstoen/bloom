import Foundation

/// How the selected items stand. `total == backedUp + pending + failed`; `waitingForWiFi` is the part
/// of `pending` that needs an iCloud download the cellular switches don't allow right now.
public struct BackupCounts: Sendable, Equatable {
    public var total, backedUp, pending, failed: Int
    public var waitingForWiFi: Int

    public init(total: Int = 0, backedUp: Int = 0, pending: Int = 0, failed: Int = 0, waitingForWiFi: Int = 0) {
        self.total = total
        self.backedUp = backedUp
        self.pending = pending
        self.failed = failed
        self.waitingForWiFi = waitingForWiFi
    }

    mutating func add(_ state: BackupState) { change(state, by: 1) }
    mutating func remove(_ state: BackupState) { change(state, by: -1) }

    private mutating func change(_ state: BackupState, by delta: Int) {
        total += delta
        switch state {
        case .backedUp: backedUp += delta
        case .failed: failed += delta
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
    /// Saves the index every `saveInterval` items, at the end, and when stopped by cancellation or an
    /// error (which is then rethrown). Throws `BackupIndexError.unavailable` before reading anything
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
                // to the checksums it was given for.
                guard var entry = await index.entry(for: item.assetID), entry.checksums == item.dictionary else { continue }
                entry.state = Self.verdict(for: item, results: byID)
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
                        // Already hashed: ask the server again (it may have the file by now), no reads.
                        if entry.state == .pending(reason: .notChecked) || entry.state == .pending(reason: .needsUpload) {
                            try await enqueue(id, resources, entry.checksums)
                        }
                    } else {
                        let (checksums, state) = try await hash(asset, resources: resources)
                        await record(
                            BackupEntry(modificationDate: asset.modificationDate, checksums: checksums, state: state),
                            for: id)
                        if state == .pending(reason: .notChecked) { try await enqueue(id, resources, checksums) }
                    }
                    if batchChecksums >= Self.batchSize { try await flush() }
                    if handled.isMultiple(of: Self.saveInterval) { try await index.save() }
                }
            }
            try await flush()
        } catch {
            // Keep what was learned: hashed items keep their checksums, so the next scan asks
            // the server without reading them again.
            try? await index.save()
            throw error
        }
        try await index.save()
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

    /// Backed up only when the server has every resource; then the photo's (or video's) server ID is kept.
    /// A trashed server copy still counts as on the server. A missing answer leaves the item unchecked.
    private static func verdict(for item: Hashed, results: [String: BulkUploadCheckResult]) -> BackupState {
        let answers = item.checksums.map { results[checkID(item.assetID, $0.type)] }
        guard answers.allSatisfy({ $0 != nil }) else { return .pending(reason: .notChecked) }
        guard answers.allSatisfy({ $0!.isDuplicate }) else { return .pending(reason: .needsUpload) }
        guard let serverID = answers.first??.serverAssetID else { return .pending(reason: .notChecked) }
        return .backedUp(serverAssetID: serverID)
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
                if error is CancellationError || Task.isCancelled { throw error }
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
