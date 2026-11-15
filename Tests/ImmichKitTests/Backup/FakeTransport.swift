import Foundation
@testable import ImmichKit

/// A transport for tests that plays the part of iOS and the server: each job's body is parsed back into the
/// `AssetUploadRequest` it carries and sent with `service.uploadAsset`, and the outcome goes through the
/// recorder, as `BackgroundSessionTransport` does.
///
/// - `.immediate`: the upload happens inside `enqueue`, in a task of its own (cancelling the caller doesn't
///   cancel it; `cancelAll()` does), so results arrive in the order items were sent.
/// - `.manual`: jobs wait until the test finishes them (`complete`, `finish`), as uploads that take a while.
final class FakeTransport: BackupTransport, @unchecked Sendable {
    enum Mode { case immediate, manual }

    /// One enqueued job with what its body and request said.
    struct Sent: Sendable {
        let job: UploadJob
        let request: URLRequest
        /// The form fields of the body (`visibility`, `livePhotoVideoId`, `filename`, …).
        let fields: [String: String]
        let upload: AssetUploadRequest
        /// `needsLink` of the item as saved in the index file when the job was enqueued.
        let savedNeedsLink: Bool?
    }

    private let index: BackupIndex
    private let staging: BackupStaging
    private let recorder: BackupResultRecorder
    private let service: any ImmichService
    private let directory: URL?
    private let mode: Mode
    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var _cancelAllCount = 0
    private var _maxInFlight = 0
    private var _blocked = false
    private var _clearCount = 0
    private var running: [UUID: Task<Void, Never>] = [:]
    private let cancelGate = CancelGate()
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// `directory` is the index's, to read what was saved at enqueue time.
    init(index: BackupIndex, staging: BackupStaging, recorder: BackupResultRecorder, service: any ImmichService,
         directory: URL? = nil, mode: Mode = .immediate) {
        self.index = index
        self.staging = staging
        self.recorder = recorder
        self.service = service
        self.directory = directory
        self.mode = mode
    }

    var sent: [Sent] { lock.withLock { _sent } }
    var cancelAllCount: Int { lock.withLock { _cancelAllCount } }
    /// The most jobs in flight at once, the new one included.
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var clearCount: Int { lock.withLock { _clearCount } }

    /// Returns once `count` jobs (in total) have been enqueued.
    func waitForEnqueued(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let reached = lock.withLock { () -> Bool in
                if _sent.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func setRedirectBlocked(_ blocked: Bool) { lock.withLock { _blocked = blocked } }

    // MARK: BackupTransport

    func enqueue(_ job: UploadJob, request: URLRequest) async throws {
        if isRedirectBlocked { throw BackupTransportError.redirectBlocked }
        guard await !index.jobs.contains(where: { $0.attempt == job.attempt }) else { return }
        guard let body = staging.url(forBodyNamed: job.bodyFileName) else { throw CocoaError(.fileNoSuchFile) }
        let (fields, upload) = try Self.parse(body: body, request: request)
        await index.addJob(job)
        try await index.save()
        let inFlight = await index.jobs.count
        var savedNeedsLink: Bool?
        if let directory { savedNeedsLink = await BackupIndex(directory: directory).entry(for: job.assetID)?.needsLink }
        let sent = Sent(job: job, request: request, fields: fields, upload: upload, savedNeedsLink: savedNeedsLink)
        let reached = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _sent.append(sent)
            _maxInFlight = max(_maxInFlight, inFlight)
            let reached = waiters.filter { $0.count <= _sent.count }
            waiters.removeAll { $0.count <= _sent.count }
            return reached.map(\.continuation)
        }
        for continuation in reached { continuation.resume() }
        if mode == .immediate { await start(sent).value }
    }

    /// What the real transport does when it starts up (and `inFlight()` waits for): the staging files no job
    /// refers to are removed. Here on every call, which the tests make only while nothing is being staged.
    func inFlight() async -> [UploadJob] {
        let jobs = await index.jobs
        await staging.removeUnreferenced(keeping: Set(jobs.compactMap { staging.url(forBodyNamed: $0.bodyFileName) }))
        return jobs
    }

    /// Makes `cancelAll()` wait, once it has begun, until `releaseCancelAll()`: a cancel that takes a while.
    func holdCancelAll() async { await cancelGate.hold() }
    func releaseCancelAll() async { await cancelGate.release() }
    /// Returns once a `cancelAll()` has begun (and is waiting, if held).
    func waitForCancelAllStarted() async { await cancelGate.waitUntilEntered() }

    /// Cancels the uploads under way; jobs not started are recorded as cancelled.
    func cancelAll() async {
        await cancelGate.pass()
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            _cancelAllCount += 1
            return Array(running.values)
        }
        for task in tasks { task.cancel() }
        let started = Set(lock.withLock { running.keys })
        for job in await index.jobs where !started.contains(job.attempt) {
            await recorder.record(job, .failed(.cancelled))
        }
    }

    /// The attempts passed to `cancel(attempts:)`, in order.
    private var _cancelledAttempts: [Set<UUID>] = []
    var cancelledAttempts: [Set<UUID>] { lock.withLock { _cancelledAttempts } }

    func cancel(attempts: Set<UUID>) async {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            _cancelledAttempts.append(attempts)
            return running.filter { attempts.contains($0.key) }.map(\.value)
        }
        for task in tasks { task.cancel() }
        let started = Set(lock.withLock { running.keys })
        for job in await index.jobs where attempts.contains(job.attempt) && !started.contains(job.attempt) {
            await recorder.record(job, .failed(.cancelled))
        }
    }

    var isRedirectBlocked: Bool { lock.withLock { _blocked } }

    private var _progress: [UUID: UploadBytes] = [:]
    /// What `uploadProgress()` reports, as a test sets it.
    func setProgress(_ progress: [UUID: UploadBytes]) { lock.withLock { _progress = progress } }
    func uploadProgress() -> [UUID: UploadBytes] { lock.withLock { _progress } }

    func clearRedirectBlock() {
        lock.withLock {
            _blocked = false
            _clearCount += 1
        }
    }

    // MARK: Finishing jobs (`.manual`)

    /// Sends the jobs that match `isIncluded` and are still in flight, in the order they were enqueued,
    /// and records each outcome.
    func complete(where isIncluded: (UploadJob) -> Bool = { _ in true }) async {
        let open = Set(await index.jobs.map(\.attempt))
        for sent in sent where open.contains(sent.job.attempt) && isIncluded(sent.job) {
            await start(sent).value
        }
    }

    /// Records `outcome` for the in-flight jobs that match, without the server.
    func finish(where isIncluded: (UploadJob) -> Bool, with outcome: UploadOutcome) async {
        for job in await index.jobs where isIncluded(job) {
            await recorder.record(job, outcome)
        }
    }

    // MARK: Helpers

    private func start(_ sent: Sent) -> Task<Void, Never> {
        let service = service
        let recorder = recorder
        let task = Task {
            let outcome: UploadOutcome
            do {
                outcome = .uploaded(try await service.uploadAsset(sent.upload))
            } catch {
                outcome = .failed(Task.isCancelled ? .cancelled : UploadFailure(error))
            }
            await recorder.record(sent.job, outcome)
        }
        lock.withLock { running[sent.job.attempt] = task }
        let attempt = sent.job.attempt
        return Task {
            await task.value
            _ = self.lock.withLock { self.running.removeValue(forKey: attempt) }
        }
    }

    /// The form fields and the request the body file and request header describe.
    static func parse(body: URL, request: URLRequest) throws -> ([String: String], AssetUploadRequest) {
        let data = try Data(contentsOf: body)
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let boundary = contentType.components(separatedBy: "boundary=").last, !boundary.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let separator = Data("--\(boundary)\r\n".utf8)
        var fields: [String: String] = [:]
        var mimeType = ""
        var position = data.startIndex
        while let start = data.range(of: separator, in: position..<data.endIndex) {
            let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: start.upperBound..<data.endIndex)!
            let headers = String(decoding: data[start.upperBound..<headerEnd.lowerBound], as: UTF8.self)
            let name = headers.components(separatedBy: "name=\"")[1].components(separatedBy: "\"")[0]
            if name == "assetData" {
                mimeType = headers.components(separatedBy: "Content-Type: ").last ?? ""
                break
            }
            let valueEnd = data.range(of: Data("\r\n".utf8), in: headerEnd.upperBound..<data.endIndex)!
            fields[name] = String(decoding: data[headerEnd.upperBound..<valueEnd.lowerBound], as: UTF8.self)
            position = valueEnd.upperBound
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ name: String) -> Date { fields[name].flatMap { dates.date(from: $0) } ?? .distantPast }
        let upload = AssetUploadRequest(
            fileURL: body, filename: fields["filename"] ?? "", mimeType: mimeType,
            checksum: request.value(forHTTPHeaderField: "x-immich-checksum") ?? "",
            createdAt: date("fileCreatedAt"), modifiedAt: date("fileModifiedAt"),
            isFavorite: fields["isFavorite"] == "true", duration: fields["duration"].flatMap(Double.init).map { $0 / 1000 },
            livePhotoVideoID: fields["livePhotoVideoId"], allowsCellular: request.allowsCellularAccess)
        return (fields, upload)
    }
}

extension BackupUploadRequests {
    /// An https server, so the key may be sent.
    static var test: BackupUploadRequests {
        BackupUploadRequests(credentials: try! ServerCredentials(server: "https://immich.example.com", apiKey: "test-key"))
    }
}

/// Holds `cancelAll()` of the fake transport at the start until released.
private actor CancelGate {
    private var held = false
    private var entered = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() { held = true }

    func release() {
        held = false
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    func pass() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if held { await withCheckedContinuation { waiting.append($0) } }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
}
