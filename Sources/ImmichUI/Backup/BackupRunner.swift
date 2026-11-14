import Foundation
import ImmichKit
import Observation

/// Decides when backups run: with the Backup switch on and the app open, it scans the selection and
/// then uploads what the server is missing. That happens when the app comes back from the background
/// (or opens), when the Backup screen is opened, when the album choice or a cellular switch changes,
/// and when the photo library changes (debounced).
///
/// A library change during an upload never interrupts the item in flight: the run uploads at least one
/// item, then scans again before the next. A change during a scan is followed by one more scan, after
/// which the queue gets its turn. A changed album choice pauses the run before the next item, so items
/// no longer selected aren't uploaded. Leaving the foreground or turning the switch off cancels the
/// upload in flight (the uploader puts the item back and removes its staged file; the server's checksum
/// check makes the retry safe), and so does the user's Cancel of the scan a run is waiting for.
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
    /// The longest wait from the first change of a burst, so steady changes still get scanned.
    nonisolated static let defaultDebounceLimit: Duration = .seconds(10)
    /// During a run the counts on screen are refreshed at most this often (they read the whole selection).
    static let countsInterval: Duration = .seconds(3)
    /// Scans in a row, after the first, that library changes may cause before the queue gets an upload in.
    static let rescansBeforeUpload = 1

    private struct Work {
        let id: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored private weak var model: BackupModel?
    @ObservationIgnored private let source: any PhotoLibrarySource
    @ObservationIgnored private let staging: BackupStaging
    @ObservationIgnored private var uploader: BackupUploader?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let debounceLimit: Duration
    @ObservationIgnored private let clock: BackupRetryClock

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStopped = false
    /// The scan-then-upload run going now; nil when none (or after it was cancelled).
    @ObservationIgnored private var current: Work?
    /// The newest run task. Each waits for the one before, so a cancelled run has ended before the next starts.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// A scan (then upload) is wanted: set by the triggers, cleared when the scan starts.
    @ObservationIgnored private var wantsRun = false
    /// The album choice or a cellular switch changed: the queue is out of date, pause before the next item.
    @ObservationIgnored private var choiceChanged = false
    /// The current run is waiting for a scan (a user Cancel of it ends the run).
    @ObservationIgnored private var isScanningForRun = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var retiredWatchers: [Task<Void, Never>] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// When the current burst of library changes started.
    @ObservationIgnored private var burstStart: ContinuousClock.Instant?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var countsRefreshed: ContinuousClock.Instant?
    @ObservationIgnored private var operations: [UUID: Task<Void, Error>] = [:]
    /// Try Again / Re-upload calls waiting for the lane: a run pauses for them between items.
    @ObservationIgnored private var waitingOperations = 0
    @ObservationIgnored private var laneBusy = false
    @ObservationIgnored private var laneWaiters: [CheckedContinuation<Void, Never>] = []

    // Test hooks: events to wait for instead of polling.
    @ObservationIgnored private var receivedChanges = 0
    @ObservationIgnored private var changeObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var laneObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// - Parameters:
    ///   - uploader: shares the model's index (see `BackupModel.makeUploader`).
    ///   - staging: the uploader's staging folder, emptied by `stop()` and `removeLeftoverStaging()`.
    ///   - debounce, debounceLimit, clock: the wait after a library change, its maximum from the first
    ///     change of a burst, and the time source it is measured and waited with (tests control it).
    convenience init(
        model: BackupModel, uploader: BackupUploader, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration = BackupRunner.defaultDebounce, debounceLimit: Duration = BackupRunner.defaultDebounceLimit,
        clock: BackupRetryClock = .live
    ) {
        self.init(model: model, uploader: Optional(uploader), source: source, staging: staging,
                  debounce: debounce, debounceLimit: debounceLimit, clock: clock)
    }

    /// Makes the uploader from the model when it is first needed (opening the index reads a file).
    convenience init(
        model: BackupModel, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration = BackupRunner.defaultDebounce, debounceLimit: Duration = BackupRunner.defaultDebounceLimit,
        clock: BackupRetryClock = .live
    ) {
        self.init(model: model, uploader: nil, source: source, staging: staging,
                  debounce: debounce, debounceLimit: debounceLimit, clock: clock)
    }

    private init(
        model: BackupModel, uploader: BackupUploader?, source: any PhotoLibrarySource, staging: BackupStaging,
        debounce: Duration, debounceLimit: Duration, clock: BackupRetryClock
    ) {
        self.model = model
        self.uploader = uploader
        self.source = source
        self.staging = staging
        self.debounce = debounce
        self.debounceLimit = debounceLimit
        self.clock = clock
        model.adopt(self)
    }

    private var isEnabled: Bool { model?.settings.isEnabled ?? false }
    private var mayRun: Bool { isEnabled && isActive && !isStopped }

    // MARK: - Triggers

    /// The app is in the foreground. Starts a run only when it comes back from the background (or opens):
    /// returning from Control Center, Face ID or a permission prompt isn't a reason to scan again.
    func appBecameActive() {
        guard !isStopped else { return }
        let wasActive = isActive
        isActive = true
        update()
        if !wasActive { requestRun() }
    }

    /// Cancels the upload in flight and any Try Again or Re-upload; retried the next time the app is active.
    func appLeftForeground() {
        isActive = false
        cancelOperations()
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
        if !isEnabled { cancelOperations() }
        update()
        requestRun()
    }

    /// Called by the model when the album choice or a cellular switch changed (the model saves it and
    /// scans): the run pauses before its next item, then scans and uploads with the new choice.
    func selectionDidChange() {
        guard mayRun else { return }
        wantsRun = true
        choiceChanged = true
        start()
    }

    /// Called by the model when the user cancels a scan: ends the run that was waiting for it.
    func scanCancelled() {
        if isScanningForRun { cancelRun() }
    }

    /// Cancels and waits until nothing uploads, then empties the staging folder. Nothing runs afterwards.
    /// Call before the backup directory is removed.
    func stop() async {
        isStopped = true
        isActive = false
        let pendingOperations = Array(operations.values)
        cancelOperations()
        update()
        for watcher in retiredWatchers { await watcher.value }
        retiredWatchers = []
        await tail?.value
        for operation in pendingOperations { _ = try? await operation.value }
        await cleanup?.value
        await acquireLane()
        await staging.removeAll()
        releaseLane()
    }

    /// Empties the staging folder of files a run the system ended left behind. Call at launch; it waits
    /// for its turn on the lane, so it never removes a file being uploaded.
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

    // MARK: - Try Again and Re-upload

    /// The uploader's Try Again, taking turns with uploads; then the items are checked and uploaded.
    /// Cancelled by leaving the foreground, turning the switch off and `stop()`.
    func retryFailed(_ ids: [String]) async {
        try? await operation { uploader in
            try Task.checkCancellation()
            await uploader.retryFailed(ids)
        }
    }

    /// The uploader's Re-upload, taking turns with uploads; then the queue is uploaded. Cancelled
    /// (throwing `CancellationError`) like `retryFailed`.
    func reupload(_ ids: [String]) async throws {
        try await operation { uploader in try await uploader.reupload(ids) }
    }

    /// Runs `body` in a task of its own, so `cancelOperations()` reaches it whoever called.
    private func operation(_ body: @escaping @MainActor (BackupUploader) async throws -> Void) async throws {
        guard !isStopped else { throw CancellationError() }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.perform(body)
        }
        operations[id] = task
        defer { operations[id] = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func perform(_ body: @MainActor (BackupUploader) async throws -> Void) async throws {
        waitingOperations += 1
        await acquireLane()
        waitingOperations -= 1
        defer { releaseLane() }
        try Task.checkCancellation()
        guard !isStopped, let uploader = await uploaderForRun() else { throw CancellationError() }
        do {
            try await body(uploader)
        } catch {
            await finishOperation()
            throw error
        }
        // Restored or re-uploaded items are on the server again: the Library should show them.
        model?.serverLibraryChanged()
        await finishOperation()
    }

    private func finishOperation() async {
        await model?.uploadsChanged()
        guard mayRun else { return }
        wantsRun = true
        start()
    }

    private func cancelOperations() {
        for task in operations.values { task.cancel() }
    }

    // MARK: - Running

    /// Starts or stops watching the library and cancels the run, to match the switch and the app state.
    private func update() {
        if mayRun {
            if watcher == nil { watch() }
        } else {
            if let watcher {
                watcher.cancel()
                retiredWatchers.append(watcher)
            }
            watcher = nil
            debounceTask?.cancel()
            burstStart = nil
            cancelRun()
        }
    }

    /// Scan, then upload, unless that is going on already.
    private func requestRun() {
        guard mayRun, current == nil else { return }
        wantsRun = true
        start()
    }

    private func start() {
        guard current == nil, mayRun else { return }
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
        choiceChanged = false
        isScanningForRun = false
        isUploading = false
        uploadProgress = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        current?.id == id && !Task.isCancelled && mayRun
    }

    private func run(_ id: UUID) async {
        defer {
            if current?.id == id {
                current = nil
                isScanningForRun = false
                // A trigger that came while the run was ending isn't lost.
                if wantsRun, mayRun { start() } else {
                    wantsRun = false
                    choiceChanged = false
                }
            }
        }
        await cleanup?.value
        guard isCurrent(id) else { return }
        guard let model else {
            wantsRun = false
            return
        }
        // At launch the Backup screen hasn't loaded the selection yet.
        if !model.hasLoaded { await model.load() }
        var rescans = 0
        while isCurrent(id), wantsRun {
            wantsRun = false
            choiceChanged = false
            isScanningForRun = true
            let completed = await model.scanForRun()
            isScanningForRun = false
            guard isCurrent(id) else { return }
            // Cancelled (a new album choice, say): scan again if something asked for it, else wait for
            // the next trigger. Never upload from a scan that didn't finish.
            guard completed else { continue }
            if wantsRun, choiceChanged || rescans < Self.rescansBeforeUpload {
                rescans += 1
                continue
            }
            guard model.error == nil, model.canCheck else { return }
            // Paused for a library change: the loop scans again. Paused for a Try Again or Re-upload:
            // that operation starts the next run when it is done (`finishOperation`).
            guard await upload(id) else { return }
            rescans = 0
        }
    }

    /// One upload run. Returns `false` when the run stopped on an error (or was cancelled).
    private func upload(_ id: UUID) async -> Bool {
        await acquireLane()
        defer { releaseLane() }
        guard isCurrent(id), let uploader = await uploaderForRun(), isCurrent(id) else { return false }
        isUploading = true
        let items = ItemCounter()
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
                progress: { progress in
                    items.note(progress)
                    continuation.yield(progress)
                },
                shouldPause: { [weak self] in
                    let finished = items.finished
                    return await self?.shouldPause(id, itemsFinished: finished) ?? true
                })
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
        // New assets on the server: once per run, so the Library isn't reloaded after every item.
        if items.finished > 0 { model?.serverLibraryChanged() }
        return succeeded
    }

    /// Asked by the uploader between items. Pauses at once for a cancelled run, a new album choice or a
    /// waiting Try Again / Re-upload; for a library change only after an item, so changes can't starve uploads.
    private func shouldPause(_ id: UUID, itemsFinished: Int) -> Bool {
        current?.id != id || choiceChanged || waitingOperations > 0 || (wantsRun && itemsFinished > 0)
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

    /// Debounced: a scan starts `debounce` after the last change, or `debounceLimit` after the first
    /// change of a burst, whichever comes first.
    private func libraryChanged() {
        defer {
            receivedChanges += 1
            let reached = changeObservers.filter { $0.count <= receivedChanges }
            changeObservers.removeAll { $0.count <= receivedChanges }
            for observer in reached { observer.continuation.resume() }
        }
        guard mayRun else { return }
        let now = clock.now()
        let first = burstStart ?? now
        burstStart = first
        let deadline = min(now + debounce, first + debounceLimit)
        let wait = max(.zero, now.duration(to: deadline))
        debounceTask?.cancel()
        let clock = clock
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(wait) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.burstStart = nil
            guard self.mayRun else { return }
            // A running upload pauses after an item (`shouldPause`); a scan is followed by another.
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
        await withCheckedContinuation { continuation in
            laneWaiters.append(continuation)
            let reached = laneObservers.filter { $0.count <= laneWaiters.count }
            laneObservers.removeAll { $0.count <= laneWaiters.count }
            for observer in reached { observer.continuation.resume() }
        }
    }

    private func releaseLane() {
        if laneWaiters.isEmpty { laneBusy = false }
        else { laneWaiters.removeFirst().resume() }
    }

    // MARK: - Test hooks

    /// Whether something asked for another scan that the current run hasn't started yet.
    var isRescanPending: Bool { wantsRun && current != nil }

    /// Waits until the watcher has handed `count` library changes (in total) to the runner and the
    /// debounce they started has run. The debounce's sleep must return.
    func handledLibraryChanges(_ count: Int) async {
        if receivedChanges < count {
            await withCheckedContinuation { changeObservers.append((count, $0)) }
        }
        while let task = debounceTask {
            await task.value
            if debounceTask == task { debounceTask = nil }
        }
    }

    /// Waits until `count` callers wait for the lane.
    func waitUntilWaitingForLane(_ count: Int) async {
        if laneWaiters.count >= count { return }
        await withCheckedContinuation { laneObservers.append((count, $0)) }
    }

    /// Waits until runs, stopped watchers, pending debounces and the staging cleanup have finished.
    func settle() async {
        while true {
            if !retiredWatchers.isEmpty {
                let watchers = retiredWatchers
                retiredWatchers = []
                for watcher in watchers { await watcher.value }
                continue
            }
            if let task = debounceTask { await task.value; if debounceTask == task { debounceTask = nil }; continue }
            if let task = tail { await task.value; if tail == task { tail = nil }; continue }
            if let task = cleanup { await task.value; if cleanup == task { cleanup = nil }; continue }
            return
        }
    }
}

/// Counts the items an upload run has finished, from its progress events (an event with a filename
/// starts an item, the next one without ends it). Read by `shouldPause` off the main actor.
private final class ItemCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inItem = false
    private var _finished = 0

    var finished: Int { lock.withLock { _finished } }

    func note(_ progress: UploadProgress) {
        lock.withLock {
            if progress.currentFilename != nil {
                inItem = true
            } else if inItem {
                inItem = false
                _finished += 1
            }
        }
    }
}
