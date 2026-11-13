import Foundation
import ImmichKit
import Observation

/// What the Backup screens show: which photos are on the server, which still aren't, and the
/// choices that steer that (albums, cellular). Nothing is uploaded yet.
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
        didSet { if settings != oldValue { settings.save(to: defaults) } }
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
    @ObservationIgnored private var isStopped = false

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
        settings = BackupSettings.load(from: defaults)
    }

    // MARK: - Reading

    /// Reads access, albums, the saved selection and the counts the index already knows.
    func load() async {
        let index = await ensureIndex()
        // A choice made while this was loading is newer than what the index has saved so far.
        let saved = await index.selection()
        if rescan == nil { selection = saved }
        access = await source.authorization()
        guard access != .denied else {
            albums = []
            counts = BackupCounts()
            failedItems = []
            return
        }
        albums = await source.albums()
        await refreshCounts()
    }

    /// Whether Check Now makes sense: photo access and at least one included album.
    var canCheck: Bool { access != .denied && !selection.included.isEmpty }

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
        guard access != .denied else { return }
        let scanner = await makeScanner()
        // Another caller may have started a scan while this one was suspended.
        if let scanTask { await scanTask.value; return }
        guard !isStopped else { return }

        error = nil
        isScanning = true
        progress = Progress(done: 0, total: counts.total)
        generation += 1
        let current = generation
        scanTask = Task { [weak self] in
            var result: BackupCounts?
            var failure: Error?
            do {
                result = try await scanner.scan { [weak self] counts, handled in
                    Task { @MainActor in self?.apply(counts, handled: handled, generation: current) }
                }
            } catch {
                failure = error
            }
            await self?.finishScan(result: result, failure: failure)
        }
        await scanTask?.value
    }

    /// Stops the running scan. Hashed items keep their checksums, so the next scan carries on.
    func cancel() {
        rescan?.task.cancel()
        scanTask?.cancel()
    }

    /// Cancels and waits until nothing runs any more; no new scan starts afterwards. Call before the
    /// backup directory is removed, or a running save could recreate it.
    func stop() async {
        isStopped = true
        let pending = rescan?.task
        pending?.cancel()
        scanTask?.cancel()
        await pending?.value
        await scanTask?.value
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
        self.counts = counts
        progress = Progress(done: handled, total: max(counts.total, handled))
    }

    private func finishScan(result: BackupCounts?, failure: Error?) async {
        if let failure, !(failure is CancellationError) {
            error = Self.message(for: failure)
        }
        progress = nil
        if let result { counts = result } else { await refreshCounts() }
        await refreshFailures()
        scanTask = nil
        isScanning = false
    }

    private static func message(for error: Error) -> String {
        if case BackupIndexError.unavailable = error {
            return tr("Bloom couldn't open its backup records. Unlock your device and try again.")
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
        guard new != selection else { return }
        selection = new
        rescan?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await self?.applySelection(new)
            if self?.rescan?.id == id { self?.rescan = nil }
        }
        rescan = (id, task)
    }

    private func applySelection(_ new: BackupSelection) async {
        let index = await ensureIndex()
        await index.setSelection(new)
        do { try await index.save() } catch { self.error = Self.message(for: error) }
        guard !Task.isCancelled else { return }
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
        let scanner = await makeScanner()
        counts = await scanner.counts()
        await refreshFailures()
    }

    private func refreshFailures() async {
        guard counts.failed > 0 else { failedItems = []; return }
        let index = await ensureIndex()
        // The index's selection is what the scanner counted, so the list always matches the counts.
        let ids = await index.selection().assetIDs(in: source).sorted()
        var items: [FailedItem] = []
        for id in ids {
            if case let .failed(reason)? = await index.entry(for: id)?.state {
                items.append(FailedItem(id: id, reason: reason))
                if items.count == Self.failedItemLimit { break }
            }
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
}
