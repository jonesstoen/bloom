import Foundation
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

    enum AlbumState { case included, excluded, neither }

    /// The most failed items listed on screen.
    static let failedItemLimit = 50

    private(set) var access: PhotoAccess?
    private(set) var counts = BackupCounts()
    /// Non-nil while a scan runs.
    private(set) var progress: Progress?
    private(set) var isScanning = false
    private(set) var albums: [DeviceAlbum] = []
    private(set) var selection = BackupSelection()
    private(set) var failedItems: [FailedItem] = []
    private(set) var error: String?
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
            }
        }
    }

    @ObservationIgnored private let source: any PhotoLibrarySource
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var network: (any NetworkConditions)?
    @ObservationIgnored private var indexTask: Task<BackupIndex, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescan: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var generation = 0
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

    /// The uploader for this account: same index, photo library, server and settings as the scans.
    func makeUploader(clock: BackupRetryClock = .live) async -> BackupUploader {
        let index = await ensureIndex()
        let network = self.network ?? PathMonitorNetwork()
        self.network = network
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
            return
        }
        albums = await source.albums()
        await refreshCounts()
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
    func scan() async {
        guard !isStopped else { return }
        if let scanTask { await scanTask.value; return }
        access = await source.authorization()
        guard canRead else { return }
        await reopenIndexIfNeeded()
        let scanner = await makeScanner()
        // Another caller may have started a scan while this one was suspended.
        if let scanTask { await scanTask.value; return }
        // A rescan that was replaced while it got ready must not start a scan the next one has to cancel.
        guard !isStopped, !Task.isCancelled else { return }

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
        }
        await scanTask?.value
    }

    /// Stops the running scan. Hashed items keep their checksums, so the next scan carries on.
    func cancel() {
        guard !isStopped else { return }
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
        await scanTask?.value
    }

    /// Uploads changed what is on the server: shows the new counts (a running scan brings its own).
    func uploadsChanged() async {
        guard !isScanning, !isStopped else { return }
        await refreshCounts()
    }

    /// An upload run stopped on something every item would run into: shown like a scan's error.
    func reportUploadFailure(_ failure: Error) {
        switch failure {
        case BackupIndexError.unavailable, ImmichServiceError.unauthorized: report(failure)
        // A full disk fails the item with its reason; other errors are only retried next time.
        default: break
        }
    }

    /// Waits until scans and the rescans that selection changes trigger have finished.
    func settle() async {
        while true {
            if let task = rescan?.task { await task.value; continue }
            if let task = scanTask { await task.value; continue }
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
        if let result { counts = result } else { await refreshCounts() }
        await refreshFailures()
        scanTask = nil
        isScanning = false
    }

    private func report(_ failure: Error) {
        if case BackupIndexError.unavailable = failure { indexWasUnavailable = true }
        error = Self.message(for: failure)
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

    private static func message(for error: Error) -> String {
        if case BackupIndexError.unavailable = error {
            return tr("Bloom couldn't open its backup records. Unlock your device and try again.")
        }
        if case ImmichServiceError.unauthorized = error {
            return tr("This API key can't check backups. Create a key with the View, Organize and Back Up permissions and sign in with it.")
        }
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
        await scanTask?.value
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
        let network = self.network ?? PathMonitorNetwork()
        self.network = network
        return BackupScanner(source: source, service: service, index: index, network: network, settings: settings)
    }

    private func refreshCounts() async {
        // A scan that started or finished meanwhile has newer counts than this one will bring.
        let before = generation
        let scanner = await makeScanner()
        let fresh = await scanner.counts()
        guard before == generation else { return }
        counts = fresh
        await refreshFailures()
    }

    private func refreshFailures() async {
        guard counts.failed > 0 else { failedItems = []; return }
        let index = await ensureIndex()
        // Match counts(): a missing or edited asset no longer has its cached failure state.
        let ids = await index.selection().assetIDs(in: source).sorted()
        var items: [FailedItem] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let dates = await source.modificationDates(chunk)
            for id in chunk {
                guard let date = dates[id], let entry = await index.entry(for: id),
                      entry.modificationDate == date, case let .failed(reason) = entry.state else { continue }
                items.append(FailedItem(id: id, reason: reason))
                if items.count == Self.failedItemLimit { break }
            }
            if items.count == Self.failedItemLimit { break }
        }
        failedItems = items
    }
}

// MARK: - Preview source

/// A small, fixed photo library for previews and the demo session. Never touches PhotoKit.
struct PreviewPhotoLibrary: PhotoLibrarySource {
    var access: PhotoAccess = .full
    var photoCount = 40

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

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
