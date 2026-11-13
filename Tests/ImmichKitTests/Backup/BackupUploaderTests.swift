import XCTest
@testable import ImmichKit

/// Time for the uploader's back-off: `sleep` returns at once and moves `now` forward.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var _sleeps: [Duration] = []

    var seconds: Double { lock.withLock { Double(elapsed.components.seconds) } }
    var totalSlept: Duration { lock.withLock { _sleeps.reduce(.zero, +) } }

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
            })
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
    /// The clock's time at each `isOnCellular` read: the uploader reads it once per attempt.
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
        let settings = setup.settings
        return BackupUploader(
            source: source ?? setup.library, service: service ?? setup.service, index: setup.index,
            staging: BackupStaging(directory: setup.stagingDirectory, freeSpace: { 100 * 1024 * 1024 * 1024 }),
            settings: { settings.get() }, network: setup.network, clock: setup.clock.clock)
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

    func testLivePhotoUploadsMotionFirstThenLinkedPhoto() async throws {
        let setup = await makeSetup(album: ["l"])
        let sums = addAsset("l", to: setup.library, types: [.photo, .pairedVideo])
        await queue("l", sums, in: setup.index)

        try await run(makeUploader(setup))

        let uploads = await setup.service.uploads
        XCTAssertEqual(uploads.map(\.checksum), [sums[.pairedVideo]!, sums[.photo]!])
        let stored = await setup.index.entry(for: "l")
        let entry = try XCTUnwrap(stored)
        let motionID = try XCTUnwrap(entry.serverIDs[.pairedVideo])
        let photoID = try XCTUnwrap(entry.serverIDs[.photo])
        XCTAssertNil(uploads[0].livePhotoVideoID)
        XCTAssertNil(uploads[0].duration, "The motion half is not a video asset of its own")
        XCTAssertEqual(uploads[1].livePhotoVideoID, motionID)
        XCTAssertEqual(entry.state, .backedUp(serverAssetID: photoID))
        let links = await setup.service.links
        XCTAssertTrue(links.isEmpty, "Created with livePhotoVideoId needs no separate link")
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
        XCTAssertEqual(uploads[2].livePhotoVideoID, "motion-1")
        let stored = await setup.index.entry(for: "l")
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(entry.serverIDs[.pairedVideo], "motion-1", "No second motion asset")
        XCTAssertEqual(entry.state, .backedUp(serverAssetID: try XCTUnwrap(entry.serverIDs[.photo])))
        let links = await setup.service.links.count
        XCTAssertEqual(links, 0)
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
        XCTAssertEqual(uploads[3].livePhotoVideoID, "motion-1")
        let entry = await setup.index.entry(for: "l")
        XCTAssertEqual(entry?.serverIDs[.pairedVideo], "motion-1", "No second motion asset")
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
        XCTAssertEqual(uploads[1].livePhotoVideoID, mMotionID, "The stored motion ID")
        XCTAssertEqual(setup.library.reads.count, readsAfterScan + 2, "The known halves aren't even read")
        let pEntry = await setup.index.entry(for: "p")
        let pMotionID = try XCTUnwrap(pEntry?.serverIDs[.pairedVideo])
        let links = await setup.service.links.map { "\($0.photoID)->\($0.motionID)" }
        XCTAssertEqual(links, ["\(pPhotoID)->\(pMotionID)"], "A photo already there is linked to its new motion")
        XCTAssertEqual(pEntry?.state, .backedUp(serverAssetID: pPhotoID))
        let mEntry = await setup.index.entry(for: "m")
        let mPhotoID = try XCTUnwrap(mEntry?.serverIDs[.photo])
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
        await setup.service.setLatency(.seconds(3600))
        let uploader = makeUploader(setup)
        let service = setup.service
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await service.waitForUploads(1)
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
        for (error, holds) in [(ImmichServiceError.network("offline"), true), (.unexpectedStatus(502), false)] {
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
        XCTAssertEqual(setup.network.checks, [0, 5, 35, 155, 755], "Back-off: 5 s, 30 s, 2 min, 10 min")
        let afterRun = await state("s", setup.index)
        XCTAssertEqual(afterRun, .pending(reason: .needsUpload))
        XCTAssertEqual(stagedFiles(setup), [])

        // Skipped for the rest of this session.
        await setup.service.setUploadFailure(nil)
        try await run(uploader)
        let afterSecond = await setup.service.uploads.count
        XCTAssertEqual(afterSecond, 5)
        // A new session tries again.
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
        let settings = setup.settings
        let uploader = BackupUploader(
            source: setup.library, service: setup.service, index: setup.index,
            staging: BackupStaging(directory: setup.stagingDirectory, freeSpace: { 1024 }),
            settings: { settings.get() }, network: setup.network, clock: setup.clock.clock)

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

    func testCancellationDuringUploadLeavesNoStagingFiles() async throws {
        let setup = await makeSetup(album: ["c"])
        let sums = addAsset("c", to: setup.library)
        await queue("c", sums, in: setup.index)
        await setup.service.setLatency(.seconds(3600))
        let uploader = makeUploader(setup)
        let service = setup.service
        let task = Task { try await uploader.run(progress: { _ in }, shouldPause: { false }) }

        await service.waitForUploads(1)
        XCTAssertEqual(stagedFiles(setup).count, 1)
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(stagedFiles(setup), [])
        let cancelled = await setup.service.cancelledRequests
        XCTAssertEqual(cancelled, [.upload(sums[.photo]!)])
        let s = await state("c", setup.index)
        XCTAssertEqual(s, .pending(reason: .needsUpload))
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
        XCTAssertEqual(uploads.first?.livePhotoVideoID, "M")
        let links = await setup.service.links.count
        XCTAssertEqual(links, 0)
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
}
