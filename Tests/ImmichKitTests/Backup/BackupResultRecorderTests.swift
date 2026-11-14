import XCTest
@testable import ImmichKit

final class BackupResultRecorderTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupResultRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let directory: URL
        let stagingDirectory: URL
        let staging: BackupStaging
        let index: BackupIndex
        let recorder: BackupResultRecorder
    }

    private func makeFixture() -> Fixture {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let stagingDirectory = directory.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staging = BackupStaging(directory: stagingDirectory, freeSpace: { .max })
        return Fixture(
            directory: directory, stagingDirectory: stagingDirectory, staging: staging, index: index,
            recorder: BackupResultRecorder(index: index, staging: staging))
    }

    private func entry(
        checksums: [DeviceResourceType: String] = [.photo: "aa"],
        state: BackupState = .pending(reason: .needsUpload),
        serverIDs: [DeviceResourceType: String] = [:],
        needsLink: Bool = false
    ) -> BackupEntry {
        BackupEntry(modificationDate: date, checksums: checksums, state: state, serverIDs: serverIDs, needsLink: needsLink)
    }

    /// A job with a body file on disk, registered in the index like the transport does at enqueue.
    private func makeJob(
        _ fixture: Fixture, asset: String = "A", resource: DeviceResourceType = .photo, checksum: String = "aa"
    ) async throws -> UploadJob {
        let name = "\(UUID().uuidString).multipart"
        try Data("body".utf8).write(to: fixture.stagingDirectory.appendingPathComponent(name))
        let job = UploadJob(assetID: asset, resource: resource, attempt: UUID(), bodyFileName: name, checksum: checksum)
        await fixture.index.addJob(job)
        return job
    }

    private func exists(_ job: UploadJob, in fixture: Fixture) -> Bool {
        FileManager.default.fileExists(atPath: fixture.staging.url(forBodyNamed: job.bodyFileName).path)
    }

    func testRecordingSuccessMarksBackedUpAndDeletesBody() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertEqual(recorded?.serverIDs, [.photo: "srv-1"])
        XCTAssertFalse(exists(job, in: fixture))
        let jobs = await fixture.index.jobs
        XCTAssertTrue(jobs.isEmpty)
        // It is on disk, not only in memory.
        let reloaded = await BackupIndex(directory: fixture.directory).entry(for: "A")
        XCTAssertEqual(reloaded?.state, .backedUp(serverAssetID: "srv-1"))
    }

    func testRecordingDuplicateCountsAsSuccess() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "existing", status: .duplicate)))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "existing"))
        XCTAssertEqual(recorded?.serverIDs, [.photo: "existing"])
    }

    func testRecordingIsIdempotentForTheSameAttempt() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)
        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))

        // The server copy was deleted meanwhile; a late second delivery of the same result must not undo that.
        await fixture.index.set(
            entry(state: .deletedOnServer(trashed: [], gone: [.photo])), for: "A")
        let before = await fixture.index.entry(for: "A")
        let savesBefore = await fixture.index.saveCount

        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))
        await fixture.recorder.record(job, .failed(.service(.unexpectedStatus(400))))

        let after = await fixture.index.entry(for: "A")
        let savesAfter = await fixture.index.saveCount
        XCTAssertEqual(after, before)
        XCTAssertEqual(savesAfter, savesBefore)
    }

    func testRecordingForAChangedEntryIsIgnored() async throws {
        let fixture = makeFixture()
        // The scanner hashed a newer version of the asset after this job was staged.
        let newer = entry(checksums: [.photo: "zz"])
        await fixture.index.set(newer, for: "A")
        let job = try await makeJob(fixture, checksum: "aa")

        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded, newer)
        // The result is final either way: the job is done and its body goes.
        XCTAssertFalse(exists(job, in: fixture))
        let jobs = await fixture.index.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testRecordingForAMissingEntryDeletesTheBody() async throws {
        let fixture = makeFixture()
        let job = try await makeJob(fixture, asset: "gone")

        await fixture.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))

        let recorded = await fixture.index.entry(for: "gone")
        XCTAssertNil(recorded)
        XCTAssertFalse(exists(job, in: fixture))
    }

    func testRejectedBecomesFailedWithMessage() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .failed(.rejected(status: 400, message: "File type not supported")))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .failed(reason: "File type not supported"))
        XCTAssertTrue(recorded?.serverIDs.isEmpty ?? false)
        XCTAssertFalse(exists(job, in: fixture))
    }

    func testRejectedWithoutMessageNamesTheStatus() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .failed(.rejected(status: 413, message: "")))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .failed(reason: ImmichServiceError.unexpectedStatus(413).localizedDescription))
    }

    func testFailuresThatRetryKeepTheItemQueued() async throws {
        let failures: [UploadFailure] = [
            .service(.network("offline", code: .notConnectedToInternet)),
            .service(.unexpectedStatus(503)),
            .service(.unexpectedStatus(429)),
            .service(.unexpectedStatus(500)),
            .service(.invalidResponse),
            // Nothing the item did wrong: the run stops and the item stays queued.
            .service(.unauthorized),
            .cancelled,
        ]
        for failure in failures {
            let fixture = makeFixture()
            await fixture.index.set(entry(state: .pending(reason: .waitingForWiFi)), for: "A")
            let job = try await makeJob(fixture)

            await fixture.recorder.record(job, .failed(failure))

            let recorded = await fixture.index.entry(for: "A")
            XCTAssertEqual(recorded?.state, .pending(reason: .needsUpload), "\(failure)")
            XCTAssertFalse(exists(job, in: fixture), "\(failure)")
        }
    }

    func testOtherServerAnswersFail() async throws {
        let fixture = makeFixture()
        await fixture.index.set(entry(), for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .failed(.service(.unexpectedStatus(302))))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .failed(reason: ImmichServiceError.unexpectedStatus(302).localizedDescription))
    }

    func testLivePhotoStaysQueuedUntilBothHalvesAndTheLinkAreDone() async throws {
        let fixture = makeFixture()
        let live = entry(checksums: [.photo: "aa", .pairedVideo: "bb"], needsLink: true)
        await fixture.index.set(live, for: "A")
        let motion = try await makeJob(fixture, resource: .pairedVideo, checksum: "bb")
        let photo = try await makeJob(fixture, resource: .photo, checksum: "aa")

        await fixture.recorder.record(motion, .uploaded(AssetUploadResult(id: "srv-m", status: .created)))
        var recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(recorded?.serverIDs, [.pairedVideo: "srv-m"])

        await fixture.recorder.record(photo, .uploaded(AssetUploadResult(id: "srv-p", status: .created)))
        recorded = await fixture.index.entry(for: "A")
        // Both are on the server but not joined: the uploader links them, then the item is backed up.
        XCTAssertEqual(recorded?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(recorded?.serverIDs, [.pairedVideo: "srv-m", .photo: "srv-p"])
        XCTAssertEqual(recorded?.needsLink, true)
    }

    func testLivePhotoAlreadyLinkedIsBackedUpWhenItsLastHalfArrives() async throws {
        let fixture = makeFixture()
        await fixture.index.set(
            entry(checksums: [.photo: "aa", .pairedVideo: "bb"], serverIDs: [.pairedVideo: "srv-m"]), for: "A")
        let photo = try await makeJob(fixture, resource: .photo, checksum: "aa")

        await fixture.recorder.record(photo, .uploaded(AssetUploadResult(id: "srv-p", status: .duplicate)))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-p"))
    }

    func testFailureOfOneHalfKeepsTheOthersID() async throws {
        let fixture = makeFixture()
        await fixture.index.set(
            entry(checksums: [.photo: "aa", .pairedVideo: "bb"], serverIDs: [.pairedVideo: "srv-m"], needsLink: true),
            for: "A")
        let photo = try await makeJob(fixture, resource: .photo, checksum: "aa")

        await fixture.recorder.record(photo, .failed(.rejected(status: 400, message: "bad")))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .failed(reason: "bad"))
        XCTAssertEqual(recorded?.serverIDs, [.pairedVideo: "srv-m"])
        XCTAssertEqual(recorded?.needsLink, true)
    }

    func testResultNeverTouchesAnItemTheUserOrServerMovedOn() async throws {
        let fixture = makeFixture()
        let deleted = entry(state: .deletedOnServer(trashed: [.photo], gone: []), serverIDs: [.photo: "srv-old"])
        await fixture.index.set(deleted, for: "A")
        let job = try await makeJob(fixture)

        await fixture.recorder.record(job, .failed(.rejected(status: 400, message: "bad")))

        let recorded = await fixture.index.entry(for: "A")
        XCTAssertEqual(recorded, deleted)
    }

    // MARK: - Index

    func testPhase2IndexLoadsWithNoJobs() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.set(entry(state: .backedUp(serverAssetID: "srv-1")), for: "A")
        try await index.save()
        // An index written by Phase 2 has no `jobs` key.
        let file = directory.appendingPathComponent("index.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["jobs"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let loaded = BackupIndex(directory: directory)

        let recorded = await loaded.entry(for: "A")
        let jobs = await loaded.jobs
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertTrue(jobs.isEmpty)
    }

    func testJobsSurviveSaveAndReload() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let first = UploadJob(
            assetID: "A", resource: .photo, attempt: UUID(), bodyFileName: "1.multipart", checksum: "aa")
        let second = UploadJob(
            assetID: "A", resource: .pairedVideo, attempt: UUID(), bodyFileName: "2.multipart", checksum: "bb")
        let other = UploadJob(
            assetID: "B", resource: .video, attempt: UUID(), bodyFileName: "3.multipart", checksum: "cc")
        await index.addJob(first)
        await index.addJob(second)
        await index.addJob(other)
        await index.addJob(first) // adding the same attempt again changes nothing
        let removed = await index.removeJob(attempt: other.attempt)
        let removedAgain = await index.removeJob(attempt: other.attempt)
        try await index.save()

        let loaded = BackupIndex(directory: directory)
        let jobs = await loaded.jobs
        let forA = await loaded.jobs(for: "A")
        let forB = await loaded.jobs(for: "B")
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
        XCTAssertEqual(jobs, [first, second])
        XCTAssertEqual(forA, [first, second])
        XCTAssertTrue(forB.isEmpty)
    }

    func testJobResolvesAgainstADifferentStagingRoot() async throws {
        // The app container's path changed between launches: the index is reloaded and staging lives elsewhere.
        let oldRoot = makeDirectory()
        let newRoot = makeDirectory()
        let index = BackupIndex(directory: oldRoot)
        await index.set(entry(), for: "A")
        let oldStaging = BackupStaging(
            directory: oldRoot.appendingPathComponent("Staging", isDirectory: true), freeSpace: { .max })
        let job = UploadJob(assetID: "A", resource: .photo, attempt: UUID(), bodyFileName: "x.multipart", checksum: "aa")
        await index.addJob(job)
        try await index.save()
        XCTAssertEqual(oldStaging.url(forBodyNamed: job.bodyFileName).deletingLastPathComponent().lastPathComponent, "Staging")

        // Same index file, now found in a different place, with the body in the new staging folder.
        try FileManager.default.copyItem(
            at: oldRoot.appendingPathComponent("index.json"), to: newRoot.appendingPathComponent("index.json"))
        let reloaded = BackupIndex(directory: newRoot)
        let newStagingDirectory = newRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: newStagingDirectory, withIntermediateDirectories: true)
        let body = newStagingDirectory.appendingPathComponent(job.bodyFileName)
        try Data("body".utf8).write(to: body)
        let newStaging = BackupStaging(directory: newStagingDirectory, freeSpace: { .max })
        let recorder = BackupResultRecorder(index: reloaded, staging: newStaging)

        let reloadedJobs = await reloaded.jobs
        let loaded = try XCTUnwrap(reloadedJobs.first)
        XCTAssertEqual(newStaging.url(forBodyNamed: loaded.bodyFileName).standardizedFileURL, body.standardizedFileURL)
        await recorder.record(loaded, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))

        let recorded = await reloaded.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }

    func testBodyNameCannotPointOutsideStaging() {
        let staging = BackupStaging(directory: makeDirectory().appendingPathComponent("Staging"), freeSpace: { .max })
        let url = staging.url(forBodyNamed: "../../index.json")
        XCTAssertEqual(url.lastPathComponent, "index.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Staging")
    }

    func testClearForgetsJobs() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.addJob(UploadJob(
            assetID: "A", resource: .photo, attempt: UUID(), bodyFileName: "1.multipart", checksum: "aa"))
        await index.clear()
        let jobs = await index.jobs
        XCTAssertTrue(jobs.isEmpty)
    }
}
