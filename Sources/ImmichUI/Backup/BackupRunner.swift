import Foundation
import ImmichKit
import Observation

/// Decides when backups run: with the Backup switch on and the app open, it scans the selection and
/// then uploads what the server is missing. That happens when the app becomes active, when the Backup
/// screen is opened, and when the photo library changes (debounced).
///
/// A library change during an upload never interrupts it: the current item finishes, then the runner
/// scans again before the next one. A change during a scan starts another scan once it has finished.
/// Leaving the foreground or turning the switch off cancels the upload in flight (the uploader puts
/// the item back and removes its staged file; the server's checksum check makes the retry safe).
///
/// Uploads (`run`), Try Again and Re-upload never overlap: they take turns on one lane, and a waiting
/// Try Again or Re-upload pauses a run between items. The scans themselves are the model's.
@MainActor @Observable
final class BackupRunner {
    /// While the uploader works through the queue.
    private(set) var isUploading = false
    /// The upload run's latest progress; nil when nothing uploads.
    private(set) var uploadProgress: UploadProgress?

    /// Wait after the last library change before scanning: PhotoKit reports a burst for one photo.
    nonisolated static let defaultDebounce: Duration = .seconds(2)
    /// During a run the counts on screen are refreshed at most this often (they read the whole selection).
    static let countsInterval: Duration = .seconds(3)

    private struct Work {
        let id: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored private weak var model: BackupModel?
    @ObservationIgnored private let source: any PhotoLibrarySource
    @ObservationIgnored private let staging: BackupStaging
    @ObservationIgnored private var uploader: BackupUploader?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStopped = false
    /// The scan-then-upload run going now; nil when none (or after it was cancelled).
    @ObservationIgnored private var current: Work?
    /// The newest run task. Each waits for the one before, so a cancelled run has ended before the next starts.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// A scan (then upload) is wanted: set by the triggers, cleared when the scan starts.
    @ObservationIgnored private var wantsRun = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var countsRefreshed: ContinuousClock.Instant?
    @ObservationIgnored private var laneBusy = false
    @ObservationIgnored private var laneWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - uploader: shares the model's index (see `BackupModel.makeUploader`).
    ///   - staging: the uploader's staging folder, emptied by `stop()` and `removeLeftoverStaging()`.
    ///   - debounce, sleep: the wait after a library change, and how it is waited (tests return at once).
    convenience init(
        model: BackupModel, uploader: BackupUploader, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration = BackupRunner.defaultDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(model: model, uploader: Optional(uploader), source: source, staging: staging, debounce: debounce, sleep: sleep)
    }

    /// Makes the uploader from the model when it is first needed (opening the index reads a file).
    convenience init(
        model: BackupModel, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration = BackupRunner.defaultDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(model: model, uploader: nil, source: source, staging: staging, debounce: debounce, sleep: sleep)
    }

    private init(
        model: BackupModel, uploader: BackupUploader?, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.model = model
        self.uploader = uploader
        self.source = source
        self.staging = staging
        self.debounce = debounce
        self.sleep = sleep
        model.adopt(self)
    }

    private var isEnabled: Bool { model?.settings.isEnabled ?? false }

    // MARK: - Triggers

    func appBecameActive() {
        guard !isStopped else { return }
        isActive = true
        update()
        requestRun()
    }

    /// Cancels the upload in flight; it is retried the next time the app is active.
    func appLeftForeground() {
        isActive = false
        update()
    }

    func backupScreenOpened() {
        requestRun()
    }

    /// The Backup switch. Saved with the other settings; off cancels the upload in flight.
    func setEnabled(_ on: Bool) {
        guard !isStopped else { return }
        // The model's settings tell the runner (`enabledDidChange`), also when they are set directly.
        model?.settings.isEnabled = on
    }

    /// Called by the model when the switch changed.
    func enabledDidChange() {
        update()
        requestRun()
    }

    /// Cancels and waits until nothing uploads, then empties the staging folder. Nothing runs afterwards.
    /// Call before the backup directory is removed.
    func stop() async {
        isStopped = true
        isActive = false
        update()
        debounceTask?.cancel()
        await tail?.value
        await cleanup?.value
        // A Try Again or Re-upload in progress finishes first.
        await acquireLane()
        await staging.removeAll()
        releaseLane()
    }

    /// Empties the staging folder of files a run the system ended left behind. Call at launch; it waits
    /// for its turn, so it never removes a file being uploaded.
    func removeLeftoverStaging() {
        guard !isStopped else { return }
        let previous = cleanup
        cleanup = Task { [weak self, staging] in
            await previous?.value
            guard let self else { return }
            await self.acquireLane()
            await staging.removeAll()
            self.releaseLane()
        }
    }

    /// Whether a library change asked for another scan that hasn't started yet.
    var isRescanPending: Bool { wantsRun && current != nil }

    /// Waits until runs and pending library changes have been handled (for tests).
    func settle() async {
        while true {
            if let task = debounceTask { await task.value; if debounceTask == task { debounceTask = nil }; continue }
            if let task = tail { await task.value; if tail == task { tail = nil }; continue }
            if let task = cleanup { await task.value; if cleanup == task { cleanup = nil }; continue }
            return
        }
    }

    // MARK: - Try Again and Re-upload

    /// The uploader's Try Again, taking turns with uploads; then the items are checked and uploaded.
    func retryFailed(_ ids: [String]) async {
        await acquireLane()
        defer { releaseLane() }
        guard !isStopped else { return }
        await uploaderForRun()?.retryFailed(ids)
        await finishOperation()
    }

    /// The uploader's Re-upload, taking turns with uploads; then the queue is uploaded.
    func reupload(_ ids: [String]) async throws {
        await acquireLane()
        defer { releaseLane() }
        guard !isStopped else { return }
        do {
            try await uploaderForRun()?.reupload(ids)
        } catch {
            await finishOperation()
            throw error
        }
        await finishOperation()
    }

    private func finishOperation() async {
        await model?.uploadsChanged()
        guard isEnabled, isActive, !isStopped else { return }
        wantsRun = true
        start()
    }

    // MARK: - Running

    /// Starts or stops watching the library and cancels the run, to match the switch and the app state.
    private func update() {
        let shouldRun = isEnabled && isActive && !isStopped
        if shouldRun {
            if watcher == nil { watch() }
        } else {
            watcher?.cancel()
            watcher = nil
            debounceTask?.cancel()
            cancelRun()
        }
    }

    /// Scan, then upload, unless that is going on already.
    private func requestRun() {
        guard isEnabled, isActive, !isStopped, current == nil else { return }
        wantsRun = true
        start()
    }

    private func start() {
        guard current == nil, isEnabled, isActive, !isStopped else { return }
        let previous = tail
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(id)
        }
        current = Work(id: id, task: task)
        tail = task
    }

    private func cancelRun() {
        current?.task.cancel()
        current = nil
        wantsRun = false
        isUploading = false
        uploadProgress = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        current?.id == id && !Task.isCancelled && isEnabled && isActive && !isStopped
    }

    private func run(_ id: UUID) async {
        defer { if current?.id == id { current = nil } }
        await cleanup?.value
        guard isCurrent(id), let model else { return }
        // At launch the Backup screen hasn't loaded the selection yet.
        if !model.hasLoaded { await model.load() }
        while isCurrent(id), wantsRun {
            wantsRun = false
            await model.scan()
            guard isCurrent(id) else { return }
            // The library changed while scanning: scan again before uploading.
            if wantsRun { continue }
            guard model.error == nil, model.canCheck else { return }
            // Paused for a rescan: the loop scans again. Paused for a Try Again or Re-upload: that
            // operation starts the next run when it is done (`finishOperation`).
            guard await upload(id) else { return }
        }
    }

    /// One upload run. Returns `false` when the run stopped on an error (or was cancelled).
    private func upload(_ id: UUID) async -> Bool {
        await acquireLane()
        defer { releaseLane() }
        guard isCurrent(id) else { return false }
        guard let uploader = await uploaderForRun(), isCurrent(id) else { return false }
        isUploading = true
        // One pending event at most: a long queue mustn't pile up work on the main actor.
        let (updates, continuation) = AsyncStream<UploadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delivery = Task { [weak self] in
            for await progress in updates {
                guard let self, self.current?.id == id else { continue }
                let finishedItem = progress.done > (self.uploadProgress?.done ?? 0)
                self.uploadProgress = progress
                if finishedItem, self.countsRefreshed.map({ $0.duration(to: .now) >= Self.countsInterval }) ?? true {
                    self.countsRefreshed = .now
                    await self.model?.uploadsChanged()
                }
            }
        }
        var succeeded = true
        do {
            try await uploader.run(
                progress: { continuation.yield($0) },
                shouldPause: { [weak self] in await self?.shouldPause(id) ?? true })
        } catch {
            succeeded = false
            if !(error is CancellationError) { model?.reportUploadFailure(error) }
        }
        continuation.finish()
        await delivery.value
        if current?.id == id {
            isUploading = false
            uploadProgress = nil
        }
        await model?.uploadsChanged()
        return succeeded
    }

    /// Asked by the uploader between items: stop for a rescan, a waiting Try Again or Re-upload, or a
    /// cancelled run.
    private func shouldPause(_ id: UUID) -> Bool {
        current?.id != id || wantsRun || !laneWaiters.isEmpty
    }

    /// nil only once the model is gone (the session ended).
    private func uploaderForRun() async -> BackupUploader? {
        if let uploader { return uploader }
        guard let model else { return nil }
        let made = await model.makeUploader()
        // Another caller may have made it meanwhile: there is one uploader (its retries are per session).
        if let uploader { return uploader }
        uploader = made
        return made
    }

    // MARK: - Library changes

    private func watch() {
        let changes = source.changes()
        watcher = Task { [weak self] in
            for await _ in changes {
                self?.libraryChanged()
            }
        }
    }

    private func libraryChanged() {
        debounceTask?.cancel()
        let sleep = sleep
        let debounce = debounce
        debounceTask = Task { [weak self] in
            do { try await sleep(debounce) } catch { return }
            guard !Task.isCancelled, let self, self.isEnabled, self.isActive, !self.isStopped else { return }
            // A running upload pauses after its current item (`shouldPause`); a scan is followed by another.
            self.wantsRun = true
            self.start()
        }
    }

    // MARK: - Lane

    /// Waits for the turn to use the uploader, first come first served.
    private func acquireLane() async {
        guard laneBusy else {
            laneBusy = true
            return
        }
        await withCheckedContinuation { laneWaiters.append($0) }
    }

    private func releaseLane() {
        if laneWaiters.isEmpty { laneBusy = false }
        else { laneWaiters.removeFirst().resume() }
    }
}
