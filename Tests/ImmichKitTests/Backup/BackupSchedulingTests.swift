import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Scheduling the nightly processing task and the app-refresh task, running them, and what the switch,
/// backgrounding and sign-out do to them. A fake scheduler stands in for `BGTaskScheduler` and a fake task
/// handle for `BGTask`, so all of it runs on macOS.
final class BackupSchedulingTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private let account = try! ServerCredentials(server: "https://photos.example.com", apiKey: "key-of-account-a")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupSchedulingTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func makeEngine(
        scheduler: FakeScheduler, session: SchedulingFakeSession = SchedulingFakeSession(),
        directory: URL? = nil, identifier: String = "test-session", enabled: Bool = true,
        onClose: @escaping @Sendable (BackupEngine) -> Void = { _ in }
    ) -> BackupEngine {
        let now = self.now
        return BackupEngine(
            credentials: account, directory: directory ?? temporaryDirectory(), sessionIdentifier: identifier,
            source: FakePhotoLibrary(), service: MockImmichService(), network: AlwaysWiFi(),
            settings: { BackupSettings(isEnabled: enabled) }, freeSpace: { 100 * 1024 * 1024 * 1024 },
            backgroundTasks: BackupTaskScheduler(scheduler, now: { now }), onClose: onClose
        ) { directory, index, staging, recorder in
            BackgroundSessionTransport(
                directory: directory, index: index, staging: staging, recorder: recorder, graceDelay: {}
            ) { _ in session }
        }
    }

    @MainActor private func makeModel(engine: BackupEngine) -> BackupModel {
        let suite = "BackupSchedulingTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return BackupModel(engine: engine, defaults: defaults)
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    // MARK: - Tests

    func testSwitchOnSchedulesBothTasks() async throws {
        let scheduler = FakeScheduler()
        let engine = makeEngine(scheduler: scheduler)
        let model = await makeModel(engine: engine)

        await model.runner.setEnabled(true)
        XCTAssertEqual(scheduler.submittedKinds, [.processing, .refresh])

        scheduler.reset()
        await model.runner.appLeftForeground()
        XCTAssertEqual(scheduler.submittedKinds, [.processing, .refresh], "Submitted again on backgrounding")

        await model.runner.setEnabled(false)
        scheduler.reset()
        await model.runner.appLeftForeground()
        XCTAssertEqual(scheduler.submittedKinds, [], "Nothing is scheduled while the switch is off")
    }

    func testSwitchOffCancelsTasksAndUploads() async throws {
        let scheduler = FakeScheduler()
        let session = SchedulingFakeSession()
        let inFlight = SchedulingFakeTask(id: 7)
        session.report([inFlight])
        let engine = makeEngine(scheduler: scheduler, session: session)
        let model = await makeModel(engine: engine)
        await model.runner.setEnabled(true)
        scheduler.reset()

        await model.runner.setEnabled(false)

        XCTAssertEqual(scheduler.cancelledKinds, [.processing, .refresh])
        XCTAssertEqual(scheduler.submittedKinds, [])
        await eventually { inFlight.isCancelled }
    }

    func testProcessingRequiresPowerAndNetwork() throws {
        let scheduler = FakeScheduler()
        BackupTaskScheduler(scheduler, now: { [now] in now }).submitAll()

        let processing = try XCTUnwrap(scheduler.submitted.first { $0.kind == .processing })
        XCTAssertTrue(processing.requiresExternalPower)
        XCTAssertTrue(processing.requiresNetworkConnectivity)
        XCTAssertEqual(processing.kind.identifier, "no.johannesstoen.bloom.backup.processing")

        let refresh = try XCTUnwrap(scheduler.submitted.first { $0.kind == .refresh })
        let begin = try XCTUnwrap(refresh.earliestBeginDate)
        XCTAssertEqual(begin.timeIntervalSince(now), 3600, accuracy: 1, "About an hour from now")
        XCTAssertEqual(refresh.kind.identifier, "no.johannesstoen.bloom.backup.refresh")
        XCTAssertEqual(Set(BackupTaskKind.allCases.map(\.identifier)), [
            "no.johannesstoen.bloom.backup.processing", "no.johannesstoen.bloom.backup.refresh",
        ])
    }

    func testExpirationStopsTheRunAndReportsFailure() async throws {
        let scheduler = FakeScheduler()
        let engine = makeEngine(scheduler: scheduler)
        // The app holds the turn, so the processing run waits until it is cancelled.
        _ = await engine.gate.acquire()
        let task = FakeBackgroundTask()

        let run = BackupBackgroundTasks.handle(
            .processing, task: task, scheduler: BackupTaskScheduler(scheduler), lookup: { .found(engine) })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(task.completions, [], "Still waiting for its turn")

        task.expire()
        XCTAssertEqual(task.completions, [false])
        await run.value
        await engine.gate.release()
        XCTAssertEqual(task.completions, [false], "Completed exactly once")

        // A run that ends on its own reports success, once.
        let normal = FakeBackgroundTask()
        await BackupBackgroundTasks.handle(
            .refresh, task: normal, scheduler: BackupTaskScheduler(scheduler), lookup: { .found(engine) }
        ).value
        XCTAssertEqual(normal.completions, [true])
        normal.expire()
        XCTAssertEqual(normal.completions, [true], "An expiration after the end changes nothing")
    }

    func testEachRunReschedules() async throws {
        let scheduler = FakeScheduler()
        let engine = makeEngine(scheduler: scheduler)

        await engine.runIncremental(budget: .seconds(10))
        XCTAssertEqual(scheduler.submittedKinds, [.processing, .refresh])

        scheduler.reset()
        await engine.runProcessing()
        XCTAssertEqual(scheduler.submittedKinds, [.processing, .refresh])

        let off = FakeScheduler()
        let switchedOff = makeEngine(scheduler: off, enabled: false)
        await switchedOff.runProcessing()
        XCTAssertEqual(off.submittedKinds, [], "Not while the switch is off")
    }

    func testSignOutCancelsEverything() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        try store.save(account)
        let scheduler = FakeScheduler()
        let session = SchedulingFakeSession()
        let inFlight = SchedulingFakeTask(id: 9)
        session.report([inFlight])
        let root = temporaryDirectory()
        let registry = BackupEngineRegistry(
            store: store, root: root, editing: EditingPermission(isAllowed: false)
        ) { [now] credentials, directory, identifier, given, onClose in
            BackupEngine(
                credentials: credentials, directory: directory, sessionIdentifier: identifier,
                source: FakePhotoLibrary(), service: given ?? MockImmichService(), network: AlwaysWiFi(),
                settings: { BackupSettings(isEnabled: true) }, freeSpace: { 100 * 1024 * 1024 * 1024 },
                backgroundTasks: BackupTaskScheduler(scheduler, now: { now }), onClose: onClose
            ) { directory, index, staging, recorder in
                BackgroundSessionTransport(
                    directory: directory, index: index, staging: staging, recorder: recorder, graceDelay: {}
                ) { _ in session }
            }
        }
        let mock = MockImmichService()
        let model = await RootModel(store: store, makeService: { _ in mock }, editing: nil, backupEngines: registry)
        await model.restore()
        let backup = try await MainActor.run { try XCTUnwrap(model.session?.backup) }
        let engine = try await MainActor.run { try XCTUnwrap(backup.engine) }
        await backup.runner.setEnabled(true)
        scheduler.reset()

        await model.signOut()

        XCTAssertEqual(scheduler.cancelledKinds, [.processing, .refresh])
        XCTAssertTrue(inFlight.isCancelled, "Uploads in flight cancelled")
        XCTAssertTrue(session.isInvalidated, "The account's session invalidated")
        XCTAssertTrue(engine.isClosed)

        // Signed out: nothing schedules and nothing runs.
        scheduler.reset()
        engine.setBackgroundTasks(enabled: true)
        await engine.runProcessing()
        let task = FakeBackgroundTask()
        await BackupBackgroundTasks.handle(
            .processing, task: task, scheduler: BackupTaskScheduler(scheduler), lookup: { registry.signedInEngine() }
        ).value
        XCTAssertEqual(scheduler.submittedKinds, [])
        XCTAssertEqual(scheduler.cancelledKinds, [.processing, .refresh], "A task that fires signed out cancels the rest")
        XCTAssertEqual(task.completions, [true])
    }

    func testSessionEventsInvalidateOnlySessionsOfNoAccount() async throws {
        let invalidated = Recorder<String>()
        let completed = Recorder<String>()

        BackupBackgroundTasks.handleEvents(
            forSession: "no.johannesstoen.bloom.backup.gone", lookup: { _ in .noAccount },
            invalidate: { invalidated.append($0) }, completion: { completed.append("gone") })
        XCTAssertEqual(invalidated.values, ["no.johannesstoen.bloom.backup.gone"])
        XCTAssertEqual(completed.values, ["gone"])

        // Before the first unlock the Keychain can't be read: the session may be live, so it isn't touched.
        BackupBackgroundTasks.handleEvents(
            forSession: "no.johannesstoen.bloom.backup.locked", lookup: { _ in .credentialsUnavailable },
            invalidate: { invalidated.append($0) }, completion: { completed.append("locked") })
        XCTAssertEqual(invalidated.values, ["no.johannesstoen.bloom.backup.gone"])
        XCTAssertEqual(completed.values, ["gone", "locked"])

        // The account's own session: the transport gets the handler (it calls it once the events are recorded).
        let engine = makeEngine(scheduler: FakeScheduler())
        BackupBackgroundTasks.handleEvents(
            forSession: engine.sessionIdentifier, lookup: { _ in .found(engine) },
            invalidate: { invalidated.append($0) }, completion: { completed.append("found") })
        XCTAssertEqual(invalidated.values, ["no.johannesstoen.bloom.backup.gone"])
    }
}

// MARK: - Fakes

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class FakeScheduler: BackgroundTaskScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BackupTaskRequest] = []
    private var cancels: [BackupTaskKind] = []

    var submitted: [BackupTaskRequest] { lock.withLock { requests } }
    var submittedKinds: [BackupTaskKind] { submitted.map(\.kind) }
    var cancelledKinds: [BackupTaskKind] { lock.withLock { cancels } }

    func submit(_ request: BackupTaskRequest) throws { lock.withLock { requests.append(request) } }
    func cancel(_ kind: BackupTaskKind) { lock.withLock { cancels.append(kind) } }
    func reset() { lock.withLock { requests = []; cancels = [] } }
}

private final class FakeBackgroundTask: BackgroundTaskHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var results: [Bool] = []

    var completions: [Bool] { lock.withLock { results } }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    func setTaskCompleted(success: Bool) { lock.withLock { results.append(success) } }
    func expire() { lock.withLock { handler }?() }
}

private struct AlwaysWiFi: NetworkConditions {
    var isOnCellular: Bool { get async { false } }
    var isConnected: Bool { get async { true } }
    func changes() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            continuation.yield(NetworkPath(isConnected: true, isOnCellular: false))
            continuation.finish()
        }
    }
}

private final class SchedulingFakeTask: UploadTaskHandle, @unchecked Sendable {
    let taskIdentifier: Int
    private let lock = NSLock()
    private var cancelled = false
    private var storedDescription: String?

    init(id: Int) { taskIdentifier = id }

    var taskDescription: String? {
        get { lock.withLock { storedDescription } }
        set { lock.withLock { storedDescription = newValue } }
    }
    var originalRequest: URLRequest? { nil }
    var currentRequest: URLRequest? { nil }
    var response: URLResponse? { nil }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func resume() {}
    func cancel() { lock.withLock { cancelled = true } }
}

private final class SchedulingFakeSession: UploadSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [any UploadTaskHandle] = []
    private var invalidated = false
    private var nextID = 100

    var isInvalidated: Bool { lock.withLock { invalidated } }
    func report(_ tasks: [SchedulingFakeTask]) { lock.withLock { live.append(contentsOf: tasks) } }

    func uploadTask(with request: URLRequest, fromFile file: URL) -> any UploadTaskHandle {
        lock.withLock {
            nextID += 1
            let task = SchedulingFakeTask(id: nextID)
            live.append(task)
            return task
        }
    }

    func allTasks() async -> [any UploadTaskHandle] { lock.withLock { live } }
    func invalidateAndCancel() { lock.withLock { invalidated = true } }
}
