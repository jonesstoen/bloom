import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// A network the test switches by hand. Like `PathMonitorNetwork`, each `changes()` stream starts with
/// the current path; `set(connected:cellular:)` then delivers the new one to every stream.
private final class FakeNetwork: NetworkConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var path: NetworkPath
    private var listeners: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]

    init(cellular: Bool) { path = NetworkPath(isConnected: true, isOnCellular: cellular) }

    var isOnCellular: Bool { lock.withLock { path.isOnCellular } }
    var isConnected: Bool { lock.withLock { path.isConnected } }
    var listenerCount: Int { lock.withLock { listeners.count } }

    func set(connected: Bool = true, cellular: Bool = false) {
        lock.withLock {
            path = NetworkPath(isConnected: connected, isOnCellular: cellular || !connected)
            for listener in listeners.values { listener.yield(path) }
        }
    }

    func changes() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream<NetworkPath>.makeStream()
        let id = UUID()
        lock.withLock {
            listeners[id] = continuation
            continuation.yield(path)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
        return stream
    }
}

/// The debounce waits the runner asked for. They return at once: tests don't wait for real time.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Duration] = []
    var sleeps: [Duration] { lock.withLock { _sleeps } }

    var clock: BackupRetryClock {
        BackupRetryClock(now: { ContinuousClock.now }, sleep: { [self] duration in
            lock.withLock { _sleeps.append(duration) }
            try Task.checkCancellation()
        })
    }
}

/// A debounce clock the test moves by hand. Each sleep waits until `releaseSleeps()` or until its task is cancelled.
private actor ManualClock {
    private nonisolated let start = ContinuousClock.now
    private nonisolated let offset = LockedBox(Duration.zero)
    private(set) var sleeps: [Duration] = []
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated var clock: BackupRetryClock {
        BackupRetryClock(now: { [self] in start + offset.value }, sleep: { [self] in try await sleep($0) })
    }

    nonisolated func advance(to seconds: Duration) { offset.value = seconds }

    func waitForSleeps(_ count: Int) async {
        if sleeps.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseSleeps() {
        for continuation in pending.values { continuation.resume() }
        pending = [:]
    }

    private func sleep(_ duration: Duration) async throws {
        sleeps.append(duration)
        let reached = observers.filter { $0.count <= sleeps.count }
        observers.removeAll { $0.count <= sleeps.count }
        for observer in reached { observer.continuation.resume() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { pending[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Reads and upload requests in the order they started, by asset ID.
private final class EventLog: @unchecked Sendable {
    enum Event: Equatable {
        case read(String)
        case upload(String)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    var events: [Event] { lock.withLock { _events } }
    func append(_ event: Event) { lock.withLock { _events.append(event) } }
}

/// Holds the first call for each armed key (`"read a1"`, `"upload a2"`) until `release(_:)` (it then goes
/// on) or until its task is cancelled (it then throws, like a request the app cut off).
private actor Holds {
    private var armed: Set<String>
    private var heldKeys: Set<String> = []
    private var released: Set<String> = []
    private var held: [String: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(key: String, continuation: CheckedContinuation<Void, Never>)] = []
    /// Keys whose held call was cancelled.
    private(set) var interrupted: [String] = []

    init(_ keys: Set<String>) { armed = keys }

    func arm(_ key: String) { armed.insert(key) }

    func pass(_ key: String) async throws {
        guard armed.remove(key) != nil else { return }
        heldKeys.insert(key)
        for observer in observers where observer.key == key { observer.continuation.resume() }
        observers.removeAll { $0.key == key }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if released.contains(key) { continuation.resume() }
                    else if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { held[key] = continuation }
                }
            } onCancel: {
                Task { await self.cancel(key) }
            }
        } catch {
            interrupted.append(key)
            throw error
        }
    }

    func waitUntilHeld(_ key: String) async {
        if heldKeys.contains(key) { return }
        await withCheckedContinuation { observers.append((key, $0)) }
    }

    func release(_ key: String) {
        released.insert(key)
        held.removeValue(forKey: key)?.resume()
    }

    private func cancel(_ key: String) {
        held.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }
}

/// The fake photo library, logging reads and holding the armed ones.
private struct GatedLibrary: PhotoLibrarySource {
    let base: FakePhotoLibrary
    let holds: Holds
    let log: EventLog

    func authorization() async -> PhotoAccess { await base.authorization() }
    func requestAuthorization() async -> PhotoAccess { await base.requestAuthorization() }
    func albums() async -> [DeviceAlbum] { await base.albums() }
    func assetIDs(inAlbum id: String) async -> Set<String> { await base.assetIDs(inAlbum: id) }
    func asset(_ id: String) async -> DeviceAsset? { await base.asset(id) }
    func assets(_ ids: [String]) async -> [DeviceAsset] { await base.assets(ids) }
    func modificationDates(_ ids: [String]) async -> [String: Date] { await base.modificationDates(ids) }
    func changes() -> AsyncStream<Void> { base.changes() }
    func thumbnailData(_ id: String, pixelSide: Int) async -> Data? { await base.thumbnailData(id, pixelSide: pixelSide) }
    func read(_ resource: DeviceResource, of assetID: String, allowNetwork: Bool,
              onData: @escaping @Sendable (Data) -> Void) async throws {
        log.append(.read(assetID))
        try await holds.pass("read \(assetID)")
        try await base.read(resource, of: assetID, allowNetwork: allowNetwork, onData: onData)
    }
}

/// The mock server, logging upload requests and holding the armed ones.
private struct GatedUploadService: ImmichService {
    let mock: MockImmichService
    let holds: Holds
    let log: EventLog

    func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult {
        let id = (request.filename as NSString).deletingPathExtension
        log.append(.upload(id))
        try await holds.pass("upload \(id)")
        return try await mock.uploadAsset(request)
    }

    func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] { try await mock.checkBulkUpload(items) }
    func linkLivePhoto(photoID: String, motionID: String) async throws { try await mock.linkLivePhoto(photoID: photoID, motionID: motionID) }
    func restoreAssets(assetIDs: [String]) async throws -> RestoreResult { try await mock.restoreAssets(assetIDs: assetIDs) }
    func moveToTrash(assetIDs: [String]) async throws -> TrashResult { try await mock.moveToTrash(assetIDs: assetIDs) }
    func serverFeatures() async throws -> ServerFeatures { try await mock.serverFeatures() }
    func ping() async throws { try await mock.ping() }
    func serverVersion() async throws -> ServerVersion { try await mock.serverVersion() }
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] { try await mock.timeBuckets(options: options) }
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] { try await mock.timeBucketAssets(bucketID: bucketID, options: options) }
    func thumbnail(assetID: String, size: ImageSize) async throws -> Data { try await mock.thumbnail(assetID: assetID, size: size) }
    func albums(shared: Bool?) async throws -> [Album] { try await mock.albums(shared: shared) }
    func albumsForAdding() async throws -> [Album] { try await mock.albumsForAdding() }
    func album(id: String) async throws -> Album { try await mock.album(id: id) }
    func people(withHidden: Bool) async throws -> [Person] { try await mock.people(withHidden: withHidden) }
    func person(id: String) async throws -> Person { try await mock.person(id: id) }
    func personThumbnail(personID: String) async throws -> Data { try await mock.personThumbnail(personID: personID) }
    func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults { try await mock.smartSearch(query, page: page, size: size) }
    func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults { try await mock.metadataSearch(query, page: page, size: size) }
    func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String] { try await mock.searchSuggestions(kind, context: context) }
    func asset(id: String) async throws -> Asset { try await mock.asset(id: id) }
    func original(assetID: String) async throws -> Data { try await mock.original(assetID: assetID) }
    func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest { try await mock.mediaRequest(kind, assetID: assetID) }
    func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] { try await mock.mapMarkers(options) }
    func memories(_ query: MemoryQuery) async throws -> [Memory] { try await mock.memories(query) }
    func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset { try await mock.setFavorite(assetID: assetID, isFavorite: isFavorite) }
    func setHidden(assetID: String, hidden: Bool) async throws -> Asset { try await mock.setHidden(assetID: assetID, hidden: hidden) }
    func createAlbum(name: String, assetIDs: [String]) async throws -> String { try await mock.createAlbum(name: name, assetIDs: assetIDs) }
    func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult { try await mock.addAssets(toAlbum: albumID, assetIDs: assetIDs) }
}

@MainActor
final class BackupRunnerTests: XCTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        Localization.languageOverride = "en"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        for url in directories { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        directories = []
        suites = []
        super.tearDown()
    }

    // MARK: Helpers

    private struct Setup {
        let library: FakePhotoLibrary
        let mock: MockImmichService
        let holds: Holds
        let log: EventLog
        let model: BackupModel
        let runner: BackupRunner
        let directory: URL
        let defaults: UserDefaults
        let debounce: SleepLog
        let network: FakeNetwork
        /// The model's transport (made with the uploader).
        let transportBox: LockedBox<FakeTransport?>
        var transport: FakeTransport { transportBox.value! }

        var stagingDirectory: URL { directory.appendingPathComponent("Staging", isDirectory: true) }

        var stagedFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        }

        /// The item's state as last saved.
        func savedState(_ id: String) async -> BackupState? {
            await BackupIndex(directory: directory).entry(for: id)?.state
        }

        /// Upload requests made, held and cancelled ones included.
        func uploadRequests() async -> Int {
            let interrupted = await holds.interrupted.filter { $0.hasPrefix("upload") }.count
            return await mock.uploads.count + interrupted
        }

        func setAlbum(_ ids: [String], id album: String = "recents") {
            library.addAlbum(id: album, title: album, assetIDs: Set(ids))
        }

        /// Upload requests that reached the server, by asset ID.
        var uploadedIDs: [String] {
            get async { await mock.uploads.map { ($0.filename as NSString).deletingPathExtension } }
        }
    }

    private static func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    private static func content(_ id: String) -> Data { Data("content of \(id)".utf8) }

    private static func checksum(_ id: String) -> String {
        var sha = SHA1Stream()
        sha.update(content(id))
        return sha.base64()
    }

    /// `id` taken `age` seconds before the newest; the newest is uploaded first.
    private static func addAsset(_ id: String, age: TimeInterval, to library: FakePhotoLibrary) {
        let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
        library.setData([content(id)], for: resource)
        library.addAsset(DeviceAsset(
            id: id, isVideo: false, creationDate: date(-age), modificationDate: date(-age),
            isFavorite: false, duration: 0, resources: [resource]))
    }

    /// Recents holds `ids` (the first is the newest) and, with `selected`, is saved as the backup selection.
    /// `holds` are the calls to hold (`"read a1"`, `"upload a2"`); `debounceClock` defaults to one whose
    /// sleeps return at once.
    private func makeSetup(
        _ ids: [String], selected: Bool = true, cellular: Bool = false, holds keys: Set<String> = [],
        debounceClock: BackupRetryClock? = nil, retryClock customRetryClock: BackupRetryClock? = nil,
        transport mode: FakeTransport.Mode = .immediate
    ) async throws -> Setup {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRunnerTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let suite = "BackupRunnerTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        let library = FakePhotoLibrary()
        for (offset, id) in ids.enumerated() { Self.addAsset(id, age: TimeInterval(offset), to: library) }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        if selected {
            let saved = BackupIndex(directory: directory)
            await saved.setSelection(BackupSelection(included: ["recents"]))
            try await saved.save()
        }

        let mock = MockImmichService()
        let holds = Holds(keys)
        let log = EventLog()
        let source = GatedLibrary(base: library, holds: holds, log: log)
        let network = FakeNetwork(cellular: cellular)
        let service = GatedUploadService(mock: mock, holds: holds, log: log)
        let transportBox = LockedBox<FakeTransport?>(nil)
        // Uploads go through a fake of the system's transport that sends them to the gated mock server.
        let uploads = BackupModel.Uploads(requests: .test) { index, staging, recorder in
            let made = FakeTransport(index: index, staging: staging, recorder: recorder, service: service, mode: mode)
            transportBox.value = made
            return made
        }
        let model = BackupModel(
            source: source, service: service, directory: directory,
            network: network, defaults: defaults, uploads: uploads)
        let retryClock = BackupRetryClock(now: { ContinuousClock.now }, sleep: { _ in try Task.checkCancellation() })
        let uploader = await model.makeUploader(clock: customRetryClock ?? retryClock)
        let debounce = SleepLog()
        let runner = BackupRunner(
            model: model, uploader: uploader, source: source, staging: model.staging,
            debounce: .seconds(2), debounceLimit: .seconds(10), clock: debounceClock ?? debounce.clock)
        return Setup(library: library, mock: mock, holds: holds, log: log, model: model, runner: runner,
                     directory: directory, defaults: defaults, debounce: debounce, network: network,
                     transportBox: transportBox)
    }

    private func position(of request: MockImmichService.Request, in requests: [MockImmichService.Request]) -> Int? {
        requests.firstIndex(of: request)
    }

    private func isCheck(_ request: MockImmichService.Request) -> Bool {
        if case .bulkUploadCheck = request { true } else { false }
    }

    // MARK: When it runs

    func testDisabledRunsNothingOnActive() async throws {
        let setup = try await makeSetup(["a1"])
        XCTAssertFalse(setup.model.settings.isEnabled, "Off by default")
        setup.runner.appBecameActive()
        setup.runner.backupScreenOpened()
        XCTAssertEqual(setup.library.changeListenerCount, 0, "The library isn't watched while off")
        setup.library.emitChange()
        await setup.runner.settle()

        let requests = await setup.mock.requests
        XCTAssertEqual(requests, [], "No scan and no upload while the switch is off")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertNil(setup.runner.uploadProgress)

        // Check Now still works.
        let completed = await setup.model.scan()
        XCTAssertTrue(completed)
        let checks = await setup.mock.requests.filter(isCheck)
        XCTAssertFalse(checks.isEmpty)
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 0)
    }

    func testEnabledActiveScansThenUploads() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        XCTAssertTrue(setup.model.settings.isEnabled)
        XCTAssertTrue(BackupSettings.load(from: setup.defaults).isEnabled, "The switch is saved")
        setup.runner.appBecameActive()
        await setup.runner.settle()

        let requests = await setup.mock.requests
        let firstCheck = requests.firstIndex(where: isCheck)
        let upload = position(of: .upload(Self.checksum("a1")), in: requests)
        XCTAssertNotNil(firstCheck)
        XCTAssertNotNil(upload)
        if let firstCheck, let upload { XCTAssertLessThan(firstCheck, upload, "Scan first, then upload") }
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 1)
        let state = await setup.savedState("a1")
        guard case .backedUp = state else { return XCTFail("Expected backedUp, got \(String(describing: state))") }
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertNil(setup.runner.uploadProgress)
        XCTAssertEqual(setup.model.counts.backedUp, 1, "The counts follow the upload")
        XCTAssertEqual(setup.stagedFiles, [])
    }

    func testCheckNowWithTheSwitchOnUploads() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        Self.addAsset("a2", age: -1, to: setup.library)
        setup.setAlbum(["a1", "a2"])
        setup.runner.checkNow()
        await setup.runner.settle()
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 2, "Check Now with the switch on uploads what it finds")
    }

    /// Owner's phone test: uploaded with the switch on, purged on the web, then Check Now.
    func testPurgedOnServerAfterUploadShowsUnderDeletedOnServer() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(setup.model.counts.backedUp, 1)
        await setup.mock.setServerChecksums([])   // trash emptied on the web
        setup.runner.checkNow()
        await setup.runner.settle()
        await setup.model.settle()
        XCTAssertEqual(setup.model.counts.deletedOnServer, 1, "\(setup.model.counts)")
        XCTAssertEqual(setup.model.counts.backedUp, 0)
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 1, "never uploaded again")
    }

    func testCheckNowWithTheSwitchOffOnlyChecks() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.appBecameActive()
        setup.runner.checkNow()
        await setup.runner.settle()
        await setup.model.settle()
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(setup.model.counts.total, 1, "It still checks")
    }

    func testFinishedUploadRunTellsTheLibraryOnce() async throws {
        let setup = try await makeSetup(["a1", "a2"])
        var changes = 0
        setup.model.onServerLibraryChanged = { changes += 1 }
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(changes, 1, "One Library reload per upload run, not one per item")
    }

    func testRunWithNothingToUploadDoesNotReloadTheLibrary() async throws {
        let setup = try await makeSetup([])
        var changes = 0
        setup.model.onServerLibraryChanged = { changes += 1 }
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(changes, 0)
    }

    func testBecomingActiveWithoutBackgroundDoesNotScanAgain() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let afterLaunch = await setup.mock.requests.count

        // Control Center, Face ID, a permission prompt: inactive, then active again.
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let afterInactive = await setup.mock.requests.count
        XCTAssertEqual(afterInactive, afterLaunch)

        setup.runner.appLeftForeground()
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let afterBackground = await setup.mock.requests.count
        XCTAssertGreaterThan(afterBackground, afterLaunch, "Back from the background: scanned again")
    }

    func testRunStoppedByAnErrorIsReported() async throws {
        let setup = try await makeSetup(["a1"])
        await setup.mock.setUploadFailure(ImmichServiceError.insecureConnection)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(setup.model.error,
                       "Couldn't back up your photos: \(ImmichServiceError.insecureConnection.localizedDescription)")
    }

    // MARK: Album and cellular choices

    func testChoosingAnAlbumWhileEnabledUploads() async throws {
        let setup = try await makeSetup(["a1"], selected: false)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let before = await setup.uploadRequests()
        XCTAssertEqual(before, 0, "No album chosen yet")

        setup.model.setSelection(BackupSelection(included: ["recents"]))
        await setup.runner.settle()
        await setup.model.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a1"])
        let state = await setup.savedState("a1")
        guard case .backedUp = state else { return XCTFail("Expected backedUp, got \(String(describing: state))") }
    }

    func testDeselectingAnAlbumDuringUploadSkipsItsItems() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.setAlbum(["a2"], id: "holiday")
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")

        setup.model.setSelection(BackupSelection(included: ["holiday"]))
        await setup.holds.release("upload a2")
        await setup.runner.settle()
        await setup.model.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a2"], "a1 is no longer selected")
    }

    func testCellularSwitchWhileEnabledUploadsWaitingItems() async throws {
        let setup = try await makeSetup(["a1"], cellular: true)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let waiting = await setup.savedState("a1")
        XCTAssertEqual(waiting, .pending(reason: .waitingForWiFi))
        let before = await setup.uploadRequests()
        XCTAssertEqual(before, 0)

        setup.model.settings.photosOnCellular = true
        await setup.runner.settle()
        await setup.model.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a1"])
    }

    // MARK: Network

    private static let offline = ImmichServiceError.network(
        "The Internet connection appears to be offline.", code: .notConnectedToInternet)

    /// `settle()`, failing instead of hanging when a run waits for something that never comes.
    private func settleOrFail(_ setup: Setup, _ message: String) async {
        let settled = expectation(description: message)
        Task { await setup.runner.settle(); settled.fulfill() }
        await fulfillment(of: [settled], timeout: 10)
    }

    /// Owner's phone: with Wi-Fi off the run stopped, and nothing resumed when Wi-Fi came back.
    func testNetworkComingBackResumesTheRun() async throws {
        let setup = try await makeSetup(["a1"])
        await setup.mock.setFailure(Self.offline)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertTrue(setup.model.cannotReachServer)
        XCTAssertNil(setup.model.error)
        XCTAssertEqual(setup.network.listenerCount, 1, "The network is watched while on and open")
        await setup.runner.handledNetworkChanges(1)
        XCTAssertEqual(setup.model.connectionStatus, .serverUnreachable, "The device has a network")

        setup.network.set(connected: false)
        await setup.runner.handledNetworkChanges(2) // the first is the path when watching started
        await setup.runner.settle()
        XCTAssertEqual(setup.model.connectionStatus, .waitingForNetwork)
        let uploadsOffline = await setup.uploadRequests()
        XCTAssertEqual(uploadsOffline, 0)

        await setup.mock.setFailure(nil)
        setup.network.set(connected: true)
        await setup.runner.handledNetworkChanges(3)
        XCTAssertEqual(setup.debounce.sleeps.last, .seconds(2), "Debounced like library changes")
        await setup.runner.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a1"])
        XCTAssertFalse(setup.model.cannotReachServer, "Cleared by the scan that worked")
        XCTAssertNil(setup.model.connectionStatus)
        XCTAssertNil(setup.model.error)
    }

    /// The connected path can arrive before the scan that was under way fails on the old one: that scan's
    /// failure mustn't be the last word.
    func testReconnectDuringAFailingScanScansAgain() async throws {
        let setup = try await makeSetup(["a1"], holds: ["read a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("read a1") // the probe went through; the scan reads a1
        await setup.mock.setFailure(Self.offline)
        setup.network.set(connected: false)
        setup.network.set(connected: true)
        await setup.runner.handledNetworkChanges(3)
        XCTAssertFalse(setup.model.cannotReachServer, "The scan hasn't failed yet")

        await setup.holds.release("read a1")
        await setup.runner.settle()
        let checks = await setup.mock.requests.filter(isCheck).count
        XCTAssertEqual(checks, 3, "The probe, the failed check, and the check of the second scan")
        XCTAssertTrue(setup.model.cannotReachServer)
        XCTAssertEqual(setup.model.connectionStatus, .serverUnreachable)
    }

    /// An upload run waiting out the back-off after losing the connection goes on as soon as the network is
    /// back, instead of after the rest of the wait.
    func testReconnectWakesARunWaitingOutTheBackOff() async throws {
        let retry = ManualClock()
        let setup = try await makeSetup(["a1"], retryClock: retry.clock)
        await setup.mock.setUploadFailure(Self.offline)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await retry.waitForSleeps(1) // a1 failed; the run waits out the 5 s back-off
        XCTAssertTrue(setup.runner.isUploading)
        XCTAssertFalse(setup.model.cannotReachServer, "The uploader retries by itself")

        await setup.mock.setUploadFailure(nil)
        setup.network.set(connected: false)
        setup.network.set(connected: true)
        await setup.runner.handledNetworkChanges(3)
        await retry.releaseSleeps() // the wait's slice ends and the run is asked whether to pause
        await settleOrFail(setup, "The run went on without waiting out the back-off")

        let sleeps = await retry.sleeps
        XCTAssertEqual(sleeps.count, 1, "No further back-off wait")
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 2, "The failed attempt and the one after the network came back")
        let state = await setup.savedState("a1")
        guard case .backedUp = state else { return XCTFail("Expected backedUp, got \(String(describing: state))") }
    }

    func testSwitchingFromCellularToWiFiUploadsItemsWaitingForWiFi() async throws {
        let setup = try await makeSetup(["a1"], cellular: true)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let waiting = await setup.savedState("a1")
        XCTAssertEqual(waiting, .pending(reason: .waitingForWiFi))
        XCTAssertEqual(setup.model.counts.waitingForWiFi, 1)

        // Another path update while still on cellular: nothing to do.
        setup.network.set(cellular: true)
        await setup.runner.handledNetworkChanges(2)
        await setup.runner.settle()
        let before = await setup.uploadRequests()
        XCTAssertEqual(before, 0)

        setup.network.set(cellular: false)
        await setup.runner.handledNetworkChanges(3)
        await setup.runner.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a1"])
    }

    func testNetworkChangesWithTheSwitchOffRunNothing() async throws {
        let setup = try await makeSetup(["a1"], cellular: true)
        await setup.mock.setFailure(Self.offline)
        setup.runner.appBecameActive()
        setup.runner.checkNow()
        await setup.runner.settle()
        XCTAssertTrue(setup.model.cannotReachServer, "Check Now with the switch off still notes it")
        XCTAssertEqual(setup.model.connectionStatus, .serverUnreachable, "Nothing waits for the network while off")
        XCTAssertNil(setup.model.error)
        XCTAssertEqual(setup.network.listenerCount, 0, "The network isn't watched while off")

        await setup.mock.setFailure(nil)
        let before = await setup.mock.requests
        setup.network.set(connected: false)
        XCTAssertEqual(setup.model.connectionStatus, .serverUnreachable, "Never the waiting text while off")
        setup.network.set(cellular: false)
        await setup.runner.settle()
        let after = await setup.mock.requests
        XCTAssertEqual(after, before, "Nothing runs")
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 0)
    }

    func testTheNetworkIsOnlyWatchedWhileOnAndOpen() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(setup.network.listenerCount, 1)

        setup.runner.appLeftForeground()
        await setup.runner.settle()
        XCTAssertEqual(setup.network.listenerCount, 0, "Not watched in the background")

        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(setup.network.listenerCount, 1)

        await setup.runner.stop()
        XCTAssertEqual(setup.network.listenerCount, 0, "Released by stop()")
        let before = await setup.mock.requests
        setup.network.set(connected: false)
        setup.network.set(connected: true)
        await setup.runner.settle()
        let after = await setup.mock.requests
        XCTAssertEqual(after, before, "Nothing runs after stop")
    }

    /// Going to the background and back keeps no ended watcher around (nothing settles in the app).
    func testRetiredWatchersDoNotPileUp() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        for _ in 0..<20 {
            setup.runner.appLeftForeground()
            setup.runner.appBecameActive()
        }
        // Cancelled watchers end on the main actor once it is free; no clock involved.
        for _ in 0..<1000 where setup.runner.retiredWatcherCount > 0 { await Task.yield() }
        XCTAssertEqual(setup.runner.retiredWatcherCount, 0)
        await setup.runner.settle()
    }

    func testUserCancelOfTheRunsScanStopsTheRun() async throws {
        let setup = try await makeSetup(["a1"])
        await setup.model.scan() // a1 is known to need uploading
        Self.addAsset("a3", age: -10, to: setup.library)
        setup.setAlbum(["a1", "a3"])
        await setup.holds.arm("read a3")
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("read a3")
        // A change during the scan: without Cancel the run would scan again and upload.
        setup.library.emitChange()
        await setup.runner.handledLibraryChanges(1)
        XCTAssertTrue(setup.runner.isRescanPending)

        setup.model.cancel()
        await setup.runner.settle()
        await setup.model.settle()
        let afterCancel = await setup.uploadRequests()
        XCTAssertEqual(afterCancel, 0, "Cancel stops the whole run, not just the scan")
        XCTAssertFalse(setup.runner.isUploading)

        setup.runner.backupScreenOpened()
        await setup.runner.settle()
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(Set(uploaded), ["a1", "a3"], "The next trigger runs again")
    }

    func testScanReportsWhetherItCompleted() async throws {
        let setup = try await makeSetup(["a1"], holds: ["read a1"])
        let cancelled = Task { await setup.model.scan() }
        await setup.holds.waitUntilHeld("read a1")
        setup.model.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        let completed = await setup.model.scan()
        XCTAssertTrue(completed)
    }

    // MARK: Library changes

    func testLibraryChangeDuringUploadFinishesItemThenRescans() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2") // the newest

        // A photo is taken meanwhile.
        Self.addAsset("a3", age: -10, to: setup.library)
        setup.setAlbum(["a1", "a2", "a3"])
        setup.library.emitChange()
        await setup.runner.handledLibraryChanges(1)
        XCTAssertTrue(setup.runner.isRescanPending)
        XCTAssertTrue(setup.runner.isUploading)
        XCTAssertEqual(setup.debounce.sleeps, [.seconds(2)], "The change is debounced")

        await setup.holds.release("upload a2")
        await setup.runner.settle()

        let requests = await setup.mock.requests
        let first = try XCTUnwrap(position(of: .upload(Self.checksum("a2")), in: requests), "a2 finished")
        let rescan = try XCTUnwrap(requests.indices.first { $0 > first && isCheck(requests[$0]) }, "A scan after the first upload")
        let new = try XCTUnwrap(position(of: .upload(Self.checksum("a3")), in: requests), "The new photo is found and uploaded")
        let older = try XCTUnwrap(position(of: .upload(Self.checksum("a1")), in: requests))
        XCTAssertLessThan(rescan, new)
        XCTAssertLessThan(rescan, older, "The next item waits for the scan")
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 3, "Nothing was sent twice")
        for id in ["a1", "a2", "a3"] {
            let state = await setup.savedState(id)
            guard case .backedUp = state else { return XCTFail("\(id): expected backedUp, got \(String(describing: state))") }
        }
    }

    /// Scan 1 is held on a1 while b1 is added, scan 2 on b1 while c1 is added: two changes, each during
    /// a scan. Returns the reads and uploads in order.
    private func changesDuringScans() async throws -> [EventLog.Event] {
        let setup = try await makeSetup(["a1"], holds: ["read a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("read a1")

        Self.addAsset("b1", age: -10, to: setup.library)
        setup.setAlbum(["a1", "b1"])
        await setup.holds.arm("read b1")
        setup.library.emitChange()
        await setup.runner.handledLibraryChanges(1)
        await setup.holds.release("read a1")

        await setup.holds.waitUntilHeld("read b1") // the rescan
        Self.addAsset("c1", age: -20, to: setup.library)
        setup.setAlbum(["a1", "b1", "c1"])
        setup.library.emitChange()
        await setup.runner.handledLibraryChanges(2)
        await setup.holds.release("read b1")
        await setup.runner.settle()

        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(Set(uploaded), ["a1", "b1", "c1"])
        XCTAssertEqual(uploaded.count, 3)
        return setup.log.events
    }

    func testChangesDuringScansRescanOnlyOnceBeforeUploading() async throws {
        let events = try await changesDuringScans()
        let firstUpload = try XCTUnwrap(events.firstIndex { if case .upload = $0 { true } else { false } })
        let readC1 = try XCTUnwrap(events.firstIndex(of: .read("c1")))
        XCTAssertLessThan(firstUpload, readC1, "After one rescan the queue gets its turn: \(events)")
        XCTAssertEqual(events.prefix(2), [.read("a1"), .read("b1")], "Scan, then one rescan")
    }

    func testPendingChangeStillLetsOneItemUploadFirst() async throws {
        let events = try await changesDuringScans()
        let readC1 = try XCTUnwrap(events.firstIndex(of: .read("c1")))
        let uploadsBefore = events[..<readC1].filter { if case .upload = $0 { true } else { false } }
        XCTAssertEqual(uploadsBefore, [.upload("b1")], "One item, then the pending change is honoured: \(events)")
    }

    func testDebounceWaitsAtMostTenSecondsFromTheFirstChange() async throws {
        let manual = ManualClock()
        let setup = try await makeSetup(["a1"], debounceClock: manual.clock)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.runner.settle()
        let checksBefore = await setup.mock.requests.filter(isCheck).count

        // A change every 1.5 s: each one would push a plain 2 s debounce further out.
        for step in 0...6 {
            manual.advance(to: .milliseconds(1500 * step))
            setup.library.emitChange()
            await manual.waitForSleeps(step + 1)
        }
        let sleeps = await manual.sleeps
        XCTAssertEqual(sleeps, [.seconds(2), .seconds(2), .seconds(2), .seconds(2), .seconds(2), .seconds(2), .seconds(1)],
                       "The last wait ends 10 s after the first change")
        let checksWhileWaiting = await setup.mock.requests.filter(isCheck).count
        XCTAssertEqual(checksWhileWaiting, checksBefore)

        await manual.releaseSleeps()
        await setup.runner.settle()
        let checksAfter = await setup.mock.requests.filter(isCheck).count
        XCTAssertGreaterThan(checksAfter, checksBefore, "Scanned once the wait ended")
    }

    // MARK: Leaving, switching off, stopping

    /// Phase 3 (replaces "leaving the foreground cancels the upload"): an upload handed to the transport
    /// belongs to the system. Leaving the foreground stops scanning and staging, not it; its result is
    /// recorded when it arrives, and nothing is sent twice.
    func testLeavingTheForegroundKeepsUploadsGoing() async throws {
        let setup = try await makeSetup(["a1"], transport: .manual)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(1)
        XCTAssertTrue(setup.runner.isUploading)

        setup.runner.appLeftForeground()
        await setup.runner.settle()
        XCTAssertEqual(setup.transport.cancelAllCount, 0, "The upload in flight was not cancelled")
        let inFlight = await setup.transport.inFlight().count
        XCTAssertEqual(inFlight, 1)
        XCTAssertEqual(setup.stagedFiles.count, 1, "Its body stays until its result is recorded")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertNil(setup.runner.uploadProgress)
        XCTAssertEqual(setup.library.changeListenerCount, 0, "The library isn't watched in the background")

        // The system finishes it while Bloom is in the background.
        await setup.transport.complete()
        let state = await setup.savedState("a1")
        guard case .backedUp = state else { return XCTFail("Expected backedUp, got \(String(describing: state))") }
        XCTAssertEqual(setup.stagedFiles, [])

        setup.runner.appBecameActive()
        await setup.runner.settle()
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 1, "Not sent again")
        XCTAssertEqual(setup.transport.sent.count, 1)
    }

    /// Turning the switch off cancels what the transport has in flight; the items go back to the queue and
    /// nothing new is enqueued.
    func testSwitchOffCancelsInFlightUploads() async throws {
        let setup = try await makeSetup(["a2", "a1"], transport: .manual)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(2)

        setup.runner.setEnabled(false)
        await setup.runner.settle()
        XCTAssertEqual(setup.transport.cancelAllCount, 1)
        let inFlight = await setup.transport.inFlight()
        XCTAssertEqual(inFlight, [])
        for id in ["a1", "a2"] {
            let state = await setup.savedState(id)
            XCTAssertEqual(state, .pending(reason: .needsUpload), id)
        }
        XCTAssertEqual(setup.stagedFiles, [])
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0)

        setup.runner.appLeftForeground()
        setup.runner.appBecameActive()
        await setup.runner.settle()
        XCTAssertEqual(setup.transport.sent.count, 2, "Nothing new enqueued while off")
    }

    func testSwitchOffDuringUploadStops() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")

        setup.runner.setEnabled(false)
        XCTAssertFalse(setup.model.settings.isEnabled)
        XCTAssertFalse(BackupSettings.load(from: setup.defaults).isEnabled, "The switch is saved")
        await setup.runner.settle()
        let interrupted = await setup.holds.interrupted
        XCTAssertEqual(interrupted, ["upload a2"])
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0, "No item after the interrupted one")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertEqual(setup.stagedFiles, [])
        XCTAssertEqual(setup.library.changeListenerCount, 0, "The library isn't watched while off")
        for id in ["a1", "a2"] {
            let state = await setup.savedState(id)
            XCTAssertEqual(state, .pending(reason: .needsUpload), id)
        }

        // Off: coming back to the app starts nothing.
        let before = await setup.mock.requests
        setup.runner.appLeftForeground()
        setup.runner.appBecameActive()
        XCTAssertEqual(setup.library.changeListenerCount, 0)
        await setup.runner.settle()
        let after = await setup.mock.requests
        XCTAssertEqual(after, before)
    }

    func testStopRemovesStagingAndRunsNothingAfter() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")
        // Left behind by an earlier run the system ended.
        try Data("left over".utf8).write(to: setup.stagingDirectory.appendingPathComponent("leftover.staged"))

        await setup.runner.stop()
        XCTAssertEqual(setup.stagedFiles, [], "Staging is emptied once nothing uploads")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertEqual(setup.library.changeListenerCount, 0)
        let before = await setup.mock.requests

        setup.runner.appBecameActive()
        setup.runner.backupScreenOpened()
        setup.runner.setEnabled(true)
        XCTAssertEqual(setup.library.changeListenerCount, 0)
        await setup.runner.settle()
        let after = await setup.mock.requests
        XCTAssertEqual(after, before, "Nothing runs after stop")
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 1, "Only the interrupted request")
        for id in ["a1", "a2"] {
            let state = await setup.savedState(id)
            XCTAssertEqual(state, .pending(reason: .needsUpload), id)
        }
    }

    func testModelStopStopsTheRunnerAndEmptiesStaging() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")
        try Data("left over".utf8).write(to: setup.stagingDirectory.appendingPathComponent("leftover.staged"))
        XCTAssertEqual(setup.stagedFiles.count, 2, "The held item's file and the leftover")

        await setup.model.stop() // what sign-out awaits before removing the backup directory
        XCTAssertEqual(setup.stagedFiles, [])
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertEqual(setup.library.changeListenerCount, 0)
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0)
    }

    func testLeftoverCleanupWaitsForTheUploadInFlight() async throws {
        let setup = try await makeSetup(["a2", "a1"], holds: ["upload a2"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")
        try Data("left over".utf8).write(to: setup.stagingDirectory.appendingPathComponent("leftover.staged"))

        setup.runner.removeLeftoverStaging()
        await setup.runner.waitUntilWaitingForLane(1)
        XCTAssertEqual(setup.stagedFiles.count, 2, "The file being uploaded is left alone")

        await setup.holds.release("upload a2")
        await setup.runner.settle()
        // Phase 3: files nothing refers to are removed by the transport's startup reconcile (`inFlight()`, which
        // the fake does as the real one does), which also knows the bodies of the system's own upload tasks;
        // the runner only waits for it for its turn. Never a body in use. (That the cleanup itself reaches the
        // reconcile is `testLeftoverCleanupReachesTheTransportsReconcile`; the run's own reconcile would do here.)
        XCTAssertEqual(setup.stagedFiles, [], "The reconcile removed the leftover, and no body of an upload is left")
        let uploaded = await setup.uploadedIDs
        XCTAssertEqual(uploaded, ["a2", "a1"], "The cleanup didn't interrupt the run")
    }

    /// Without a run going, the cleanup alone reaches the transport's reconcile: the leftover goes, and what
    /// an upload in flight still needs would stay (`testLeftoverCleanupWaitsForTheUploadInFlight`).
    func testLeftoverCleanupReachesTheTransportsReconcile() async throws {
        let setup = try await makeSetup(["a1"])
        try FileManager.default.createDirectory(at: setup.stagingDirectory, withIntermediateDirectories: true)
        try Data("left over".utf8).write(to: setup.stagingDirectory.appendingPathComponent("leftover.staged"))

        setup.runner.removeLeftoverStaging()
        await setup.runner.settle()

        XCTAssertEqual(setup.stagedFiles, [])
        XCTAssertFalse(setup.runner.isUploading)
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0, "Only a cleanup: the switch is off")
    }

    // MARK: Try Again

    func testTryAgainWaitsForTheItemInFlightThenRescans() async throws {
        let setup = try await makeSetup(["a2", "a1", "bad"], holds: ["upload a2"])
        let bad = DeviceResource(type: .photo, filename: "bad.jpg")
        setup.library.failReads(of: bad, with: NSError(domain: "Test", code: 1))
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.holds.waitUntilHeld("upload a2")
        let failed = await setup.savedState("bad")
        guard case .failed = failed else { return XCTFail("Expected failed, got \(String(describing: failed))") }

        let retry = Task { await setup.runner.retryFailed(["bad"]) }
        await setup.runner.waitUntilWaitingForLane(1)
        let whileUploading = await setup.savedState("bad")
        XCTAssertEqual(whileUploading, failed, "Try Again waits while an item uploads")

        await setup.holds.release("upload a2")
        await retry.value
        await setup.runner.settle()
        let requests = await setup.mock.requests
        let first = try XCTUnwrap(position(of: .upload(Self.checksum("a2")), in: requests))
        let older = try XCTUnwrap(position(of: .upload(Self.checksum("a1")), in: requests))
        XCTAssertTrue(requests[first..<older].contains(where: isCheck),
                      "The run paused for Try Again, then checked again before the next item")
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 2)
    }

    func testTryAgainIsCancelledWhenLeavingTheForeground() async throws {
        // Phase 3: the upload is the transport's (leaving doesn't interrupt it); the run waits for its result.
        let setup = try await makeSetup(["a2", "bad"], transport: .manual)
        let bad = DeviceResource(type: .photo, filename: "bad.jpg")
        setup.library.failReads(of: bad, with: NSError(domain: "Test", code: 1))
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(1)
        let failed = await setup.savedState("bad")

        let retry = Task { await setup.runner.retryFailed(["bad"]) }
        await setup.runner.waitUntilWaitingForLane(1)
        setup.runner.appLeftForeground()
        await retry.value
        await setup.runner.settle()
        let after = await setup.savedState("bad")
        XCTAssertEqual(after, failed, "Cancelled with the run, so it didn't run late")
    }

    // MARK: Phase 3 fix round 1

    /// An upload handed to the transport isn't a finished item: leaving the foreground right after
    /// enqueueing doesn't tell the Library that new assets are on the server.
    func testEnqueuedItemDoesNotReloadTheLibrary() async throws {
        let setup = try await makeSetup(["a1"], transport: .manual)
        var changes = 0
        setup.model.onServerLibraryChanged = { changes += 1 }
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(1)

        setup.runner.appLeftForeground()
        await setup.runner.settle()

        XCTAssertEqual(changes, 0, "Nothing is on the server yet")
    }

    /// A recorded result does: one of two uploads has its result when the run ends, and the Library reloads.
    func testRecordedResultReloadsTheLibrary() async throws {
        let setup = try await makeSetup(["a2", "a1"], transport: .manual)
        var changes = 0
        setup.model.onServerLibraryChanged = { changes += 1 }
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(2)
        await setup.transport.complete { $0.assetID == "a2" }
        for _ in 0..<1000 where setup.runner.uploadProgress?.done != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(setup.runner.uploadProgress?.done, 1, "The run noticed the result")

        setup.runner.appLeftForeground()
        await setup.runner.settle()

        XCTAssertEqual(changes, 1)
    }

    /// Switching off and on again while the cancel of the uploads in flight is still going: the new run
    /// enqueues nothing until it is done, or the cancel would take the new uploads with it.
    func testNewRunWaitsForThePendingCancelOfTheUploads() async throws {
        let setup = try await makeSetup(["a1"], transport: .manual)
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.transport.waitForEnqueued(1)
        await setup.transport.holdCancelAll()

        setup.runner.setEnabled(false)
        await setup.transport.waitForCancelAllStarted()
        Self.addAsset("a0", age: -5, to: setup.library)
        setup.setAlbum(["a1", "a0"])
        setup.runner.setEnabled(true)
        // The run scans (and finds a0), then would enqueue.
        for _ in 0..<100 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(setup.transport.sent.count, 1, "Nothing enqueued while the cancel is pending")

        // A wedged run fails the test instead of hanging it: the watchdog ends the run.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            XCTFail("The runs didn't finish within 20 s")
            setup.runner.appLeftForeground()
        }
        defer { watchdog.cancel() }
        await setup.transport.releaseCancelAll()
        for _ in 0..<2000 where setup.transport.sent.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(setup.transport.sent.count, 3, "Both items are enqueued once the cancel is done")
        await setup.transport.complete()
        await setup.runner.settle()
        for id in ["a0", "a1"] {
            let state = await setup.savedState(id)
            guard case .backedUp = state else { return XCTFail("\(id): expected backedUp, got \(String(describing: state))") }
        }
        XCTAssertEqual(setup.stagedFiles, [])
    }
}
