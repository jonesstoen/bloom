import CryptoKit
import Foundation

/// One upload task as the transport needs it. `URLSessionTask` is one; tests use a fake.
public protocol UploadTaskHandle: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    /// The task's `UploadJob`, encoded (see `BackgroundSessionTransport`). iOS keeps it with the task across
    /// relaunches, so a result delivered to a new process still names its job.
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    /// After a redirect, the request to the new location.
    var currentRequest: URLRequest? { get }
    /// The response, from wherever it finally came (its `url` differs from the original after a redirect).
    var response: URLResponse? { get }
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

public enum BackupTransportError: Error, Equatable, Sendable {
    /// An upload was redirected to another server, which got the request with the API key. Nothing is sent
    /// until `BackgroundSessionTransport.clearRedirectBlock()`.
    case redirectBlocked
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
/// - Background sessions follow redirects on their own and copy the headers (the delegate isn't asked), so
///   a cross-origin redirect is caught after the fact: the result is refused and further uploads are
///   blocked until `clearRedirectBlock()`.
///
/// Create at most one per session identifier per process (iOS allows one session per identifier), and
/// create it before calling `BackupStaging.stageBody` for its account (see `reconcile()`).
public final class BackgroundSessionTransport: BackupTransport, Sendable {
    /// How long a job without a task waits for a late result before it is requeued (see `reconcile()`).
    public static let defaultGrace: Duration = .seconds(30)

    /// Where the session's delegate hands its callbacks. Exposed to tests, which deliver events through it.
    let events: BackgroundSessionEvents
    private let access: SessionAccess
    private let index: BackupIndex
    private let staging: BackupStaging
    private let redirectBlock: RedirectBlock
    private let startup = Signal()

    /// The live transport: a background `URLSession` called `identifier`
    /// (`sessionIdentifier(serverURL:userID:)`). `directory` is the account's backup directory (where the
    /// index lives); the redirect block is kept there.
    public convenience init(
        identifier: String, directory: URL, index: BackupIndex, staging: BackupStaging, recorder: BackupResultRecorder
    ) {
        self.init(directory: directory, index: index, staging: staging, recorder: recorder) { events in
            LiveUploadSession(identifier: identifier, events: events)
        }
    }

    /// `makeSession` gets the event sink and must create the session with it; it is called once, here.
    /// `graceDelay` returns once the grace period for jobs without a task has passed.
    init(
        directory: URL, index: BackupIndex, staging: BackupStaging, recorder: BackupResultRecorder,
        graceDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: BackgroundSessionTransport.defaultGrace) },
        makeSession: (BackgroundSessionEvents) -> any UploadSessionDriving
    ) {
        self.index = index
        self.staging = staging
        redirectBlock = RedirectBlock(directory: directory)
        // The sink first, then the session: events delivered during creation already have a home.
        events = BackgroundSessionEvents(recorder: recorder, redirectBlock: redirectBlock)
        access = SessionAccess(session: makeSession(events))
        // Reconcile is the first thing the transport does. The sink counts it as unfinished work from its
        // creation, so the system completion handler also waits for it.
        Task { [self] in
            await runReconcile(graceDelay: graceDelay)
            startup.fire()
        }
    }

    // MARK: - BackupTransport

    /// Saves the job in the index, then starts a task sending its body file with `request`. Cellular,
    /// expensive (hotspot) and constrained (Low Data Mode) access all follow `request.allowsCellularAccess`,
    /// which the uploader sets from the switch for the asset's media type. Enqueuing an attempt the index
    /// already has does nothing.
    ///
    /// Throws, with nothing sent: `BackupTransportError.redirectBlocked` while a redirect block is set,
    /// `CancellationError` after `invalidate()`, and the save's error when the job can't be saved. When
    /// `cancelAll()` runs while this is under way, the new task is cancelled at once (it then completes as
    /// cancelled like the others); this returns normally then.
    public func enqueue(_ job: UploadJob, request: URLRequest) async throws {
        // Taken first: a `cancelAll` from here on also cancels this upload.
        let generation = access.generation
        await startup.wait()
        try checkSendable()
        guard await !index.jobs.contains(where: { $0.attempt == job.attempt }) else { return }
        guard let body = staging.url(forBodyNamed: job.bodyFileName) else { throw CocoaError(.fileNoSuchFile) }
        let description = try Self.description(of: job)
        await index.addJob(job)
        do {
            try await index.save()
            try checkSendable()
            try access.startTask(
                with: Self.applyingNetworkPolicy(to: request), fromFile: body, description: description,
                since: generation)
        } catch {
            await index.removeJob(attempt: job.attempt)
            try? await index.save()
            throw error
        }
    }

    private func checkSendable() throws {
        if redirectBlock.isSet { throw BackupTransportError.redirectBlocked }
        if access.isInvalidated { throw CancellationError() }
    }

    /// The jobs started and not yet recorded, including those reconcile is still waiting on.
    public func inFlight() async -> [UploadJob] {
        await startup.wait()
        return await index.jobs
    }

    /// Cancels every task of the session, and any enqueue under way. Each one then completes as cancelled:
    /// its item goes back to the queue and its body file is deleted, through the recorder.
    public func cancelAll() async {
        access.advanceGeneration()
        for task in await access.allTasks() { task.cancel() }
    }

    /// Cancels the tasks of these attempts only (a cellular switch turned off, say).
    public func cancel(attempts: Set<UUID>) async {
        guard !attempts.isEmpty else { return }
        for task in await access.allTasks() {
            if let job = Self.job(in: task.taskDescription), attempts.contains(job.attempt) { task.cancel() }
        }
    }

    /// Cancels everything and invalidates the session (sign-out). Every later `enqueue` throws
    /// `CancellationError`, and a redirect seen afterwards is no longer written to disk (the account's
    /// directory is about to be removed and must not be recreated).
    public func invalidate() {
        redirectBlock.close()
        access.invalidate()
        events.clearProgress()
        events.releaseHandlers()
    }

    // MARK: - Redirects

    /// An upload was redirected to another server (scheme, host or port), which received the API key.
    /// Kept on disk; while set, `enqueue` throws `BackupTransportError.redirectBlocked`.
    public var isRedirectBlocked: Bool { redirectBlock.isSet }

    /// The bytes sent of each task that reported any (`urlSession(_:task:didSendBodyData:…)`), by attempt.
    public func uploadProgress() -> [UUID: UploadBytes] { events.progress() }

    /// Lifts the redirect block. Only the user's Try Again on the Backup screen calls it.
    public func clearRedirectBlock() {
        redirectBlock.clear()
    }

    // MARK: - Relaunch

    /// Stores the completion handler iOS passes to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` for this session. It is called
    /// on the main thread once iOS has delivered the session's events (`urlSessionDidFinishEvents`) and every
    /// result is saved; also when the events came before the handler was stored.
    public func handleEvents(completion: @escaping () -> Void) {
        events.store(completion)
    }

    /// Brings the index in line with the tasks iOS still has, in two phases. The first runs once, when the
    /// transport starts; calling this waits for it.
    ///
    /// 1. Every file in the staging folder that no index job and no task iOS reports refers to is removed
    ///    (`BackupStaging.removeUnreferenced`), unless the index couldn't be read. A task iOS reports keeps its
    ///    body file whether or not the index still has its job. Index jobs without a task are only
    ///    remembered: iOS may still deliver their results (a task that finished while Bloom wasn't running
    ///    isn't always listed), so they stay, with their bodies, and `inFlight()` reports them.
    /// 2. Once iOS says it has delivered everything (`urlSessionDidFinishEvents`) or the grace period has
    ///    passed, whichever comes first, each of those jobs whose result didn't arrive is requeued: recorded
    ///    as cancelled, so the item goes back to `pending(.needsUpload)`, the job is removed and, after the
    ///    save, its body deleted. The uploader stages and sends it again (the server's checksum dedupe makes
    ///    that safe). It isn't re-sent from the old body: the request (headers, boundary) isn't stored and
    ///    can't be rebuilt here, and a fresh staging also re-checks the bytes against the checksum.
    ///
    /// Because of the cleanup, nothing may stage a body for this account until the first phase has finished:
    /// await this (or `inFlight()`) before the first `BackupStaging.stageBody`. It also tells staging which
    /// bodies are still waiting for their upload, which its budget relies on after a relaunch.
    public func reconcile() async {
        await startup.wait()
    }

    /// Callers waiting for the first phase of reconcile (tests check that an enqueue does).
    var waitingForStartup: Int { startup.waiterCount }

    private func runReconcile(graceDelay: @escaping @Sendable () async -> Void) async {
        var liveAttempts: Set<UUID> = []
        var keptNames: Set<String> = []
        for task in await access.allTasks() {
            guard let job = Self.job(in: task.taskDescription) else { continue }
            liveAttempts.insert(job.attempt)
            keptNames.insert(job.bodyFileName)
        }
        // The index first, then the records in progress: a job a record has just taken out of the index is
        // then still among the records in progress.
        let jobs = await index.jobs
        let events = events
        let suspects = jobs.filter { !liveAttempts.contains($0.attempt) && !events.wasDelivered($0.attempt) }
        keptNames.formUnion(jobs.map(\.bodyFileName))
        keptNames.formUnion(events.bodiesBeingRecorded())
        // An index that couldn't be read has no jobs in memory: every body would look unreferenced.
        if await index.isAvailable {
            await staging.removeUnreferenced(keeping: Set(keptNames.compactMap { staging.url(forBodyNamed: $0) }))
        }
        events.finishStartup(suspects: suspects)
        guard !suspects.isEmpty else { return }
        Task {
            await graceDelay()
            events.graceElapsed()
        }
    }

    // MARK: - Helpers

    /// The background session's identifier for one account: stable, different per server and user, and
    /// holding nothing readable (a short SHA-256 of the server URL and user ID). The URL is normalised (scheme
    /// and host lowercased, a default port, user info and trailing slashes dropped), but pass the same one
    /// each time all the same: the signed-in account's canonical server URL from its credentials.
    public static func sessionIdentifier(serverURL: URL, userID: String) -> String {
        var server = serverURL.absoluteString
        if var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            let scheme = components.scheme?.lowercased()
            let host = components.host?.lowercased()
            components.scheme = scheme
            components.host = host
            if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
                components.port = nil
            }
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            components.path = path
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

    static func description(of job: UploadJob) throws -> String {
        String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
    }

    static func job(in description: String?) -> UploadJob? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(UploadJob.self, from: Data(description.utf8))
    }
}

/// The session, behind a lock with what decides whether a task may still start: `uploadTask` on an
/// invalidated `URLSession` raises an exception, and a `cancelAll` must also stop an enqueue under way.
private final class SessionAccess: @unchecked Sendable {
    private let session: any UploadSessionDriving
    private let lock = NSLock()
    private var invalidated = false
    private var cancelGeneration = 0

    init(session: any UploadSessionDriving) {
        self.session = session
    }

    var generation: Int { lock.withLock { cancelGeneration } }
    var isInvalidated: Bool { lock.withLock { invalidated } }

    func advanceGeneration() {
        lock.withLock { cancelGeneration += 1 }
    }

    /// Creates the task and resumes it, or cancels it at once when `cancelAll` ran since `generation`.
    func startTask(with request: URLRequest, fromFile file: URL, description: String, since generation: Int) throws {
        try lock.withLock {
            guard !invalidated else { throw CancellationError() }
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = description
            if cancelGeneration == generation { task.resume() } else { task.cancel() }
        }
    }

    func allTasks() async -> [any UploadTaskHandle] {
        guard !isInvalidated else { return [] }
        return await session.allTasks()
    }

    func invalidate() {
        lock.withLock {
            guard !invalidated else { return }
            invalidated = true
            session.invalidateAndCancel()
        }
    }
}

/// Whether a redirect to another server was seen, kept as a file in the account's backup directory so it
/// survives relaunch. Only the file's existence counts, so it reads the same while the phone is locked.
final class RedirectBlock: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var blocked: Bool
    /// After sign-out: `set()` keeps the block in memory only.
    private var closed = false

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("redirect-blocked", isDirectory: false)
        blocked = FileManager.default.fileExists(atPath: fileURL.path)
    }

    var isSet: Bool { lock.withLock { blocked } }

    func set() {
        lock.withLock {
            blocked = true
            guard !closed else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            // In memory it holds for this process even if the write fails.
            try? Data().write(to: fileURL, options: options)
        }
    }

    /// Nothing is written or removed on disk from now on.
    func close() {
        lock.withLock { closed = true }
    }

    func clear() {
        lock.withLock {
            blocked = false
            guard !closed else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// Fires once; `wait()` returns once it has.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callers waiting right now.
    var waiterCount: Int { lock.withLock { waiters.count } }

    func fire() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fired = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Receives the background session's delegate callbacks (on the session's delegate queue, synchronously)
/// and turns each completion into one `BackupResultRecorder.record`. Its bookkeeping is under a lock and
/// done synchronously in the callback, so the order of callbacks is kept: a task's data before its
/// completion, every completion before "finished events". The records themselves run in tasks.
final class BackgroundSessionEvents: @unchecked Sendable {
    private struct Handler: @unchecked Sendable {
        let call: () -> Void
    }

    /// The second phase of reconcile (see `BackgroundSessionTransport.reconcile()`).
    private enum Requeue {
        /// The first phase hasn't finished.
        case notReady
        /// Jobs without a task are waiting for a late result.
        case waiting
        case running
        case done
    }

    private enum Step {
        case none
        case requeue
        case release([Handler])
    }

    private struct State {
        /// Response bodies so far, by task identifier (an upload's answer is a few bytes of JSON).
        var responses: [Int: Data] = [:]
        /// Work the completion handler waits for: records in progress, the startup reconcile (counted from
        /// the start, see `init`) and the requeue of jobs without a task.
        var pendingWork = 1
        /// iOS has delivered everything for now (`urlSessionDidFinishEvents`) and no handler took it yet.
        /// A later completion starts a new batch and clears it.
        var eventsFinished = false
        var handlers: [Handler] = []
        /// Attempts whose completion this process received; reconcile leaves their jobs to the recorder.
        var delivered: Set<UUID> = []
        /// Body file names of records in progress, by attempt.
        var recording: [UUID: String] = [:]
        var requeue = Requeue.notReady
        /// Index jobs without a task at startup.
        var suspects: [UploadJob] = []
        /// Bytes sent of tasks in flight, by attempt; removed when the task completes.
        var progress: [UUID: UploadBytes] = [:]
    }

    private let recorder: BackupResultRecorder
    private let redirectBlock: RedirectBlock
    private let lock = NSLock()
    private var state = State()
    private let requeueDone = Signal()

    init(recorder: BackupResultRecorder, redirectBlock: RedirectBlock) {
        self.recorder = recorder
        self.redirectBlock = redirectBlock
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

    /// iOS reports how much of a task's body it sent. Only the latest report is kept; a task whose job
    /// can't be read is ignored.
    func didSendBodyData(for task: any UploadTaskHandle, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let job = BackgroundSessionTransport.job(in: task.taskDescription) else { return }
        let bytes = UploadBytes(sent: totalBytesSent, expected: totalBytesExpectedToSend)
        lock.withLock { state.progress[job.attempt] = bytes }
    }

    /// Forgets every task's progress (the session is invalidated: none of them reports again).
    func clearProgress() {
        lock.withLock { state.progress = [:] }
    }

    /// The latest bytes sent of each task in flight, by attempt.
    func progress() -> [UUID: UploadBytes] {
        lock.withLock { state.progress }
    }

    /// `status` is the HTTP status of the task's response, `nil` without one.
    func didComplete(_ task: any UploadTaskHandle, status: Int?, error: Error?) {
        let job = BackgroundSessionTransport.job(in: task.taskDescription)
        // Background sessions follow redirects without asking the delegate. If this one ended up elsewhere,
        // that server had the key: block further uploads before anything else, and don't trust the answer.
        let redirected = Self.leftItsOrigin(task)
        if redirected { redirectBlock.set() }
        let data = lock.withLock {
            state.pendingWork += 1
            state.eventsFinished = false
            if let job {
                state.progress[job.attempt] = nil
                state.delivered.insert(job.attempt)
                state.recording[job.attempt] = job.bodyFileName
            }
            return state.responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        }
        let outcome = redirected
            ? UploadOutcome.failed(.service(.insecureConnection)) : Self.outcome(status: status, data: data, error: error)
        let recorder = recorder
        Task {
            // A task without a readable job can't be recorded; its body is removed by the next cleanup.
            if let job { await recorder.record(job, outcome) }
            self.settle {
                $0.pendingWork -= 1
                if let attempt = job?.attempt { $0.recording[attempt] = nil }
            }
        }
    }

    func didFinishEvents() {
        settle { $0.eventsFinished = true }
    }

    /// The redirect to follow, `nil` to refuse it: only to the same scheme, host and port, because the
    /// request carries the API key (`SameOriginRedirects`). Background sessions don't ask (see
    /// `didComplete`); kept for a session that does.
    func redirect(for task: any UploadTaskHandle, response: HTTPURLResponse, to request: URLRequest) -> URLRequest? {
        SameOriginRedirects.allows(from: task.originalRequest?.url ?? response.url, to: request.url) ? request : nil
    }

    func store(_ completion: @escaping () -> Void) {
        settle { $0.handlers.append(Handler(call: completion)) }
    }

    /// The session is ending (sign-out): calls the stored handlers on the main thread instead of dropping them,
    /// so iOS isn't left waiting for the app to finish handling the events. Each is called once.
    func releaseHandlers() {
        let handlers = lock.withLock { () -> [Handler] in
            defer { state.handlers = [] }
            return state.handlers
        }
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler.call() }
        }
    }

    /// The first phase of reconcile has finished; `suspects` wait for the second.
    func finishStartup(suspects: [UploadJob]) {
        if suspects.isEmpty { requeueDone.fire() }
        settle {
            $0.pendingWork -= 1
            $0.suspects = suspects
            $0.requeue = suspects.isEmpty ? .done : .waiting
        }
    }

    /// The grace period for jobs without a task has passed.
    func graceElapsed() {
        let start = lock.withLock { () -> Bool in
            guard state.requeue == .waiting else { return false }
            state.requeue = .running
            state.pendingWork += 1
            return true
        }
        if start { requeueSuspects() }
    }

    /// Returns once the jobs without a task are requeued or turned out delivered (tests).
    func waitForRequeue() async {
        await requeueDone.wait()
    }

    /// Whether a record, reconcile or requeue is still under way (tests).
    var hasPendingWork: Bool { lock.withLock { state.pendingWork > 0 } }

    func wasDelivered(_ attempt: UUID) -> Bool {
        lock.withLock { state.delivered.contains(attempt) }
    }

    func bodiesBeingRecorded() -> Set<String> {
        lock.withLock { Set(state.recording.values) }
    }

    /// Applies `change`, then does what has become due: requeue the jobs without a task once everything is
    /// delivered, then call the stored handlers.
    private func settle(_ change: (inout State) -> Void) {
        let step = lock.withLock { () -> Step in
            change(&state)
            guard state.pendingWork == 0, state.eventsFinished else { return .none }
            if state.requeue == .waiting {
                state.requeue = .running
                state.pendingWork += 1
                return .requeue
            }
            guard !state.handlers.isEmpty else { return .none }
            state.eventsFinished = false
            defer { state.handlers = [] }
            return .release(state.handlers)
        }
        switch step {
        case .none:
            break
        case .requeue:
            requeueSuspects()
        case let .release(handlers):
            DispatchQueue.main.async {
                for handler in handlers { handler.call() }
            }
        }
    }

    private func requeueSuspects() {
        let suspects = lock.withLock { state.suspects }
        let recorder = recorder
        Task {
            for job in suspects where !self.wasDelivered(job.attempt) {
                await recorder.record(job, .failed(.cancelled))
            }
            self.settle {
                $0.requeue = .done
                $0.suspects = []
                $0.pendingWork -= 1
            }
            self.requeueDone.fire()
        }
    }

    /// Whether the task's response (or, without one, its current request) is on another server than the
    /// request it started with.
    static func leftItsOrigin(_ task: any UploadTaskHandle) -> Bool {
        guard let origin = task.originalRequest?.url,
              let final = task.response?.url ?? task.currentRequest?.url else { return false }
        return !SameOriginRedirects.allows(from: origin, to: final)
    }

    static func outcome(status: Int?, data: Data, error: Error?) -> UploadOutcome {
        if let error {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else {
                // As Phase 2's error mapping: anything that isn't a URL error is an unusable answer, retried.
                return .failed(.service(.invalidResponse))
            }
            return .failed(UploadFailure(URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo)))
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        events.didSendBodyData(for: task, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        events.didComplete(task, status: (task.response as? HTTPURLResponse)?.statusCode, error: error)
    }

    /// Not called for background sessions (they follow redirects themselves); `didComplete` checks instead.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(events.redirect(for: task, response: response, to: request))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.didFinishEvents()
    }
}

extension BackgroundSessionTransport {
    /// The account's background session configuration (internal so a test can check it).
    static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
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
        // A few uploads at a time per server (the default is 6 on iOS): the rest waits in the system's queue.
        configuration.httpMaximumConnectionsPerHost = 3
        return configuration
    }
}

/// A background `URLSession` for uploads. Not exercised by unit tests (they use a fake session).
private final class LiveUploadSession: UploadSessionDriving {
    private let session: URLSession

    init(identifier: String, events: BackgroundSessionEvents) {
        let configuration = BackgroundSessionTransport.backgroundConfiguration(identifier: identifier)
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
