import XCTest
@testable import ImmichKit
@testable import ImmichUI

private struct WiFi: NetworkConditions {
    var isOnCellular: Bool { false }
}

/// The debounce waits the runner asked for. They return at once: tests don't wait for real time.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Duration] = []
    var sleeps: [Duration] { lock.withLock { _sleeps } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            lock.withLock { _sleeps.append(duration) }
            try Task.checkCancellation()
        }
    }
}

/// Holds the first upload request in flight until `release()` (then it goes to the server) or until
/// its task is cancelled (then it never reaches the server, like a request the app cut off).
private actor UploadGate {
    private var used = false
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Error>?
    private var released = false
    /// Held requests that were cancelled.
    private(set) var interrupted = 0

    /// Whether this call is the one to hold (only the first is).
    func claim() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func hold() async throws {
        isHeld = true
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters = []
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if released { continuation.resume() }
                    else if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { held = continuation }
                }
            } onCancel: {
                Task { await self.cancelHeld() }
            }
        } catch {
            interrupted += 1
            throw error
        }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }

    private func cancelHeld() {
        held?.resume(throwing: CancellationError())
        held = nil
    }
}

/// The mock server, with the first upload request held by `gate`.
private struct GatedUploadService: ImmichService {
    let mock: MockImmichService
    let gate: UploadGate

    func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult {
        if await gate.claim() { try await gate.hold() }
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
        let gate: UploadGate
        let model: BackupModel
        let runner: BackupRunner
        let directory: URL
        let defaults: UserDefaults
        let debounce: SleepLog

        var stagingDirectory: URL { directory.appendingPathComponent("Staging", isDirectory: true) }

        var stagedFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        }

        /// The item's state as last saved.
        func savedState(_ id: String) async -> BackupState? {
            await BackupIndex(directory: directory).entry(for: id)?.state
        }

        /// Upload requests made, the held one included.
        func uploadRequests() async -> Int {
            let interrupted = await gate.interrupted
            return await mock.uploads.count + interrupted
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

    /// Recents holds `ids` (the first is the newest) and is saved as the backup selection.
    private func makeSetup(_ ids: [String]) async throws -> Setup {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRunnerTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let suite = "BackupRunnerTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        let library = FakePhotoLibrary()
        for (offset, id) in ids.enumerated() { Self.addAsset(id, age: TimeInterval(offset), to: library) }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        let saved = BackupIndex(directory: directory)
        await saved.setSelection(BackupSelection(included: ["recents"]))
        try await saved.save()

        let mock = MockImmichService()
        let gate = UploadGate()
        let model = BackupModel(
            source: library, service: GatedUploadService(mock: mock, gate: gate), directory: directory,
            network: WiFi(), defaults: defaults)
        let retryClock = BackupRetryClock(now: { ContinuousClock.now }, sleep: { _ in try Task.checkCancellation() })
        let uploader = await model.makeUploader(clock: retryClock)
        let debounce = SleepLog()
        let runner = BackupRunner(
            model: model, uploader: uploader, source: library, staging: model.staging,
            debounce: .seconds(2), sleep: debounce.sleep)
        return Setup(library: library, mock: mock, gate: gate, model: model, runner: runner,
                     directory: directory, defaults: defaults, debounce: debounce)
    }

    /// Lets main-actor work queued by the code under test run until `condition` holds. Bounded, and
    /// independent of wall-clock time.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition never became true", file: file, line: line)
    }

    private func position(of request: MockImmichService.Request, in requests: [MockImmichService.Request]) -> Int? {
        requests.firstIndex(of: request)
    }

    // MARK: Tests

    func testDisabledRunsNothingOnActive() async throws {
        let setup = try await makeSetup(["a1"])
        XCTAssertFalse(setup.model.settings.isEnabled, "Off by default")
        setup.runner.appBecameActive()
        setup.runner.backupScreenOpened()
        setup.library.emitChange()
        await setup.runner.settle()

        let requests = await setup.mock.requests
        XCTAssertEqual(requests, [], "No scan and no upload while the switch is off")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertNil(setup.runner.uploadProgress)

        // Check Now still works.
        await setup.model.scan()
        let checks = await setup.mock.requests.filter { if case .bulkUploadCheck = $0 { true } else { false } }
        XCTAssertFalse(checks.isEmpty)
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 0)
    }

    func testEnabledActiveScansThenUploads() async throws {
        let setup = try await makeSetup(["a1"])
        await setup.gate.release()
        setup.runner.setEnabled(true)
        XCTAssertTrue(setup.model.settings.isEnabled)
        XCTAssertTrue(BackupSettings.load(from: setup.defaults).isEnabled, "The switch is saved")
        setup.runner.appBecameActive()
        await setup.runner.settle()

        let requests = await setup.mock.requests
        let firstCheck = requests.firstIndex { if case .bulkUploadCheck = $0 { true } else { false } }
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

    func testLibraryChangeDuringUploadFinishesItemThenRescans() async throws {
        let setup = try await makeSetup(["a2", "a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.gate.waitUntilHeld() // a2, the newest, is being uploaded

        // A photo is taken meanwhile.
        Self.addAsset("a3", age: -10, to: setup.library)
        setup.library.addAlbum(id: "recents", title: "Recents", assetIDs: ["a1", "a2", "a3"])
        setup.library.emitChange()
        await waitUntil { setup.runner.isRescanPending }
        XCTAssertTrue(setup.runner.isUploading)
        XCTAssertEqual(setup.debounce.sleeps, [.seconds(2)], "The change is debounced")

        await setup.gate.release()
        await setup.runner.settle()

        let requests = await setup.mock.requests
        let first = try XCTUnwrap(position(of: .upload(Self.checksum("a2")), in: requests), "a2 finished")
        let rescan = try XCTUnwrap(requests.indices.first { index in
            guard index > first, case .bulkUploadCheck = requests[index] else { return false }
            return true
        }, "A scan after the first upload")
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

    func testLeavingForegroundCancelsAndRetriesNextTime() async throws {
        let setup = try await makeSetup(["a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.gate.waitUntilHeld()
        XCTAssertTrue(setup.runner.isUploading)

        setup.runner.appLeftForeground()
        await setup.runner.settle()
        let interrupted = await setup.gate.interrupted
        XCTAssertEqual(interrupted, 1, "The upload in flight was cancelled")
        let afterLeaving = await setup.mock.uploads.count
        XCTAssertEqual(afterLeaving, 0)
        let pending = await setup.savedState("a1")
        XCTAssertEqual(pending, .pending(reason: .needsUpload), "Retried next time")
        XCTAssertEqual(setup.stagedFiles, [], "No staging file is left")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertNil(setup.runner.uploadProgress)

        // A change in the background starts nothing.
        setup.library.emitChange()
        await setup.runner.settle()
        let stillNone = await setup.mock.uploads.count
        XCTAssertEqual(stillNone, 0)

        setup.runner.appBecameActive()
        await setup.runner.settle()
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 2, "No request beyond the interrupted one and its retry")
        let state = await setup.savedState("a1")
        guard case .backedUp = state else { return XCTFail("Expected backedUp, got \(String(describing: state))") }
        XCTAssertEqual(setup.stagedFiles, [])
    }

    func testStopRemovesStagingAndRunsNothingAfter() async throws {
        let setup = try await makeSetup(["a2", "a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.gate.waitUntilHeld()
        // Left behind by an earlier run the system ended.
        try Data("left over".utf8).write(to: setup.stagingDirectory.appendingPathComponent("leftover.staged"))

        await setup.runner.stop()
        XCTAssertEqual(setup.stagedFiles, [], "Staging is emptied once nothing uploads")
        XCTAssertFalse(setup.runner.isUploading)
        let before = await setup.mock.requests

        setup.runner.appBecameActive()
        setup.runner.backupScreenOpened()
        setup.runner.setEnabled(true)
        setup.library.emitChange()
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

    func testTryAgainWaitsForTheItemInFlightThenRescans() async throws {
        let setup = try await makeSetup(["a2", "a1", "bad"])
        let bad = DeviceResource(type: .photo, filename: "bad.jpg")
        setup.library.failReads(of: bad, with: NSError(domain: "Test", code: 1))
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.gate.waitUntilHeld() // a2
        let failed = await setup.savedState("bad")
        guard case .failed = failed else { return XCTFail("Expected failed, got \(String(describing: failed))") }

        let retry = Task { await setup.runner.retryFailed(["bad"]) }
        for _ in 0..<200 { await Task.yield() }
        let whileUploading = await setup.savedState("bad")
        XCTAssertEqual(whileUploading, failed, "Try Again waits while an item uploads")

        await setup.gate.release()
        await retry.value
        await setup.runner.settle()
        let requests = await setup.mock.requests
        let first = try XCTUnwrap(position(of: .upload(Self.checksum("a2")), in: requests))
        let older = try XCTUnwrap(position(of: .upload(Self.checksum("a1")), in: requests))
        XCTAssertTrue(requests[first..<older].contains { if case .bulkUploadCheck = $0 { true } else { false } },
                      "The run paused for Try Again, then checked again before the next item")
        let uploads = await setup.uploadRequests()
        XCTAssertEqual(uploads, 2)
    }

    func testSwitchOffDuringUploadStops() async throws {
        let setup = try await makeSetup(["a2", "a1"])
        setup.runner.setEnabled(true)
        setup.runner.appBecameActive()
        await setup.gate.waitUntilHeld()

        setup.runner.setEnabled(false)
        XCTAssertFalse(setup.model.settings.isEnabled)
        XCTAssertFalse(BackupSettings.load(from: setup.defaults).isEnabled, "The switch is saved")
        await setup.runner.settle()
        let interrupted = await setup.gate.interrupted
        XCTAssertEqual(interrupted, 1)
        let uploads = await setup.mock.uploads.count
        XCTAssertEqual(uploads, 0, "No item after the interrupted one")
        XCTAssertFalse(setup.runner.isUploading)
        XCTAssertEqual(setup.stagedFiles, [])
        for id in ["a1", "a2"] {
            let state = await setup.savedState(id)
            XCTAssertEqual(state, .pending(reason: .needsUpload), id)
        }

        // Off: coming back to the app and library changes start nothing.
        let before = await setup.mock.requests
        setup.runner.appLeftForeground()
        setup.runner.appBecameActive()
        setup.library.emitChange()
        await setup.runner.settle()
        let after = await setup.mock.requests
        XCTAssertEqual(after, before)
    }
}
