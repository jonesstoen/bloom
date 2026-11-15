import Foundation

public enum BackupStagingError: Error, Equatable, Sendable {
    /// The phone hasn't room for the staged file and the upload body made from it.
    case notEnoughSpace
    /// The staged-but-unrecorded upload bodies already take the whole staging budget; try again once
    /// some of them have been uploaded and recorded.
    case overBudget
    /// The bytes read from the photo library hash differently from the checksum the scanner recorded:
    /// the asset changed between the scan and the staging. The body is discarded.
    case checksumMismatch
}

/// What a failed resource read means for the item, the same in the scanner and the uploader.
enum BackupReadFailure {
    /// `pending(.waitingForWiFi)` when the resource is only in iCloud and the network isn't allowed,
    /// `failed` with the reason otherwise. Cancellation is rethrown: callback-based readers can
    /// finish with their own error when a request is cancelled, so a cancelled task counts too.
    static func state(for error: Error, reading resource: DeviceResource) throws -> BackupState {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if let error = error as? PhotoLibraryReadError, error == .needsNetwork { return .pending(reason: .waitingForWiFi) }
        if let error = error as? PhotoLibraryReadError, error == .notDelivered {
            return .failed(reason: tr("The Photos app couldn't hand over the original file of %@.", resource.filename))
        }
        return .failed(reason: tr("Couldn't read %@: %@", resource.filename, error.localizedDescription))
    }
}

/// Copies resources from the photo library into files for upload, hashing them on the way.
/// The files live in `directory` (the account's `Staging` folder), are protected until the first
/// unlock and kept out of backups. `stageBody` writes each resource once, straight into its
/// multipart upload body, which stays until its result is recorded; `removeUnreferenced(keeping:)`
/// cleans up the rest and `removeAll()` empties the folder (sign-out).
/// Never changes the photo library.
public actor BackupStaging {
    /// Room left free on top of what the upload needs.
    public static let margin: Int64 = 200 * 1024 * 1024
    /// The most bytes of staged-but-unrecorded upload bodies kept on the phone at once.
    public static let defaultBudget: Int64 = 2 * 1024 * 1024 * 1024
    /// PhotoKit has no public API for a resource's size, so the space check starts from an estimate:
    /// generous for a photo, a motion clip and a video per second (4K HEVC is about 0.5–1 MB/s).
    /// A file larger than that is checked again while it is written.
    static let photoEstimate: Int64 = 30 * 1024 * 1024
    static let motionEstimate: Int64 = 20 * 1024 * 1024
    static let videoBytesPerSecond: Int64 = 2 * 1024 * 1024
    static let minimumVideoEstimate: Int64 = 50 * 1024 * 1024

    private let directory: URL
    private let freeSpace: @Sendable () -> Int64
    private let recheckInterval: Int64
    private let budget: Int64
    /// Bodies being written right now, with the size reserved for each (the estimate). `stageBody` is
    /// reentrant at the photo library read, so the budget check can't rely on what is on disk yet.
    private var reservations: [URL: Int64] = [:]
    /// Bodies this actor finished and handed out, and the files the last `removeUnreferenced` kept: the
    /// ones that really are staged-but-unrecorded uploads. Anything else in the folder is a leftover.
    private var referenced: Set<String> = []
    private let estimate: @Sendable (DeviceResource, DeviceAsset) -> Int64

    /// `freeSpace` gives the bytes available on the volume of `directory`
    /// (see `availableCapacity(at:)`); it is asked before each resource and again while one
    /// turns out larger than expected.
    public init(directory: URL, freeSpace: @escaping @Sendable () -> Int64) {
        self.init(directory: directory, freeSpace: freeSpace, recheckInterval: 64 * 1024 * 1024)
    }

    /// Tests set a small `recheckInterval` and their own `estimate`.
    init(
        directory: URL, freeSpace: @escaping @Sendable () -> Int64, recheckInterval: Int64,
        budget: Int64 = BackupStaging.defaultBudget,
        estimate: @escaping @Sendable (DeviceResource, DeviceAsset) -> Int64 = { BackupStaging.estimate($0, of: $1) }
    ) {
        self.directory = directory
        self.freeSpace = freeSpace
        self.recheckInterval = max(1, recheckInterval)
        self.budget = max(0, budget)
        self.estimate = estimate
    }

    /// Streams `resource` into a new file in the staging folder and returns it with the SHA1 (base64)
    /// of its bytes. Needs room for the file twice (the upload body is a second copy) plus
    /// `margin`, else throws `BackupStagingError.notEnoughSpace` before reading anything; a file
    /// larger than expected is checked again while it is written. Read errors
    /// (`PhotoLibraryReadError.needsNetwork` among them) and cancellation are rethrown. On any
    /// error the partial file is removed.
    public func stage(
        _ resource: DeviceResource, of asset: DeviceAsset, from source: any PhotoLibrarySource, allowNetwork: Bool
    ) async throws -> (url: URL, checksum: String) {
        let expected = max(estimate(resource, asset), 0)
        guard freeSpace() >= 2 * expected + Self.margin else { throw BackupStagingError.notEnoughSpace }

        try Self.createDirectory(directory)
        let url = directory.appendingPathComponent("\(UUID().uuidString).staged")
        var attributes: [FileAttributeKey: Any]?
        #if os(iOS)
        attributes = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let sink = try StagingSink(
                url: url, freeSpace: freeSpace, firstCheck: expected + recheckInterval, interval: recheckInterval)
            defer { sink.close() }
            // The read runs as its own task so a staging failure (no room, a write error) can stop it:
            // PhotoKit then cancels the data request instead of downloading the rest of the file.
            let reader = Task { try await source.read(resource, of: asset.id, allowNetwork: allowNetwork) { sink.write($0) } }
            sink.onFailure { reader.cancel() }
            do {
                try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            } catch {
                throw sink.failure ?? error
            }
            try Task.checkCancellation()
            let checksum = try sink.finish()
            return (url, checksum)
        } catch {
            remove(url)
            if Self.isOutOfSpace(error) { throw BackupStagingError.notEnoughSpace }
            throw error
        }
    }

    /// Streams `resource` from the photo library straight into a new multipart upload body in the
    /// staging folder (prefix, bytes, suffix) and hashes the bytes in the same pass, so there is one
    /// copy on disk. The body stays until the caller has recorded the upload's result and removes it.
    ///
    /// Throws, with no file left: `notEnoughSpace` (needs room for the body once plus `margin`; checked
    /// again while a larger file is written), `overBudget` (the unrecorded bodies already staged plus this
    /// one, and the bodies being staged at the same time, would pass the budget; a body is always allowed
    /// when no other body is being staged and none is waiting for its upload, else a video larger than the
    /// whole budget could never be backed up),
    /// `checksumMismatch` (the bytes don't hash to `expectedChecksum`), read errors
    /// (`PhotoLibraryReadError.needsNetwork` among them) and cancellation.
    public func stageBody(
        _ resource: DeviceResource, of asset: DeviceAsset, from source: any PhotoLibrarySource, allowNetwork: Bool,
        fields: MultipartFields, expectedChecksum: String
    ) async throws -> (bodyFile: URL, boundary: String) {
        let expected = max(estimate(resource, asset), 0)
        guard freeSpace() >= expected + Self.margin else { throw BackupStagingError.notEnoughSpace }

        try Self.createDirectory(directory)
        let boundary = "bloom-\(UUID().uuidString)"
        let url = directory.appendingPathComponent("\(UUID().uuidString).multipart")
        var attributes: [FileAttributeKey: Any]?
        #if os(iOS)
        attributes = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // The budget check and the reservation happen in one synchronous stretch (no await between), so
        // two bodies started together can't both see the same free budget.
        let taken = stagedBytes()
        if !taken.exempt, taken.bytes + expected > budget {
            remove(url)
            throw BackupStagingError.overBudget
        }
        reservations[url] = expected
        defer { reservations[url] = nil }
        do {
            // Staged bodies are rebuilt from the photo library if lost; no reason to put them in a backup.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutableURL = url
            // `try?`: a file system without the flag only loses an optimisation, the upload still works.
            try? mutableURL.setResourceValues(excluded)

            let sink = try StagingSink(
                url: url, freeSpace: freeSpace, firstCheck: expected + recheckInterval, interval: recheckInterval,
                prefix: MultipartBody.prefix(fields, boundary: boundary), copies: 0)
            defer { sink.close() }
            let reader = Task { try await source.read(resource, of: asset.id, allowNetwork: allowNetwork) { sink.write($0) } }
            sink.onFailure { reader.cancel() }
            do {
                try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            } catch {
                throw sink.failure ?? error
            }
            try Task.checkCancellation()
            let checksum = try sink.finish(suffix: MultipartBody.suffix(boundary: boundary))
            guard checksum == expectedChecksum else { throw BackupStagingError.checksumMismatch }
            referenced.insert(url.lastPathComponent)
            return (url, boundary)
        } catch {
            remove(url)
            if Self.isOutOfSpace(error) { throw BackupStagingError.notEnoughSpace }
            throw error
        }
    }

    /// The file in the staging folder called `name`, for an upload body recorded by name (see
    /// `UploadJob.bodyFileName`). `nil` for a name that isn't a plain file name inside the folder: empty,
    /// `.`, `..`, or one with a path separator. Callers treat `nil` as "no body".
    public nonisolated func url(forBodyNamed name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            return nil
        }
        return url
    }

    /// Removes one staged file. Safe to call from a `defer`, and for a file that is already gone.
    public nonisolated func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every file in the staging folder that isn't in `keeping`: leftovers from an app that was
    /// stopped mid-staging, and bodies whose upload no longer exists. Pass the body files of the
    /// uploads still recorded or in flight; never removes those. Never removes a body that is being
    /// written by `stageBody` either. A body `stageBody` has returned must be recorded in the index (or
    /// be in `keeping`) before the next cleanup, or the cleanup deletes it.
    public func removeUnreferenced(keeping: Set<URL>) {
        let directoryPath = directory.standardizedFileURL.path
        // Only files directly in the staging folder count as kept; same name elsewhere doesn't.
        let kept = Set(keeping.filter {
            $0.standardizedFileURL.deletingLastPathComponent().path == directoryPath
        }.map { $0.standardizedFileURL.lastPathComponent })
        let writing = Set(reservations.keys.map(\.lastPathComponent))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !kept.contains(name) && !writing.contains(name) {
            remove(directory.appendingPathComponent(name))
        }
        referenced = kept
    }

    /// Empties the staging folder: staged files and any upload bodies left behind by an app that was
    /// stopped mid-upload. Call only while nothing is uploading.
    public func removeAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names { remove(directory.appendingPathComponent(name)) }
        referenced = []
    }

    /// Free bytes on the volume holding `directory` (or its nearest existing parent), as iOS counts
    /// them for user-requested work. `Int64.max` when the system can't tell, so an unknown answer
    /// doesn't stop the backup; a full disk still fails the write and stops it.
    public static func availableCapacity(at directory: URL) -> Int64 {
        var url = directory
        while true {
            if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return Int64.max }
            url = parent
        }
    }

    /// Whether `error` is the disk being full.
    static func isOutOfSpace(_ error: Error) -> Bool {
        if error as? BackupStagingError == .notEnoughSpace { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    // MARK: - Helpers

    /// What the staging folder takes against the budget: for each file the larger of its size on disk
    /// and its reservation (a body still being written counts at least its estimate). `exempt` is true
    /// when nothing else is being written and no finished, unrecorded body is waiting, so a body larger
    /// than the budget can still go through; leftovers of an earlier run count as bytes but don't block it.
    private func stagedBytes() -> (bytes: Int64, exempt: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var total: Int64 = 0
        var waiting = false
        for name in names {
            let url = directory.appendingPathComponent(name)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            total += max(size, reservations[url] ?? 0)
            if referenced.contains(name) { waiting = true }
        }
        referenced.formIntersection(names)
        return (total, reservations.isEmpty && !waiting)
    }

    // MARK: - Estimates

    static func estimate(_ resource: DeviceResource, of asset: DeviceAsset) -> Int64 {
        switch resource.type {
        case .video, .fullSizeVideo:
            let seconds = Int64(min(max(0, asset.duration.rounded(.up)), 1_000_000))
            return max(minimumVideoEstimate, seconds * videoBytesPerSecond)
        case .pairedVideo, .fullSizePairedVideo:
            return motionEstimate
        case .photo, .fullSizePhoto, .other:
            return photoEstimate
        }
    }

    private static func createDirectory(_ directory: URL) throws {
        var attributes: [FileAttributeKey: Any]?
        #if os(iOS)
        attributes = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    }
}

/// Receives a resource's bytes from PhotoKit's data callback: writes them to the staged file and
/// hashes them. After the first failure (a write error, or no room left) further bytes are dropped
/// and `finish()` throws it.
private final class StagingSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let freeSpace: @Sendable () -> Int64
    private let interval: Int64
    /// How many more copies of what's written must fit besides it: 1 when an upload body will be made
    /// from the file afterwards, 0 when the file is the body.
    private let copies: Int64
    private var sha = SHA1Stream()
    private var written: Int64 = 0
    private var nextCheck: Int64
    private var _failure: Error?
    private var failureHandler: (@Sendable () -> Void)?

    var failure: Error? { lock.withLock { _failure } }

    /// Calls `handler` once at the first failure (at once if there already was one).
    func onFailure(_ handler: @escaping @Sendable () -> Void) {
        let failedAlready = lock.withLock {
            failureHandler = handler
            return _failure != nil
        }
        if failedAlready { handler() }
    }

    /// `prefix` is written first and isn't hashed (the multipart header of a body file).
    init(
        url: URL, freeSpace: @escaping @Sendable () -> Int64, firstCheck: Int64, interval: Int64,
        prefix: Data = Data(), copies: Int64 = 1
    ) throws {
        handle = try FileHandle(forWritingTo: url)
        if !prefix.isEmpty { try handle.write(contentsOf: prefix) }
        self.freeSpace = freeSpace
        self.interval = interval
        self.copies = copies
        nextCheck = firstCheck
    }

    func write(_ data: Data) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard _failure == nil else { return nil }
            do {
                try autoreleasepool { try handle.write(contentsOf: data) }
            } catch {
                _failure = error
                return failureHandler
            }
            sha.update(data)
            written += Int64(data.count)
            // Larger than expected: the rest of this file and the body copy of all of it must still fit.
            if written >= nextCheck {
                if freeSpace() < copies * written + BackupStaging.margin {
                    _failure = BackupStagingError.notEnoughSpace
                    return failureHandler
                }
                nextCheck = written + interval
            }
            return nil
        }
        handler?() // outside the lock: cancelling the read may call back into PhotoKit
    }

    /// Writes `suffix` (not hashed) and returns the SHA1 of the bytes received.
    func finish(suffix: Data = Data()) throws -> String {
        try lock.withLock {
            if let _failure { throw _failure }
            if !suffix.isEmpty { try handle.write(contentsOf: suffix) }
            return sha.base64()
        }
    }

    func close() { lock.withLock { try? handle.close() } }
}
