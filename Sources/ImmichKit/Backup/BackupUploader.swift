import Foundation
import UniformTypeIdentifiers

/// How far an upload run has come: `done` of `total` items handled, and the file being uploaded now.
public struct UploadProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var currentFilename: String?

    public init(done: Int, total: Int, currentFilename: String?) {
        self.done = done
        self.total = total
        self.currentFilename = currentFilename
    }
}

/// The time source for the uploader's back-off, injectable so tests don't wait.
public struct BackupRetryClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static var live: BackupRetryClock {
        BackupRetryClock(now: { .now }, sleep: { try await Task.sleep(for: $0) })
    }
}

/// Uploads the selected items the server doesn't have, one at a time, newest first.
///
/// Each item is re-read from the photo library and staged resource by resource; an item that changed
/// since the scanner hashed it goes back to the scanner instead of being uploaded under a stale
/// checksum. A Live Photo's motion video goes first, then the photo with `livePhotoVideoId`.
/// Network trouble, 408, 429 and 5xx keep the item pending and retry it after 5 s, 30 s, 2 min and
/// 10 min (in memory), after which it is left for the rest of the session. Never changes the photo
/// library; restores from the server's trash only on `reupload`.
public actor BackupUploader {
    /// Waits after the first, second, third and fourth failure; the fifth ends the session's tries.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)]
    /// Assets per PhotoKit fetch when ordering the queue.
    static let fetchSize = 500
    /// A wait for a retry is split up so a pause request is noticed.
    static let waitSlice: Duration = .seconds(2)

    private let source: any PhotoLibrarySource
    private let service: any ImmichService
    private let index: BackupIndex
    private let staging: BackupStaging
    private let settings: @Sendable () -> BackupSettings
    private let network: any NetworkConditions
    private let clock: BackupRetryClock

    private struct Retry {
        var failures: Int
        var notBefore: ContinuousClock.Instant
    }
    /// Items waiting to be tried again (this session only).
    private var retries: [String: Retry] = [:]
    /// Items that failed too often to be tried again this session.
    private var skipped: Set<String> = []
    /// Network loss and rate limiting hold back every item, not just the one that failed, so an
    /// outage doesn't read (and download from iCloud) the whole queue for nothing.
    private var holdUntil: ContinuousClock.Instant?
    private var isRunning = false

    /// `settings` is read for each item: the cellular switches can change during a run.
    public init(
        source: any PhotoLibrarySource,
        service: any ImmichService,
        index: BackupIndex,
        staging: BackupStaging,
        settings: @escaping @Sendable () -> BackupSettings,
        network: any NetworkConditions,
        clock: BackupRetryClock = .live
    ) {
        self.source = source
        self.service = service
        self.index = index
        self.staging = staging
        self.settings = settings
        self.network = network
        self.clock = clock
    }

    private struct Candidate {
        let id: String
        let creationDate: Date
        let filename: String
    }

    private enum Outcome { case done, willRetry }

    // MARK: - Run

    /// Uploads the current selection's items that need it (`pending(.needsUpload)`, and items the
    /// uploader itself left waiting for Wi-Fi), newest `creationDate` first. `progress` is called
    /// before and after each item. `shouldPause` is asked before each item and while waiting for a
    /// retry; when it answers `true` the run returns (the current item is finished first).
    ///
    /// Throws `ImmichServiceError.unauthorized` (and other errors no item can get past) and
    /// `BackupStagingError.notEnoughSpace` after recording the item; cancellation removes the current
    /// staged file and rethrows. The index is saved after each item. A second call while a run is going
    /// returns at once.
    public func run(
        progress: @escaping @Sendable (UploadProgress) -> Void,
        shouldPause: @escaping @Sendable () async -> Bool
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        // Fails fast on an unavailable index, before anything is uploaded that couldn't be recorded.
        try await index.saveIfChanged()

        var queue = await queuedItems()
        let total = queue.count
        var done = 0
        defer { if total == 0 { progress(UploadProgress(done: 0, total: 0, currentFilename: nil)) } }
        while !queue.isEmpty {
            try Task.checkCancellation()
            if await shouldPause() { return }
            let now = clock.now()
            guard let position = queue.firstIndex(where: { readyTime(for: $0.id, now: now) <= now }) else {
                let next = queue.map { readyTime(for: $0.id, now: now) }.min() ?? now
                if try await wait(until: next, shouldPause: shouldPause) { return }
                continue
            }
            let item = queue[position]
            progress(UploadProgress(done: done, total: total, currentFilename: item.filename))
            if try await upload(item.id) == .done {
                queue.remove(at: position)
                done += 1
            }
            progress(UploadProgress(done: done, total: total, currentFilename: nil))
        }
    }

    /// The queue for this run, newest first. Left out: items given up on for the session, items the
    /// scanner still has to finish (waiting for Wi-Fi without all checksums), and items waiting for
    /// Wi-Fi while the network still doesn't allow them (so they aren't counted as being uploaded).
    private func queuedItems() async -> [Candidate] {
        let ids = await index.selection().assetIDs(in: source)
        let queued = await index.entries(where: { Self.isQueued($0.state) }, in: ids, limit: Int.max)
        let entries = Dictionary(queued.filter { !skipped.contains($0.0) }, uniquingKeysWith: { first, _ in first })
        let sorted = entries.keys.sorted()
        var onCellular: Bool?
        var candidates: [Candidate] = []
        for start in stride(from: 0, to: sorted.count, by: Self.fetchSize) {
            let chunk = Array(sorted[start..<min(start + Self.fetchSize, sorted.count)])
            for asset in await source.assets(chunk) {
                guard let entry = entries[asset.id] else { continue }
                let resources = BackupResourcePolicy.upload(from: asset.resources)
                guard let main = resources.first else { continue }
                if entry.state == .pending(reason: .waitingForWiFi) {
                    guard Self.hasChecksums(entry, for: resources) else { continue }
                    if onCellular == nil { onCellular = await network.isOnCellular }
                    guard settings().allowsNetwork(for: asset, onCellular: onCellular ?? true) else { continue }
                }
                candidates.append(Candidate(
                    id: asset.id, creationDate: asset.creationDate, filename: Self.uploadFilename(for: main, in: asset)))
            }
        }
        return candidates.sorted { ($0.creationDate, $0.id) > ($1.creationDate, $1.id) }
    }

    /// When the item may be tried: now, or after its back-off and any hold on the whole run.
    private func readyTime(for id: String, now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(retries[id]?.notBefore ?? now, holdUntil ?? now)
    }

    /// Sleeps until `deadline` in slices, asking `shouldPause` after each. Returns `true` when paused.
    private func wait(until deadline: ContinuousClock.Instant, shouldPause: @Sendable () async -> Bool) async throws -> Bool {
        while clock.now() < deadline {
            try await clock.sleep(min(clock.now().duration(to: deadline), Self.waitSlice))
            if await shouldPause() { return true }
        }
        return false
    }

    /// One attempt at one item. `.willRetry` keeps it in this run's queue for a later attempt.
    private func upload(_ id: String) async throws -> Outcome {
        guard let entry = await index.entry(for: id), Self.isQueued(entry.state),
              let asset = await source.asset(id) else { return .done }
        let resources = BackupResourcePolicy.upload(from: asset.resources)
        guard let main = resources.first else { return .done } // the scanner lists it as a problem
        let complete = Self.hasChecksums(entry, for: resources)
        if entry.state == .pending(reason: .waitingForWiFi), !complete { return .done }
        guard asset.modificationDate == entry.modificationDate, complete else {
            await sendBack(id, from: entry)
            try await index.saveIfChanged()
            return .done
        }
        let settings = settings()
        guard settings.allowsNetwork(for: asset, onCellular: await network.isOnCellular) else {
            await write(id, from: entry) { $0.state = .pending(reason: .waitingForWiFi) }
            try await index.saveIfChanged()
            return .done
        }

        try await markForLinking(id, entry, resources)
        // A half with a server ID from the latest check is on the server (a duplicate, not trashed):
        // it is never sent again, its ID is used instead.
        let missing = Set(resources.map(\.type).filter { entry.serverIDs[$0] == nil })
        let attempt = await send(
            asset, resources: resources, missing: missing, known: entry.serverIDs,
            checksums: entry.checksums, allowsCellular: settings.allowsNetwork(for: asset, onCellular: true))
        let learned = attempt.learned
        func record(_ state: BackupState) async {
            await write(id, from: entry) {
                $0.serverIDs.merge(learned) { _, new in new }
                $0.state = state
            }
        }

        var outcome = Outcome.done
        do {
            switch attempt.failure {
            case nil:
                retries[id] = nil
                await write(id, from: entry) {
                    $0.serverIDs.merge(learned) { _, new in new }
                    $0.needsLink = false
                    if let serverID = $0.serverIDs[main.type] { $0.state = .backedUp(serverAssetID: serverID) }
                }
            case .changed:
                await sendBack(id, from: entry)
            case let .stage(error, resource):
                switch Self.classify(error) {
                case .cancelled, .stop, .outOfSpace:
                    try await stop(with: error, record: record)
                default:
                    await record(try BackupReadFailure.state(for: error, reading: resource))
                }
            case let .upload(error):
                switch Self.classify(error) {
                case .cancelled, .stop, .outOfSpace:
                    try await stop(with: error, record: record)
                case let .retry(holdsRun):
                    await record(.pending(reason: .needsUpload))
                    if scheduleRetry(id, holdsRun: holdsRun) { outcome = .willRetry }
                case let .failed(reason):
                    await record(.failed(reason: reason))
                }
            case let .link(error):
                // Both halves are on the server and their IDs recorded, `needsLink` stays set: the next
                // attempt (or Try Again) only links.
                switch Self.classify(error) {
                case .cancelled, .stop, .outOfSpace:
                    try await stop(with: error, record: record)
                case let .retry(holdsRun):
                    await record(.pending(reason: .needsUpload))
                    if scheduleRetry(id, holdsRun: holdsRun) { outcome = .willRetry }
                case .failed:
                    await record(.failed(reason: Self.linkFailedReason(error)))
                }
            }
        } catch {
            try? await index.saveIfChanged()
            throw error
        }
        try await index.saveIfChanged()
        return outcome
    }

    /// Records what the stopped attempt learned and rethrows: cancellation as `CancellationError`, a full
    /// disk as `notEnoughSpace` after failing the item.
    private func stop(with error: Error, record: (BackupState) async -> Void) async throws {
        switch Self.classify(error) {
        case .cancelled:
            await record(.pending(reason: .needsUpload))
            throw CancellationError()
        case .outOfSpace:
            await record(.failed(reason: Self.notEnoughSpaceReason))
            throw BackupStagingError.notEnoughSpace
        default:
            await record(.pending(reason: .needsUpload))
            throw error
        }
    }

    /// Counts a failure. Returns `false` when the item has had its tries for this session.
    private func scheduleRetry(_ id: String, holdsRun: Bool) -> Bool {
        var retry = retries[id] ?? Retry(failures: 0, notBefore: clock.now())
        retry.failures += 1
        guard retry.failures <= Self.retryDelays.count else {
            retries[id] = nil
            skipped.insert(id)
            return false
        }
        retry.notBefore = clock.now() + Self.retryDelays[retry.failures - 1]
        retries[id] = retry
        if holdsRun { holdUntil = retry.notBefore }
        return true
    }

    // MARK: - Try Again and Re-upload

    /// Sends failed items back to the scanner (`pending(.notChecked)`), keeping their checksums: the next
    /// scan asks the server about them again without reading them and queues them. Other states are left alone.
    public func retryFailed(_ ids: [String]) async {
        for id in ids {
            guard let entry = await index.entry(for: id), case .failed = entry.state else { continue }
            await write(id, from: entry) { $0.state = .pending(reason: .notChecked) }
            retries[id] = nil
            skipped.remove(id)
        }
        try? await index.saveIfChanged()
    }

    /// The user's Re-upload for items deleted on the server: copies in the server's trash are restored,
    /// a Live Photo half that is gone is uploaded now (and linked to the other half), and an item gone
    /// entirely goes back to `pending(.needsUpload)` for the next run. A half the server still has is never
    /// uploaded. Other states are left alone. Rethrows what `restoreAssets` throws (`editingOff` while
    /// Allow Changes is off), `unauthorized` and cancellation; the index is saved after each item.
    public func reupload(_ ids: [String]) async throws {
        for id in ids {
            do {
                try Task.checkCancellation()
                try await reuploadItem(id)
            } catch {
                try? await index.saveIfChanged()
                throw error
            }
            try await index.saveIfChanged()
        }
    }

    private func reuploadItem(_ id: String) async throws {
        guard let entry = await index.entry(for: id), case let .deletedOnServer(trashed, wasGone) = entry.state else { return }
        var gone = wasGone
        // A trashed copy without a known ID can't be restored; it is uploaded like a gone one.
        let restorable = trashed.compactMap { type in entry.serverIDs[type].map { (type: type, id: $0) } }
        gone.formUnion(trashed.filter { entry.serverIDs[$0] == nil })
        var stillTrashed: Set<DeviceResourceType> = []
        if !restorable.isEmpty {
            let result = try await service.restoreAssets(assetIDs: restorable.map(\.id))
            let confirmed = Set(result.confirmedIDs)
            stillTrashed = Set(restorable.filter { !confirmed.contains($0.id) }.map(\.type))
        }
        var serverIDs = entry.serverIDs.filter { !gone.contains($0.key) }
        let types = Set(entry.checksums.keys)
        let present = types.subtracting(gone).subtracting(stillTrashed)

        if !stillTrashed.isEmpty {
            // Not restored this time: nothing is uploaded next to a copy that is still in the trash.
            let ids = serverIDs
            await write(id, from: entry) {
                $0.serverIDs = ids
                $0.state = .deletedOnServer(trashed: stillTrashed, gone: gone)
            }
            return
        }
        if gone.isEmpty {
            let ids = serverIDs
            await write(id, from: entry) {
                $0.serverIDs = ids
                // Restored, but still to be joined: the run links it.
                $0.state = $0.needsLink ? .pending(reason: .needsUpload)
                    : Self.mainType(of: types).flatMap { ids[$0] }.map { .backedUp(serverAssetID: $0) }
                        ?? .pending(reason: .needsUpload)
            }
            return
        }
        let needsUpload: (inout BackupEntry) -> Void = { [serverIDs] in
            $0.serverIDs = serverIDs
            $0.state = .pending(reason: .needsUpload)
        }
        guard !present.isEmpty, present.allSatisfy({ serverIDs[$0] != nil }) else {
            // Gone entirely: uploaded by the next run like any other item.
            retries[id] = nil
            skipped.remove(id)
            await write(id, from: entry, needsUpload)
            return
        }

        // Part of a Live Photo is gone: upload just that part.
        guard let asset = await source.asset(id) else {
            // Gone from the phone as well: only the restore could be done.
            let ids = serverIDs
            await write(id, from: entry) {
                $0.serverIDs = ids
                $0.state = .deletedOnServer(trashed: [], gone: gone)
            }
            return
        }
        let resources = BackupResourcePolicy.upload(from: asset.resources)
        guard asset.modificationDate == entry.modificationDate, Set(resources.map(\.type)) == types,
              Self.hasChecksums(entry, for: resources) else {
            await sendBack(id, from: entry)
            return
        }
        let settings = settings()
        guard settings.allowsNetwork(for: asset, onCellular: await network.isOnCellular) else {
            await write(id, from: entry, needsUpload) // the run waits for Wi-Fi
            return
        }
        try await markForLinking(id, entry, resources)
        let attempt = await send(
            asset, resources: resources, missing: gone, known: serverIDs, checksums: entry.checksums,
            allowsCellular: settings.allowsNetwork(for: asset, onCellular: true))
        serverIDs.merge(attempt.learned) { _, new in new }
        let learnedIDs = serverIDs
        let record: (BackupState) async -> Void = { state in
            await self.write(id, from: entry) {
                $0.serverIDs = learnedIDs
                $0.state = state
            }
        }
        switch attempt.failure {
        case nil:
            let main = resources[0].type
            await write(id, from: entry) {
                $0.serverIDs = learnedIDs
                $0.needsLink = false
                $0.state = learnedIDs[main].map { .backedUp(serverAssetID: $0) } ?? .pending(reason: .needsUpload)
            }
        case .changed:
            await sendBack(id, from: entry)
        case let .stage(error, _), let .upload(error), let .link(error):
            switch Self.classify(error) {
            case .cancelled, .stop, .outOfSpace:
                try await stop(with: error, record: record)
            default:
                // The run tries again and reports what goes wrong there.
                await record(.pending(reason: .needsUpload))
            }
        }
    }

    // MARK: - Sending

    private enum Failure {
        /// A staged resource's checksum differs from the recorded one.
        case changed
        case stage(Error, DeviceResource)
        case upload(Error)
        case link(Error)
    }

    private struct Attempt {
        /// Server IDs of the resources uploaded in this attempt.
        var learned: [DeviceResourceType: String] = [:]
        var failure: Failure?
    }

    private enum StepError: Error {
        case stage(Error, DeviceResource)
        case upload(Error)
    }

    /// Uploads the `missing` resources of `asset`, motion video first, and links a Live Photo whose
    /// photo didn't take the motion's ID on upload (a photo the server already had, or one not sent).
    /// `known` holds the server IDs of the halves the server has. Stops at the first problem.
    private func send(
        _ asset: DeviceAsset, resources: [DeviceResource], missing: Set<DeviceResourceType>,
        known: [DeviceResourceType: String], checksums: [DeviceResourceType: String], allowsCellular: Bool
    ) async -> Attempt {
        var attempt = Attempt()
        let motion = resources.first { Self.isMotion($0.type) }
        let photo = motion == nil ? nil : resources.first { !Self.isMotion($0.type) }
        var motionID = motion.flatMap { known[$0.type] }
        var photoResult: AssetUploadResult?
        let ordered = resources.filter { Self.isMotion($0.type) } + resources.filter { !Self.isMotion($0.type) }
        for resource in ordered where missing.contains(resource.type) {
            guard let expected = checksums[resource.type] else {
                attempt.failure = .changed
                return attempt
            }
            let isPhotoHalf = resource == photo
            do {
                guard let result = try await sendResource(
                    resource, of: asset, checksum: expected, livePhotoVideoID: isPhotoHalf ? motionID : nil,
                    allowsCellular: allowsCellular)
                else {
                    attempt.failure = .changed
                    return attempt
                }
                attempt.learned[resource.type] = result.id
                if resource == motion { motionID = result.id }
                if isPhotoHalf { photoResult = result }
            } catch StepError.stage(let error, let resource) {
                attempt.failure = .stage(error, resource)
                return attempt
            } catch StepError.upload(let error) {
                attempt.failure = .upload(error)
                return attempt
            } catch {
                attempt.failure = .upload(error)
                return attempt
            }
        }
        guard motion != nil, let photo, let motionID, let photoID = photoResult?.id ?? known[photo.type] else { return attempt }
        // Only a photo created in this attempt took `livePhotoVideoId`; a duplicate or an unsent photo is
        // linked (again, after a failed link: the same link twice is harmless).
        if photoResult?.status != .created {
            do {
                try await service.linkLivePhoto(photoID: photoID, motionID: motionID)
            } catch {
                attempt.failure = .link(error)
            }
        }
        return attempt
    }

    /// Stages one resource, checks its checksum and uploads it. `nil` when the bytes differ from
    /// `checksum` (nothing is uploaded then). The staged file is removed before returning or throwing.
    private func sendResource(
        _ resource: DeviceResource, of asset: DeviceAsset, checksum expected: String, livePhotoVideoID: String?,
        allowsCellular: Bool
    ) async throws -> AssetUploadResult? {
        let staged: (url: URL, checksum: String)
        do {
            staged = try await staging.stage(resource, of: asset, from: source, allowNetwork: true)
        } catch {
            throw StepError.stage(error, resource)
        }
        defer { staging.remove(staged.url) }
        guard staged.checksum == expected else { return nil }
        let isVideoFile = asset.isVideo && (resource.type == .video || resource.type == .fullSizeVideo)
        let request = AssetUploadRequest(
            fileURL: staged.url, filename: Self.uploadFilename(for: resource, in: asset),
            mimeType: Self.mimeType(for: resource), checksum: staged.checksum, createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate, isFavorite: asset.isFavorite,
            duration: isVideoFile ? asset.duration : nil, livePhotoVideoID: livePhotoVideoID,
            allowsCellular: allowsCellular)
        do {
            try Task.checkCancellation()
            return try await service.uploadAsset(request)
        } catch {
            throw StepError.upload(error)
        }
    }

    // MARK: - Index

    /// Applies `change` to the item's current entry if it still describes the version `snapshot` did
    /// (same modification date and checksums): the scanner may have recorded a newer one meanwhile.
    /// The check and the change happen in one step inside the index, on the entry as it is then.
    private func write(_ id: String, from snapshot: BackupEntry, _ change: (inout BackupEntry) -> Void) async {
        await index.update(id, ifModificationDate: snapshot.modificationDate, checksums: snapshot.checksums, change)
    }

    /// Before anything of a Live Photo is sent, records (and saves) that its halves may need joining, so
    /// a link that fails or never happens (the app stopped in between) is still made later.
    private func markForLinking(_ id: String, _ entry: BackupEntry, _ resources: [DeviceResource]) async throws {
        guard !entry.needsLink, resources.contains(where: { Self.isMotion($0.type) }),
              resources.contains(where: { !Self.isMotion($0.type) }) else { return }
        await write(id, from: entry) { $0.needsLink = true }
        try await index.saveIfChanged()
    }

    /// The item changed since it was hashed: the scanner hashes and checks it again.
    private func sendBack(_ id: String, from snapshot: BackupEntry) async {
        await write(id, from: snapshot) {
            $0.state = .pending(reason: .notChecked)
            $0.checksums = [:]
        }
    }

    // MARK: - Helpers

    static var notEnoughSpaceReason: String { tr("Not enough free space on the iPhone.") }

    static func linkFailedReason(_ error: Error) -> String {
        tr("Couldn't join the photo and video of this Live Photo on the server: %@", error.localizedDescription)
    }

    private static func isQueued(_ state: BackupState) -> Bool {
        state == .pending(reason: .needsUpload) || state == .pending(reason: .waitingForWiFi)
    }

    private static func hasChecksums(_ entry: BackupEntry, for resources: [DeviceResource]) -> Bool {
        resources.allSatisfy { entry.checksums[$0.type] != nil }
    }

    private static func isMotion(_ type: DeviceResourceType) -> Bool {
        type == .pairedVideo || type == .fullSizePairedVideo
    }

    /// The resource whose server ID stands for the item: the photo, or the video.
    private static func mainType(of types: Set<DeviceResourceType>) -> DeviceResourceType? {
        let order: [DeviceResourceType] = [.fullSizePhoto, .photo, .fullSizeVideo, .video, .fullSizePairedVideo, .pairedVideo]
        return order.first { types.contains($0) }
    }

    private enum ErrorKind {
        case cancelled
        /// No item can get past it: stop the run.
        case stop
        case outOfSpace
        case retry(holdsRun: Bool)
        case failed(String)
    }

    private static func classify(_ error: Error) -> ErrorKind {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if BackupStaging.isOutOfSpace(error) { return .outOfSpace }
        switch error {
        case let BackupUploadError.rejected(status, message):
            return .failed(message.isEmpty ? ImmichServiceError.unexpectedStatus(status).localizedDescription : message)
        case let error as ImmichServiceError:
            switch error {
            case .unauthorized, .insecureConnection, .invalidServerURL:
                return .stop
            case .network, .unexpectedStatus(429):
                return .retry(holdsRun: true)
            case .unexpectedStatus(408), .unexpectedStatus(500...599), .invalidResponse:
                return .retry(holdsRun: false)
            case .unexpectedStatus, .editingOff:
                return .failed(error.localizedDescription)
            }
        default:
            return .failed(error.localizedDescription)
        }
    }

    /// The MIME type from the resource's uniform type, else from its filename extension.
    static func mimeType(for resource: DeviceResource) -> String {
        if let identifier = resource.uniformTypeIdentifier, let mime = UTType(identifier)?.preferredMIMEType { return mime }
        let ext = (resource.filename as NSString).pathExtension
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    /// The filename the server shows. An edit's file is called `FullSizeRender…` in PhotoKit; it is
    /// uploaded under the original's name with the edit's extension, as the Photos app exports it.
    static func uploadFilename(for resource: DeviceResource, in asset: DeviceAsset) -> String {
        let originalType: DeviceResourceType? = switch resource.type {
        case .fullSizePhoto: .photo
        case .fullSizeVideo: .video
        case .fullSizePairedVideo: .pairedVideo
        default: nil
        }
        guard let originalType, let original = asset.resources.first(where: { $0.type == originalType }) else {
            return resource.filename
        }
        let stem = (original.filename as NSString).deletingPathExtension
        guard !stem.isEmpty else { return resource.filename }
        let ext = (resource.filename as NSString).pathExtension
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
