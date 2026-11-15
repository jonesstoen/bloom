import Foundation
import ImageIO
import ImmichKit
import Observation
import os
#if os(iOS)
import UIKit
#endif

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
        /// When the photo was taken, if the photo library still has it: helps to find it in Photos.
        var date: Date?
    }

    /// An item the server had once and no longer has (see `BackupState.deletedOnServer`).
    struct DeletedItem: Identifiable, Equatable {
        let id: String
        /// When the photo was taken, if the photo library still has it.
        let date: Date?
        /// Every missing copy is in the server's trash (so "In the Trash"); else at least one is gone for good.
        let isTrashed: Bool
    }

    /// An item still to back up, with where it stands (see `BackupModel.remainingItems`).
    struct RemainingItem: Identifiable, Equatable {
        enum Status: Equatable {
            /// In flight in the transport.
            case uploading
            /// Queued; the next run sends it.
            case waiting
            case waitingForWiFi
            case notChecked
            /// A try failed in a way trying again can fix; the next try is not before `at`. `failures` in a row so
            /// far, and why the last one failed when known (see `retryReason`).
            case retrying(at: Date, failures: Int, reason: String?)
        }

        let id: String
        /// When the photo was taken, if the photo library still has it.
        let date: Date?
        let status: Status
    }

    /// The photo a scan is reading (and maybe downloading from iCloud) to hash it, for "Checking Now".
    struct CheckingItem: Equatable {
        let id: String
        /// When the photo was taken, if the photo library still has it.
        let date: Date?
    }

    /// The remaining items of one state, a section of the Remaining list (see `remainingSections`).
    struct RemainingSection: Identifiable, Equatable {
        /// The states in the order the list shows them.
        enum Kind: Int, CaseIterable, Equatable {
            case uploading, waiting, waitingForWiFi, retrying, notChecked
        }

        let kind: Kind
        /// Newest first.
        let items: [RemainingItem]
        var id: Kind { kind }
    }

    /// What `refreshLists()` read of a remaining item: its status is worked out from this when it is shown,
    /// since in-flight uploads and retry times change between index passes.
    private struct RemainingBase: Equatable {
        let id: String
        let date: Date?
        let reason: PendingReason
        let retry: BackupRetryState?
    }

    enum AlbumState { case included, excluded, neither }

    /// How this account's uploads are sent: the request builder and the transport, made once from the
    /// model's index, staging folder and result recorder. Without it (previews, tests that only scan) scans
    /// run but nothing is uploaded.
    struct Uploads {
        let requests: BackupUploadRequests
        let makeTransport: @Sendable (BackupIndex, BackupStaging, BackupResultRecorder) -> any BackupTransport
    }

    /// The most failed items listed on screen.
    static let failedItemLimit = 50
    /// The most deleted-on-server items listed on screen.
    static let deletedItemLimit = 200
    /// The most remaining items listed on screen.
    static let remainingItemLimit = 200
    /// Pixel side of the thumbnails in the Remaining and Deleted on Server lists.
    static let thumbnailPixelSide = 160

    private(set) var access: PhotoAccess?
    private(set) var counts = BackupCounts()
    /// Non-nil while a scan runs.
    private(set) var progress: Progress?
    /// The scan waits for a background run to finish before it starts (see `BackupGate`).
    private(set) var isWaitingForBackgroundRun = false
    /// The photo the running scan reads now, at most four changes a second; nil when no scan has read
    /// anything for about a second (it may still be asking the server about photos it read before).
    private(set) var checkingItem: CheckingItem?
    private(set) var isScanning = false
    private(set) var albums: [DeviceAlbum] = []
    private(set) var selection = BackupSelection()
    private(set) var failedItems: [FailedItem] = []
    /// The first `deletedItemLimit` items deleted on the server, newest first. `counts.deletedOnServer` has the total.
    private(set) var deletedItems: [DeletedItem] = []
    /// The `remainingItemLimit` items still to back up that were edited last, shown newest first (by the date
    /// taken), each with its state. The cut is by latest edit, which is cheap and needs no asset fetch for
    /// the items cut. `remainingTotal` has the total.
    private(set) var remainingItems: [RemainingItem] = []
    /// How many items are still to back up as the last pass found them (all of them, not just the listed ones).
    private(set) var remainingTotal = 0
    /// How far each upload in flight has got, by asset ID. A separate observable, so the fast progress
    /// updates (`refreshUploadProgress()`) only redraw the views that read it.
    @ObservationIgnored let uploadProgress = BackupUploadProgress()
    private(set) var error: String?
    /// The last scan or upload stopped because the server couldn't be reached (offline, VPN off, server
    /// down). Shown as `connectionStatus` instead of `error`; cleared when a scan or upload run gets through.
    /// The runner tries again when the network comes back.
    private(set) var cannotReachServer = false

    enum ConnectionStatus: Equatable {
        /// The device has no network: the runner carries on when it is back.
        case waitingForNetwork
        /// The device has a network but the server didn't answer, or nothing watches the network (the
        /// Backup switch is off).
        case serverUnreachable
    }

    /// What the screen says about `cannotReachServer`. "Waiting" only while the switch is on and the runner
    /// sees no network, since only then does anything wait.
    var connectionStatus: ConnectionStatus? {
        guard cannotReachServer else { return nil }
        return settings.isEnabled && madeRunner?.isOffline == true ? .waitingForNetwork : .serverUnreachable
    }
    /// Uploads iOS is sending (or has queued) for this account, including while Bloom is closed. Read by
    /// `refreshBackgroundStatus()`.
    private(set) var inFlightCount = 0
    /// When an upload last reached the server (the index's `lastSuccess`); `nil` before the first.
    private(set) var lastBackup: Date?
    /// The transport saw an upload redirected to another address and sends nothing until the server answers
    /// at its own address again.
    private(set) var isRedirectBlocked = false
    /// Background App Refresh is off for Bloom (set from `backgroundRefreshIsDenied`).
    private(set) var isBackgroundRefreshOff = false
    /// Whether the user has turned Background App Refresh off for Bloom. Injected so tests can set it;
    /// the live value asks iOS (always `false` elsewhere).
    @ObservationIgnored var backgroundRefreshIsDenied: @MainActor () -> Bool = {
        #if os(iOS)
        UIApplication.shared.backgroundRefreshStatus == .denied
        #else
        false
        #endif
    }
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
            if (oldValue.photosOnCellular && !settings.photosOnCellular)
                || (oldValue.videosOnCellular && !settings.videosOnCellular) {
                cancelUploadsNotAllowedOnCellular(by: new)
            }
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
    /// Decoded thumbnails of the Remaining and Deleted on Server rows, by asset ID, and the IDs that had none.
    @ObservationIgnored private var thumbnailCache: [String: CGImage] = [:]
    @ObservationIgnored private var thumbnailMisses: Set<String> = []
    /// Clears `checkingItem` a moment after the last read ended, unless another read starts first.
    @ObservationIgnored private var checkingClear: Task<Void, Never>?
    /// The remaining items as the last index pass read them, and the assets the transport has in flight
    /// (`refreshBackgroundStatus()`); `remainingItems` is made from both.
    @ObservationIgnored private var remainingBase: [RemainingBase] = []
    @ObservationIgnored private var inFlightJobs: [UploadJob] = []
    /// The last bytes the transport reported of each in-flight attempt. A finished attempt stops reporting
    /// before the job list is read again; its last bytes count until it leaves the list.
    @ObservationIgnored private var lastUploadBytes: [UUID: UploadBytes] = [:]
    /// Previews only: stands in for the account's transport when reading what is in flight.
    @ObservationIgnored private var previewTransport: (any BackupTransport)?
    @ObservationIgnored private var uploadingIDs: Set<String> = []
    /// The in-flight assets the last `refreshLists()` kept in the list, so a new one can trigger a pass.
    @ObservationIgnored private var listedInFlightIDs: Set<String> = []
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
    /// The account's `Staging` folder, where the uploader stages each resource's upload body.
    @ObservationIgnored let staging: BackupStaging
    @ObservationIgnored private let uploads: Uploads?
    @ObservationIgnored private var connection: BackupUploadConnection?
    /// The account's backup engine, when the model works on one: its index, staging folder, transport and
    /// uploader are the ones background launches use too (see `BackupEngine`).
    @ObservationIgnored let engine: BackupEngine?
    /// `load()` has run: the selection and photo access on the model are known.
    @ObservationIgnored private(set) var hasLoaded = false

    /// - Parameters:
    ///   - directory: where the account's `index.json` lives; the index is opened on first use.
    ///   - network: defaults to a path monitor, started when the first scan needs it.
    ///   - uploads: how uploads are sent; without it nothing is uploaded.
    convenience init(
        source: some PhotoLibrarySource,
        service: any ImmichService,
        directory: URL,
        network: (any NetworkConditions)? = nil,
        defaults: UserDefaults = .standard,
        uploads: Uploads? = nil
    ) {
        self.init(
            source: source, service: service, directory: directory, network: network, defaults: defaults,
            uploads: uploads, engine: nil)
    }

    /// The account's Backup screen on its engine: the engine's photo library, server, network, index, staging
    /// folder, transport and uploader. `defaults` must be where the engine reads the switches from.
    convenience init(engine: BackupEngine, defaults: UserDefaults = .standard) {
        self.init(
            source: engine.source, service: engine.service, directory: engine.directory, network: engine.network,
            defaults: defaults, uploads: nil, engine: engine)
    }

    private init(
        source: any PhotoLibrarySource, service: any ImmichService, directory: URL, network: (any NetworkConditions)?,
        defaults: UserDefaults, uploads: Uploads?, engine: BackupEngine?
    ) {
        self.source = source
        self.service = service
        self.directory = directory
        self.network = network
        self.defaults = defaults
        self.uploads = uploads
        self.engine = engine
        let settings = BackupSettings.load(from: defaults)
        self.settings = settings
        sharedSettings = OSAllocatedUnfairLock(initialState: settings)
        if let engine {
            staging = engine.staging
        } else {
            let stagingDirectory = directory.appendingPathComponent("Staging", isDirectory: true)
            staging = BackupStaging(
                directory: stagingDirectory, freeSpace: { BackupStaging.availableCapacity(at: stagingDirectory) })
        }
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
        // One uploader per account: background runs use it too, and a second run waits its turn.
        if let engine { return engine.uploader }
        let index = await ensureIndex()
        let connection = await uploadConnection(clock: clock)
        let network = networkConditions
        let settings = sharedSettings
        return BackupUploader(
            source: source, service: service, index: index, staging: staging,
            settings: { settings.withLock { $0 } }, network: network, clock: clock, connection: connection)
    }

    /// The account's transport, its result recorder and request builder, made on first use; nil without
    /// `uploads`. `clock` dates the retry times the recorder keeps (the first caller's is used). On an engine,
    /// the engine's. Once stopped, only one made before: a transport is never made just to be cancelled.
    func uploadConnection(clock: BackupRetryClock = .live) async -> BackupUploadConnection? {
        if let engine { return engine.connection }
        guard let uploads, !isStopped else { return connection }
        let index = await ensureIndex()
        if let connection { return connection }
        guard !isStopped else { return nil }
        let recorder = BackupResultRecorder(index: index, staging: staging, now: clock.date)
        let made = BackupUploadConnection(
            transport: uploads.makeTransport(index, staging, recorder), recorder: recorder, requests: uploads.requests)
        connection = made
        return made
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
            remainingBase = []
            remainingItems = []
            remainingTotal = 0
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
        let engine = engine
        scanTask = Task { [weak self] in
            var result: BackupCounts?
            var failure: Error?
            // On an engine, one scan or upload run at a time: a background run waits (or gives up) meanwhile.
            if await engine?.gate.isHeldByBackgroundRun == true { self?.isWaitingForBackgroundRun = true }
            let entered = await engine?.gate.acquire() ?? true
            self?.isWaitingForBackgroundRun = false
            guard entered else {
                await self?.finishScan(result: nil, failure: CancellationError())
                return false
            }
            // Read before the scan: whatever changes during it is found by the next background refresh.
            let token = await engine?.source.changedAssetIDs(since: nil).token
            // A single consumer with one pending snapshot avoids a task backlog for large libraries.
            let (updates, continuation) = AsyncStream<(BackupCounts, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let delivery = Task { [weak self] in
                for await (counts, handled) in updates {
                    self?.apply(counts, handled: handled, generation: current)
                }
            }
            // The photo being read: only the newest is kept, shown at most every 250 ms.
            let (reads, readContinuation) = AsyncStream<(id: String, date: Date)?>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            let readDelivery = Task { [weak self] in
                for await item in reads {
                    guard !Task.isCancelled else { break }
                    self?.showChecking(item, generation: current)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                result = try await scanner.scan(reading: { readContinuation.yield($0) }) { counts, handled in
                    continuation.yield((counts, handled))
                }
            } catch {
                failure = error
            }
            // A full scan got through: the next refresh only checks what changed after the token.
            if result != nil { engine?.storeChangeToken(token) }
            await engine?.gate.release()
            continuation.finish()
            readContinuation.finish()
            readDelivery.cancel()
            await delivery.value
            await readDelivery.value
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
        // Uploads too (also those the system was sending); the runner then empties the staging folder.
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
    func uploadRunSucceeded() { cannotReachServer = false }

    /// An upload run stopped on something every item would run into: shown like a scan's error.
    func reportUploadFailure(_ failure: Error) {
        switch failure {
        case is CancellationError: return
        case BackupStagingError.notEnoughSpace:
            // The item is listed under Problems with Bloom's reason; this explains why the run stopped.
            cannotReachServer = false
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

    /// Shows `item` as the photo being checked, if the scan of `current` still runs. A read that ended (nil)
    /// clears it only when no other read starts within a second, so it doesn't flicker between photos. The
    /// photo it replaces gives up its thumbnail unless a list shows it, so a long scan doesn't keep one per photo.
    private func showChecking(_ item: (id: String, date: Date)?, generation current: Int) {
        guard isScanning, current == generation else { return }
        guard let item else {
            guard checkingItem != nil, checkingClear == nil else { return }
            checkingClear = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.checkingClear = nil
                guard current == self.generation, let shown = self.checkingItem?.id else { return }
                self.checkingItem = nil
                self.forgetThumbnailIfUnlisted(shown)
            }
            return
        }
        checkingClear?.cancel()
        checkingClear = nil
        guard checkingItem?.id != item.id else { return }
        let previous = checkingItem?.id
        checkingItem = CheckingItem(id: item.id, date: item.date)
        if let previous { forgetThumbnailIfUnlisted(previous) }
    }

    private func forgetThumbnailIfUnlisted(_ id: String) {
        guard !remainingBase.contains(where: { $0.id == id }), !deletedItems.contains(where: { $0.id == id }),
              !failedItems.contains(where: { $0.id == id }) else { return }
        thumbnailCache[id] = nil
        thumbnailMisses.remove(id)
    }

    private func finishScan(result: BackupCounts?, failure: Error?) async {
        if let failure, !(failure is CancellationError) { report(failure) }
        // Before the first await: a late progress callback must not bring `progress` back or
        // overwrite the final counts.
        generation += 1
        progress = nil
        checkingClear?.cancel()
        checkingClear = nil
        if let checked = checkingItem?.id {
            checkingItem = nil
            forgetThumbnailIfUnlisted(checked)
        }
        if let result {
            counts = result
            completedScans += 1
            cannotReachServer = false
        } else { await refreshCounts() }
        await refreshLists()
        scanTask = nil
        isScanning = false
    }

    /// No connection to the server becomes the waiting status (leaving any other error as it is); any
    /// other failure becomes `error`.
    private func report(_ failure: Error, uploading: Bool = false) {
        if ImmichServiceError.isConnectivityFailure(failure) {
            cannotReachServer = true
            return
        }
        cannotReachServer = false
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
        if let engine { return engine.index }
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

    /// Reads what the background upload session is doing: the uploads in flight, the redirect block, the time
    /// of the last success and the Background App Refresh setting. The screen calls it every few seconds.
    func refreshBackgroundStatus() async {
        guard !isStopped else { return }
        isBackgroundRefreshOff = backgroundRefreshIsDenied()
        let index = await ensureIndex()
        let last = await index.lastSuccess
        if last != lastBackup { lastBackup = last }
        guard let transport = await statusTransport() else {
            inFlightCount = 0
            isRedirectBlocked = false
            inFlightJobs = []
            uploadingIDs = []
            publishRemaining()
            if !uploadProgress.fractions.isEmpty { uploadProgress.fractions = [:] }
            return
        }
        let jobs = await transport.inFlight()
        let count = jobs.count
        let blocked = transport.isRedirectBlocked
        inFlightJobs = jobs
        uploadingIDs = Set(jobs.map(\.assetID))
        // An upload of an item the last pass cut from the list: a new pass keeps it (in-flight rows are never cut).
        if counts.pending > 0, !uploadingIDs.isSubset(of: listedInFlightIDs.union(remainingBase.map(\.id))) {
            // Marked before the pass, so a pass that is discarded or doesn't find them doesn't fire again.
            listedInFlightIDs.formUnion(uploadingIDs)
            await refreshLists()
        }
        publishRemaining()
        if count != inFlightCount { inFlightCount = count }
        if blocked != isRedirectBlocked { isRedirectBlocked = blocked }
    }

    /// The transport whose uploads in flight and progress the screen shows.
    private func statusTransport() async -> (any BackupTransport)? {
        if let previewTransport { return previewTransport }
        return await uploadConnection()?.transport
    }

    /// The latest `cancelUploadsNotAllowedOnCellular`, kept so tests can wait for it.
    @ObservationIgnored private(set) var cellularCancel: Task<Void, Never>?

    /// A cellular switch was turned off: the uploads in flight that were sent with cellular access and that
    /// `settings` no longer allow on cellular are cancelled (their items go back to the queue through the
    /// recorder's cancelled path, and the next run sends them without cellular access).
    private func cancelUploadsNotAllowedOnCellular(by settings: BackupSettings) {
        let previous = cellularCancel
        let source = source
        cellularCancel = Task { [weak self] in
            await previous?.value
            guard let transport = await self?.uploadConnection()?.transport else { return }
            var attempts: Set<UUID> = []
            for job in await transport.inFlight() where job.allowsCellular {
                if let asset = await source.asset(job.assetID), !settings.allowsNetwork(for: asset, onCellular: true) {
                    attempts.insert(job.attempt)
                }
            }
            if !attempts.isEmpty { await transport.cancel(attempts: attempts) }
        }
    }

    /// The user's Try Again under the redirect message: lifts the block (only ever done by the user, as a
    /// proxy may redirect just the uploads) and starts a run, which checks the server again before it sends.
    func retryAfterRedirect() async {
        guard !isStopped, let transport = await uploadConnection()?.transport else { return }
        transport.clearRedirectBlock()
        isRedirectBlocked = false
        runner.checkNow()
    }

    /// New counts and lists from one pass over the selection.
    private func refreshCounts() async {
        await refreshLists(updatingCounts: true)
    }

    /// Reads the counts and the failed, deleted-on-server and remaining items in one pass over the selection
    /// (`survey`). Only the newest call publishes: a slower, older one is discarded. The counts are published
    /// only with `updatingCounts`, and not when a scan started or finished meanwhile (it brings newer ones).
    private func refreshLists(updatingCounts: Bool = false) async {
        listsRevision += 1
        let revision = listsRevision
        let before = generation
        let inFlight = uploadingIDs
        let survey = await survey(keeping: inFlight)
        guard revision == listsRevision else { return }
        if updatingCounts, before == generation, counts != survey.counts { counts = survey.counts }
        let failed = survey.failed.compactMap { id, entry -> FailedItem? in
            guard case let .failed(reason) = entry.state else { return nil }
            return FailedItem(id: id, reason: reason)
        }
        // The newest edits first, so the limit keeps those.
        let deleted = Array(survey.deleted
            .sorted { Self.isNewerEdit(($0.id, $0.entry.modificationDate), ($1.id, $1.entry.modificationDate)) }
            .prefix(Self.deletedItemLimit))
        let remaining = survey.remaining
        var shownFailed = Array(failed.prefix(Self.failedItemLimit))
        let knownFailed = Dictionary(failedItems.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        let createdFailed = Dictionary(
            await source.assets(shownFailed.map(\.id).filter { knownFailed[$0] == nil }).map { ($0.id, $0.creationDate) },
            uniquingKeysWith: { first, _ in first })
        guard revision == listsRevision else { return }
        for i in shownFailed.indices {
            shownFailed[i].date = knownFailed[shownFailed[i].id] ?? createdFailed[shownFailed[i].id]
        }
        if failedItems != shownFailed { failedItems = shownFailed }

        let known = Dictionary(deletedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownRemaining = Dictionary(remainingBase.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        let created = Dictionary(
            await source.assets(deleted.map(\.id).filter { known[$0] == nil }).map { ($0.id, $0.creationDate) },
            uniquingKeysWith: { first, _ in first })
        let createdRemaining = Dictionary(
            await source.assets(remaining.items.map(\.id).filter { knownRemaining[$0] == nil }).map { ($0.id, $0.creationDate) },
            uniquingKeysWith: { first, _ in first })
        guard revision == listsRevision else { return }
        let items: [DeletedItem] = deleted.compactMap { id, entry in
            guard case let .deletedOnServer(trashed, gone) = entry.state else { return nil }
            // Every missing copy is in the trash: it can be restored without uploading anything.
            return DeletedItem(id: id, date: known[id]?.date ?? created[id], isTrashed: !trashed.isEmpty && gone.isEmpty)
        }.sorted { Self.isNewer(($0.id, $0.date), ($1.id, $1.date)) }
        if deletedItems != items { deletedItems = items }
        let bases: [RemainingBase] = remaining.items.map { item in
            RemainingBase(
                id: item.id, date: knownRemaining[item.id] ?? createdRemaining[item.id], reason: item.reason,
                retry: item.retry)
        }.sorted { Self.isNewer(($0.id, $0.date), ($1.id, $1.date)) }
        if remainingBase != bases { remainingBase = bases }
        if remainingTotal != remaining.total { remainingTotal = remaining.total }
        listedInFlightIDs = inFlight
        publishRemaining()
        // Thumbnails of rows that are gone aren't needed any more.
        let shown = Set(items.map(\.id)).union(bases.map(\.id)).union(shownFailed.map(\.id))
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

    /// An item still to back up, as the index pass found it.
    private struct PendingItem {
        let id: String
        let reason: PendingReason
        let retry: BackupRetryState?
    }

    /// What one pass over the selection found (see `survey(keeping:)`).
    private struct Survey {
        var counts = BackupCounts()
        /// The items still to back up, cut to `remainingItemLimit`, with the total before the cut.
        var remaining: (total: Int, items: [PendingItem]) = (0, [])
        /// Current failed entries, in ID order.
        var failed: [(id: String, entry: BackupEntry)] = []
        /// Current deleted-on-server entries, in ID order.
        var deleted: [(id: String, entry: BackupEntry)] = []
    }

    /// One pass over the selected photos: their modification dates and index entries, read in chunks of 500.
    /// Counts exactly as `BackupScanner.counts()` does: an entry recorded for the photo as it is now counts in
    /// its state; no entry or a stale one (changed since it was recorded) counts as not checked yet; a photo
    /// gone from the library isn't counted. The remaining items are the newest edits first, cut at
    /// `remainingItemLimit` (the items in `keeping`, those in flight, are never cut: the others make room).
    private func survey(keeping: Set<String>) async -> Survey {
        let index = await ensureIndex()
        let ids = await index.selection().assetIDs(in: source).sorted()
        var survey = Survey()
        var found: [(id: String, modified: Date, item: PendingItem)] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let dates = await source.modificationDates(chunk)
            let entries = Dictionary(
                await index.entries(where: { _ in true }, in: Set(chunk), limit: .max), uniquingKeysWith: { first, _ in first })
            for id in chunk {
                guard let modified = dates[id] else { continue }
                guard let entry = entries[id], entry.modificationDate == modified else {
                    survey.counts.add(.pending(reason: .notChecked))
                    found.append((id, modified, PendingItem(id: id, reason: .notChecked, retry: nil)))
                    continue
                }
                survey.counts.add(entry.state)
                switch entry.state {
                case let .pending(reason):
                    found.append((id, modified, PendingItem(id: id, reason: reason, retry: entry.retry)))
                case .failed: survey.failed.append((id, entry))
                case .deletedOnServer: survey.deleted.append((id, entry))
                case .backedUp: break
                }
            }
        }
        let newest = found.sorted { Self.isNewerEdit(($0.id, $0.modified), ($1.id, $1.modified)) }
        let kept = newest.filter { keeping.contains($0.id) }.map(\.item)
        let others = newest.filter { !keeping.contains($0.id) }.prefix(max(0, Self.remainingItemLimit - kept.count))
        survey.remaining = (found.count, kept + others.map(\.item))
        return survey
    }

    /// The order of lists cut to a limit: the later edit first, ties by ID.
    private static func isNewerEdit(_ a: (id: String, date: Date), _ b: (id: String, date: Date)) -> Bool {
        a.date != b.date ? a.date > b.date : a.id < b.id
    }

    /// The order of rows: the later date first, rows without a date last, ties by ID.
    private static func isNewer(_ a: (id: String, date: Date?), _ b: (id: String, date: Date?)) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?) where x != y: x > y
        case (_?, nil): true
        case (nil, _?): false
        default: a.id < b.id
        }
    }

    /// Makes `remainingItems` from the last index pass and the uploads in flight, assigning only when it
    /// changed. A retry time that has passed no longer counts.
    private func publishRemaining(now: Date = Date()) {
        let items = remainingBase.map { base in
            let status: RemainingItem.Status
            if uploadingIDs.contains(base.id) {
                status = .uploading
            } else if let retry = base.retry, retry.notBefore > now {
                status = .retrying(at: retry.notBefore, failures: retry.failures, reason: Self.retryReason(retry))
            } else {
                switch base.reason {
                case .needsUpload: status = .waiting
                case .waitingForWiFi: status = .waitingForWiFi
                case .notChecked: status = .notChecked
                }
            }
            return RemainingItem(id: base.id, date: base.date, status: status)
        }
        if remainingItems != items { remainingItems = items }
    }

    /// Why an item waits to be tried again: no connection, else what the last failure said (nil when unknown).
    static func retryReason(_ retry: BackupRetryState) -> String? {
        retry.wasOffline ? tr("No connection to the server.") : retry.lastError
    }

    /// `remainingItems` grouped by state, in the list's order, without empty sections.
    var remainingSections: [RemainingSection] { Self.remainingSections(remainingItems) }

    /// The list shows fewer items than remain (its footer says so).
    var isRemainingCut: Bool { remainingTotal > remainingItems.count }

    /// The share of the selection on the server, of what is on it or still to back up; nil when nothing
    /// remains.
    var backedUpFraction: Double? {
        guard counts.pending > 0 else { return nil }
        return Double(counts.backedUp) / Double(counts.backedUp + counts.pending)
    }

    /// Groups items into sections in `RemainingSection.Kind` order, each newest first (by date taken,
    /// undated last), leaving out empty ones.
    static func remainingSections(_ items: [RemainingItem]) -> [RemainingSection] {
        let grouped = Dictionary(grouping: items) { item -> RemainingSection.Kind in
            switch item.status {
            case .uploading: .uploading
            case .waiting: .waiting
            case .waitingForWiFi: .waitingForWiFi
            case .retrying: .retrying
            case .notChecked: .notChecked
            }
        }
        return RemainingSection.Kind.allCases.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return RemainingSection(kind: kind, items: items.sorted { isNewer(($0.id, $0.date), ($1.id, $1.date)) })
        }
    }

    /// How far each asset's upload has got, from the transport's bytes by attempt. The halves of a Live
    /// Photo (or any asset with several jobs) make one fraction: by bytes when every job knows its size,
    /// otherwise the mean of the jobs' fractions, a job without one counting as nothing sent. An asset none
    /// of whose jobs has reported a fraction is left out (its row shows indeterminate progress).
    static func uploadFractions(jobs: [UploadJob], progress: [UUID: UploadBytes]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (asset, assetJobs) in Dictionary(grouping: jobs, by: \.assetID) {
            let reports = assetJobs.map { progress[$0.attempt] }
            guard reports.contains(where: { $0?.fraction != nil }) else { continue }
            let sized = reports.compactMap { $0 }.filter { $0.expected > 0 }
            if sized.count == reports.count {
                let sent = sized.reduce(0.0) { $0 + Double(min($1.sent, $1.expected)) }
                let expected = sized.reduce(0.0) { $0 + Double($1.expected) }
                result[asset] = min(1, max(0, sent / expected))
            } else {
                result[asset] = reports.reduce(0.0) { $0 + ($1?.fraction ?? 0) } / Double(reports.count)
            }
        }
        return result
    }

    /// Progress shown never goes back while an asset stays in flight: a finished half of a Live Photo, or a
    /// finished asset, stops reporting before the job list is read again. Assets no longer in flight are dropped.
    private static func monotonicFractions(
        old: [String: Double], new: [String: Double], inFlight: Set<String>
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for id in inFlight {
            switch (old[id], new[id]) {
            case let (before?, now?): result[id] = max(before, now)
            case let (before?, nil): result[id] = before
            case let (nil, now?): result[id] = now
            case (nil, nil): break
            }
        }
        return result
    }

    /// Reads the transport's progress for the uploads in flight (as the last `refreshBackgroundStatus()`
    /// found them) into `uploadProgress`. Cheap: the Remaining list calls it a few times a second.
    func refreshUploadProgress() async {
        guard !isStopped, !inFlightJobs.isEmpty, let transport = await statusTransport() else {
            lastUploadBytes = [:]
            if !uploadProgress.fractions.isEmpty { uploadProgress.fractions = [:] }
            return
        }
        let attempts = Set(inFlightJobs.map(\.attempt))
        var bytes = lastUploadBytes.filter { attempts.contains($0.key) }
        for (attempt, reported) in transport.uploadProgress() where attempts.contains(attempt) { bytes[attempt] = reported }
        lastUploadBytes = bytes
        let fresh = Self.uploadFractions(jobs: inFlightJobs, progress: bytes)
        let fractions = Self.monotonicFractions(old: uploadProgress.fractions, new: fresh, inFlight: uploadingIDs)
        if uploadProgress.fractions != fractions { uploadProgress.fractions = fractions }
    }

    private static func isFailed(_ entry: BackupEntry) -> Bool {
        if case .failed = entry.state { true } else { false }
    }

    private static func isDeletedOnServer(_ entry: BackupEntry) -> Bool {
        if case .deletedOnServer = entry.state { true } else { false }
    }

    // MARK: - Thumbnails

    /// The thumbnail of a Remaining or Deleted on Server row, decoded off the main actor and kept for later rows and
    /// refreshes. Photos without one (gone from the iPhone, say) are remembered, not asked for again.
    func thumbnail(for id: String) async -> CGImage? {
        if let image = thumbnailCache[id] { return image }
        if thumbnailMisses.contains(id) { return nil }
        guard let data = await source.thumbnailData(id, pixelSide: Self.thumbnailPixelSide) else {
            thumbnailMisses.insert(id)
            return nil
        }
        let image = await Task.detached { Self.decode(data) }.value
        // The row went away meanwhile (a photo that was being checked): don't keep what nobody shows.
        guard !Task.isCancelled else { return image }
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
            cannotReachServer = false
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
    /// The first `uploading` remaining items are shown in flight, one with progress and the rest without yet.
    func loadPreview(
        deletedOnServer: Int = 0, problems: Int = 0, remaining: Int = 0, uploading: Int = 0, checking: Bool = false
    ) async {
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
        let pendingReasons: [PendingReason] = [.needsUpload, .waitingForWiFi, .notChecked, .needsUpload]
        for number in 0..<remaining {
            let id = "preview-\(10 + number)"
            // The last one is waiting to try again; the rest show the other states.
            let retry = number == remaining - 1 && remaining > 3
                ? BackupRetryState(failures: 1, notBefore: Date().addingTimeInterval(15 * 60), wasOffline: false, holdsRun: false)
                : nil
            await index.set(
                BackupEntry(
                    modificationDate: date, checksums: [.photo: "preview-\(id)"],
                    state: .pending(reason: pendingReasons[number % pendingReasons.count]), retry: retry),
                for: id)
        }
        let reasons = ["Couldn't read IMG_0012.HEIC: the file is in iCloud", "The server refused IMG_0031.MOV"]
        for number in 0..<problems {
            let id = "preview-\(30 + number)"
            await index.set(
                BackupEntry(modificationDate: date, checksums: [:], state: .failed(reason: reasons[number % reasons.count])),
                for: id)
        }
        if uploading > 0 {
            let jobs = (0..<min(uploading, remaining)).map { number in
                UploadJob(
                    assetID: "preview-\(10 + number)", resource: .photo, attempt: UUID(),
                    bodyFileName: "preview-\(number).multipart", checksum: "preview")
            }
            let progress = jobs.first.map { [$0.attempt: UploadBytes(sent: 1_400_000, expected: 3_200_000)] } ?? [:]
            previewTransport = PreviewTransport(jobs: jobs, progress: progress)
        }
        await load()
        await refreshBackgroundStatus()
        await refreshUploadProgress()
        if checking {
            isScanning = true
            progress = Progress(done: 7_012, total: 12_969)
            checkingItem = CheckingItem(id: "preview-checking", date: PreviewPhotoLibrary.date)
        }
    }
}

/// For previews: uploads that stay in flight with fixed progress. Sends nothing.
private struct PreviewTransport: BackupTransport {
    let jobs: [UploadJob]
    let progress: [UUID: UploadBytes]

    func enqueue(_ job: UploadJob, request: URLRequest) async throws {}
    func inFlight() async -> [UploadJob] { jobs }
    func cancelAll() async {}
    func cancel(attempts: Set<UUID>) async {}
    var isRedirectBlocked: Bool { false }
    func clearRedirectBlock() {}
    func uploadProgress() -> [UUID: UploadBytes] { progress }
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

/// How far each upload in flight has got (0...1), by asset ID; an asset without a fraction yet is missing.
/// Kept apart from `BackupModel` so its several updates a second only redraw the progress views.
@MainActor @Observable
final class BackupUploadProgress {
    var fractions: [String: Double] = [:]
}
