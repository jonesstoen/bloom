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
    /// Items between index saves, so an interrupted scan keeps most of its work.
    static let saveInterval = 200

    private let source: any PhotoLibrarySource
    private let service: any ImmichService
    private let index: BackupIndex
    private let network: any NetworkConditions
    private let settings: BackupSettings

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
    }

    /// Scans the current selection. `progress` gets the counts and the number of items handled so far,
    /// after each item. Saves the index every `saveInterval` items, at the end, and when stopped by
    /// cancellation or an error (which is then rethrown). Throws `BackupIndexError.unavailable`
    /// before reading anything when the index file couldn't be loaded.
    @discardableResult
    public func scan(progress: @Sendable (BackupCounts, Int) -> Void) async throws -> BackupCounts {
        // Fails fast on an unavailable index, so no work is done that couldn't be kept.
        try await index.save()
        let assets = await selectedAssets()
        var states: [String: BackupState] = [:]
        var counts = BackupCounts()
        for asset in assets {
            let state = Self.state(of: asset, entry: await index.entry(for: asset.id))
            states[asset.id] = state
            counts.add(state)
        }

        func record(_ entry: BackupEntry, for assetID: String) async {
            await index.set(entry, for: assetID)
            if let old = states[assetID] { counts.remove(old) }
            states[assetID] = entry.state
            counts.add(entry.state)
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
                guard var entry = await index.entry(for: item.assetID) else { continue }
                entry.state = Self.verdict(for: item, results: byID)
                await record(entry, for: item.assetID)
            }
            batch = []
            batchChecksums = 0
        }

        do {
            for (offset, asset) in assets.enumerated() {
                try Task.checkCancellation()
                let resources = BackupResourcePolicy.upload(from: asset.resources)
                let entry = await index.entry(for: asset.id)
                if resources.isEmpty {
                    let reason = tr("This item has no photo or video file that Bloom can back up.")
                    await record(
                        BackupEntry(modificationDate: asset.modificationDate, checksums: [:], state: .failed(reason: reason)),
                        for: asset.id)
                } else if let entry, Self.isCurrent(entry, for: asset, resources: resources) {
                    // Already hashed: only ask the server again if it never answered.
                    if entry.state == .pending(reason: .notChecked) {
                        let sums = resources.map { (type: $0.type, checksum: entry.checksums[$0.type]!) }
                        if batchChecksums + sums.count > Self.batchSize { try await flush() }
                        batch.append(Hashed(assetID: asset.id, checksums: sums))
                        batchChecksums += sums.count
                    }
                } else {
                    let (checksums, state) = try await hash(asset, resources: resources)
                    await record(
                        BackupEntry(modificationDate: asset.modificationDate, checksums: checksums, state: state),
                        for: asset.id)
                    if state == .pending(reason: .notChecked) {
                        let sums = resources.map { (type: $0.type, checksum: checksums[$0.type]!) }
                        if batchChecksums + sums.count > Self.batchSize { try await flush() }
                        batch.append(Hashed(assetID: asset.id, checksums: sums))
                        batchChecksums += sums.count
                    }
                }
                if batchChecksums >= Self.batchSize { try await flush() }
                let checked = offset + 1
                progress(counts, checked)
                if checked.isMultiple(of: Self.saveInterval) { try await index.save() }
            }
            try await flush()
        } catch {
            // Keep what was learned: hashed items stay `notChecked` with their checksums,
            // so the next scan asks the server without reading them again.
            try? await index.save()
            throw error
        }
        try await index.save()
        return counts
    }

    /// The counts for the current selection, from the index alone (reads no resources).
    /// Items changed since they were recorded count as pending.
    public func counts() async -> BackupCounts {
        var counts = BackupCounts()
        for asset in await selectedAssets() {
            counts.add(Self.state(of: asset, entry: await index.entry(for: asset.id)))
        }
        return counts
    }

    // MARK: - Helpers

    /// The selection's assets that still exist, in a stable order. Vanished assets are left out.
    private func selectedAssets() async -> [DeviceAsset] {
        let ids = await index.selection().assetIDs(in: source).sorted()
        var assets: [DeviceAsset] = []
        assets.reserveCapacity(ids.count)
        for id in ids {
            if let asset = await source.asset(id) { assets.append(asset) }
        }
        return assets
    }

    private static func state(of asset: DeviceAsset, entry: BackupEntry?) -> BackupState {
        if BackupResourcePolicy.upload(from: asset.resources).isEmpty {
            return .failed(reason: tr("This item has no photo or video file that Bloom can back up."))
        }
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
