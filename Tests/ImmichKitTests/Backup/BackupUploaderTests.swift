import XCTest
@testable import ImmichKit

/// Time for the uploader's back-off: `sleep` returns at once and moves `now` forward.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var _sleeps: [Duration] = []

    private static let startDate = Date(timeIntervalSince1970: 1_800_000_000)

    var seconds: Double { lock.withLock { Double(elapsed.components.seconds) } }
    var totalSlept: Duration { lock.withLock { _sleeps.reduce(.zero, +) } }
    /// Wall-clock time on this clock (retry times kept in the index).
    var date: Date { lock.withLock { Self.startDate.addingTimeInterval(BackupUploader.seconds(elapsed)) } }

    /// Moves time on without a sleep (time passing between launches).
    func advance(_ duration: Duration) { lock.withLock { elapsed += duration } }

    var clock: BackupRetryClock {
        BackupRetryClock(
            now: { [self] in lock.withLock { start + elapsed } },
            sleep: { [self] duration in
                try Task.checkCancellation()
                lock.withLock {
                    elapsed += duration
                    _sleeps.append(duration)
                }
                await Task.yield()
            },
            date: { [self] in date })
    }
}

/// Cellular or Wi-Fi, switchable during a test; records when (on `clock`) each item asked.
private final class TestNetwork: NetworkConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var cellular: Bool
    private var _checks: [Double] = []
    private let clock: TestClock?

    init(cellular: Bool = false, clock: TestClock? = nil) {
        self.cellular = cellular
        self.clock = clock
    }

    func setCellular(_ on: Bool) { lock.withLock { cellular = on } }
    /// The clock's time at each `isOnCellular` read: the uploader reads it once when it builds the
    /// queue and once per attempt.
    var checks: [Double] { lock.withLock { _checks } }

    var isOnCellular: Bool {
        get async {
            let now = clock?.seconds ?? 0
            return lock.withLock {
                _checks.append(now)
                return cellular
            }
        }
    }

    /// Doesn't observe the network: the stream ends at once.
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}

/// Counts calls; `increment()` returns the new count.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackupSettings
    init(_ value: BackupSettings = BackupSettings()) { self.value = value }
    func get() -> BackupSettings { lock.withLock { value } }
    func set(_ new: BackupSettings) { lock.withLock { value = new } }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [UploadProgress] = []
    func append(_ event: UploadProgress) { lock.withLock { _events.append(event) } }
    var events: [UploadProgress] { lock.withLock { _events } }
}

/// Holds reads of one asset until released (or cancelled), after the data has been delivered.
private actor ReadGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var released = false

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func markStarted() {
        hasStarted = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters = []
    }

    /// Marks the read started and suspends until `release()`.
    func hold() async {
        markStarted()
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

private struct GatedLibrary: PhotoLibrarySource {
    let base: FakePhotoLibrary
    let gate: ReadGate
    let assetID: String
    /// Keeps the read open until cancelled, instead of waiting for `release()`.
    let untilCancelled: Bool

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
        guard assetID == self.assetID else {
            return try await base.read(resource, of: assetID, allowNetwork: allowNetwork, onData: onData)
        }
        // Deliver everything first, then wait: a staging file with content exists while held.
        try await base.read(resource, of: assetID, allowNetwork: allowNetwork, onData: onData)
        if untilCancelled {
            await gate.markStarted()
            try await Task.sleep(for: .seconds(3600))
        } else {
            await gate.hold()
        }
        try Task.checkCancellation()
    }
}

/// Counts `shouldPause` calls, so a test can wait until a run has come round to waiting.
private final class PauseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// For `shouldPause`: counts the call and answers `false`.
    func ask() -> Bool {
        let reached = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            calls += 1
            let reached = waiters.filter { $0.count <= calls }
            waiters.removeAll { $0.count <= calls }
            return reached.map(\.continuation)
        }
        for continuation in reached { continuation.resume() }
        return false
    }

    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if calls >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    func set() { lock.withLock { _isSet = true } }
    var isSet: Bool { lock.withLock { _isSet } }
}

final class BackupUploaderTests: XCTestCase {
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        // Reasons are compared as English text, whatever the Mac's language.
        Localization.languageOverride = "en"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    // MARK: Helpers

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Setup {
        let library: FakePhotoLibrary
        let service: MockImmichService
        let index: BackupIndex
        let directory: URL
        let stagingDirectory: URL
        let clock: TestClock
        let network: TestNetwork
        let settings: SettingsBox
    }

    private func makeSetup(album ids: Set<String>, cellular: Bool = false, settings: BackupSettings = BackupSettings()) async -> Setup {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupUploaderTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let library = FakePhotoLibrary()
        library.addAlbum(id: "A", title: "Recents", assetIDs: ids)
        let index = BackupIndex(directory: directory)
        await index.setSelection(BackupSelection(included: ["A"]))
        let clock = TestClock()
        return Setup(
            library: library, service: MockImmichService(), index: index, directory: directory,
            stagingDirectory: directory.appendingPathComponent("Staging", isDirectory: true),
            clock: clock, network: TestNetwork(cellular: cellular, clock: clock), settings: SettingsBox(settings))
    }

    private func makeUploader(
        _ setup: Setup, source: (any PhotoLibrarySource)? = nil, service: (any ImmichService)? = nil
    ) -> BackupUploader {
        makeStack(setup, source: source, service: service).uploader
    }

    /// An uploader with its own staging folder, recorder and fake transport (as after a launch), sharing the
    /// setup's index, library, server and clock.
    private func makeStack(
        _ setup: Setup, source: (any PhotoLibrarySource)? = nil, service: (any ImmichService)? = nil,
        index: BackupIndex? = nil, mode: FakeTransport.Mode = .immediate,
        staging: BackupStaging? = nil
    ) -> (uploader: BackupUploader, transport: FakeTransport) {
        let settings = setup.settings
        let index = index ?? setup.index
        let clock = setup.clock
        let staging = staging ?? BackupStaging(directory: setup.stagingDirectory, freeSpace: { 100 * 1024 * 1024 * 1024 })
        let recorder = BackupResultRecorder(index: index, staging: staging, now: { clock.date })
        let transport = FakeTransport(
            index: index, staging: staging, recorder: recorder, service: service ?? setup.service,
            directory: setup.directory, mode: mode)
        let uploader = BackupUploader(
            source: source ?? setup.library, service: service ?? setup.service, index: index, staging: staging,
            settings: { settings.get() }, network: setup.network, clock: setup.clock.clock,
            connection: BackupUploadConnection(transport: transport, recorder: recorder, requests: .test))
        return (uploader, transport)
    }

    private func makeScanner(_ setup: Setup) -> BackupScanner {
        BackupScanner(source: setup.library, service: setup.service, index: setup.index,
                      network: setup.network, settings: setup.settings.get())
    }

    private func checksum(_ string: String) -> String {
        var sha = SHA1Stream()
        sha.update(Data(string.utf8))
        return sha.base64()
    }

    private static let utis: [DeviceResourceType: String] = [
        .photo: "public.heic", .fullSizePhoto: "public.jpeg", .pairedVideo: "com.apple.quicktime-movie",
        .fullSizePairedVideo: "com.apple.quicktime-movie", .video: "com.apple.quicktime-movie",
        .fullSizeVideo: "com.apple.quicktime-movie",
    ]

    /// Adds an asset whose resources hold `"<assetID>/<filename>/<modified>"` in two chunks and
    /// returns their checksums.
    @discardableResult
    private func addAsset(
        _ id: String, to library: FakePhotoLibrary, types: [DeviceResourceType] = [.photo],
        isVideo: Bool = false, created: Date = BackupUploaderTests.date, modified: Date = BackupUploaderTests.date,
        isFavorite: Bool = false, duration: TimeInterval = 0, filenames: [DeviceResourceType: String] = [:]
    ) -> [DeviceResourceType: String] {
        var sums: [DeviceResourceType: String] = [:]
        var resources: [DeviceResource] = []
        for type in types {
            let resource = DeviceResource(type: type, filename: filenames[type] ?? "\(id)-\(type.rawValue)",
                                          uniformTypeIdentifier: Self.utis[type])
            let content = "\(id)/\(resource.filename)/\(modified.timeIntervalSince1970)"
            let bytes = Data(content.utf8)
            library.setData([bytes.prefix(3), bytes.dropFirst(3)].map { Data($0) }, for: resource)
            sums[type] = checksum(content)
            resources.append(resource)
        }
        library.addAsset(DeviceAsset(
            id: id, isVideo: isVideo, creationDate: created, modificationDate: modified,
            isFavorite: isFavorite, duration: duration, resources: resources))
        return sums
    }

    /// Records the item as the scanner leaves it when the server lacks it.
    private func queue(
        _ id: String, _ sums: [DeviceResourceType: String], in index: BackupIndex,
        state: BackupState = .pending(reason: .needsUpload), serverIDs: [DeviceResourceType: String] = [:],
        modified: Date = BackupUploaderTests.date
    ) async {
        await index.set(BackupEntry(modificationDate: modified, checksums: sums, state: state, serverIDs: serverIDs), for: id)
    }

    private func run(
        _ uploader: BackupUploader, log: ProgressLog = ProgressLog(),
        shouldPause: @escaping @Sendable () async -> Bool = { false }
    ) async throws {
        try await uploader.run(progress: { log.append($0) }, shouldPause: shouldPause)
    }

    /// Awaits `task`; one that doesn't finish within `seconds` is cancelled and fails the test, so a
    /// wedged run is a failure instead of a hang.
    private func finish<T: Sendable>(
        _ task: Task<T, Error>, within seconds: Double = 30, file: StaticString = #filePath, line: UInt = #line
    ) async -> Result<T, Error> {
        let timedOut = LockedFlag()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(seconds))
            timedOut.set()
            task.cancel()
        }
        let result = await task.result
        watchdog.cancel()
        if timedOut.isSet { XCTFail("The run didn't finish within \(seconds) s", file: file, line: line) }
        return result
    }

    /// Polls until `condition` holds; `false` after `seconds` (a failing wait instead of a hanging one).
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func state(_ id: String, _ index: BackupIndex) async -> BackupState? { await index.entry(for: id)?.state }

    private func stagedFiles(_ setup: Setup) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: setup.stagingDirectory.path)) ?? []
    }

    private func uploadedChecksums(_ service: MockImmichService) async -> [String] {
        await service.uploads.map(\.checksum)
    }

    // MARK: Uploading

    func testUploadsNewestFirstAndMarksBackedUp() async throws {
        let setup = await makeSetup(album: ["old", "new", "mid"])
        let old = addAsset("old", to: setup.library, created: Self.date.addingTimeInterval(-3600))
        let new = addAsset("new", to: setup.library, created: Self.date, modified: Self.date.addingTimeInterval(5),
                           isFavorite: true)
        let mid = addAsset("mid", to: setup.library, created: Self.date.addingTimeInterval(-60))
        // Queued but no longer selected: not uploaded.
        let outside = addAsset("outside", to: setup.library)
        await queue("outside", outside, in: setup.index)
        try await makeScanner(setup).scan { _, _ in }
        let log = ProgressLog()

        try await run(makeUploader(setup), log: log)

        let uploadedSums = await uploadedChecksums(setup.service)
        XCTAssertEqual(uploadedSums, [new[.photo]!, mid[.photo]!, old[.photo]!])
        let firstUpload = await setup.service.uploads.first
        let first = try XCTUnwrap(firstUpload)
        XCTAssertEqual(first.filename, "new-photo")
        XCTAssertEqual(first.mimeType, "image/heic")
        XCTAssertEqual(first.createdAt, Self.date)
        XCTAssertEqual(first.modifiedAt, Self.date.addingTimeInterval(5))
        XCTAssertTrue(first.isFavorite)
        XCTAssertNil(first.duration)
        XCTAssertNil(first.livePhotoVideoID)
        XCTAssertFalse(first.allowsCellular, "Cellular switches are off")

        let saved = BackupIndex(directory: setup.directory)
        for id in ["old", "new", "mid"] {
            let savedEntry = await saved.entry(for: id)
            let entry = try XCTUnwrap(savedEntry, id)
            let serverID = try XCTUnwrap(entry.serverIDs[.photo], id)
            XCTAssertEqual(entry.state, .backedUp(serverAssetID: serverID), id)
        }
        let outsideState = await state("outside", setup.index)
        XCTAssertEqual(outsideState, .pending(reason: .needsUpload))
        XCTAssertEqual(log.events.first, UploadProgress(done: 0, total: 3, currentFilename: "new-photo"))
        XCTAssertEqual(log.events.last, UploadProgress(done: 3, total: 3, currentFilename: nil))
        XCTAssertEqual(stagedFiles(setup), [])

        // The server now has them: the next scan finds everything backed up, nothing more is uploaded.
        let counts = try await makeScanner(setup).scan { _, _ in }
        XCTAssertEqual(counts.backedUp, 3)
        try await run(makeUploader(setup))
        let total = await setup.service.uploads.count
        XCTAssertEqual(total, 3)
    }

    func testVideoUploadsWithItsDuration() async throws {
        let setup = await makeSetup(album: ["v"])
        let sums = addAsset("v", to: setup.library, types: [.video], isVideo: true, duration: 12.4)
        await queue("v", sums, in: setup.index)

        try await run(makeUploader(setup))

        let firstUpload = await setup.service.uploads.first
        let upload = try XCTUnwrap(firstUpload)
        XCTAssertEqual(upload.duration, 12.4)
        XCTAssertEqual(upload.mimeType, "video/quicktime")
        XCTAssertEqual(upload.checksum, sums[.video])
    }

    func testEditedPhotoUploadsTheEditUnderTheOriginalName() async throws {
        let setup = await makeSetup(album: ["e"])
        let sums = addAsset("e", to: setup.library, types: [.photo, .fullSizePhoto],
                            filenames: [.photo: "IMG_0042.HEIC", .fullSizePhoto: "FullSizeRender.jpg"])
        await queue("e", [.fullSizePhoto: sums[.fullSizePhoto]!], in: setup.index)

        try await run(makeUploader(setup))

        let firstUpload = await setup.service.uploads.first
        let upload = try XCTUnwrap(firstUpload)
        XCTAssertEqual(upload.checksum, sums[.fullSizePhoto])
        XCTAssertEqual(upload.filename, "IMG_0042.jpg")
        XCTAssertEqual(upload.mimeType, "image/jpeg")
    }

    /// Phase 3: the photo goes up without `livePhotoVideoId` (in the background the motion's ID may not be
    /// known yet); the motion goes up hidden and the two are linked once both are on the server.
    func testLivePhotoUploadsMotionFirstThenLinkedPhoto() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        let stack = makeStack(setup)

        try await run(stack.uploader)

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [sums[.pairedVideo]!, sums[.photo]!])
        let stored = await setup.index.entry(for: "l")
        let entry = try XCTUnwrap(stored)
        let motionID = try XCTUnwrap(entry.serverIDs[.pairedVideo])
        let photoID = try XCTUnwrap(entry.serverIDs[.photo])
        XCTAssertNil(uploads[0].livePhotoVideoID)
        XCTAssertNil(uploads[0].duration, "The motion half is not a video asset of its own")
        XCTAssertNil(uploads[1].livePhotoVideoID, "Linked afterwards instead")
        XCTAssertEqual(stack.transport.sent.map { $0.fields["visibility"] }, ["hidden", nil], "Only the motion is hidden")
        XCTAssertEqual(entry.state, .backedUp(serverAssetID: photoID))
        XCTAssertEqual(entry.needsLink, false)
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["\(photoID)->\(motionID)"], "Linked once both are on the server")
    }

    func testLivePhotoRetryAfterPhotoFailureReusesMotionDuplicate() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        await setup.service.setUploadResults([AssetUploadResult(id: "motion-1", status: .created)])
        await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(500), afterCalls: 1)
        let uploader = makeUploader(setup)
        let service = setup.service

        // First run: motion created, photo answered 500; stopped while waiting to retry.
        try await run(uploader, shouldPause: { await service.uploads.count >= 2 })
        let afterFirst = await state("l", setup.index)
        XCTAssertEqual(afterFirst, .pending(reason: .needsUpload))

        let learned = await setup.index.entry(for: "l")?.serverIDs
        XCTAssertEqual(learned, [.pairedVideo: "motion-1"], "The motion's ID is kept for the retry")

        // Second run: the motion the server has is not sent again; the photo is created and linked to it.
        await setup.service.setUploadFailure(nil)
        try await run(uploader)

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [sums[.pairedVideo]!, sums[.photo]!, sums[.photo]!])
        XCTAssertNil(uploads[2].livePhotoVideoID, "Phase 3: linked after the upload")
        let stored = await setup.index.entry(for: "l")
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(entry.serverIDs[.pairedVideo], "motion-1", "No second motion asset")
        let photoID = try XCTUnwrap(entry.serverIDs[.photo])
        XCTAssertEqual(entry.state, .backedUp(serverAssetID: photoID))
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["\(photoID)->motion-1"])
        XCTAssertEqual(stagedFiles(setup), [])
    }

    /// The motion was uploaded but its ID never recorded (the app was stopped before the index was
    /// saved): sending it again is answered as a duplicate, and that ID is used.
    func testMotionSentAgainWithoutARecordedIDIsAnsweredDuplicate() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        await setup.service.setUploadResults([AssetUploadResult(id: "motion-1", status: .created)])
        await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(500), afterCalls: 1)
        let service = setup.service
        try await run(makeUploader(setup), shouldPause: { await service.uploads.count >= 2 })
        await queue("l", sums, in: setup.index) // as if the learned ID had been lost
        await setup.service.setUploadFailure(nil)

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [sums[.pairedVideo]!, sums[.photo]!, sums[.pairedVideo]!, sums[.photo]!])
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.serverIDs[.pairedVideo], "motion-1", "No second motion asset")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        let photoID = try XCTUnwrap(entry?.serverIDs[.photo])
        XCTAssertEqual(links, ["\(photoID)->motion-1"], "Phase 3: the photo is linked to the duplicate's ID after the upload")
    }

    func testHalfAlreadyOnTheServerIsNeverSent() async throws {
        let setup = await makeSetup(album: ["p", "m"])
        let p = addAsset("p", to: setup.library, types: [.photo, .pairedVideo], created: Self.date)
        let m = addAsset("m", to: setup.library, types: [.photo, .pairedVideo], created: Self.date.addingTimeInterval(-60))
        // The server has p's photo and m's motion (found by the scan, not trashed).
        await setup.service.setServerChecksums([p[.photo]!, m[.pairedVideo]!])
        try await makeScanner(setup).scan { _, _ in }
        let pPhotoID = "server-\(p[.photo]!)", mMotionID = "server-\(m[.pairedVideo]!)"
        let pScanned = await setup.index.entry(for: "p")
        XCTAssertEqual(pScanned?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(pScanned?.serverIDs, [.photo: pPhotoID])
        let readsAfterScan = setup.library.reads.count

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [p[.pairedVideo]!, m[.photo]!], "Only the halves the server lacks")
        XCTAssertNil(uploads[1].livePhotoVideoID, "Phase 3: linked after the upload")
        XCTAssertEqual(setup.library.reads.count, readsAfterScan + 2, "The known halves aren't even read")
        let pEntry = await setup.index.entry(for: "p")
        let pMotionID = try XCTUnwrap(pEntry?.serverIDs[.pairedVideo])
        XCTAssertEqual(pEntry?.state, .backedUp(serverAssetID: pPhotoID))
        let mEntry = await setup.index.entry(for: "m")
        let mPhotoID = try XCTUnwrap(mEntry?.serverIDs[.photo])
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["\(pPhotoID)->\(pMotionID)", "\(mPhotoID)->\(mMotionID)"],
                       "A photo already there is linked to its new motion; a new photo to the stored motion ID")
        XCTAssertEqual(mEntry?.state, .backedUp(serverAssetID: mPhotoID))
        XCTAssertEqual(mEntry?.serverIDs[.pairedVideo], mMotionID)
    }

    func testLivePhotoWhosePhotoWasAlreadyOnTheServerIsLinked() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        await setup.service.setUploadResults([
            AssetUploadResult(id: "M", status: .created), AssetUploadResult(id: "P", status: .duplicate),
        ])

        try await run(makeUploader(setup))

        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M"], "A duplicate photo doesn't take livePhotoVideoId: link it")
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P", .pairedVideo: "M"])
    }

    func testLinkFailureKeepsNeedsUploadWithLearnedIDsAndRelinksNextTime() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        await setup.service.setUploadResults([
            AssetUploadResult(id: "M", status: .created), AssetUploadResult(id: "P", status: .duplicate),
        ])
        await setup.service.setLinkFailure(ImmichServiceError.unexpectedStatus(500))
        let service = setup.service

        try await run(makeUploader(setup), shouldPause: { await !service.links.isEmpty })

        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P", .pairedVideo: "M"])
        XCTAssertEqual(entry?.needsLink, true)

        await setup.service.setLinkFailure(nil)
        try await run(makeUploader(setup))

        let results = await setup.service.uploads.count
        XCTAssertEqual(results, 2, "Both halves are on the server: the retry only links")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M", "P->M"])
        let final = await state("l", setup.index)
        XCTAssertEqual(final, .backedUp(serverAssetID: "P"))
        let cleared = await setup.index.entry(for: "l")?.needsLink
        XCTAssertEqual(cleared, false)
    }

    /// The runner scans before every run: the scan must not take a split Live Photo for backed up.
    func testFailedLinkSurvivesTheScanAndIsRetried() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        try await makeScanner(setup).scan { _, _ in }
        await setup.service.setUploadResults([
            AssetUploadResult(id: "M", status: .created), AssetUploadResult(id: "P", status: .duplicate),
        ])
        await setup.service.setLinkFailure(ImmichServiceError.unexpectedStatus(503))
        let service = setup.service
        try await run(makeUploader(setup), shouldPause: { await !service.links.isEmpty })

        // Both halves are duplicates on the server now; the link is still missing.
        let counts = try await makeScanner(setup).scan { _, _ in }
        XCTAssertEqual(counts.backedUp, 0)
        let scanned = await setup.index.entry(for: "l")
        XCTAssertEqual(scanned?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(scanned?.needsLink, true)
        XCTAssertEqual(scanned?.serverIDs, [.photo: "P", .pairedVideo: "M"])

        await setup.service.setLinkFailure(nil)
        try await run(makeUploader(setup))

        let uploads = await uploadedChecksums(setup.service)
        XCTAssertEqual(uploads, [sums[.pairedVideo]!, sums[.photo]!], "Nothing sent again")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M", "P->M"], "Exactly one re-link")
        let final = await setup.index.entry(for: "l")
        XCTAssertEqual(final?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(final?.needsLink, false)
        let after = try await makeScanner(setup).scan { _, _ in }
        XCTAssertEqual(after.backedUp, 1)
    }

    /// Marked (and saved) before the first byte goes out, so an app stopped between the motion upload
    /// and the link still links next time.
    func testLivePhotoIsMarkedForLinkingBeforeAnythingIsSent() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        // Phase 3: the uploads are the transport's, held until the test finishes them.
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await stack.transport.waitForEnqueued(1)
        XCTAssertEqual(stack.transport.sent.first?.savedNeedsLink, true, "Saved before the first half was enqueued")
        let saved = await BackupIndex(directory: setup.directory).entry(for: "l")
        XCTAssertEqual(saved?.needsLink, true)
        task.cancel()
        _ = await task.result
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(entry?.needsLink, true)
    }

    func testPermanentLinkRefusalBecomesFailed() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        await setup.service.setUploadResults([
            AssetUploadResult(id: "M", status: .created), AssetUploadResult(id: "P", status: .duplicate),
        ])
        await setup.service.setLinkFailure(ImmichServiceError.unexpectedStatus(400))

        try await run(makeUploader(setup))

        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .failed(
            reason: "Couldn't join the photo and video of this Live Photo on the server: The server answered with HTTP status 400."))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P", .pairedVideo: "M"])
        XCTAssertEqual(entry?.needsLink, true, "Try Again links it")
        let links = await setup.service.links.count
        XCTAssertEqual(links, 1, "A refusal is not retried automatically")
        XCTAssertEqual(setup.clock.totalSlept, .zero)
    }

    func testLinkNetworkLossHoldsTheRunAndServerErrorsBackOffPerItem() async throws {
        for (error, holds) in [
            (ImmichServiceError.network("offline"), true), (.unexpectedStatus(503), true), (.unexpectedStatus(500), false),
        ] {
            let setup = await makeSetup(album: ["a", "b"])
            let a = addAsset("a", to: setup.library, types: [.photo, .pairedVideo], created: Self.date)
            let b = addAsset("b", to: setup.library, types: [.photo, .pairedVideo], created: Self.date.addingTimeInterval(-60))
            await queue("a", a, in: setup.index, serverIDs: [.photo: "PA"])
            await queue("b", b, in: setup.index, serverIDs: [.photo: "PB"])
            await setup.service.setLinkFailure(error)

            try await run(makeUploader(setup))

            let order = await setup.service.links.map(\.photoID)
            let expected = holds
                ? Array(repeating: "PA", count: 5) + Array(repeating: "PB", count: 5)
                : Array(repeating: ["PA", "PB"], count: 5).flatMap { $0 }
            XCTAssertEqual(order, expected, "\(error)")
            let uploads = await setup.service.uploads.count
            XCTAssertEqual(uploads, 2, "Each motion is sent once; retries only link")
        }
    }

    // MARK: Sent back to the scanner

    func testChangedAssetIsSentBackToScanner() async throws {
        let setup = await makeSetup(album: ["c"])
        addAsset("c", to: setup.library)
        try await makeScanner(setup).scan { _, _ in }
        let readsAfterScan = setup.library.reads.count
        // Edited on the phone after the scan.
        addAsset("c", to: setup.library, modified: Self.date.addingTimeInterval(60))

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(setup.library.reads.count, readsAfterScan, "Not read: the scanner re-hashes it")
        let entry = await setup.index.entry(for: "c")
        XCTAssertEqual(entry?.state, .pending(reason: .notChecked))
        XCTAssertEqual(entry?.checksums, [:])
        let saved = await BackupIndex(directory: setup.directory).entry(for: "c")
        XCTAssertEqual(saved?.state, .pending(reason: .notChecked))
    }

    func testChecksumMismatchIsSentBackToScanner() async throws {
        let setup = await makeSetup(album: ["m"])
        addAsset("m", to: setup.library)
        try await makeScanner(setup).scan { _, _ in }
        // Same modification date, different bytes (an edit PhotoKit hasn't dated yet).
        setup.library.setData([Data("other bytes".utf8)],
                              for: DeviceResource(type: .photo, filename: "m-photo", uniformTypeIdentifier: "public.heic"))

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0, "Stale checksum: nothing is uploaded under it")
        let entry = await setup.index.entry(for: "m")
        XCTAssertEqual(entry?.state, .pending(reason: .notChecked))
        XCTAssertEqual(entry?.checksums, [:])
        XCTAssertEqual(stagedFiles(setup), [])
    }

    func testEntryChangedDuringUploadIsNotOverwritten() async throws {
        let setup = await makeSetup(album: ["r"])
        let sums = addAsset("r", to: setup.library)
        await queue("r", sums, in: setup.index)
        let gate = ReadGate()
        let uploader = makeUploader(setup, source: GatedLibrary(base: setup.library, gate: gate, assetID: "r", untilCancelled: false))
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await gate.waitUntilStarted()
        // The scanner recorded a newer version meanwhile.
        let newer = BackupEntry(modificationDate: Self.date.addingTimeInterval(60), checksums: [:], state: .pending(reason: .notChecked))
        await setup.index.set(newer, for: "r")
        await gate.release()
        try await task.value

        let entry = await setup.index.entry(for: "r")
        XCTAssertEqual(entry, newer)
    }

    // MARK: Errors and retry

    func testServerErrorKeepsNeedsUploadAndBacksOff() async throws {
        let setup = await makeSetup(album: ["s"])
        let sums = addAsset("s", to: setup.library)
        await queue("s", sums, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(503))
        let uploader = makeUploader(setup)

        try await run(uploader)

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 5)
        // One read when the run builds its queue, then one per attempt.
        XCTAssertEqual(setup.network.checks, [0, 0, 5, 35, 155, 755], "Back-off: 5 s, 30 s, 2 min, 10 min")
        let afterRun = await state("s", setup.index)
        XCTAssertEqual(afterRun, .pending(reason: .needsUpload))
        XCTAssertEqual(stagedFiles(setup), [])

        // Skipped for the rest of this session.
        await setup.service.setUploadFailure(nil)
        try await run(uploader)
        let afterSecond = await setup.service.uploads.count
        XCTAssertEqual(afterSecond, 5)
        // Phase 3: kept in the index, so a new launch doesn't send it again at once either…
        try await run(makeUploader(setup))
        let afterRelaunch = await setup.service.uploads.count
        XCTAssertEqual(afterRelaunch, 5)
        let retry = await setup.index.entry(for: "s")?.retry
        XCTAssertEqual(retry?.failures, 5)
        // … but once the pause is over.
        setup.clock.advance(.seconds(BackupUploader.givenUpPause))
        try await run(makeUploader(setup))
        let final = await state("s", setup.index)
        let finalID = await setup.index.entry(for: "s")?.serverIDs[.photo]
        XCTAssertEqual(final, .backedUp(serverAssetID: try XCTUnwrap(finalID)))
    }

    func testRetryableErrorsKeepNeedsUpload() async throws {
        let errors: [any Error] = [
            ImmichServiceError.unexpectedStatus(408), ImmichServiceError.unexpectedStatus(429),
            ImmichServiceError.unexpectedStatus(500), ImmichServiceError.unexpectedStatus(502),
            ImmichServiceError.network("offline"), ImmichServiceError.invalidResponse,
        ]
        for error in errors {
            let setup = await makeSetup(album: ["s"])
            let sums = addAsset("s", to: setup.library)
            await queue("s", sums, in: setup.index)
            await setup.service.setUploadFailure(error)
            let service = setup.service
            try await run(makeUploader(setup), shouldPause: { await !service.uploads.isEmpty })
            let after = await state("s", setup.index)
            XCTAssertEqual(after, .pending(reason: .needsUpload), "\(error)")
        }
    }

    func testServerErrorLetsOtherItemsGoFirst() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(500))

        try await run(makeUploader(setup))

        let order = await uploadedChecksums(setup.service)
        XCTAssertEqual(order, Array(repeating: [a[.photo]!, b[.photo]!], count: 5).flatMap { $0 })
    }

    func testNetworkLossRetriesTheSameItemBeforeReadingOthers() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.network("The Internet connection appears to be offline."))

        try await run(makeUploader(setup))

        let order = await uploadedChecksums(setup.service)
        XCTAssertEqual(order, Array(repeating: a[.photo]!, count: 5) + Array(repeating: b[.photo]!, count: 5))
    }

    /// Given up on for the session while offline, tried again once the network is back. An item given up on
    /// for another reason (a server that is down) stays given up on.
    func testNetworkReturnedRetriesItemsGivenUpOnForNoConnection() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        let uploader = makeUploader(setup)
        await queue("a", a, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.network("offline", code: .notConnectedToInternet))
        try await run(uploader)
        await queue("b", b, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(503))
        try await run(uploader)
        let given = await uploadedChecksums(setup.service)
        XCTAssertEqual(given, Array(repeating: a[.photo]!, count: 5) + Array(repeating: b[.photo]!, count: 5))

        await setup.service.setUploadFailure(nil)
        try await run(uploader)
        let stillSkipped = await setup.service.uploads.count
        XCTAssertEqual(stillSkipped, 10, "Both are given up on until the network returns")

        await uploader.networkReturned()
        try await run(uploader)
        let after = await uploadedChecksums(setup.service)
        XCTAssertEqual(Array(after.dropFirst(10)), [a[.photo]!], "Only the item that failed for no connection")
        let aState = await state("a", setup.index)
        guard case .backedUp = aState else { return XCTFail("Expected backedUp, got \(String(describing: aState))") }
        let bState = await state("b", setup.index)
        XCTAssertEqual(bState, .pending(reason: .needsUpload))
    }

    /// A run waiting out the back-off after no connection: once the network is back the next run doesn't wait.
    func testNetworkReturnedEndsTheBackOff() async throws {
        let setup = await makeSetup(album: ["a"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let uploader = makeUploader(setup)
        await queue("a", a, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.network("offline", code: .notConnectedToInternet), afterCalls: 0)
        // Asked before the item, after it failed, then during the back-off wait: paused there (as the
        // runner does when the network returns).
        let asked = LockedCounter()
        try await run(uploader, shouldPause: { asked.increment() > 2 })
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 1)
        let sleptBefore = setup.clock.totalSlept
        XCTAssertGreaterThan(sleptBefore, .zero, "It was waiting")

        await setup.service.setUploadFailure(nil)
        await uploader.networkReturned()
        try await run(uploader)
        XCTAssertEqual(setup.clock.totalSlept, sleptBefore, "No wait left after the network returned")
        let aState = await state("a", setup.index)
        guard case .backedUp = aState else { return XCTFail("Expected backedUp, got \(String(describing: aState))") }
    }

    /// A server that is down (502, 503, 504 from the proxy) fails every item alike: the run waits as a
    /// whole instead of reading the next items for nothing.
    func testServerDownHoldsTheRun() async throws {
        for status in [502, 503, 504] {
            let setup = await makeSetup(album: ["a", "b"])
            let a = addAsset("a", to: setup.library, created: Self.date)
            let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
            await queue("a", a, in: setup.index)
            await queue("b", b, in: setup.index)
            await setup.service.setUploadFailure(ImmichServiceError.unexpectedStatus(status))

            try await run(makeUploader(setup))

            let order = await uploadedChecksums(setup.service)
            XCTAssertEqual(order, Array(repeating: a[.photo]!, count: 5) + Array(repeating: b[.photo]!, count: 5), "\(status)")
            for id in ["a", "b"] {
                let after = await state(id, setup.index)
                XCTAssertEqual(after, .pending(reason: .needsUpload), "\(status)")
            }
        }
    }

    func testRejectedBecomesFailedWithServerMessage() async throws {
        let setup = await makeSetup(album: ["r", "q"])
        let r = addAsset("r", to: setup.library)
        await queue("r", r, in: setup.index)
        await setup.service.setUploadFailure(BackupUploadError.rejected(status: 400, message: "Unsupported file type"))

        try await run(makeUploader(setup))

        let rState = await state("r", setup.index)
        XCTAssertEqual(rState, .failed(reason: "Unsupported file type"))
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 1, "A refusal is not retried")
        XCTAssertEqual(setup.clock.totalSlept, .zero)

        // Without a message from the server, the status is shown.
        let q = addAsset("q", to: setup.library)
        await queue("q", q, in: setup.index)
        await setup.service.setUploadFailure(BackupUploadError.rejected(status: 415, message: ""))
        try await run(makeUploader(setup))
        let qState = await state("q", setup.index)
        XCTAssertEqual(qState, .failed(reason: "The server answered with HTTP status 415."))
        let saved = await BackupIndex(directory: setup.directory).entry(for: "r")
        XCTAssertEqual(saved?.checksums, r, "Checksums are kept for Try Again")
    }

    func testUnauthorizedStopsTheRun() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        await setup.service.setUploadFailure(ImmichServiceError.unauthorized)

        do {
            try await run(makeUploader(setup))
            XCTFail("Expected unauthorized")
        } catch let error as ImmichServiceError {
            XCTAssertEqual(error, .unauthorized)
        }

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 1)
        for id in ["a", "b"] {
            let s = await state(id, setup.index)
            XCTAssertEqual(s, .pending(reason: .needsUpload), id)
        }
        XCTAssertEqual(stagedFiles(setup), [])
    }

    func testReadFailureBecomesFailedAsInTheScanner() async throws {
        let setup = await makeSetup(album: ["f"])
        let sums = addAsset("f", to: setup.library)
        await queue("f", sums, in: setup.index)
        struct Broken: Error, LocalizedError { var errorDescription: String? { "disk on fire" } }
        setup.library.failReads(of: DeviceResource(type: .photo, filename: "f-photo", uniformTypeIdentifier: "public.heic"),
                                with: Broken())

        try await run(makeUploader(setup))

        let s = await state("f", setup.index)
        XCTAssertEqual(s, .failed(reason: "Couldn't read f-photo: disk on fire"))
        XCTAssertEqual(stagedFiles(setup), [])
    }

    func testNotEnoughSpaceFailsTheItemAndStopsTheRun() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        let uploader = makeStack(setup, staging: BackupStaging(directory: setup.stagingDirectory, freeSpace: { 1024 })).uploader

        do {
            try await run(uploader)
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }

        let aState = await state("a", setup.index)
        XCTAssertEqual(aState, .failed(reason: "Not enough free space on the iPhone."))
        let bState = await state("b", setup.index)
        XCTAssertEqual(bState, .pending(reason: .needsUpload))
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
    }

    func testCellularWithSwitchOffWaitsForWiFiAndUploadsNothing() async throws {
        let setup = await makeSetup(album: ["w"])
        let sums = addAsset("w", to: setup.library)
        try await makeScanner(setup).scan { _, _ in }
        let readsAfterScan = setup.library.reads.count
        setup.network.setCellular(true)

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(setup.library.reads.count, readsAfterScan, "No iCloud download on cellular either")
        let waiting = await setup.index.entry(for: "w")
        XCTAssertEqual(waiting?.state, .pending(reason: .waitingForWiFi))
        XCTAssertEqual(waiting?.checksums, sums)
        // A scan on cellular leaves it waiting and reads nothing.
        try await makeScanner(setup).scan { _, _ in }
        XCTAssertEqual(setup.library.reads.count, readsAfterScan)
        // Still on cellular: a run doesn't count it as being uploaded.
        let lookups = setup.library.singleLookups
        let log = ProgressLog()
        try await run(makeUploader(setup), log: log)
        XCTAssertEqual(log.events, [UploadProgress(done: 0, total: 0, currentFilename: nil)])
        XCTAssertEqual(setup.library.singleLookups, lookups)

        // Back on Wi-Fi: uploaded, with the request still kept off cellular.
        setup.network.setCellular(false)
        try await run(makeUploader(setup))
        let firstUpload = await setup.service.uploads.first
        let upload = try XCTUnwrap(firstUpload)
        XCTAssertFalse(upload.allowsCellular)
        let s = await state("w", setup.index)
        let serverID = await setup.index.entry(for: "w")?.serverIDs[.photo]
        XCTAssertEqual(s, .backedUp(serverAssetID: try XCTUnwrap(serverID)))
    }

    /// On cellular with both switches off, the run doesn't walk the queue item by item: everything waits
    /// for Wi-Fi in one pass, with one index save, and nothing counts as being uploaded.
    func testCellularWithSwitchesOffMarksTheQueueWaitingInOnePass() async throws {
        let ids = (0..<50).map { "c\($0)" }
        let setup = await makeSetup(album: Set(ids), cellular: true)
        for (n, id) in ids.enumerated() {
            let video = n.isMultiple(of: 2)
            let sums = addAsset(id, to: setup.library, types: [video ? .video : .photo], isVideo: video)
            await queue(id, sums, in: setup.index)
        }
        try await setup.index.save()
        let savesBefore = await setup.index.saveCount
        let lookups = setup.library.singleLookups
        let log = ProgressLog()

        try await run(makeUploader(setup), log: log)

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(setup.library.reads, [])
        XCTAssertEqual(setup.library.singleLookups, lookups, "no item is fetched on its own")
        for id in ids {
            let s = await state(id, setup.index)
            XCTAssertEqual(s, .pending(reason: .waitingForWiFi), id)
        }
        let saves = await setup.index.saveCount - savesBefore
        XCTAssertGreaterThanOrEqual(saves, 1, "the waiting items are saved")
        XCTAssertLessThanOrEqual(saves, 2)
        XCTAssertEqual(log.events, [UploadProgress(done: 0, total: 0, currentFilename: nil)])
        XCTAssertLessThanOrEqual(setup.network.checks.count, 2, "the network is asked once per run, not per item")
    }

    /// Only the media type the cellular switches allow is queued; the rest waits for Wi-Fi uncounted.
    func testCellularQueuesOnlyTheAllowedMediaType() async throws {
        let setup = await makeSetup(album: ["p", "v"], cellular: true, settings: BackupSettings(photosOnCellular: true))
        let p = addAsset("p", to: setup.library, created: Self.date)
        let v = addAsset("v", to: setup.library, types: [.video], isVideo: true, created: Self.date.addingTimeInterval(60))
        await queue("p", p, in: setup.index)
        await queue("v", v, in: setup.index)
        let log = ProgressLog()

        try await run(makeUploader(setup), log: log)

        let uploads = await uploadedChecksums(setup.service)
        XCTAssertEqual(uploads, [p[.photo]!])
        XCTAssertEqual(log.events.map(\.total), Array(repeating: 1, count: log.events.count))
        let vState = await state("v", setup.index)
        XCTAssertEqual(vState, .pending(reason: .waitingForWiFi))
    }

    func testSettingsAreReadForEachItem() async throws {
        let setup = await makeSetup(album: ["a", "b"], cellular: true, settings: BackupSettings(photosOnCellular: true))
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        let service = setup.service
        let settings = setup.settings

        // The switch is turned off while the first item uploads.
        try await run(makeUploader(setup), shouldPause: {
            if await !service.uploads.isEmpty { settings.set(BackupSettings(photosOnCellular: false)) }
            return false
        })

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [a[.photo]!])
        XCTAssertTrue(uploads[0].allowsCellular)
        let bState = await state("b", setup.index)
        XCTAssertEqual(bState, .pending(reason: .waitingForWiFi))
    }

    func testCancellationLeavesNoStagingFiles() async throws {
        let setup = await makeSetup(album: ["c"])
        let sums = addAsset("c", to: setup.library)
        await queue("c", sums, in: setup.index)
        let gate = ReadGate()
        let uploader = makeUploader(setup, source: GatedLibrary(base: setup.library, gate: gate, assetID: "c", untilCancelled: true))
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await gate.waitUntilStarted()
        XCTAssertEqual(stagedFiles(setup).count, 1, "Staged while reading")
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(stagedFiles(setup), [])
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
        let saved = await BackupIndex(directory: setup.directory).entry(for: "c")
        XCTAssertEqual(saved?.state, .pending(reason: .needsUpload), "Retried next time")
    }

    /// Phase 3: cancelling the run doesn't cancel an upload the transport has (it belongs to the system).
    /// Its body stays until the result is recorded, then nothing is left.
    func testCancellationDuringUploadLeavesNoStagingFiles() async throws {
        let setup = await makeSetup(album: ["c"])
        let sums = addAsset("c", to: setup.library)
        await queue("c", sums, in: setup.index)
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await stack.transport.waitForEnqueued(1)
        XCTAssertEqual(stagedFiles(setup).count, 1)
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(stagedFiles(setup).count, 1, "The body of the upload in flight stays")
        XCTAssertEqual(stack.transport.cancelAllCount, 0)
        let s = await state("c", setup.index)
        XCTAssertEqual(s, .pending(reason: .needsUpload))

        await stack.transport.complete()
        XCTAssertEqual(stagedFiles(setup), [])
        let cancelled = await setup.service.cancelledRequests
        XCTAssertEqual(cancelled, [])
        let uploads = await uploadedChecksums(setup.service)
        XCTAssertEqual(uploads, [sums[.photo]!], "Sent once")
        let final = await state("c", setup.index)
        guard case .backedUp = final else { return XCTFail("Expected backedUp, got \(String(describing: final))") }
    }

    func testPauseBetweenItemsIsHonoured() async throws {
        let setup = await makeSetup(album: ["a", "b", "c"])
        for (offset, id) in ["a", "b", "c"].enumerated() {
            let sums = addAsset(id, to: setup.library, created: Self.date.addingTimeInterval(Double(-offset * 60)))
            await queue(id, sums, in: setup.index)
        }
        let service = setup.service
        let uploader = makeUploader(setup)

        try await run(uploader, shouldPause: { await !service.uploads.isEmpty })

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 1, "The current item finished, then the run paused")
        let aState = await state("a", setup.index)
        XCTAssertNotEqual(aState, .pending(reason: .needsUpload))
        for id in ["b", "c"] {
            let s = await state(id, setup.index)
            XCTAssertEqual(s, .pending(reason: .needsUpload), id)
        }

        try await run(uploader)
        let after = await setup.service.uploads.count
        XCTAssertEqual(after, 3)
    }

    func testRetryFailedRequeues() async throws {
        let setup = await makeSetup(album: ["f", "b"])
        let f = addAsset("f", to: setup.library)
        let b = addAsset("b", to: setup.library)
        await queue("f", f, in: setup.index, state: .failed(reason: "Unsupported file type"), serverIDs: [.photo: "old"])
        await queue("b", b, in: setup.index, state: .backedUp(serverAssetID: "B"), serverIDs: [.photo: "B"])

        await makeUploader(setup).retryFailed(["f", "b", "missing"])

        let saved = BackupIndex(directory: setup.directory)
        let entry = await saved.entry(for: "f")
        XCTAssertEqual(entry?.state, .pending(reason: .notChecked))
        XCTAssertEqual(entry?.checksums, f, "Kept: the next scan only asks the server")
        XCTAssertEqual(entry?.serverIDs, [.photo: "old"])
        let other = await saved.entry(for: "b")
        XCTAssertEqual(other?.state, .backedUp(serverAssetID: "B"))
        let missing = await saved.entry(for: "missing")
        XCTAssertNil(missing)
    }

    // MARK: Re-upload

    func testReuploadRestoresTrashedAndQueuesGone() async throws {
        let setup = await makeSetup(album: ["t", "g", "lt", "b"])
        let t = addAsset("t", to: setup.library)
        let g = addAsset("g", to: setup.library)
        let lt = addAsset("lt", to: setup.library, types: [.photo, .pairedVideo])
        let b = addAsset("b", to: setup.library)
        await setup.service.setAssets([
            Asset(id: "srv-t", kind: .image, takenAt: Self.date, isTrashed: true),
            Asset(id: "srv-lp", kind: .image, takenAt: Self.date, isTrashed: true),
            Asset(id: "srv-lm", kind: .video, takenAt: Self.date, isTrashed: true),
        ])
        await queue("t", t, in: setup.index, state: .deletedOnServer(trashed: [.photo], gone: []), serverIDs: [.photo: "srv-t"])
        await queue("g", g, in: setup.index, state: .deletedOnServer(trashed: [], gone: [.photo]))
        await queue("lt", lt, in: setup.index, state: .deletedOnServer(trashed: [.photo, .pairedVideo], gone: []),
                    serverIDs: [.photo: "srv-lp", .pairedVideo: "srv-lm"])
        await queue("b", b, in: setup.index, state: .backedUp(serverAssetID: "B"), serverIDs: [.photo: "B"])

        try await makeUploader(setup).reupload(["t", "g", "lt", "b"])

        let saved = BackupIndex(directory: setup.directory)
        let tState = await saved.entry(for: "t")?.state
        XCTAssertEqual(tState, .backedUp(serverAssetID: "srv-t"))
        let ltEntry = await saved.entry(for: "lt")
        XCTAssertEqual(ltEntry?.state, .backedUp(serverAssetID: "srv-lp"))
        XCTAssertEqual(ltEntry?.serverIDs, [.photo: "srv-lp", .pairedVideo: "srv-lm"])
        let gState = await saved.entry(for: "g")?.state
        XCTAssertEqual(gState, .pending(reason: .needsUpload))
        let bState = await saved.entry(for: "b")?.state
        XCTAssertEqual(bState, .backedUp(serverAssetID: "B"))
        let restored = await setup.service.requests.filter { if case .restoreAssets = $0 { true } else { false } }
        XCTAssertEqual(Set(restored), [.restoreAssets("srv-t"), .restoreAssets("srv-lp"), .restoreAssets("srv-lm")])
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0, "Gone items are uploaded by the next run")

        try await run(makeUploader(setup))
        let after = await uploadedChecksums(setup.service)
        XCTAssertEqual(after, [g[.photo]!])
    }

    func testReuploadGoneMotionUploadsAndLinks() async throws {
        let setup = await makeSetup(album: ["l", "tl"])
        let l = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        let tl = addAsset("tl", to: setup.library, types: [.photo, .pairedVideo])
        await setup.service.setAssets([Asset(id: "TP", kind: .image, takenAt: Self.date, isTrashed: true)])
        // Motion purged, photo still on the server.
        await queue("l", l, in: setup.index, state: .deletedOnServer(trashed: [], gone: [.pairedVideo]), serverIDs: [.photo: "P"])
        // Motion purged, photo in the trash: restored, then linked to the new motion.
        await queue("tl", tl, in: setup.index, state: .deletedOnServer(trashed: [.photo], gone: [.pairedVideo]),
                    serverIDs: [.photo: "TP"])
        await setup.service.setUploadResults([
            AssetUploadResult(id: "M", status: .created), AssetUploadResult(id: "TM", status: .created),
        ])

        try await makeUploader(setup).reupload(["l", "tl"])

        let uploads = await uploadedChecksums(setup.service)
        XCTAssertEqual(uploads, [l[.pairedVideo]!, tl[.pairedVideo]!], "Never the photo the server still has")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M", "TP->TM"])
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P", .pairedVideo: "M"])
        let other = await setup.index.entry(for: "tl")
        XCTAssertEqual(other?.state, .backedUp(serverAssetID: "TP"))
        XCTAssertEqual(stagedFiles(setup), [])
    }

    func testReuploadGonePhotoUploadsWithTheExistingMotion() async throws {
        let setup = await makeSetup(album: ["l"])
        let l = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", l, in: setup.index, state: .deletedOnServer(trashed: [], gone: [.photo]), serverIDs: [.pairedVideo: "M"])
        await setup.service.setUploadResults([AssetUploadResult(id: "P2", status: .created)])

        try await makeUploader(setup).reupload(["l"])

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [l[.photo]!])
        XCTAssertNil(uploads.first?.livePhotoVideoID, "Phase 3: linked after the upload")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P2->M"])
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "P2"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P2", .pairedVideo: "M"])
    }

    func testReuploadRethrowsEditingOffAndChangesNothing() async throws {
        let setup = await makeSetup(album: ["t"])
        let t = addAsset("t", to: setup.library)
        await setup.service.setAssets([Asset(id: "srv-t", kind: .image, takenAt: Self.date, isTrashed: true)])
        let deleted = BackupState.deletedOnServer(trashed: [.photo], gone: [])
        await queue("t", t, in: setup.index, state: deleted, serverIDs: [.photo: "srv-t"])
        let guarded = EditGuardedService(base: setup.service, permission: EditingPermission(isAllowed: false))

        do {
            try await makeUploader(setup, service: guarded).reupload(["t"])
            XCTFail("Expected editingOff")
        } catch let error as ImmichServiceError {
            XCTAssertEqual(error, .editingOff)
        }
        let s = await state("t", setup.index)
        XCTAssertEqual(s, deleted)
    }

    func testDeletedOnServerItemsAreNeverUploadedByRun() async throws {
        let setup = await makeSetup(album: ["t", "g", "f", "b", "n"])
        let states: [String: BackupState] = [
            "t": .deletedOnServer(trashed: [.photo], gone: []),
            "g": .deletedOnServer(trashed: [], gone: [.photo]),
            "f": .failed(reason: "Unsupported file type"),
            "b": .backedUp(serverAssetID: "B"),
            "n": .pending(reason: .notChecked),
        ]
        for (id, state) in states {
            let sums = addAsset(id, to: setup.library)
            await queue(id, sums, in: setup.index, state: state)
        }
        let log = ProgressLog()

        try await run(makeUploader(setup), log: log)

        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(setup.library.reads, [])
        for (id, expected) in states {
            let s = await state(id, setup.index)
            XCTAssertEqual(s, expected, id)
        }
        XCTAssertEqual(log.events.last?.total ?? 0, 0)
    }

    // MARK: Phase 3: the transport

    func testEnqueuesWithoutWaitingAndKeepsTheInFlightLimit() async throws {
        let ids = ["a", "b", "c", "d", "e"]
        let setup = await makeSetup(album: Set(ids))
        for (offset, id) in ids.enumerated() {
            let sums = addAsset(id, to: setup.library, created: Self.date.addingTimeInterval(Double(-offset * 60)))
            await queue(id, sums, in: setup.index)
        }
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let probe = PauseProbe()
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { probe.ask() }) }

        // Three items handed over before any has finished; the fourth waits for room.
        await stack.transport.waitForEnqueued(BackupUploader.maxInFlight)
        await probe.waitForCalls(BackupUploader.maxInFlight + 1)
        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["a", "b", "c"])
        let uploadsSoFar = await setup.service.uploads.count
        XCTAssertEqual(uploadsSoFar, 0, "Nothing waited for an upload to finish")
        XCTAssertEqual(stagedFiles(setup).count, 3)

        await stack.transport.complete { $0.assetID == "a" }
        await stack.transport.waitForEnqueued(4)
        XCTAssertEqual(stack.transport.sent.last?.job.assetID, "d")
        await stack.transport.complete { $0.assetID == "b" }
        await stack.transport.waitForEnqueued(5)
        await stack.transport.complete()
        try await task.value

        XCTAssertEqual(stack.transport.maxInFlight, BackupUploader.maxInFlight)
        let uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 5, "Each item once")
        for id in ids {
            let s = await state(id, setup.index)
            guard case .backedUp = s else { return XCTFail("\(id): expected backedUp, got \(String(describing: s))") }
        }
        XCTAssertEqual(stagedFiles(setup), [])
        let jobs = await setup.index.jobs
        XCTAssertEqual(jobs, [])
    }

    func testLivePhotoMotionIsHiddenAndLinkedOnceBothFinished() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        await setup.service.setUploadResults([AssetUploadResult(id: "P", status: .created)])
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await stack.transport.waitForEnqueued(2)
        let sent = stack.transport.sent
        XCTAssertEqual(sent.map(\.job.resource), [.pairedVideo, .photo], "Both halves at once, motion first")
        XCTAssertEqual(sent.map(\.savedNeedsLink), [true, true], "needsLink saved before either half was enqueued")
        XCTAssertEqual(sent[0].fields["visibility"], "hidden")
        XCTAssertNil(sent[1].fields["visibility"])
        XCTAssertNil(sent[1].fields["livePhotoVideoId"], "The photo doesn't wait for the motion's ID")
        XCTAssertNil(sent[0].fields["livePhotoVideoId"])

        // The photo finishes first: nothing to link yet.
        await stack.transport.complete { $0.resource == .photo }
        let early = await setup.service.links.count
        XCTAssertEqual(early, 0)
        let half = await setup.index.entry(for: "l")
        XCTAssertEqual(half?.state, .pending(reason: .needsUpload), "Not backed up before the link")
        XCTAssertEqual(half?.needsLink, true)

        await setup.service.setUploadResults([AssetUploadResult(id: "M", status: .created)])
        await stack.transport.complete { $0.resource == .pairedVideo }
        try await task.value

        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M"], "Linked once, after both were recorded")
        let entry = await BackupIndex(directory: setup.directory).entry(for: "l")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "P", .pairedVideo: "M"])
        XCTAssertEqual(entry?.needsLink, false)
        XCTAssertEqual(stagedFiles(setup), [])
    }

    /// Review focus: one half finished, the other failed, then the app was relaunched: only the missing half
    /// is sent, the link happens once both IDs exist, and the motion stays hidden (never sent again).
    func testRetrySendsOnlyTheMissingHalf() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)
        try await setup.index.save()
        let first = makeStack(setup, mode: .manual)
        let index = setup.index
        let firstRun = Task {
            try await first.uploader.run(progress: { _ in }, shouldPause: { await index.entry(for: "l")?.retry != nil })
        }
        await first.transport.waitForEnqueued(2)
        await setup.service.setUploadResults([AssetUploadResult(id: "M", status: .created)])
        await first.transport.complete { $0.resource == .pairedVideo }
        await first.transport.finish(where: { $0.resource == .photo }, with: .failed(.service(.unexpectedStatus(500))))
        try await finish(firstRun).get()

        // Relaunch: everything made again from the saved index.
        let relaunched = BackupIndex(directory: setup.directory)
        let saved = await relaunched.entry(for: "l")
        XCTAssertEqual(saved?.serverIDs, [.pairedVideo: "M"])
        XCTAssertEqual(saved?.needsLink, true)
        XCTAssertEqual(saved?.retry?.failures, 1, "The failure is kept across the relaunch")
        let second = makeStack(setup, index: relaunched)
        await setup.service.setUploadResults([AssetUploadResult(id: "P", status: .created)])
        try await run(second.uploader)

        XCTAssertEqual(second.transport.sent.map(\.job.resource), [.photo], "Only the half without a server ID")
        XCTAssertNil(second.transport.sent.first?.fields["visibility"])
        XCTAssertGreaterThanOrEqual(setup.clock.totalSlept, .seconds(5), "The back-off from before the relaunch is kept")
        let uploads = await setup.service.uploads.map(\.checksum)
        XCTAssertEqual(uploads, [sums[.pairedVideo]!, sums[.photo]!], "The motion was sent once, hidden")
        XCTAssertEqual(first.transport.sent.first?.fields["visibility"], "hidden")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M"])
        let entry = await relaunched.entry(for: "l")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(entry?.needsLink, false)
        XCTAssertNil(entry?.retry)
    }

    /// Review focus: an index written by Phase 2 (no jobs, no retry bookkeeping, a Live Photo between its
    /// upload and its link) loads and goes on without uploading anything the server has.
    func testPhase2IndexContinuesWithoutReuploading() async throws {
        let setup = await makeSetup(album: ["done", "half", "plain", "bad"])
        let done = addAsset("done", to: setup.library, created: Self.date)
        let half = addAsset("half", to: setup.library, types: [.photo, .pairedVideo], created: Self.date.addingTimeInterval(-60))
        let plain = addAsset("plain", to: setup.library, created: Self.date.addingTimeInterval(-120))
        let bad = addAsset("bad", to: setup.library, created: Self.date.addingTimeInterval(-180))
        await setup.index.set(BackupEntry(modificationDate: Self.date, checksums: done, state: .backedUp(serverAssetID: "D"),
                                          serverIDs: [.photo: "D"]), for: "done")
        await setup.index.set(BackupEntry(modificationDate: Self.date, checksums: half, state: .pending(reason: .needsUpload),
                                          serverIDs: [.pairedVideo: "HM"], needsLink: true), for: "half")
        await queue("plain", plain, in: setup.index)
        await queue("bad", bad, in: setup.index, state: .failed(reason: "Unsupported file type"))
        try await setup.index.save()
        // As Phase 2 wrote it: no `jobs`, and no `retry` in any entry.
        let file = setup.directory.appendingPathComponent("index.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["jobs"] = nil
        let phase2 = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(String(decoding: phase2, as: UTF8.self).contains("retry"))
        try phase2.write(to: file)

        let loaded = BackupIndex(directory: setup.directory)
        let jobs = await loaded.jobs
        XCTAssertEqual(jobs, [])
        let stack = makeStack(setup, index: loaded)
        await setup.service.setUploadResults([
            AssetUploadResult(id: "HP", status: .created), AssetUploadResult(id: "PL", status: .created),
        ])
        try await run(stack.uploader)

        let uploads = await setup.service.uploads.map(\.checksum)
        XCTAssertEqual(uploads, [half[.photo]!, plain[.photo]!], "Nothing the server already has")
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["HP->HM"])
        let states = await ["done", "half", "plain", "bad"].asyncMap { await loaded.entry(for: $0)?.state }
        XCTAssertEqual(states, [.backedUp(serverAssetID: "D"), .backedUp(serverAssetID: "HP"),
                                .backedUp(serverAssetID: "PL"), .failed(reason: "Unsupported file type")])
    }

    /// A video larger than the staging budget isn't starved: once it doesn't fit, nothing else is staged
    /// until the bodies in flight are recorded, and then it goes first, before the smaller items after it.
    func testOverBudgetWaitsForTheBodiesInFlightWithoutSkippingAhead() async throws {
        let setup = await makeSetup(album: ["n", "v", "a"])
        let n = addAsset("n", to: setup.library, created: Self.date)
        let v = addAsset("v", to: setup.library, types: [.video], isVideo: true, created: Self.date.addingTimeInterval(-60), duration: 600)
        let a = addAsset("a", to: setup.library, created: Self.date.addingTimeInterval(-120))
        for (id, sums) in [("n", n), ("v", v), ("a", a)] { await queue(id, sums, in: setup.index) }
        let staging = BackupStaging(
            directory: setup.stagingDirectory, freeSpace: { 100 * 1024 * 1024 * 1024 }, recheckInterval: 1024 * 1024,
            budget: 50_000, estimate: { _, asset in asset.id == "v" ? 100_000 : 10 })
        let stack = makeStack(setup, mode: .manual, staging: staging)
        let uploader = stack.uploader
        let probe = PauseProbe()
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { probe.ask() }) }

        // n is in flight; v doesn't fit; the run waits instead of staging a.
        await stack.transport.waitForEnqueued(1)
        await probe.waitForCalls(3)
        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["n"])
        XCTAssertEqual(stagedFiles(setup).count, 1, "Nothing else staged while waiting for room")
        XCTAssertFalse(setup.library.reads.contains { $0.assetID == "a" }, "The smaller item doesn't go ahead")

        await stack.transport.complete { $0.assetID == "n" }
        await stack.transport.waitForEnqueued(2)
        XCTAssertEqual(stack.transport.sent.last?.job.assetID, "v", "The video goes next once the bodies are recorded")
        await stack.transport.complete { $0.assetID == "v" }
        await stack.transport.waitForEnqueued(3)
        await stack.transport.complete()
        try await task.value
        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["n", "v", "a"])
        XCTAssertEqual(stagedFiles(setup), [])
    }

    /// An item whose upload from an earlier launch is still in flight (or not yet reconciled) isn't staged
    /// again; its result is waited for.
    func testItemWithAJobInFlightIsNotStagedAgain() async throws {
        let setup = await makeSetup(album: ["a"])
        let sums = addAsset("a", to: setup.library)
        await queue("a", sums, in: setup.index)
        try FileManager.default.createDirectory(at: setup.stagingDirectory, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: setup.stagingDirectory.appendingPathComponent("earlier.multipart"))
        let job = UploadJob(assetID: "a", resource: .photo, attempt: UUID(), bodyFileName: "earlier.multipart",
                            checksum: sums[.photo]!)
        await setup.index.addJob(job)
        try await setup.index.save()
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let probe = PauseProbe()
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { probe.ask() }) }

        await probe.waitForCalls(1)
        XCTAssertTrue(stack.transport.sent.isEmpty)
        await stack.transport.finish(where: { $0.assetID == "a" }, with: .uploaded(AssetUploadResult(id: "A", status: .created)))
        try await task.value

        XCTAssertTrue(stack.transport.sent.isEmpty, "Not sent a second time")
        XCTAssertTrue(setup.library.reads.isEmpty, "Not even read")
        let s = await state("a", setup.index)
        XCTAssertEqual(s, .backedUp(serverAssetID: "A"))
        XCTAssertEqual(stagedFiles(setup), [])
    }

    /// The check before enqueueing can't follow a redirect: when it is redirected, nothing is enqueued, the
    /// uploads in flight are cancelled and the error is shown.
    func testPreflightRedirectEnqueuesNothingAndCancelsInFlight() async throws {
        let setup = await makeSetup(album: ["a"])
        let sums = addAsset("a", to: setup.library)
        await queue("a", sums, in: setup.index)
        await setup.service.setFailure(.unexpectedStatus(302))
        let stack = makeStack(setup)

        do {
            try await run(stack.uploader)
            XCTFail("Expected the redirect to be reported")
        } catch let error as ImmichServiceError {
            XCTAssertEqual(error, .unexpectedStatus(302))
        }
        XCTAssertTrue(stack.transport.sent.isEmpty)
        XCTAssertEqual(stack.transport.cancelAllCount, 1)
        XCTAssertEqual(stagedFiles(setup), [])
        let s = await state("a", setup.index)
        XCTAssertEqual(s, .pending(reason: .needsUpload))
    }

    func testPassedPreflightLiftsTheRedirectBlock() async throws {
        let setup = await makeSetup(album: ["a"])
        let sums = addAsset("a", to: setup.library)
        await queue("a", sums, in: setup.index)
        let stack = makeStack(setup)
        stack.transport.setRedirectBlocked(true)

        try await run(stack.uploader)

        XCTAssertEqual(stack.transport.clearCount, 1)
        XCTAssertFalse(stack.transport.isRedirectBlocked)
        let requests = await setup.service.requests
        let ping = requests.firstIndex(of: .ping)
        let upload = requests.firstIndex(of: .upload(sums[.photo]!))
        XCTAssertNotNil(ping)
        if let ping, let upload { XCTAssertLessThan(ping, upload, "Checked before anything was sent") }
        let s = await state("a", setup.index)
        guard case .backedUp = s else { return XCTFail("Expected backedUp, got \(String(describing: s))") }
    }

    /// An upload found redirected to another server (recorded as `insecureConnection`) cancels the others in
    /// flight, which would go there too, and stops the run.
    func testRecordedRedirectCancelsEverythingInFlight() async throws {
        let setup = await makeSetup(album: ["a", "b"])
        let a = addAsset("a", to: setup.library, created: Self.date)
        let b = addAsset("b", to: setup.library, created: Self.date.addingTimeInterval(-60))
        await queue("a", a, in: setup.index)
        await queue("b", b, in: setup.index)
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await stack.transport.waitForEnqueued(2)
        await stack.transport.finish(where: { $0.assetID == "a" }, with: .failed(.service(.insecureConnection)))
        let result = await finish(task)

        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? ImmichServiceError, .insecureConnection) }
        XCTAssertGreaterThanOrEqual(stack.transport.cancelAllCount, 1)
        let jobs = await setup.index.jobs
        XCTAssertEqual(jobs, [], "b was cancelled too")
        for id in ["a", "b"] {
            let s = await state(id, setup.index)
            XCTAssertEqual(s, .pending(reason: .needsUpload), id)
        }
        // Two cancels race to record b (the run's and the one the recorder's observer starts for results that
        // arrive outside a run); the one that claimed it deletes its body right after saving.
        for _ in 0..<500 where !stagedFiles(setup).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(stagedFiles(setup), [])
    }

    /// At a wake outside a run: a Live Photo with both halves on the server is linked.
    func testLinkPendingLinksBothHalvesOutsideARun() async throws {
        let setup = await makeSetup(album: ["l", "w"])
        let l = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        let w = addAsset("w", to: setup.library, types: [.photo, .pairedVideo])
        await setup.index.set(BackupEntry(modificationDate: Self.date, checksums: l, state: .pending(reason: .needsUpload),
                                          serverIDs: [.photo: "P", .pairedVideo: "M"], needsLink: true), for: "l")
        // Still waiting for its photo: nothing to link yet.
        await setup.index.set(BackupEntry(modificationDate: Self.date, checksums: w, state: .pending(reason: .needsUpload),
                                          serverIDs: [.pairedVideo: "WM"], needsLink: true), for: "w")

        await makeUploader(setup).linkPending()

        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["P->M"])
        let saved = await BackupIndex(directory: setup.directory).entry(for: "l")
        XCTAssertEqual(saved?.state, .backedUp(serverAssetID: "P"))
        XCTAssertEqual(saved?.needsLink, false)
        let wState = await state("w", setup.index)
        XCTAssertEqual(wState, .pending(reason: .needsUpload))
    }

    // MARK: Phase 3 fix round 1

    /// Uploads handed over on Wi-Fi that iOS holds once the phone is on cellular (videos, with their cellular
    /// switch off) take no in-flight slot and aren't waited for: a photo that may go on cellular still goes.
    func testHeldWiFiOnlyJobsDoNotBlockTheInFlightSlots() async throws {
        let videoIDs = ["v1", "v2", "v3"]
        let setup = await makeSetup(
            album: Set(videoIDs + ["p"]), cellular: true, settings: BackupSettings(photosOnCellular: true))
        try FileManager.default.createDirectory(at: setup.stagingDirectory, withIntermediateDirectories: true)
        for (offset, id) in videoIDs.enumerated() {
            let sums = addAsset(id, to: setup.library, types: [.video], isVideo: true,
                                created: Self.date.addingTimeInterval(Double(60 + offset)))
            await queue(id, sums, in: setup.index, state: .pending(reason: .waitingForWiFi))
            let body = "\(id).multipart"
            try Data("body".utf8).write(to: setup.stagingDirectory.appendingPathComponent(body))
            await setup.index.addJob(UploadJob(
                assetID: id, resource: .video, attempt: UUID(), bodyFileName: body, checksum: sums[.video]!))
        }
        let p = addAsset("p", to: setup.library, created: Self.date)
        await queue("p", p, in: setup.index)
        try await setup.index.save()
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        let enqueued = await eventually { stack.transport.sent.count >= 1 }
        XCTAssertTrue(enqueued, "The photo goes although three held videos fill the in-flight limit")
        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["p"])
        await stack.transport.complete { $0.assetID == "p" }
        try await finish(task).get()

        let pState = await state("p", setup.index)
        guard case .backedUp = pState else { return XCTFail("Expected backedUp, got \(String(describing: pState))") }
        let jobs = await setup.index.jobs.map(\.assetID)
        XCTAssertEqual(Set(jobs), Set(videoIDs), "The held uploads are left to the system")
    }

    /// Held uploads' bodies still take staging budget. When that is what stops an item, the run leaves the
    /// item for the next run instead of waiting for room that only Wi-Fi brings.
    func testHeldJobsFillingTheBudgetEndTheRunInsteadOfWaiting() async throws {
        let setup = await makeSetup(album: ["v", "p"], settings: BackupSettings(photosOnCellular: true))
        let v = addAsset("v", to: setup.library, types: [.video], isVideo: true, created: Self.date.addingTimeInterval(60))
        let p = addAsset("p", to: setup.library, created: Self.date)
        await queue("v", v, in: setup.index)
        await queue("p", p, in: setup.index)
        let staging = BackupStaging(
            directory: setup.stagingDirectory, freeSpace: { 100 * 1024 * 1024 * 1024 }, recheckInterval: 1024 * 1024,
            budget: 50_000, estimate: { _, asset in asset.id == "p" ? 100_000 : 10 })
        let stack = makeStack(setup, mode: .manual, staging: staging)
        let uploader = stack.uploader
        let probe = PauseProbe()
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { probe.ask() }) }

        // On Wi-Fi the video goes; the photo doesn't fit next to it, and the run waits for room.
        let enqueued = await eventually { stack.transport.sent.count >= 1 }
        XCTAssertTrue(enqueued)
        await probe.waitForCalls(3)
        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["v"])

        // The phone leaves Wi-Fi: the video is held, so nothing will free the room.
        setup.network.setCellular(true)
        uploader.wake()
        try await finish(task).get()

        XCTAssertEqual(stack.transport.sent.map(\.job.assetID), ["v"], "The photo wasn't squeezed in")
        let pState = await state("p", setup.index)
        XCTAssertEqual(pState, .pending(reason: .needsUpload), "Left for the next run")
        let jobs = await setup.index.jobs.map(\.assetID)
        XCTAssertEqual(jobs, ["v"])
    }

    /// A retry time from a clock that was moved back can't hold an item for longer than the longest back-off.
    func testRetryTimeFromAClockMovedBackIsClamped() async throws {
        let setup = await makeSetup(album: ["a"])
        let sums = addAsset("a", to: setup.library)
        await setup.index.set(BackupEntry(
            modificationDate: Self.date, checksums: sums, state: .pending(reason: .needsUpload),
            retry: BackupRetryState(
                failures: 1, notBefore: setup.clock.date.addingTimeInterval(7200), wasOffline: false, holdsRun: false)),
            for: "a")
        try await setup.index.save()

        try await run(makeUploader(setup))

        let s = await state("a", setup.index)
        guard case .backedUp = s else { return XCTFail("Expected backedUp, got \(String(describing: s))") }
        XCTAssertLessThanOrEqual(setup.clock.totalSlept, .seconds(3602), "Waited for the clamped time, not the stored one")
    }

    /// An item given up on with a retry time far ahead is held until the clamped time (kept in the index, so
    /// it runs out), not for ever.
    func testGivenUpPauseFromAClockMovedBackRunsOut() async throws {
        let setup = await makeSetup(album: ["a"])
        let sums = addAsset("a", to: setup.library)
        await setup.index.set(BackupEntry(
            modificationDate: Self.date, checksums: sums, state: .pending(reason: .needsUpload),
            retry: BackupRetryState(
                failures: 6, notBefore: setup.clock.date.addingTimeInterval(10 * 86_400), wasOffline: false, holdsRun: false)),
            for: "a")
        try await setup.index.save()

        try await run(makeUploader(setup))
        var uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 0, "Still given up on")

        setup.clock.advance(.seconds(3601))
        try await run(makeUploader(setup))
        uploads = await setup.service.uploads.count
        XCTAssertEqual(uploads, 1, "The pause ended an hour after it was first read")
    }

    /// A second failure while the item already waits out a back-off (the other half of a Live Photo) isn't
    /// counted again, but what it says is kept.
    func testSecondFailureDuringABackOffKeepsItsFlags() {
        var entry = BackupEntry(modificationDate: Self.date, checksums: [:], state: .pending(reason: .needsUpload))
        let now = Self.date
        BackupUploader.noteFailure(of: &entry, holdsRun: false, offline: false, at: now)
        BackupUploader.noteFailure(of: &entry, holdsRun: true, offline: true, at: now)

        XCTAssertEqual(entry.retry?.failures, 1, "Counted once")
        XCTAssertEqual(entry.retry?.holdsRun, true, "The server being down holds the run")
        XCTAssertEqual(entry.retry?.wasOffline, true, "Tried again once the network returns")
        XCTAssertEqual(entry.retry?.notBefore, now.addingTimeInterval(5))

        // And the other way round: a later, milder failure doesn't undo it.
        BackupUploader.noteFailure(of: &entry, holdsRun: false, offline: false, at: now)
        XCTAssertEqual(entry.retry?.holdsRun, true)
        XCTAssertEqual(entry.retry?.wasOffline, true)
    }

    /// Re-upload shares the uploader's index and transport with the run: while one is going it does nothing
    /// (the runner takes turns; a direct caller must too) instead of racing it.
    func testReuploadDuringARunDoesNothing() async throws {
        let setup = await makeSetup(album: ["a", "t"])
        let a = addAsset("a", to: setup.library, created: Self.date.addingTimeInterval(60))
        let t = addAsset("t", to: setup.library)
        await setup.service.setAssets([Asset(id: "srv-t", kind: .image, takenAt: Self.date, isTrashed: true)])
        await queue("a", a, in: setup.index)
        let trashed = BackupState.deletedOnServer(trashed: [.photo], gone: [])
        await queue("t", t, in: setup.index, state: trashed, serverIDs: [.photo: "srv-t"])
        let stack = makeStack(setup, mode: .manual)
        let uploader = stack.uploader
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }
        let enqueued = await eventually { stack.transport.sent.count >= 1 }
        XCTAssertTrue(enqueued)

        try await uploader.reupload(["t"])

        let restored = await setup.service.requests.filter { if case .restoreAssets = $0 { true } else { false } }
        XCTAssertEqual(restored, [], "Nothing restored while a run is going")
        let tState = await state("t", setup.index)
        XCTAssertEqual(tState, trashed)

        await stack.transport.complete()
        try await finish(task).get()
        try await uploader.reupload(["t"])
        let after = await state("t", setup.index)
        XCTAssertEqual(after, .backedUp(serverAssetID: "srv-t"), "Works again once the run is over")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
