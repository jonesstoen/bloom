import XCTest
@testable import ImmichKit

/// The background-session transport driven by a fake session: the tests play the part of iOS, delivering
/// response data, completions and "finished events" the way `URLSession` calls its delegate.
final class BackgroundSessionTransportTests: XCTestCase {
    private var directories: [URL] = []
    private var gates: [Gate] = []

    override func tearDown() {
        // Lets every waiting grace period end, so no task is left suspended.
        for gate in gates { gate.open() }
        gates = []
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let created = Data(#"{"id":"srv-1","status":"created"}"#.utf8)

    // MARK: - Fixture

    /// One account's backup folder: what a (re)launched process opens from disk.
    private struct Account {
        let directory: URL
        var stagingDirectory: URL { directory.appendingPathComponent("Staging", isDirectory: true) }
    }

    private struct Process {
        let index: BackupIndex
        let staging: BackupStaging
        let recorder: BackupResultRecorder
        let session: FakeUploadSession
        let transport: BackgroundSessionTransport
        /// The grace period for jobs without a task: it passes when the test opens it.
        let grace: Gate
    }

    private func makeAccount() -> Account {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundSessionTransportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        let account = Account(directory: url)
        try? FileManager.default.createDirectory(at: account.stagingDirectory, withIntermediateDirectories: true)
        return account
    }

    /// Opens the account like a launch does and waits for the startup reconcile, as anything that stages must
    /// (a body staged before reconcile is unreferenced to it and cleaned up). `onSessionCreation` runs inside
    /// the session factory, i.e. while the session is being created (iOS may deliver events right away).
    private func launch(
        _ account: Account, session: FakeUploadSession = FakeUploadSession(),
        onSessionCreation: @escaping (BackgroundSessionEvents) -> Void = { _ in }
    ) async -> Process {
        let process = open(account, session: session, onSessionCreation: onSessionCreation)
        await process.transport.reconcile()
        return process
    }

    /// Opens the account without waiting for anything.
    private func open(
        _ account: Account, session: FakeUploadSession = FakeUploadSession(),
        onSessionCreation: @escaping (BackgroundSessionEvents) -> Void = { _ in }
    ) -> Process {
        let index = BackupIndex(directory: account.directory)
        let staging = BackupStaging(directory: account.stagingDirectory, freeSpace: { .max })
        let recorder = BackupResultRecorder(index: index, staging: staging)
        let grace = Gate()
        gates.append(grace)
        let transport = BackgroundSessionTransport(
            directory: account.directory, index: index, staging: staging, recorder: recorder,
            graceDelay: { await grace.wait() }
        ) { events in
            onSessionCreation(events)
            return session
        }
        return Process(
            index: index, staging: staging, recorder: recorder, session: session, transport: transport, grace: grace)
    }

    private func entry(_ state: BackupState = .pending(reason: .needsUpload), checksum: String = "aa") -> BackupEntry {
        BackupEntry(modificationDate: date, checksums: [.photo: checksum], state: state)
    }

    /// A staged body on disk and the job for it (not yet in the index).
    private func stagedJob(_ account: Account, asset: String = "A", checksum: String = "aa") throws -> UploadJob {
        let name = "\(UUID().uuidString).multipart"
        try Data("body".utf8).write(to: account.stagingDirectory.appendingPathComponent(name))
        return UploadJob(assetID: asset, resource: .photo, attempt: UUID(), bodyFileName: name, checksum: checksum)
    }

    private func bodyExists(_ job: UploadJob, in account: Account) -> Bool {
        FileManager.default.fileExists(atPath: account.stagingDirectory.appendingPathComponent(job.bodyFileName).path)
    }

    private func request(_ url: String = "https://photos.example.com/api/assets") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        return request
    }

    private static func description(of job: UploadJob) -> String {
        String(decoding: try! JSONEncoder().encode(job), as: UTF8.self)
    }

    /// What iOS does when a task ends: it stops reporting it, delivers the response body and the completion.
    /// The response comes from `responseURL`, by default where the request went.
    private func finish(
        _ task: FakeUploadTask, in process: Process, status: Int?, body: Data = Data(), error: Error? = nil,
        responseURL: URL? = nil
    ) {
        process.session.forget(task)
        if let status, let url = responseURL ?? task.originalRequest?.url {
            task.response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        }
        if !body.isEmpty { process.transport.events.didReceive(body, for: task) }
        process.transport.events.didComplete(task, status: status, error: error)
    }

    /// What iOS does after delivering a batch of events: "finished events", then the app's stored handler
    /// must be called. Waits for that call, so every record of the batch is done.
    private func finishEvents(of process: Process, file: StaticString = #filePath, line: UInt = #line) async {
        let handled = expectation(description: "completion handler")
        process.transport.handleEvents { handled.fulfill() }
        process.transport.events.didFinishEvents()
        await fulfillment(of: [handled], timeout: 5)
    }

    /// Waits (up to 5 s) until `condition` holds; returns whether it did.
    private func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// The index file as it is on disk.
    private func savedIndex(_ account: Account) -> [String: Any] {
        let data = (try? Data(contentsOf: account.directory.appendingPathComponent("index.json"))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Results and the completion handler

    func testResultIsRecordedBeforeTheCompletionHandler() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await process.transport.enqueue(job, request: request())
        let task = try XCTUnwrap(process.session.created.first)

        let state = Locked<(called: Int, onMain: Bool, savedFirst: Bool)>((0, false, false))
        let handled = expectation(description: "completion handler")
        process.transport.handleEvents {
            // Read from disk, synchronously, inside the handler: after it returns iOS may suspend the app.
            let saved = self.savedIndex(account)
            let jobs = saved["jobs"] as? [Any]
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: saved)) ?? Data(), as: UTF8.self)
            state.withLock {
                $0.called += 1
                $0.onMain = Thread.isMainThread
                $0.savedFirst = jobs?.isEmpty == true && text.contains("srv-1")
            }
            handled.fulfill()
        }
        finish(task, in: process, status: 201, body: created)
        process.transport.events.didFinishEvents()
        await fulfillment(of: [handled], timeout: 5)

        let result = state.withLock { $0 }
        XCTAssertEqual(result.called, 1)
        XCTAssertTrue(result.onMain, "the system completion handler is called on the main thread")
        XCTAssertTrue(result.savedFirst, "the result is saved in the index before the handler is called")
        let recorded = await process.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertFalse(bodyExists(job, in: account))
    }

    func testEventsBeforeTheHandlerIsStoredAreNotLost() async throws {
        // A previous process enqueued the job and was killed; iOS relaunches the app and delivers the result
        // as soon as the session is created, before the app delegate has stored the completion handler.
        let account = makeAccount()
        let job = try stagedJob(account)
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.addJob(job)
        try await previous.save()

        let finished = FakeUploadTask(id: 7, description: Self.description(of: job), request: request())
        let process = await launch(account) { events in
            events.didReceive(self.created, for: finished)
            events.didComplete(finished, status: 201, error: nil)
            events.didFinishEvents()
        }

        // The handler arrives last; it is still called, once the record is saved.
        let handled = expectation(description: "completion handler")
        process.transport.handleEvents { handled.fulfill() }
        await fulfillment(of: [handled], timeout: 5)

        let reloaded = BackupIndex(directory: account.directory)
        let recorded = await reloaded.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        let jobs = await reloaded.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(bodyExists(job, in: account))
        XCTAssertTrue(process.session.created.isEmpty, "nothing is sent again")
    }

    func testRelaunchRecordsAFinishedTaskOnce() async throws {
        let account = makeAccount()
        let first = await launch(account)
        await first.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await first.transport.enqueue(job, request: request())
        let sent = try XCTUnwrap(first.session.created.first)
        XCTAssertTrue(sent.isResumed)

        // Killed mid-upload. iOS keeps the task and relaunches Bloom for its events.
        let survivor = FakeUploadTask(id: sent.taskIdentifier, description: sent.taskDescription, request: request())
        let relaunched = FakeUploadSession(live: [survivor])
        let second = await launch(account, session: relaunched)
        await second.transport.reconcile()
        let jobsWhileRunning = await second.index.jobs
        XCTAssertEqual(jobsWhileRunning, [job], "a task iOS still reports keeps its job")
        XCTAssertTrue(bodyExists(job, in: account), "and its body")

        finish(survivor, in: second, status: 201, body: created)
        await finishEvents(of: second)
        let recorded = await second.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertFalse(bodyExists(job, in: account))
        let saves = await second.index.saveCount

        // The same result delivered again (say, by a third launch) changes nothing.
        second.transport.events.didReceive(Data(#"{"id":"srv-2","status":"duplicate"}"#.utf8), for: survivor)
        second.transport.events.didComplete(survivor, status: 200, error: nil)
        await finishEvents(of: second)

        let third = BackupIndex(directory: account.directory)
        let final = await third.entry(for: "A")
        XCTAssertEqual(final?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertEqual(final?.serverIDs, [.photo: "srv-1"])
        let jobs = await third.jobs
        XCTAssertTrue(jobs.isEmpty)
        let savesAfter = await second.index.saveCount
        XCTAssertEqual(savesAfter, saves, "a repeated delivery writes nothing")
        XCTAssertTrue(relaunched.created.isEmpty, "no second upload is created")
    }

    func testFailuresAndCancellationsFreeTheirBodyAfterSaving() async throws {
        let account = makeAccount()
        let process = await launch(account)
        for id in ["A", "B", "C"] { await process.index.set(entry(), for: id) }
        let serverError = try stagedJob(account, asset: "A")
        let cancelled = try stagedJob(account, asset: "B")
        let refused = try stagedJob(account, asset: "C")
        for job in [serverError, cancelled, refused] { try await process.transport.enqueue(job, request: request()) }
        let tasks = process.session.created
        XCTAssertEqual(tasks.count, 3)

        finish(tasks[0], in: process, status: 500)
        finish(tasks[1], in: process, status: nil, error: URLError(.cancelled))
        finish(tasks[2], in: process, status: 400, body: Data(#"{"message":"Unsupported file type"}"#.utf8))
        await finishEvents(of: process)

        let reloaded = BackupIndex(directory: account.directory)
        let a = await reloaded.entry(for: "A")
        let b = await reloaded.entry(for: "B")
        let c = await reloaded.entry(for: "C")
        XCTAssertEqual(a?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(b?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(c?.state, .failed(reason: "Unsupported file type"))
        let jobs = await reloaded.jobs
        XCTAssertTrue(jobs.isEmpty)
        for job in [serverError, cancelled, refused] {
            XCTAssertFalse(bodyExists(job, in: account), "a finished job's body is deleted whatever the outcome")
        }
    }

    // MARK: - Reconcile

    func testReconcileRequeuesAJobWithNoTaskAndNoResult() async throws {
        let account = makeAccount()
        let job = try stagedJob(account)
        let leftover = account.stagingDirectory.appendingPathComponent("leftover.multipart")
        try Data("half a body".utf8).write(to: leftover)
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.addJob(job)
        try await previous.save()

        // Relaunched: iOS reports no task for the job and delivers no result (e.g. the app died between
        // saving the job and starting the task, or the user force-quit and iOS dropped the task).
        let process = await launch(account)

        // First phase: leftovers go; the job waits for a late result, with its body.
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "unreferenced files are removed")
        XCTAssertTrue(bodyExists(job, in: account))
        let waiting = await process.transport.inFlight()
        XCTAssertEqual(waiting, [job], "a job waiting for a late result counts as in flight")
        let untouched = await process.index.entry(for: "A")
        XCTAssertEqual(untouched?.state, .pending(reason: .needsUpload))

        // Second phase, once the grace period has passed with no result.
        process.grace.open()
        await process.transport.events.waitForRequeue()

        let reloaded = BackupIndex(directory: account.directory)
        let jobs = await reloaded.jobs
        XCTAssertTrue(jobs.isEmpty, "the job is forgotten, on disk too")
        let requeued = await reloaded.entry(for: "A")
        XCTAssertEqual(requeued?.state, .pending(reason: .needsUpload))
        XCTAssertFalse(bodyExists(job, in: account), "the body is deleted; the uploader stages it again")
        XCTAssertTrue(process.session.created.isEmpty, "reconcile doesn't send anything itself")
        let inFlight = await process.transport.inFlight()
        XCTAssertTrue(inFlight.isEmpty)
    }

    func testACompletedTaskDeliveredWithinTheGraceIsRecordedNotRequeued() async throws {
        let account = makeAccount()
        let job = try stagedJob(account)
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.addJob(job)
        try await previous.save()

        // The task finished while Bloom wasn't running; iOS doesn't list it, but delivers it a little later.
        let process = await launch(account)
        XCTAssertTrue(bodyExists(job, in: account))
        let finished = FakeUploadTask(id: 9, description: Self.description(of: job), request: request())
        finish(finished, in: process, status: 201, body: created)
        await finishEvents(of: process)

        let recorded = await process.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"), "recorded as the success it was")
        // The grace period passing afterwards changes nothing.
        process.grace.open()
        await process.transport.events.waitForRequeue()
        let reloaded = BackupIndex(directory: account.directory)
        let final = await reloaded.entry(for: "A")
        XCTAssertEqual(final?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertEqual(final?.serverIDs, [.photo: "srv-1"])
        let jobs = await reloaded.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(bodyExists(job, in: account))
    }

    func testJobsWithoutAResultAreRequeuedOnceTheEventsAreDelivered() async throws {
        let account = makeAccount()
        let delivered = try stagedJob(account, asset: "A")
        let lost = try stagedJob(account, asset: "B")
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.set(entry(), for: "B")
        await previous.addJob(delivered)
        await previous.addJob(lost)
        try await previous.save()

        // iOS delivers one result and says it is done: the other isn't coming. No need to wait out the grace.
        let process = await launch(account)
        let finished = FakeUploadTask(id: 9, description: Self.description(of: delivered), request: request())
        finish(finished, in: process, status: 201, body: created)
        await finishEvents(of: process)

        // Both are on disk before the completion handler ran (`finishEvents` waits for it).
        let reloaded = BackupIndex(directory: account.directory)
        let a = await reloaded.entry(for: "A")
        let b = await reloaded.entry(for: "B")
        XCTAssertEqual(a?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertEqual(b?.state, .pending(reason: .needsUpload))
        let jobs = await reloaded.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(bodyExists(lost, in: account))
    }

    func testReconcileKeepsTheBodyOfALiveTask() async throws {
        let account = makeAccount()
        let running = try stagedJob(account, asset: "A")
        // A task iOS reports whose job the index doesn't have (its record was lost): its body stays too.
        let unknown = try stagedJob(account, asset: "B")
        let leftover = account.stagingDirectory.appendingPathComponent("leftover.multipart")
        try Data("x".utf8).write(to: leftover)
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.set(entry(), for: "B")
        await previous.addJob(running)
        try await previous.save()

        let session = FakeUploadSession(live: [
            FakeUploadTask(id: 1, description: Self.description(of: running), request: request()),
            FakeUploadTask(id: 2, description: Self.description(of: unknown), request: request()),
        ])
        let process = await launch(account, session: session)
        process.grace.open()
        await process.transport.events.waitForRequeue()

        XCTAssertTrue(bodyExists(running, in: account))
        XCTAssertTrue(bodyExists(unknown, in: account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        let jobs = await process.index.jobs
        XCTAssertEqual(jobs, [running])
        let a = await process.index.entry(for: "A")
        XCTAssertEqual(a?.state, .pending(reason: .needsUpload))
        XCTAssertTrue(session.tasks.allSatisfy { !$0.isCancelled })
        let inFlight = await process.transport.inFlight()
        XCTAssertEqual(inFlight, [running])
    }

    func testCleanupWaitsForAReadableIndex() async throws {
        let account = makeAccount()
        let body = account.stagingDirectory.appendingPathComponent("waiting.multipart")
        try Data("x".utf8).write(to: body)
        // An index file that exists but can't be read (as while the phone is locked): its jobs are unknown.
        try FileManager.default.createDirectory(
            at: account.directory.appendingPathComponent("index.json"), withIntermediateDirectories: true)

        let process = await launch(account)
        let available = await process.index.isAvailable
        XCTAssertFalse(available)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path), "nothing is removed on an unknown index")
    }

    func testReconcileRunsWhenTheTransportStartsBeforeAnyEnqueue() async throws {
        let account = makeAccount()
        let stale = try stagedJob(account, asset: "A")
        let leftover = account.stagingDirectory.appendingPathComponent("leftover.multipart")
        try Data("x".utf8).write(to: leftover)
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        await previous.set(entry(), for: "B")
        await previous.addJob(stale)
        try await previous.save()

        // Nobody calls reconcile: starting the transport does it. It is held inside its query of the session's
        // tasks while an enqueue comes in; the enqueue must wait for it.
        let session = FakeUploadSession()
        session.holdAllTasks()
        let process = open(account, session: session)
        await session.waitUntilHeld()
        let fresh = UploadJob(assetID: "B", resource: .photo, attempt: UUID(), bodyFileName: "fresh.multipart", checksum: "aa")
        let enqueue = Task { try await process.transport.enqueue(fresh, request: self.request()) }
        let waits = await eventually { process.transport.waitingForStartup == 1 }
        XCTAssertTrue(waits, "the enqueue waits for reconcile")
        XCTAssertTrue(session.created.isEmpty, "nothing is sent before reconcile has finished")
        let jobsDuring = await process.index.jobs
        XCTAssertEqual(jobsDuring, [stale], "nor added to the index")

        session.releaseAllTasks()
        try await enqueue.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "reconcile ran first")
        let jobs = await process.index.jobs
        XCTAssertEqual(jobs, [stale, fresh], "the stale job waits for a late result; the new one is added")
        XCTAssertTrue(bodyExists(stale, in: account))
        XCTAssertEqual(session.created.count, 1)
    }

    func testEnqueueSavesTheJobBeforeStartingTheTask() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await process.transport.enqueue(job, request: request())

        let saved = await BackupIndex(directory: account.directory).jobs
        XCTAssertEqual(saved, [job])
        let task = try XCTUnwrap(process.session.created.first)
        XCTAssertTrue(task.isResumed)
        XCTAssertEqual(task.file?.lastPathComponent, job.bodyFileName)
        let carried = try JSONDecoder().decode(UploadJob.self, from: Data((task.taskDescription ?? "").utf8))
        XCTAssertEqual(carried, job, "the task carries its job")
        let inFlight = await process.transport.inFlight()
        XCTAssertEqual(inFlight, [job])
    }

    func testCancelAllCancelsEveryTaskAndRequeues() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await process.transport.enqueue(job, request: request())
        await process.transport.cancelAll()
        let task = try XCTUnwrap(process.session.created.first)
        XCTAssertTrue(task.isCancelled)

        finish(task, in: process, status: nil, error: URLError(.cancelled))
        await finishEvents(of: process)
        let requeued = await process.index.entry(for: "A")
        XCTAssertEqual(requeued?.state, .pending(reason: .needsUpload))
        XCTAssertFalse(bodyExists(job, in: account))
    }

    func testCancelAllDuringAnEnqueueCancelsTheNewTask() async throws {
        let account = makeAccount()
        let previous = BackupIndex(directory: account.directory)
        await previous.set(entry(), for: "A")
        try await previous.save()
        let session = FakeUploadSession()
        session.holdAllTasks()
        let process = open(account, session: session)
        await session.waitUntilHeld()

        // An enqueue is under way (waiting for reconcile) when the switch is turned off.
        let job = UploadJob(assetID: "A", resource: .photo, attempt: UUID(), bodyFileName: "a.multipart", checksum: "aa")
        let enqueue = Task { try await process.transport.enqueue(job, request: self.request()) }
        let waits = await eventually { process.transport.waitingForStartup == 1 }
        XCTAssertTrue(waits)
        let cancel = Task { await process.transport.cancelAll() }
        await session.waitUntilHeld(count: 2)
        session.releaseAllTasks()
        try await enqueue.value
        await cancel.value

        let task = try XCTUnwrap(session.created.first)
        XCTAssertTrue(task.isCancelled, "the task started after cancelAll is cancelled at once")
        XCTAssertFalse(task.isResumed, "and never sent")
        finish(task, in: process, status: nil, error: URLError(.cancelled))
        await finishEvents(of: process)
        let requeued = await process.index.entry(for: "A")
        XCTAssertEqual(requeued?.state, .pending(reason: .needsUpload))
        let jobs = await process.index.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testEnqueueAfterInvalidateThrowsInsteadOfStartingATask() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        process.transport.invalidate()
        XCTAssertTrue(process.session.isInvalidated)

        do {
            try await process.transport.enqueue(job, request: request())
            XCTFail("an invalidated session can't start tasks (URLSession raises an exception)")
        } catch is CancellationError {}
        XCTAssertTrue(process.session.created.isEmpty)
        let jobs = await process.index.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testAStaleFinishedEventsDoesNotReleaseANewHandlerEarly() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await process.transport.enqueue(job, request: request())
        let task = try XCTUnwrap(process.session.created.first)

        // One wake ended without a handler being stored ...
        process.transport.events.didFinishEvents()
        // ... then a new batch begins: a result arrives and is recorded, and the next handler is stored.
        finish(task, in: process, status: 201, body: created)
        let recorded = await eventually { !process.transport.events.hasPendingWork }
        XCTAssertTrue(recorded)
        let entry = await process.index.entry(for: "A")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "srv-1"))
        let calls = Locked(0)
        let handled = expectation(description: "completion handler")
        process.transport.handleEvents {
            calls.withLock { $0 += 1 }
            handled.fulfill()
        }
        // Anything already dispatched to the main queue has run once this hop has.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(calls.withLock { $0 }, 0, "the old 'finished' doesn't belong to this batch")

        process.transport.events.didFinishEvents()
        await fulfillment(of: [handled], timeout: 5)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testErrorsOutsideTheURLDomainAreRetried() {
        let posix = BackgroundSessionEvents.outcome(
            status: nil, data: Data(), error: NSError(domain: NSPOSIXErrorDomain, code: 28))
        XCTAssertEqual(posix, .failed(.service(.invalidResponse)))
        XCTAssertEqual(BackgroundSessionEvents.outcome(status: nil, data: Data(), error: URLError(.cancelled)), .failed(.cancelled))
        let timeout = BackgroundSessionEvents.outcome(
            status: nil, data: Data(), error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        guard case let .failed(.service(.network(_, code))) = timeout else { return XCTFail("\(timeout)") }
        XCTAssertEqual(code, .timedOut)
        XCTAssertEqual(BackgroundSessionEvents.outcome(status: nil, data: Data(), error: nil), .failed(.service(.invalidResponse)))
    }

    // MARK: - Requests

    func testCrossOriginRedirectIsRefused() async throws {
        // Background sessions follow redirects without asking and copy the headers, so the check is made on
        // the completed task: the response came from another server.
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        await process.index.set(entry(), for: "B")
        let job = try stagedJob(account, asset: "A")
        try await process.transport.enqueue(job, request: request("https://photos.example.com/api/assets"))
        let task = try XCTUnwrap(process.session.created.first)
        finish(task, in: process, status: 201, body: Data(#"{"id":"srv-evil","status":"created"}"#.utf8),
               responseURL: URL(string: "https://login.example.net/api/assets"))
        await finishEvents(of: process)

        let refused = await process.index.entry(for: "A")
        XCTAssertEqual(refused?.state, .pending(reason: .needsUpload), "the other server's answer isn't trusted")
        XCTAssertEqual(refused?.serverIDs, [:])
        XCTAssertFalse(bodyExists(job, in: account))
        XCTAssertTrue(process.transport.isRedirectBlocked)

        // The block survives relaunch, and nothing is sent while it is set.
        let relaunched = await launch(account)
        XCTAssertTrue(relaunched.transport.isRedirectBlocked)
        let next = try stagedJob(account, asset: "B")
        do {
            try await relaunched.transport.enqueue(next, request: request())
            XCTFail("enqueue must refuse while a redirect block is set")
        } catch BackupTransportError.redirectBlocked {}
        XCTAssertTrue(relaunched.session.created.isEmpty)
        let jobs = await relaunched.index.jobs
        XCTAssertTrue(jobs.isEmpty)

        // Only an explicit clear lifts it.
        relaunched.transport.clearRedirectBlock()
        XCTAssertFalse(relaunched.transport.isRedirectBlocked)
        try await relaunched.transport.enqueue(next, request: request())
        XCTAssertEqual(relaunched.session.created.count, 1)
        let third = await launch(account)
        XCTAssertFalse(third.transport.isRedirectBlocked)
    }

    func testSameOriginRedirectIsAccepted() async throws {
        let account = makeAccount()
        let process = await launch(account)
        await process.index.set(entry(), for: "A")
        let job = try stagedJob(account)
        try await process.transport.enqueue(job, request: request("https://photos.example.com/api/assets"))
        let task = try XCTUnwrap(process.session.created.first)
        finish(task, in: process, status: 201, body: created,
               responseURL: URL(string: "https://PHOTOS.example.com:443/api/v2/assets"))
        await finishEvents(of: process)

        let recorded = await process.index.entry(for: "A")
        XCTAssertEqual(recorded?.state, .backedUp(serverAssetID: "srv-1"))
        XCTAssertFalse(process.transport.isRedirectBlocked)
    }

    func testTheDelegateRefusesCrossOriginRedirectsWhenAsked() async throws {
        // A background session doesn't ask; a session that does gets the same rule as `SameOriginRedirects`.
        let account = makeAccount()
        let process = await launch(account)
        let events = process.transport.events
        let task = FakeUploadTask(id: 1, description: nil, request: request("https://photos.example.com/api/assets"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://photos.example.com/api/assets")!, statusCode: 307, httpVersion: nil, headerFields: nil))

        XCTAssertNil(events.redirect(for: task, response: response, to: request("https://evil.example.net/api/assets")))
        XCTAssertNil(events.redirect(for: task, response: response, to: request("http://photos.example.com/api/assets")))
        XCTAssertNil(events.redirect(for: task, response: response, to: request("https://photos.example.com:8443/api/assets")))
        XCTAssertNotNil(events.redirect(for: task, response: response, to: request("https://photos.example.com/api/v2/assets")))

        let delegate = BackgroundSessionDelegate(events: events)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let body = account.directory.appendingPathComponent("redirect-test")
        try Data().write(to: body)
        let live = session.uploadTask(with: request("https://photos.example.com/api/assets"), fromFile: body)
        let answers = Locked<[URLRequest?]>([])
        for target in ["https://evil.example.net/api/assets", "https://photos.example.com/api/v2/assets"] {
            delegate.urlSession(session, task: live, willPerformHTTPRedirection: response, newRequest: request(target)) { next in
                answers.withLock { $0.append(next) }
            }
        }
        let result = answers.withLock { $0 }
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result.first ?? nil)
        XCTAssertEqual((result.last ?? nil)?.url?.host, "photos.example.com")
    }

    func testCellularFlagsFollowTheSwitches() async throws {
        let account = makeAccount()
        let process = await launch(account)
        let service = LiveImmichService(credentials: try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key"))
        let settings = BackupSettings(photosOnCellular: false, videosOnCellular: true, isEnabled: true)
        let photo = DeviceAsset(id: "P", isVideo: false, creationDate: date, modificationDate: date, isFavorite: false,
                                duration: 0, resources: [DeviceResource(type: .photo, filename: "IMG.HEIC")])
        let video = DeviceAsset(id: "V", isVideo: true, creationDate: date, modificationDate: date, isFavorite: false,
                                duration: 3, resources: [DeviceResource(type: .video, filename: "IMG.MOV")])
        for asset in [photo, video] {
            await process.index.set(entry(), for: asset.id)
            let job = try stagedJob(account, asset: asset.id)
            let body = account.stagingDirectory.appendingPathComponent(job.bodyFileName)
            // As the uploader builds it: the switch for this media type decides cellular.
            let upload = AssetUploadRequest(
                fileURL: body, filename: asset.resources[0].filename, mimeType: "application/octet-stream",
                checksum: job.checksum, createdAt: date, modifiedAt: date, isFavorite: false, duration: nil,
                livePhotoVideoID: nil, allowsCellular: settings.allowsNetwork(for: asset, onCellular: true))
            try await process.transport.enqueue(job, request: service.makeUploadRequest(upload, boundary: "b", bodyFile: body))
        }

        let sent = process.session.created.map { try? XCTUnwrap($0.originalRequest) }
        XCTAssertEqual(sent.count, 2)
        let photoRequest = try XCTUnwrap(sent[0])
        XCTAssertFalse(photoRequest.allowsCellularAccess)
        XCTAssertFalse(photoRequest.allowsExpensiveNetworkAccess, "a hotspot counts as cellular")
        XCTAssertFalse(photoRequest.allowsConstrainedNetworkAccess, "and so does Low Data Mode")
        let videoRequest = try XCTUnwrap(sent[1])
        XCTAssertTrue(videoRequest.allowsCellularAccess)
        XCTAssertTrue(videoRequest.allowsExpensiveNetworkAccess)
        XCTAssertTrue(videoRequest.allowsConstrainedNetworkAccess)
        XCTAssertNotNil(photoRequest.value(forHTTPHeaderField: "x-immich-checksum"))
    }

    // MARK: - Session identifier

    func testIdentifierDiffersPerAccountAndHoldsNoSecret() {
        let server = URL(string: "https://photos.example.com")!
        let other = URL(string: "https://immich.example.org")!
        let user = "5f1c2d3e-aaaa-bbbb-cccc-0123456789ab"
        let id = BackgroundSessionTransport.sessionIdentifier(serverURL: server, userID: user)

        XCTAssertTrue(id.hasPrefix("no.johannesstoen.bloom.backup."))
        XCTAssertEqual(id, BackgroundSessionTransport.sessionIdentifier(serverURL: server, userID: user), "stable")
        XCTAssertEqual(id, BackgroundSessionTransport.sessionIdentifier(
            serverURL: URL(string: "https://PHOTOS.example.com/")!, userID: user), "the same server written differently")
        for same in ["https://photos.example.com:443", "https://photos.example.com:443/", "https://photos.example.com//"] {
            XCTAssertEqual(id, BackgroundSessionTransport.sessionIdentifier(serverURL: URL(string: same)!, userID: user), same)
        }
        XCTAssertEqual(
            BackgroundSessionTransport.sessionIdentifier(serverURL: URL(string: "http://photos.example.com:80/immich/")!, userID: user),
            BackgroundSessionTransport.sessionIdentifier(serverURL: URL(string: "http://photos.example.com/immich")!, userID: user))
        XCTAssertNotEqual(id, BackgroundSessionTransport.sessionIdentifier(
            serverURL: URL(string: "https://photos.example.com:8443")!, userID: user), "another port is another server")
        XCTAssertNotEqual(id, BackgroundSessionTransport.sessionIdentifier(serverURL: server, userID: "another-user"))
        XCTAssertNotEqual(id, BackgroundSessionTransport.sessionIdentifier(serverURL: other, userID: user))

        let suffix = id.dropFirst("no.johannesstoen.bloom.backup.".count)
        XCTAssertFalse(suffix.isEmpty)
        XCTAssertLessThanOrEqual(suffix.count, 32, "short")
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "only hex, nothing readable")
        XCTAssertFalse(id.contains("photos"))
        XCTAssertFalse(id.contains("example"))
        XCTAssertFalse(id.contains(user))
        XCTAssertFalse(id.contains("5f1c2d3e"))
    }
}

// MARK: - Fakes

/// Opens once; `wait()` returns once it is open.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }
}

/// A lock-protected value for state shared with callbacks.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

private final class FakeUploadTask: UploadTaskHandle, @unchecked Sendable {
    let taskIdentifier: Int
    let originalRequest: URLRequest?
    let file: URL?
    private let lock = NSLock()
    private var storedDescription: String?
    private var storedResponse: URLResponse?
    private var storedCurrentRequest: URLRequest?
    private var resumed = false
    private var cancelled = false

    init(id: Int, description: String?, request: URLRequest?, file: URL? = nil) {
        taskIdentifier = id
        storedDescription = description
        originalRequest = request
        self.file = file
    }

    var taskDescription: String? {
        get { lock.withLock { storedDescription } }
        set { lock.withLock { storedDescription = newValue } }
    }

    var response: URLResponse? {
        get { lock.withLock { storedResponse } }
        set { lock.withLock { storedResponse = newValue } }
    }

    var currentRequest: URLRequest? {
        get { lock.withLock { storedCurrentRequest ?? originalRequest } }
        set { lock.withLock { storedCurrentRequest = newValue } }
    }

    var isResumed: Bool { lock.withLock { resumed } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func resume() { lock.withLock { resumed = true } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Stands in for a background `URLSession`: hands out tasks and reports the ones "iOS" still has.
private final class FakeUploadSession: UploadSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [FakeUploadTask]
    private var made: [FakeUploadTask] = []
    private var nextID = 100
    private var invalidated = false
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(live: [FakeUploadTask] = []) { self.live = live }

    /// Tasks created through this session, in order.
    var created: [FakeUploadTask] { lock.withLock { made } }
    /// Tasks it currently reports.
    var tasks: [FakeUploadTask] { lock.withLock { live } }
    var isInvalidated: Bool { lock.withLock { invalidated } }

    func uploadTask(with request: URLRequest, fromFile file: URL) -> any UploadTaskHandle {
        lock.withLock {
            nextID += 1
            let task = FakeUploadTask(id: nextID, description: nil, request: request, file: file)
            made.append(task)
            live.append(task)
            return task
        }
    }

    func allTasks() async -> [any UploadTaskHandle] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                guard holding else { return true }
                held.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
        return lock.withLock { live }
    }

    /// Until `releaseAllTasks()`, `allTasks()` doesn't return.
    func holdAllTasks() { lock.withLock { holding = true } }

    func releaseAllTasks() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { held = [] }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once `count` callers are waiting in `allTasks()`.
    func waitUntilHeld(count: Int = 1) async {
        while lock.withLock({ held.count < count }) { await Task.yield() }
    }

    func invalidateAndCancel() {
        lock.withLock {
            invalidated = true
            for task in live { task.cancel() }
        }
    }

    /// The task ended: iOS no longer reports it.
    func forget(_ task: FakeUploadTask) {
        lock.withLock { live.removeAll { $0 === task } }
    }
}
