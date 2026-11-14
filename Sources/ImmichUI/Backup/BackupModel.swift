import Foundation
import ImageIO
import ImmichKit
import Observation
import os

/// What the Backup screens show: which photos are on the server, which still aren't, and the
/// choices that steer that (albums, cellular, the Backup switch). Uploads are started by `runner`.
///
/// Scans run in a task the model owns, never in a view's `.task`: closing the sheet must not stop
/// a scan, and the scanner cancels joiners together with the task that started it. Only `cancel()`
/// and `stop()` end one.
@MainActor @Observable
final class BackupModel {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    struct FailedItem: Identifiable, Equatable {
        let id: String
        let reason: String
    }

    /// An item the server had once and no longer has (see `BackupState.deletedOnServer`).
    struct DeletedItem: Identifiable, Equatable {
        let id: String
        /// When the photo was taken, if the photo library still has it.
        let date: Date?
        /// Every missing copy is in the server's trash (so "In the Trash"); else at least one is gone for good.
        let isTrashed: Bool
    }

    enum AlbumState { case included, excluded, neither }

    /// The most failed items listed on screen.
    static let failedItemLimit = 50
    /// The most deleted-on-server items listed on screen.
    static let deletedItemLimit = 200
    /// Pixel side of the thumbnails in the Deleted on Server list.
    static let thumbnailPixelSide = 160

    private(set) var access: PhotoAccess?
    private(set) var counts = BackupCounts()
    /// Non-nil while a scan runs.
    private(set) var progress: Progress?
    private(set) var isScanning = false
    private(set) var albums: [DeviceAlbum] = []
    private(set) var selection = BackupSelection()
    private(set) var failedItems: [FailedItem] = []
    /// The first `deletedItemLimit` items deleted on the server, newest first. `counts.deletedOnServer` has the total.
    private(set) var deletedItems: [DeletedItem] = []
    private(set) var error: String?
    /// The last scan or upload stopped because the server couldn't be reached (offline, say). Shown as a
    /// calm status instead of `error`; cleared when a scan or upload run gets through. The runner tries
    /// again when the network comes back.
    private(set) var isWaitingForNetwork = false
    /// Set when the Backup switch was turned on with no album chosen: the screen opens the album picker,
    /// and clears it when the picker closes.
    var needsAlbumChoice = false
    /// Try Again or Re-upload calls under way.
    private var workingCount = 0
    /// Try Again or Re-upload is under way.
    var isWorking: Bool { workingCount > 0 }
    var settings: BackupSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            let new = settings
            sharedSettings.withLock { $0 = new }
            if settings.isEnabled != oldValue.isEnabled { madeRunner?.enabledDidChange() }
            // The scanner works with the settings it was made with: check again with the new ones,
            // so items waiting for Wi-Fi are tried once cellular is allowed.
            if settings.photosOnCellular != oldValue.photosOnCellular
                || settings.videosOnCellular != oldValue.videosOnCellular, !selection.included.isEmpty {
                scheduleRescan()
                madeRunner?.selectionDidChange()
            }
        }
    }

    @ObservationIgnored private let source: any PhotoLibrarySource
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var network: (any NetworkConditions)?
    @ObservationIgnored private var indexTask: Task<BackupIndex, Never>?
    /// Its value: whether the scan completed (not cancelled, no error).
    @ObservationIgnored private var scanTask: Task<Bool, Never>?
    /// Scans that completed, for `scanForRun()`.
    @ObservationIgnored private var completedScans = 0
    @ObservationIgnored private var rescan: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var generation = 0
    /// Counts `refreshLists()` calls: only the newest one may publish its result.
    @ObservationIgnored private var listsRevision = 0
    /// Decoded thumbnails of the Deleted on Server rows, by asset ID, and the IDs that had none.
    @ObservationIgnored private var thumbnailCache: [String: CGImage] = [:]
    @ObservationIgnored private var thumbnailMisses: Set<String> = []
    @ObservationIgnored private var progressGate = BackupProgressGate()
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var savedSelectionRevision = 0
    @ObservationIgnored private var selectionSaveError: String?

    private var hasUnsavedSelection: Bool { selectionRevision != savedSelectionRevision }
    /// The index couldn't be read when it was last used; it is reopened before the next attempt.
    @ObservationIgnored private var indexWasUnavailable = false
    /// `settings` for the uploader, which reads them off the main actor before each item.
    @ObservationIgnored private let sharedSettings: OSAllocatedUnfairLock<BackupSettings>
    @ObservationIgnored private var madeRunner: BackupRunner?
    /// The account's `Staging` folder, where the uploader copies each resource before sending it.
    @ObservationIgnored let staging: BackupStaging
    /// `load()` has run: the selection and photo access on the model are known.
    @ObservationIgnored private(set) var hasLoaded = false

    /// - Parameters:
    ///   - directory: where the account's `index.json` lives; the index is opened on first use.
    ///   - network: defaults to a path monitor, started when the first scan needs it.
    init(
        source: some PhotoLibrarySource,
        service: any ImmichService,
        directory: URL,
        network: (any NetworkConditions)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.source = source
        self.service = service
        self.directory = directory
        self.network = network
        self.defaults = defaults
        let settings = BackupSettings.load(from: defaults)
        self.settings = settings
        sharedSettings = OSAllocatedUnfairLock(initialState: settings)
        let stagingDirectory = directory.appendingPathComponent("Staging", isDirectory: true)
        staging = BackupStaging(
            directory: stagingDirectory, freeSpace: { BackupStaging.availableCapacity(at: stagingDirectory) })
    }

    /// Decides when scans and uploads run (the Backup switch, the app being open, library changes).
    /// Made on first use; a runner made for this model in a test takes its place.
    var runner: BackupRunner {
        if let madeRunner { return madeRunner }
        return BackupRunner(model: self, source: source, staging: staging)
    }

    /// Called by `BackupRunner.init`.
    func adopt(_ runner: BackupRunner) { madeRunner = runner }

    /// The network the scans and uploads check, watched by the runner. A path monitor unless one was given.
    var networkConditions: any NetworkConditions {
        if let network { return network }
        let made = PathMonitorNetwork()
        network = made
        return made
    }

    /// The uploader for this account: same index, photo library, server and settings as the scans.
    func makeUploader(clock: BackupRetryClock = .live) async -> BackupUploader {
        let index = await ensureIndex()
        let network = networkConditions
        let settings = sharedSettings
        return BackupUploader(
            source: source, service: service, index: index, staging: staging,
            settings: { settings.withLock { $0 } }, network: network, clock: clock)
    }

    // MARK: - Reading

    /// Reads access, albums, the saved selection and the counts the index already knows.
    func load() async {
        guard !isStopped else { return }
        let loadingRevision = selectionRevision
        let mayRestoreSelection = !hasUnsavedSelection
        let index = await ensureIndex()
        if indexWasUnavailable {
            indexWasUnavailable = false
            if (try? await index.reload()) == nil { indexWasUnavailable = true }
        }
        // A choice made while this was loading is newer than what the index has saved so far.
        let saved = await index.selection()
        if rescan == nil, mayRestoreSelection, !hasUnsavedSelection, loadingRevision == selectionRevision {
            selection = saved
        }
        hasLoaded = true
        // An unlock/reopen retries the local choice, without starting another library scan.
        if hasUnsavedSelection, rescan == nil, !isStopped {
            scheduleRescan(scanning: false)
            await rescan?.task.value
        }
        var current = await source.authorization()
        // The first time, iOS asks the user here; Photos shows up in Settings only after that.
        if current == .notDetermined { current = await source.requestAuthorization() }
        access = current
        guard canRead else {
            albums = []
            counts = BackupCounts()
            failedItems = []
            deletedItems = []
            return
        }
        albums = await source.albums()
        await refreshCounts()
    }

    /// The Backup switch. Turning it on with no album chosen opens the album picker (`needsAlbumChoice`);
    /// the switch stays on, so choosing an album starts the first run.
    func setBackupEnabled(_ on: Bool) {
        runner.setEnabled(on)
        if on, hasLoaded, selection.included.isEmpty { needsAlbumChoice = true }
    }

    /// Whether Check Now makes sense: photo access and at least one included album.
    var canCheck: Bool { canRead && !selection.included.isEmpty }

    /// Whether Bloom may read the photo library (fully or in part).
    var canRead: Bool { access == .full || access == .limited }

    /// Photos waiting to be uploaded (those that failed are listed apart).
    var remaining: Int { counts.pending }

    /// "Recents · 1 excluded"
    var selectionSummary: String {
        var parts: [String] = []
        let included = selection.included.count
        if included == 0 { parts.append(tr("None")) }
        else if included == 1, let album = albums.first(where: { selection.included.contains($0.id) }) {
            parts.append(album.title)
        } else { parts.append(tr("%lld albums", Int64(included))) }
        if !selection.excluded.isEmpty { parts.append(tr("%lld excluded", Int64(selection.excluded.count))) }
        return parts.joined(separator: " · ")
    }

    func state(of album: DeviceAlbum) -> AlbumState {
        if selection.included.contains(album.id) { return .included }
        if selection.excluded.contains(album.id) { return .excluded }
        return .neither
    }

    /// The album to offer on first setup: the first one is Recents.
    var suggestedAlbumID: String? {
        selection.included.isEmpty && selection.excluded.isEmpty ? albums.first?.id : nil
    }

    // MARK: - Scanning

    /// Checks the selected photos against the server and returns when the scan has finished
    /// (or was cancelled). Joins a scan that is already running. Does nothing without photo access.
    /// Returns whether the scan completed: `false` when it was cancelled, failed or didn't run.
    @discardableResult
    func scan() async -> Bool {
        guard !isStopped else { return false }
        if let scanTask { return await scanTask.value }
        access = await source.authorization()
        guard canRead else { return false }
        await reopenIndexIfNeeded()
        let scanner = await makeScanner()
        // Another caller may have started a scan while this one was suspended.
        if let scanTask { return await scanTask.value }
        // A rescan that was replaced while it got ready must not start a scan the next one has to cancel.
        guard !isStopped, !Task.isCancelled else { return false }

        error = nil
        isScanning = true
        progress = Progress(done: 0, total: counts.total)
        progressGate = BackupProgressGate()
        generation += 1
        let current = generation
        scanTask = Task { [weak self] in
            var result: BackupCounts?
            var failure: Error?
            // A single consumer with one pending snapshot avoids a task backlog for large libraries.
            let (updates, continuation) = AsyncStream<(BackupCounts, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let delivery = Task { [weak self] in
                for await (counts, handled) in updates {
                    self?.apply(counts, handled: handled, generation: current)
                }
            }
            do {
                result = try await scanner.scan { counts, handled in
                    continuation.yield((counts, handled))
                }
            } catch {
                failure = error
            }
            continuation.finish()
            await delivery.value
            await self?.finishScan(result: result, failure: failure)
            return result != nil
        }
        return await scanTask?.value ?? false
    }

    /// For the runner: waits for a selection or settings change to be saved and scanned with (rather than
    /// scanning the old choice), else scans or joins the running scan. Returns whether a scan of the
    /// current choice completed.
    func scanForRun() async -> Bool {
        let before = completedScans
        var waited = false
        while let task = rescan?.task {
            waited = true
            await task.value
        }
        if waited, completedScans > before, scanTask == nil { return true }
        return await scan()
    }

    /// The user's Cancel: stops the running scan, and the upload run the scan was for. Hashed items keep
    /// their checksums, so the next scan carries on.
    func cancel() {
        guard !isStopped else { return }
        madeRunner?.scanCancelled()
        scanTask?.cancel()
        if hasUnsavedSelection { scheduleRescan(scanning: false) }
        else { rescan?.task.cancel() }
    }

    /// Cancels and waits until nothing runs any more; no new scan starts afterwards. Call before the
    /// backup directory is removed, or a running save could recreate it.
    func stop() async {
        isStopped = true
        let pending = rescan?.task
        pending?.cancel()
        scanTask?.cancel()
        // Uploads too; the runner then empties the staging folder.
        await madeRunner?.stop()
        await pending?.value
        _ = await scanTask?.value
    }

    /// Uploads changed what is on the server: shows the new counts (a running scan brings its own).
    func uploadsChanged() async {
        guard !isScanning, !isStopped else { return }
        await refreshCounts()
    }

    /// Called after uploads or restores put assets on the server, so the Library can reload its timeline.
    @ObservationIgnored var onServerLibraryChanged: (@MainActor () -> Void)?

    func serverLibraryChanged() { onServerLibraryChanged?() }

    /// An upload run got through: the server is reachable again.
    func uploadRunSucceeded() { isWaitingForNetwork = false }

    /// An upload run stopped on something every item would run into: shown like a scan's error.
    func reportUploadFailure(_ failure: Error) {
        switch failure {
        case is CancellationError: return
        case BackupStagingError.notEnoughSpace:
            // The item is listed under Problems with Bloom's reason; this explains why the run stopped.
            isWaitingForNetwork = false
            error = tr("Couldn't back up your photos: %@", CocoaError(.fileWriteOutOfSpace).localizedDescription)
        default: report(failure, uploading: true)
        }
    }

    /// Waits until scans and the rescans that selection changes trigger have finished.
    func settle() async {
        while true {
            if let task = rescan?.task { await task.value; continue }
            if let task = scanTask { _ = await task.value; continue }
            return
        }
    }

    private func apply(_ counts: BackupCounts, handled: Int, generation current: Int) {
        guard isScanning, current == generation, handled >= (progress?.done ?? 0) else { return }
        guard progressGate.shouldPublish(at: .now) else { return }
        self.counts = counts
        progress = Progress(done: handled, total: max(counts.total, handled))
    }

    private func finishScan(result: BackupCounts?, failure: Error?) async {
        if let failure, !(failure is CancellationError) { report(failure) }
        // Before the first await: a late progress callback must not bring `progress` back or
        // overwrite the final counts.
        generation += 1
        progress = nil
        if let result {
            counts = result
            completedScans += 1
            isWaitingForNetwork = false
        } else { await refreshCounts() }
        await refreshLists()
        scanTask = nil
        isScanning = false
    }

    /// No connection to the server becomes the waiting status (leaving any other error as it is); any
    /// other failure becomes `error`.
    private func report(_ failure: Error, uploading: Bool = false) {
        if ImmichServiceError.isConnectivityFailure(failure) {
            isWaitingForNetwork = true
            return
        }
        isWaitingForNetwork = false
        if case BackupIndexError.unavailable = failure { indexWasUnavailable = true }
        error = Self.message(for: failure, uploading: uploading)
    }

    /// An index that couldn't be read (a locked device, say) stays unavailable until it is reloaded.
    /// The reload replaces what the index holds in memory, so the choice on screen is put back.
    private func reopenIndexIfNeeded() async {
        guard indexWasUnavailable else { return }
        let index = await ensureIndex()
        indexWasUnavailable = false
        do { try await index.reload() } catch { indexWasUnavailable = true }
        await index.setSelection(selection)
    }

    private static func message(for error: Error, uploading: Bool = false) -> String {
        if case BackupIndexError.unavailable = error {
            return tr("Bloom couldn't open its backup records. Unlock your device and try again.")
        }
        if case ImmichServiceError.unauthorized = error {
            return tr("This API key can't check backups. Create a key with the View, Organize and Back Up permissions and sign in with it.")
        }
        if uploading { return tr("Couldn't back up your photos: %@", error.localizedDescription) }
        return tr("Couldn't check your photos: %@", error.localizedDescription)
    }

    // MARK: - Selection

    /// Included, then excluded, then neither, then included again.
    func cycle(_ album: DeviceAlbum) {
        var next = selection
        switch state(of: album) {
        case .included:
            next.included.remove(album.id)
            next.excluded.insert(album.id)
        case .excluded:
            next.excluded.remove(album.id)
        case .neither:
            next.included.insert(album.id)
        }
        setSelection(next)
    }

    /// Shows the choice at once, then saves it and checks again with the new selection.
    func setSelection(_ new: BackupSelection) {
        guard !isStopped, new != selection else { return }
        selection = new
        selectionRevision += 1
        scheduleRescan()
        madeRunner?.selectionDidChange()
    }

    /// Saves the current selection and checks again, replacing a rescan or scan in progress.
    private func scheduleRescan(scanning: Bool = true) {
        guard !isStopped else { return }
        // Each rescan waits for the one it replaces, so saves happen in the order of the choices
        // and `stop()` (which awaits the newest) waits for all of them.
        let previous = rescan?.task
        previous?.cancel()
        if scanning { scanTask?.cancel() }
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            await self?.applySelection(scanning: scanning)
            if self?.rescan?.id == id { self?.rescan = nil }
        }
        rescan = (id, task)
    }

    private func applySelection(scanning: Bool) async {
        let index = await ensureIndex()
        // Replaced by a newer choice (or stopped) while the index loaded: that one saves.
        guard !Task.isCancelled, !isStopped else { return }
        // The latest choice, not the one that started this task.
        let savingRevision = selectionRevision
        await index.setSelection(selection)
        do {
            try await index.save()
            savedSelectionRevision = savingRevision
            // Leave any later server error intact when only the storage retry succeeded.
            if !scanning, error == selectionSaveError { error = nil }
            selectionSaveError = nil
        } catch {
            report(error)
            selectionSaveError = self.error
        }
        guard !Task.isCancelled, !isStopped, scanning else { return }
        scanTask?.cancel()
        _ = await scanTask?.value
        guard !Task.isCancelled else { return }
        await scan()
    }

    // MARK: - Helpers

    private func ensureIndex() async -> BackupIndex {
        if let indexTask { return await indexTask.value }
        let directory = directory
        // Reads the saved file, which can be large: keep it off the main thread.
        let task = Task.detached { BackupIndex(directory: directory) }
        indexTask = task
        return await task.value
    }

    private func makeScanner() async -> BackupScanner {
        let index = await ensureIndex()
        let network = networkConditions
        return BackupScanner(source: source, service: service, index: index, network: network, settings: settings)
    }

    private func refreshCounts() async {
        // A scan that started or finished meanwhile has newer counts than this one will bring.
        let before = generation
        let scanner = await makeScanner()
        let fresh = await scanner.counts()
        guard before == generation else { return }
        counts = fresh
        await refreshLists()
    }

    /// Reads the failed and deleted-on-server items in one pass over the index. Only the newest call
    /// publishes: a slower, older one is discarded.
    private func refreshLists() async {
        listsRevision += 1
        let revision = listsRevision
        let wantsFailed = counts.failed > 0
        let wantsDeleted = counts.deletedOnServer > 0
        var failed: [FailedItem] = []
        var deleted: [(id: String, entry: BackupEntry)] = []
        if wantsFailed || wantsDeleted {
            let entries = await currentEntries {
                (wantsFailed && Self.isFailed($0)) || (wantsDeleted && Self.isDeletedOnServer($0))
            }
            failed = entries.compactMap { id, entry in
                guard case let .failed(reason) = entry.state else { return nil }
                return FailedItem(id: id, reason: reason)
            }
            // The newest edits first, so the limit keeps those.
            deleted = entries.filter { Self.isDeletedOnServer($0.entry) }
                .sorted {
                    $0.entry.modificationDate != $1.entry.modificationDate
                        ? $0.entry.modificationDate > $1.entry.modificationDate : $0.id < $1.id
                }
            deleted = Array(deleted.prefix(Self.deletedItemLimit))
        }
        guard revision == listsRevision else { return }
        let shownFailed = Array(failed.prefix(Self.failedItemLimit))
        if failedItems != shownFailed { failedItems = shownFailed }

        let known = Dictionary(deletedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let created = Dictionary(
            await source.assets(deleted.map(\.id).filter { known[$0] == nil }).map { ($0.id, $0.creationDate) },
            uniquingKeysWith: { first, _ in first })
        guard revision == listsRevision else { return }
        let items: [DeletedItem] = deleted.compactMap { id, entry in
            guard case let .deletedOnServer(trashed, gone) = entry.state else { return nil }
            // Every missing copy is in the trash: it can be restored without uploading anything.
            return DeletedItem(id: id, date: known[id]?.date ?? created[id], isTrashed: !trashed.isEmpty && gone.isEmpty)
        }.sorted {
            switch ($0.date, $1.date) {
            case let (a?, b?) where a != b: a > b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.id < $1.id
            }
        }
        if deletedItems != items { deletedItems = items }
        // Thumbnails of rows that are gone aren't needed any more.
        let shown = Set(items.map(\.id))
        thumbnailCache = thumbnailCache.filter { shown.contains($0.key) }
        thumbnailMisses.formIntersection(shown)
    }

    /// The entries of the selected photos that satisfy `isIncluded`, in ID order, left out when the photo
    /// changed since the entry was recorded or is gone (`counts()` treats those as not checked yet).
    private func currentEntries(where isIncluded: (BackupEntry) -> Bool) async -> [(id: String, entry: BackupEntry)] {
        let index = await ensureIndex()
        let ids = await index.selection().assetIDs(in: source)
        let candidates = await index.entries(where: isIncluded, in: ids, limit: .max).sorted { $0.0 < $1.0 }
        var result: [(id: String, entry: BackupEntry)] = []
        for start in stride(from: 0, to: candidates.count, by: 500) {
            let chunk = candidates[start..<min(start + 500, candidates.count)]
            let dates = await source.modificationDates(chunk.map(\.0))
            for (id, entry) in chunk where dates[id] == entry.modificationDate { result.append((id, entry)) }
        }
        return result
    }

    private static func isFailed(_ entry: BackupEntry) -> Bool {
        if case .failed = entry.state { true } else { false }
    }

    private static func isDeletedOnServer(_ entry: BackupEntry) -> Bool {
        if case .deletedOnServer = entry.state { true } else { false }
    }

    // MARK: - Thumbnails

    /// The thumbnail of a Deleted on Server row, decoded off the main actor and kept for later rows and
    /// refreshes. Photos without one (gone from the iPhone, say) are remembered, not asked for again.
    func thumbnail(for id: String) async -> CGImage? {
        if let image = thumbnailCache[id] { return image }
        if thumbnailMisses.contains(id) { return nil }
        guard let data = await source.thumbnailData(id, pixelSide: Self.thumbnailPixelSide) else {
            thumbnailMisses.insert(id)
            return nil
        }
        let image = await Task.detached { Self.decode(data) }.value
        if let image { thumbnailCache[id] = image } else { thumbnailMisses.insert(id) }
        return image
    }

    private nonisolated static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    // MARK: - Try Again and Re-upload

    /// Sends failed items back to the queue; they are checked and uploaded by the next run. Never throws:
    /// a stopped or cancelled retry just leaves them as they were.
    func retry(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        workingCount += 1
        defer { workingCount -= 1 }
        // The runner refreshes the counts and lists when it is done. A retry that was cancelled before it
        // started changed nothing.
        await runner.retryFailed(ids)
    }

    /// Try Again for every failed item, not just the ones on screen.
    func retryAll() async {
        let ids = await currentEntries(where: Self.isFailed).map(\.id)
        await retry(ids)
    }

    /// Re-upload for items deleted on the server: copies in the server's trash are restored, missing ones
    /// are uploaded (see `BackupUploader.reupload`). Failures are shown in `error`, a cancelled one is not.
    func reupload(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        workingCount += 1
        defer { workingCount -= 1 }
        error = nil
        do {
            try await runner.reupload(ids)
            isWaitingForNetwork = false
        } catch is CancellationError {
            // The user left the foreground, turned the switch off or signed out: nothing to report.
        } catch ImmichServiceError.editingOff {
            error = tr("Turn on Allow Changes in the account menu to restore photos from the server's trash.")
        } catch {
            report(error, uploading: true)
        }
        // The runner refreshes the counts and lists after the uploader ran, also when it failed. A call
        // cancelled before it started changed nothing.
    }

    /// Re-upload for every item deleted on the server, not just the ones on screen.
    func reuploadAll() async {
        let ids = await currentEntries(where: Self.isDeletedOnServer).map(\.id)
        await reupload(ids)
    }
}

// MARK: - Preview data

extension BackupModel {
    /// For previews: records items as deleted on the server and as failed in the index, then loads, so the
    /// Deleted on Server and Problems rows and lists have something to show. The first deleted item is in
    /// the server's trash, the rest are gone for good.
    func loadPreview(deletedOnServer: Int = 0, problems: Int = 0) async {
        let index = await ensureIndex()
        let date = PreviewPhotoLibrary.date
        for number in 0..<deletedOnServer {
            let state: BackupState = number % 2 == 0
                ? .deletedOnServer(trashed: [.photo], gone: [])
                : .deletedOnServer(trashed: [], gone: [.photo])
            await index.set(
                BackupEntry(modificationDate: date, checksums: [.photo: "preview-\(number)"], state: state),
                for: "preview-\(number)")
        }
        let reasons = ["Couldn't read IMG_0012.HEIC: the file is in iCloud", "The server refused IMG_0031.MOV"]
        for number in 0..<problems {
            let id = "preview-\(30 + number)"
            await index.set(
                BackupEntry(modificationDate: date, checksums: [:], state: .failed(reason: reasons[number % reasons.count])),
                for: id)
        }
        await load()
    }
}

// MARK: - Preview source

/// A small, fixed photo library for previews and the demo session. Never touches PhotoKit.
struct PreviewPhotoLibrary: PhotoLibrarySource {
    var access: PhotoAccess = .full
    var photoCount = 40

    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private var allIDs: [String] { (0..<photoCount).map { "preview-\($0)" } }

    func authorization() async -> PhotoAccess { access }
    func requestAuthorization() async -> PhotoAccess { access }

    func albums() async -> [DeviceAlbum] {
        [
            DeviceAlbum(id: "recents", title: "Recents", count: photoCount + 1),
            DeviceAlbum(id: "favorites", title: "Favorites", count: 6),
            DeviceAlbum(id: "screenshots", title: "Screenshots", count: 8),
            DeviceAlbum(id: "holiday", title: "Holiday", count: 12),
        ]
    }

    func assetIDs(inAlbum id: String) async -> Set<String> {
        switch id {
        case "recents": Set(allIDs + ["preview-empty"])
        case "favorites": Set(allIDs.prefix(6))
        case "screenshots": Set(allIDs.suffix(8))
        case "holiday": Set(allIDs.dropFirst(10).prefix(12))
        default: []
        }
    }

    func asset(_ id: String) async -> DeviceAsset? { await assets([id]).first }

    func assets(_ ids: [String]) async -> [DeviceAsset] {
        ids.map { id in
            let resources = id == "preview-empty" ? [] : [DeviceResource(type: .photo, filename: "\(id).jpg")]
            return DeviceAsset(
                id: id, isVideo: false, creationDate: Self.date, modificationDate: Self.date,
                isFavorite: false, duration: 0, resources: resources)
        }
    }

    func modificationDates(_ ids: [String]) async -> [String: Date] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.date) })
    }

    func read(
        _ resource: DeviceResource, of assetID: String, allowNetwork: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        onData(Data(resource.filename.utf8))
    }

    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    func thumbnailData(_ id: String, pixelSide: Int) async -> Data? { nil }
}
