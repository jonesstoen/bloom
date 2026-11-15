import CryptoKit
import Foundation

/// One upload task as the transport needs it. `URLSessionTask` is one; tests use a fake.
public protocol UploadTaskHandle: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    /// The task's `UploadJob`, encoded (see `BackgroundSessionTransport`). iOS keeps it with the task across
    /// relaunches, so a result delivered to a new process still names its job.
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    func resume()
    func cancel()
}

extension URLSessionTask: UploadTaskHandle {}

/// The part of a background `URLSession` the transport uses, so tests can play the part of iOS.
public protocol UploadSessionDriving: Sendable {
    func uploadTask(with request: URLRequest, fromFile file: URL) -> any UploadTaskHandle
    /// The tasks the system still has for this session (running, suspended or not yet delivered).
    func allTasks() async -> [any UploadTaskHandle]
    func invalidateAndCancel()
}

/// Uploads through a background `URLSession`, so iOS finishes an upload after Bloom is suspended or killed
/// and relaunches Bloom in the background to deliver the result.
///
/// - Each task carries its `UploadJob` in `taskDescription` (asset ID, resource, attempt, body file name,
///   checksum; no secrets), so a result is matched to its job in whichever process receives it.
/// - The event sink (`events`) exists before the session is created: iOS may deliver events as soon as a
///   session with a known identifier is created, and none may land nowhere.
/// - Every completion goes through `BackupResultRecorder`: the result is saved in the index, then the body
///   file is deleted, whatever the outcome (success, server error, refusal, cancellation). The system
///   completion handler from `handleEvents(completion:)` is called on the main thread only after every
///   record of the batch has finished.
/// - Starting the transport reconciles the index with the tasks iOS still has (`reconcile()`), and does so
///   before anything else: `enqueue` and `inFlight` wait for it.
///
/// Create at most one per session identifier per process (iOS allows one session per identifier), and
/// create it before calling `BackupStaging.stageBody` for its account (see `reconcile()`).
public final class BackgroundSessionTransport: BackupTransport, Sendable {
    /// Where the session's delegate hands its callbacks. Exposed to tests, which deliver events through it.
    let events: BackgroundSessionEvents
    private let session: any UploadSessionDriving
    private let index: BackupIndex
    private let staging: BackupStaging
    private let recorder: BackupResultRecorder
    private let startup: StartupTask

    /// The live transport: a background `URLSession` called `identifier`
    /// (`sessionIdentifier(serverURL:userID:)`) whose delegate refuses cross-origin redirects.
    public convenience init(
        identifier: String, index: BackupIndex, staging: BackupStaging, recorder: BackupResultRecorder
    ) {
        self.init(index: index, staging: staging, recorder: recorder) { events in
            LiveUploadSession(identifier: identifier, events: events)
        }
    }

    /// `makeSession` gets the event sink and must create the session with it; it is called once, here.
    init(
        index: BackupIndex, staging: BackupStaging, recorder: BackupResultRecorder,
        makeSession: (BackgroundSessionEvents) -> any UploadSessionDriving
    ) {
        self.index = index
        self.staging = staging
        self.recorder = recorder
        // The sink first, then the session: events delivered during creation already have a home.
        events = BackgroundSessionEvents(recorder: recorder)
        session = makeSession(events)
        startup = StartupTask()
        // Reconcile is the first thing the transport does. The sink counts it as unfinished work from its
        // creation, so the system completion handler also waits for it.
        startup.start { [self] in await self.runReconcile() }
    }

    // MARK: - BackupTransport

    /// Saves the job in the index, then starts a task sending its body file with `request`. Cellular,
    /// expensive (hotspot) and constrained (Low Data Mode) access all follow `request.allowsCellularAccess`,
    /// which the uploader sets from the switch for the asset's media type. Enqueuing an attempt the index
    /// already has does nothing. Throws when the job can't be saved (nothing is sent then).
    public func enqueue(_ job: UploadJob, request: URLRequest) async throws {
        await startup.wait()
        guard await !index.jobs.contains(where: { $0.attempt == job.attempt }) else { return }
        guard let body = staging.url(forBodyNamed: job.bodyFileName) else { throw CocoaError(.fileNoSuchFile) }
        await index.addJob(job)
        do {
            try await index.save()
        } catch {
            await index.removeJob(attempt: job.attempt)
            throw error
        }
        let task = session.uploadTask(with: Self.applyingNetworkPolicy(to: request), fromFile: body)
        task.taskDescription = Self.description(of: job)
        task.resume()
    }

    public func inFlight() async -> [UploadJob] {
        await startup.wait()
        return await index.jobs
    }

    /// Cancels every task of the session. Each one then completes as cancelled: its item goes back to the
    /// queue and its body file is deleted, through the recorder.
    public func cancelAll() async {
        for task in await session.allTasks() { task.cancel() }
    }

    /// Cancels everything and invalidates the session (sign-out). The transport can't send afterwards.
    public func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - Relaunch

    /// Stores the completion handler iOS passes to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` for this session. It is called
    /// on the main thread once iOS has delivered the session's events (`urlSessionDidFinishEvents`) and every
    /// result is saved; also when the events came before the handler was stored.
    public func handleEvents(completion: @escaping () -> Void) {
        events.store(completion)
    }

    /// Brings the index in line with the tasks iOS still has. Runs once, when the transport starts; calling it
    /// waits for that run.
    ///
    /// - A job in the index with no task iOS reports and no result delivered in this process is requeued:
    ///   recorded as cancelled, so the item goes back to `pending(.needsUpload)`, the job is removed and,
    ///   after the save, its body deleted. The uploader stages and sends it again (the server's checksum
    ///   dedupe makes that safe). It isn't re-sent from the old body: the request (headers, boundary) isn't
    ///   stored and can't be rebuilt here, and a fresh staging also re-checks the bytes against the checksum.
    /// - A task iOS reports keeps its body file, whether or not the index still has its job.
    /// - Every other file in the staging folder is removed, through `BackupStaging.removeUnreferenced`.
    ///
    /// Because of that cleanup, nothing may stage a body for this account until this has finished: await it
    /// (or `inFlight()`) before the first `BackupStaging.stageBody`. It also tells staging which bodies are
    /// still waiting for their upload, which its budget relies on after a relaunch.
    public func reconcile() async {
        await startup.wait()
    }

    private func runReconcile() async {
        defer { events.finishWork() }
        var liveAttempts: Set<UUID> = []
        var keptNames: Set<String> = []
        for task in await session.allTasks() {
            guard let job = Self.job(in: task.taskDescription) else { continue }
            liveAttempts.insert(job.attempt)
            keptNames.insert(job.bodyFileName)
        }
        for job in await index.jobs where !liveAttempts.contains(job.attempt) && !events.wasDelivered(job.attempt) {
            await recorder.record(job, .failed(.cancelled))
        }
        // The index first, then the records in progress: a job a record has just taken out of the index is
        // then still among the records in progress.
        keptNames.formUnion(await index.jobs.map(\.bodyFileName))
        keptNames.formUnion(events.bodiesBeingRecorded())
        await staging.removeUnreferenced(keeping: Set(keptNames.compactMap { staging.url(forBodyNamed: $0) }))
    }

    // MARK: - Helpers

    /// The background session's identifier for one account: stable, different per server and user, and
    /// holding nothing readable (a short SHA-256 of the server URL and user ID). Pass the same server URL
    /// each time (the signed-in account's).
    public static func sessionIdentifier(serverURL: URL, userID: String) -> String {
        var server = serverURL.absoluteString
        if var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            let scheme = components.scheme?.lowercased()
            let host = components.host?.lowercased()
            components.scheme = scheme
            components.host = host
            server = components.string ?? server
        }
        while server.hasSuffix("/") { server.removeLast() }
        let digest = SHA256.hash(data: Data("\(server)\n\(userID)".utf8))
        return "no.johannesstoen.bloom.backup." + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `request` with expensive and constrained access off whenever cellular is off: a personal hotspot and
    /// Low Data Mode count as cellular, as in the rest of backup.
    static func applyingNetworkPolicy(to request: URLRequest) -> URLRequest {
        var request = request
        let cellular = request.allowsCellularAccess
        request.allowsExpensiveNetworkAccess = cellular && request.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = cellular && request.allowsConstrainedNetworkAccess
        return request
    }

    static func description(of job: UploadJob) -> String? {
        (try? JSONEncoder().encode(job)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func job(in description: String?) -> UploadJob? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(UploadJob.self, from: Data(description.utf8))
    }
}

/// Runs the transport's startup work once and lets callers wait for it.
private final class StartupTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func start(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock { if task == nil { task = Task(operation: work) } }
    }

    func wait() async {
        await lock.withLock { task }?.value
    }
}

/// Receives the background session's delegate callbacks (on the session's delegate queue, synchronously)
/// and turns each completion into one `BackupResultRecorder.record`. Its bookkeeping is under a lock and
/// done synchronously in the callback, so the order of callbacks is kept: a task's data before its
/// completion, every completion before "finished events". The record itself runs in a task.
final class BackgroundSessionEvents: @unchecked Sendable {
    private struct Handler: @unchecked Sendable {
        let call: () -> Void
    }

    private struct State {
        /// Response bodies so far, by task identifier (an upload's answer is a few bytes of JSON).
        var responses: [Int: Data] = [:]
        /// Work the completion handler waits for: records in progress, and the startup reconcile
        /// (counted from the start, see `init`).
        var pendingWork = 1
        /// iOS has delivered everything for now (`urlSessionDidFinishEvents`) and no handler took it yet.
        var eventsFinished = false
        var handlers: [Handler] = []
        /// Attempts whose completion this process received; reconcile leaves their jobs to the recorder.
        var delivered: Set<UUID> = []
        /// Body file names of records in progress, by attempt.
        var recording: [UUID: String] = [:]
    }

    private let recorder: BackupResultRecorder
    private let lock = NSLock()
    private var state = State()

    init(recorder: BackupResultRecorder) {
        self.recorder = recorder
    }

    func didReceive(_ data: Data, for task: any UploadTaskHandle) {
        let limit = LiveImmichService.maxUploadResponseBytes + 1
        lock.withLock {
            var body = state.responses[task.taskIdentifier] ?? Data()
            // Kept up to one byte past the cap, so the parser still sees an oversize answer as oversize.
            guard body.count < limit else { return }
            body.append(data.prefix(limit - body.count))
            state.responses[task.taskIdentifier] = body
        }
    }

    /// `status` is the HTTP status of the task's response, `nil` without one.
    func didComplete(_ task: any UploadTaskHandle, status: Int?, error: Error?) {
        let job = BackgroundSessionTransport.job(in: task.taskDescription)
        let data = lock.withLock {
            state.pendingWork += 1
            if let job {
                state.delivered.insert(job.attempt)
                state.recording[job.attempt] = job.bodyFileName
            }
            return state.responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        }
        let outcome = Self.outcome(status: status, data: data, error: error)
        let recorder = recorder
        Task {
            // A task without a readable job can't be recorded; its body is removed by the next cleanup.
            if let job { await recorder.record(job, outcome) }
            self.finishWork(recording: job?.attempt)
        }
    }

    func didFinishEvents() {
        let handlers = lock.withLock {
            state.eventsFinished = true
            return takeHandlersIfDone()
        }
        call(handlers)
    }

    /// The redirect to follow, `nil` to refuse it: only to the same scheme, host and port, because the
    /// request carries the API key (`SameOriginRedirects`).
    func redirect(for task: any UploadTaskHandle, response: HTTPURLResponse, to request: URLRequest) -> URLRequest? {
        SameOriginRedirects.allows(from: task.originalRequest?.url ?? response.url, to: request.url) ? request : nil
    }

    func store(_ completion: @escaping () -> Void) {
        let handlers = lock.withLock {
            state.handlers.append(Handler(call: completion))
            return takeHandlersIfDone()
        }
        call(handlers)
    }

    func finishWork(recording attempt: UUID? = nil) {
        let handlers = lock.withLock {
            state.pendingWork -= 1
            if let attempt { state.recording[attempt] = nil }
            return takeHandlersIfDone()
        }
        call(handlers)
    }

    func wasDelivered(_ attempt: UUID) -> Bool {
        lock.withLock { state.delivered.contains(attempt) }
    }

    func bodiesBeingRecorded() -> Set<String> {
        lock.withLock { Set(state.recording.values) }
    }

    /// Call with the lock held.
    private func takeHandlersIfDone() -> [Handler] {
        guard state.pendingWork == 0, state.eventsFinished, !state.handlers.isEmpty else { return [] }
        state.eventsFinished = false
        defer { state.handlers = [] }
        return state.handlers
    }

    private func call(_ handlers: [Handler]) {
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler.call() }
        }
    }

    static func outcome(status: Int?, data: Data, error: Error?) -> UploadOutcome {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return .failed(UploadFailure(URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo)))
            }
            return .failed(UploadFailure(error))
        }
        guard let status else { return .failed(.service(.invalidResponse)) }
        do {
            return .uploaded(try LiveImmichService.result(status: status, data: data))
        } catch {
            return .failed(UploadFailure(error))
        }
    }
}

/// The background session's delegate: forwards everything to the event sink.
final class BackgroundSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let events: BackgroundSessionEvents

    init(events: BackgroundSessionEvents) {
        self.events = events
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        events.didReceive(data, for: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        events.didComplete(task, status: (task.response as? HTTPURLResponse)?.statusCode, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(events.redirect(for: task, response: response, to: request))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.didFinishEvents()
    }
}

/// A background `URLSession` for uploads. Not exercised by unit tests (they use a fake session).
private final class LiveUploadSession: UploadSessionDriving {
    private let session: URLSession

    init(identifier: String, events: BackgroundSessionEvents) {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // As `SameOriginRedirects.configuration`: no cache, no cookies.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Cellular is decided per request (`applyingNetworkPolicy`); the session allows what a request allows.
        configuration.allowsCellularAccess = true
        session = URLSession(
            configuration: configuration, delegate: BackgroundSessionDelegate(events: events), delegateQueue: nil)
    }

    func uploadTask(with request: URLRequest, fromFile file: URL) -> any UploadTaskHandle {
        session.uploadTask(with: request, fromFile: file)
    }

    func allTasks() async -> [any UploadTaskHandle] {
        await session.allTasks
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
    }
}
