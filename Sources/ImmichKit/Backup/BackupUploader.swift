import Foundation
import UniformTypeIdentifiers

/// How far an upload run has come: `done` of `total` items handled, and the file being uploaded now.
public struct UploadProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var currentFilename: String?

    public init(done: Int, total: Int, currentFilename: String?) {
        self.done = done
        self.total = total
        self.currentFilename = currentFilename
    }
}

/// The time source for the uploader's back-off, injectable so tests don't wait.
public struct BackupRetryClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Wall-clock time, for the retry times kept in the index (`BackupEntry.retry`).
    public var date: @Sendable () -> Date

    /// `date` follows `now` from the moment the clock is made.
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        let startDate = Date()
        let startInstant = now()
        self.init(now: now, sleep: sleep, date: {
            startDate.addingTimeInterval(BackupUploader.seconds(startInstant.duration(to: now())))
        })
    }

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant, sleep: @escaping @Sendable (Duration) async throws -> Void,
        date: @escaping @Sendable () -> Date
    ) {
        self.now = now
        self.sleep = sleep
        self.date = date
    }

    public static var live: BackupRetryClock {
        BackupRetryClock(now: { .now }, sleep: { try await Task.sleep(for: $0) }, date: { Date() })
    }
}

/// Builds the `POST /assets` request for a staged upload body, without the body: the account's server and
/// the API key, which goes in the `x-api-key` header only.
public struct BackupUploadRequests: Sendable {
    private let credentials: ServerCredentials

    public init(credentials: ServerCredentials) {
        self.credentials = credentials
    }

    /// Throws `ImmichServiceError.insecureConnection` when the server's address would expose the key (plain
    /// http outside the user's own network).
    func request(checksum: String, boundary: String, allowsCellular: Bool) throws -> URLRequest {
        guard credentials.protectsAPIKey else { throw ImmichServiceError.insecureConnection }
        var request = URLRequest(url: credentials.apiBaseURL.appendingPathComponent("assets", isDirectory: false))
        request.httpMethod = "POST"
        request.allowsCellularAccess = allowsCellular
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        request.setValue(credentials.apiKey, forHTTPHeaderField: APIKeyMiddleware.headerName.canonicalName)
        return request
    }
}

/// Where the uploader's bodies go: the account's transport, the recorder its results go through, and how
/// to build each request.
public struct BackupUploadConnection: Sendable {
    public let transport: any BackupTransport
    public let recorder: BackupResultRecorder
    public let requests: BackupUploadRequests

    public init(transport: any BackupTransport, recorder: BackupResultRecorder, requests: BackupUploadRequests) {
        self.transport = transport
        self.recorder = recorder
        self.requests = requests
    }
}

/// How an upload run goes: with the app open it waits for its results (and retries within the run); a
/// background task enqueues what it may and returns, leaving the results to the session's delegate wakes.
public struct BackupRunOptions: Sendable, Equatable {
    /// Returns once every item has its result (`true`), or as soon as nothing more can be enqueued right now.
    public var waitsForResults: Bool
    /// Upload jobs on the transport at once.
    public var maxInFlight: Int
    /// The background refresh: only items `BackupRefreshPolicy` allows, staged without iCloud downloads; an
    /// item only in iCloud is left as it is.
    public var smallLocalOnly: Bool

    public init(waitsForResults: Bool, maxInFlight: Int, smallLocalOnly: Bool) {
        self.waitsForResults = waitsForResults
        self.maxInFlight = max(1, maxInFlight)
        self.smallLocalOnly = smallLocalOnly
    }

    /// The app is open: a few uploads at a time, results waited for.
    public static let foreground = BackupRunOptions(
        waitsForResults: true, maxInFlight: BackupUploader.maxInFlight, smallLocalOnly: false)
    /// The nightly processing task (on power): enqueues as much as the staging budget allows and returns. The
    /// staging budget (2 GB of bodies) is the real limit; the job cap only keeps a backlog of small photos from
    /// handing the session thousands of tasks in one go.
    public static let processing = BackupRunOptions(waitsForResults: false, maxInFlight: 64, smallLocalOnly: false)
    /// The short refresh task: a few small, already-local photos, enqueued, and return.
    public static let refresh = BackupRunOptions(waitsForResults: false, maxInFlight: 6, smallLocalOnly: true)
}

/// Hands the selected items the server doesn't have to the transport, newest first, and links Live Photos.
///
/// Each item is re-read from the photo library and staged resource by resource, straight into its upload
/// body; an item that changed since the scanner hashed it goes back to the scanner instead of being
/// uploaded under a stale checksum. The bodies are enqueued on the transport (at most `maxInFlight` jobs at
/// a time, within the staging budget) and the results come back through `BackupResultRecorder`, also when
/// the app was suspended or relaunched meanwhile. A Live Photo's motion video is sent hidden
/// (`visibility=hidden`) together with the photo, and the two are linked once both are on the server.
///
/// Network trouble, 408, 429 and 5xx keep the item pending and retry it after 5 s, 30 s, 2 min and 10 min,
/// after which it is given up on for `givenUpPause`. That bookkeeping is kept in the index
/// (`BackupEntry.retry`), so a relaunch doesn't send a failing item again at once. Never changes the photo
/// library; restores from the server's trash only on `reupload`.
public actor BackupUploader {
    /// Waits after the first, second, third and fourth failure; the fifth gives the item up for a while.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)]
    /// How long an item that failed `retryDelays.count + 1` times in a row is left alone (Phase 2 left it for
    /// the rest of the session; a session is now any launch, in the background too).
    static let givenUpPause: TimeInterval = 3600
    /// Assets per PhotoKit fetch when ordering the queue.
    static let fetchSize = 500
    /// A wait for a retry is split up so a pause request is noticed.
    static let waitSlice: Duration = .seconds(2)
    /// Upload jobs on the transport at once.
    static let maxInFlight = 3
    /// A passed check that the server answers at its own address covers the enqueues of this long.
    static let preflightInterval: TimeInterval = 60
    /// The longest an item is held back from its last failure. A retry time further ahead than this was
    /// written by a clock that has since been moved back, and is cut to it (`clampRetryTimes`).
    static var longestPause: TimeInterval { max(seconds(retryDelays.max() ?? .zero), givenUpPause) }

    private let source: any PhotoLibrarySource
    private let service: any ImmichService
    private let index: BackupIndex
    private let staging: BackupStaging
    private let settings: @Sendable () -> BackupSettings
    private let network: any NetworkConditions
    private let clock: BackupRetryClock
    private let connection: BackupUploadConnection?
    /// Wakes a run waiting for a result; carries an error recorded for an upload that no item can get past.
    private let signal = UploaderSignal()

    private var isRunning = false
    private var isReuploading = false
    /// When the server last answered at its own address (`preflight`).
    private var lastPreflight: Date?

    /// `settings` is read for each item: the cellular switches can change during a run. Without a
    /// `connection` nothing is sent (scans and links still work).
    public init(
        source: any PhotoLibrarySource,
        service: any ImmichService,
        index: BackupIndex,
        staging: BackupStaging,
        settings: @escaping @Sendable () -> BackupSettings,
        network: any NetworkConditions,
        clock: BackupRetryClock = .live,
        connection: BackupUploadConnection? = nil
    ) {
        self.source = source
        self.service = service
        self.index = index
        self.staging = staging
        self.settings = settings
        self.network = network
        self.clock = clock
        self.connection = connection
        connection?.recorder.observe { [weak self] _, outcome in self?.recorded(outcome) }
    }

    private struct Candidate {
        let id: String
        let creationDate: Date
        let filename: String
        /// The resources it uploads: the most jobs it can start at once.
        let resourceCount: Int
    }

    /// What one attempt at an item came to.
    private enum Attempt: Equatable {
        /// Nothing more to do for it in this run.
        case finished
        /// Something was sent (or its entry changed): its entry says what comes next.
        case started
        /// The staging budget is full: nothing is staged until the bodies in flight are recorded.
        case overBudget
    }

    /// Where a queued item stands, from its entry.
    private enum Status {
        case finished
        case ready
        case waiting(until: Date, holdsRun: Bool)
    }

    // MARK: - Run

    /// Uploads the current selection's items that need it (`pending(.needsUpload)`, and items the uploader
    /// itself left waiting for Wi-Fi), newest `creationDate` first: stages each item's missing resources and
    /// enqueues them on the transport without waiting for one to finish before staging the next, up to
    /// `maxInFlight` jobs. When the staging budget is full, nothing new is staged until the bodies in flight
    /// are recorded, and the item that didn't fit goes next (a large video isn't passed over for smaller ones).
    ///
    /// Returns once every item in the queue has its result, has been given up on for now or needs the
    /// scanner, so failures are retried within the run as before. On cellular, uploads the system holds for
    /// Wi-Fi (a media type whose cellular switch is off) take no in-flight slot and aren't waited for; their
    /// bodies still count against the staging budget, and an item that doesn't fit because of them is left
    /// for the next run. `progress` reports items handed over and
    /// finished; `shouldPause` is asked before each item and while the run waits. When it answers `true` the
    /// run returns; uploads already enqueued go on (they belong to the system). A wait for results only
    /// notices a pause at `wake()`.
    ///
    /// Before it stages anything the transport has finished starting up (`BackupTransport.inFlight()`), and
    /// before it enqueues it checks that the server answers at its own address (`preflight`).
    ///
    /// `options` (default `.foreground`, as described above): a background run (`waitsForResults == false`)
    /// stages and enqueues up to its own in-flight limit and the staging budget, then returns without
    /// waiting for any result, back-off or room in the budget.
    ///
    /// Throws `ImmichServiceError.unauthorized` (and other errors no item can get past, also when an upload's
    /// result says so), `BackupStagingError.notEnoughSpace` after failing the item, and
    /// `BackupTransportError.redirectBlocked`; cancellation removes the body being staged and rethrows. The
    /// index is saved after each item. A second call while a run (or a `reupload`) is going returns at once.
    public func run(
        options: BackupRunOptions = .foreground,
        progress: @escaping @Sendable (UploadProgress) -> Void,
        shouldPause: @escaping @Sendable () async -> Bool
    ) async throws {
        guard !isRunning, !isReuploading else { return }
        isRunning = true
        defer { isRunning = false }
        // Fails fast on an unavailable index, before anything is uploaded that couldn't be recorded.
        try await index.saveIfChanged()
        guard let connection else {
            progress(UploadProgress(done: 0, total: 0, currentFilename: nil))
            return
        }
        let transport = connection.transport
        signal.reset()
        // Starting the transport cleans up the staging folder: nothing may be staged before that.
        _ = await transport.inFlight()
        await clampRetryTimes()

        let (candidates, waits) = try await queuedItems(smallLocalOnly: options.smallLocalOnly)
        var queue = candidates
        var queued = Set(queue.map(\.id))
        let total = queue.count
        var done = 0
        var notBefore: [String: Date] = [:]
        var holdUntil: Date?
        for (id, wait) in waits {
            notBefore[id] = wait.until
            if wait.holdsRun { holdUntil = max(holdUntil ?? wait.until, wait.until) }
        }
        /// Items whose entry may have changed since they were last looked at (sent, or a result pending).
        var watching: Set<String> = []
        /// After `overBudget`: nothing is staged until every body in flight is recorded.
        var draining = false
        func report(_ filename: String?) {
            progress(UploadProgress(done: done, total: total, currentFilename: filename))
        }

        while true {
            try Task.checkCancellation()
            if let error = signal.takeStop() { throw await stopping(error, transport) }
            let jobs = await transport.inFlight()
            let busy = Set(jobs.map(\.assetID))
            // On cellular the system holds the uploads of a media type that may only go on Wi-Fi: they take no
            // slot here, and nothing waits for them (their bodies still count against the staging budget).
            let parked = await parkedAssets(jobs)
            let active = jobs.filter { !parked.contains($0.assetID) }
            let settled = watching.subtracting(busy)
            if !settled.isEmpty {
                let before = done
                let now = clock.date()
                for id in settled {
                    watching.remove(id)
                    switch await status(of: id, now: now) {
                    case .finished:
                        queue.removeAll { $0.id == id }
                        queued.remove(id)
                        done += 1
                    case .ready:
                        notBefore[id] = nil
                    case let .waiting(until, holdsRun):
                        notBefore[id] = until
                        if holdsRun { holdUntil = max(holdUntil ?? until, until) }
                    }
                }
                if done != before { report(nil) }
            }
            // Results of items sent before this run (or by another one) are waited for too.
            watching.formUnion(busy.intersection(queued))
            if queue.isEmpty { break }
            if await shouldPause() { return }
            if draining, active.isEmpty { draining = false }

            let now = clock.date()
            let held = holdUntil.map { $0 > now } ?? false
            if !draining, !held,
               let position = queue.firstIndex(where: { !busy.contains($0.id) && (notBefore[$0.id] ?? .distantPast) <= now }) {
                let item = queue[position]
                // In order: a Live Photo that doesn't fit waits for room rather than letting the next one go.
                if active.isEmpty || active.count + item.resourceCount <= options.maxInFlight {
                    if let error = signal.takeStop() { throw await stopping(error, transport) }
                    report(item.filename)
                    switch try await attempt(item.id, connection: connection, smallLocalOnly: options.smallLocalOnly) {
                    case .finished:
                        queue.remove(at: position)
                        queued.remove(item.id)
                        done += 1
                    case .started:
                        watching.insert(item.id)
                    case .overBudget:
                        if active.isEmpty, await transport.inFlight().allSatisfy({ parked.contains($0.assetID) }) {
                            // Nothing in flight to wait for (bodies left behind that nothing records, or held
                            // for Wi-Fi): left for the next run instead of waiting for room that doesn't come.
                            queue.remove(at: position)
                            queued.remove(item.id)
                            done += 1
                        } else {
                            draining = true
                            watching.insert(item.id)
                        }
                    }
                    report(nil)
                    continue
                }
            }

            // Nothing can start now. A background run is done here: what it enqueued finishes without it.
            guard options.waitsForResults else { break }
            // Wait for a result, the end of a back-off or hold, or a nudge.
            let ends = queue.compactMap { item -> Date? in
                guard !busy.contains(item.id) else { return nil }
                return max(notBefore[item.id] ?? now, held ? holdUntil ?? now : now)
            }.filter { $0 > now }
            let deadline = draining ? nil : ends.min()
            if active.isEmpty {
                guard let deadline else { break }
                if try await wait(until: deadline, shouldPause: shouldPause) { return }
            } else {
                try await waitForSignal(orUntil: deadline)
            }
        }
        report(nil)
    }

    /// The queue for this run, newest first, and the back-off of the items that are waiting one out. Left
    /// out: items given up on for now, items the scanner still has to finish (waiting for Wi-Fi without all
    /// checksums), and items the network doesn't allow now (so they aren't counted as being uploaded). The
    /// network and the cellular switches are read once: queued items not allowed are marked waiting for
    /// Wi-Fi in one pass, with one index save, instead of one by one (`attempt` still checks each item, as
    /// the network can change).
    private func queuedItems(
        smallLocalOnly: Bool = false
    ) async throws -> ([Candidate], [String: (until: Date, holdsRun: Bool)]) {
        let ids = await index.selectedAssetIDs(in: source).ids
        let now = clock.date()
        let queued = await index.entries(where: { Self.isQueued($0.state) && !Self.isGivenUp($0.retry, at: now) },
                                         in: ids, limit: Int.max)
        let entries = Dictionary(queued, uniquingKeysWith: { first, _ in first })
        let sorted = entries.keys.sorted()
        let settings = settings()
        var onCellular: Bool?
        var candidates: [Candidate] = []
        var waits: [String: (until: Date, holdsRun: Bool)] = [:]
        var notAllowed: [(String, BackupEntry)] = []
        for start in stride(from: 0, to: sorted.count, by: Self.fetchSize) {
            let chunk = Array(sorted[start..<min(start + Self.fetchSize, sorted.count)])
            for asset in await source.assets(chunk) {
                guard let entry = entries[asset.id] else { continue }
                let resources = BackupResourcePolicy.upload(from: asset.resources)
                guard let main = resources.first else { continue }
                if smallLocalOnly, !BackupRefreshPolicy.allows(asset) { continue }
                let waiting = entry.state == .pending(reason: .waitingForWiFi)
                if waiting, !Self.hasChecksums(entry, for: resources) { continue }
                if onCellular == nil { onCellular = await network.isOnCellular }
                guard settings.allowsNetwork(for: asset, onCellular: onCellular ?? true) else {
                    if !waiting { notAllowed.append((asset.id, entry)) }
                    continue
                }
                candidates.append(Candidate(
                    id: asset.id, creationDate: asset.creationDate, filename: Self.uploadFilename(for: main, in: asset),
                    resourceCount: resources.count))
                if let retry = entry.retry, retry.notBefore > now {
                    waits[asset.id] = (retry.notBefore, retry.holdsRun)
                }
            }
        }
        if !notAllowed.isEmpty {
            for (id, entry) in notAllowed {
                await write(id, from: entry) {
                    if $0.state == .pending(reason: .needsUpload) { $0.state = .pending(reason: .waitingForWiFi) }
                }
            }
            try await index.saveIfChanged()
        }
        return (candidates.sorted { ($0.creationDate, $0.id) > ($1.creationDate, $1.id) }, waits)
    }

    /// The assets whose uploads in `jobs` the system holds for now: on cellular, those whose request was made
    /// without cellular access (the job's own flag, not today's switches: a switch turned on later doesn't
    /// change a request already handed to the system).
    private func parkedAssets(_ jobs: [UploadJob]) async -> Set<String> {
        guard !jobs.isEmpty, await network.isOnCellular else { return [] }
        return Set(jobs.filter { !$0.allowsCellular }.map(\.assetID))
    }

    /// Cuts retry times further ahead than `longestPause` (a clock moved back since they were written) to it,
    /// so such an item isn't held for longer than any back-off, and its pause runs out.
    private func clampRetryTimes() async {
        let latest = clock.date().addingTimeInterval(Self.longestPause)
        await index.updateAll(where: { $0.retry.map { $0.notBefore > latest } ?? false }) { $0.retry?.notBefore = latest }
        try? await index.saveIfChanged()
    }

    /// Where an item stands now that nothing of it is in flight.
    private func status(of id: String, now: Date) async -> Status {
        guard let entry = await index.entry(for: id), Self.isQueued(entry.state) else { return .finished }
        guard let retry = entry.retry, retry.notBefore > now else { return .ready }
        if Self.isGivenUp(retry, at: now) { return .finished }
        return .waiting(until: retry.notBefore, holdsRun: retry.holdsRun)
    }

    /// Sleeps until `deadline` in slices, asking `shouldPause` after each. Returns `true` when paused.
    private func wait(until deadline: Date, shouldPause: @Sendable () async -> Bool) async throws -> Bool {
        while clock.date() < deadline {
            let left = Duration.seconds(deadline.timeIntervalSince(clock.date()))
            try await clock.sleep(min(left, Self.waitSlice))
            if await shouldPause() { return true }
        }
        return false
    }

    /// Waits until a result is recorded or `wake()` is called, or at most until `deadline` (in slices).
    private func waitForSignal(orUntil deadline: Date?) async throws {
        guard let deadline else {
            await signal.wait()
            try Task.checkCancellation()
            return
        }
        let left = Duration.seconds(max(0, deadline.timeIntervalSince(clock.date())))
        let slice = min(left, Self.waitSlice)
        await withTaskGroup(of: Void.self) { [signal, clock] group in
            group.addTask { await signal.wait() }
            group.addTask { try? await clock.sleep(slice) }
            await group.next()
            group.cancelAll()
        }
        try Task.checkCancellation()
    }

    /// Ends a wait for results early, so the run asks `shouldPause` again (the runner calls it when it
    /// wants the run to pause).
    public nonisolated func wake() {
        signal.fire()
    }

    /// A recorded redirect (`insecureConnection`) ends the run only once everything else in flight is
    /// cancelled (`recorded` starts that too, for results that arrive outside a run).
    private func stopping(_ error: Error, _ transport: any BackupTransport) async -> Error {
        if case ImmichServiceError.insecureConnection = error { await transport.cancelAll() }
        return error
    }

    /// Called by the recorder after each result. A result that no item can get past ends the run; a
    /// redirect to another server also cancels everything else in flight, which would go there too.
    private nonisolated func recorded(_ outcome: UploadOutcome) {
        guard case let .failed(failure) = outcome,
              case .stop = Self.classify(failure.error, cancelled: false) else {
            signal.fire()
            return
        }
        if failure == .service(.insecureConnection), let transport = connection?.transport {
            Task { await transport.cancelAll() }
        }
        signal.fire(stopping: failure.error)
    }

    // MARK: - One item

    /// One attempt at one item: sends the resources the server doesn't have, or links a Live Photo whose
    /// halves are both there, or finds it done.
    private func attempt(
        _ id: String, connection: BackupUploadConnection, smallLocalOnly: Bool = false
    ) async throws -> Attempt {
        let transport = connection.transport
        guard let entry = await index.entry(for: id), Self.isQueued(entry.state),
              let asset = await source.asset(id) else { return .finished }
        let resources = BackupResourcePolicy.upload(from: asset.resources)
        guard let main = resources.first else { return .finished } // the scanner lists it as a problem
        let complete = Self.hasChecksums(entry, for: resources)
        if entry.state == .pending(reason: .waitingForWiFi), !complete { return .finished }
        guard asset.modificationDate == entry.modificationDate, complete else {
            await sendBack(id, from: entry)
            try await index.saveIfChanged()
            return .finished
        }
        let settings = settings()
        guard settings.allowsNetwork(for: asset, onCellular: await network.isOnCellular) else {
            await write(id, from: entry) { $0.state = .pending(reason: .waitingForWiFi) }
            try await index.saveIfChanged()
            return .finished
        }

        // A half with a server ID from the latest check or upload is on the server (a duplicate, not
        // trashed): it is never sent again, its ID is used instead.
        let missing = resources.filter { entry.serverIDs[$0.type] == nil }
        guard !missing.isEmpty else {
            if entry.needsLink, Self.isLivePhoto(resources) { return try await link(id, entry) }
            await write(id, from: entry) {
                $0.needsLink = false
                $0.retry = nil
                if let serverID = $0.serverIDs[main.type] { $0.state = .backedUp(serverAssetID: serverID) }
            }
            try await index.saveIfChanged()
            return .finished
        }

        try await markForLinking(id, entry, resources)
        try await preflight(transport)
        let allowsCellular = settings.allowsNetwork(for: asset, onCellular: true)
        var sent = false
        // The motion video first: if only one half gets out, it is the one the photo needs.
        for resource in missing.filter({ Self.isMotion($0.type) }) + missing.filter({ !Self.isMotion($0.type) }) {
            guard let expected = entry.checksums[resource.type] else { continue }
            let body: (bodyFile: URL, boundary: String)
            do {
                body = try await staging.stageBody(
                    resource, of: asset, from: source, allowNetwork: !smallLocalOnly,
                    fields: Self.fields(for: resource, of: asset), expectedChecksum: expected)
            } catch BackupStagingError.overBudget {
                return sent ? .started : .overBudget
            } catch PhotoLibraryReadError.needsNetwork where smallLocalOnly {
                // Only in iCloud: left as it is for a run that may download.
                return sent ? .started : .finished
            } catch BackupStagingError.checksumMismatch {
                await sendBack(id, from: entry)
                try await index.saveIfChanged()
                return .finished
            } catch {
                switch Self.classify(error) {
                case .cancelled, .stop, .outOfSpace:
                    try await stop(with: error, id, entry)
                default:
                    let state = try BackupReadFailure.state(for: error, reading: resource)
                    await write(id, from: entry) { $0.state = state }
                    try await index.saveIfChanged()
                    return .finished
                }
            }
            do {
                // Staged from the version the entry describes, or not sent: the scanner may have recorded a
                // newer one while the bytes were read.
                guard let current = await index.entry(for: id), Self.isQueued(current.state),
                      current.modificationDate == entry.modificationDate, current.checksums == entry.checksums else {
                    staging.remove(body.bodyFile)
                    return .started
                }
                try Task.checkCancellation()
                let request = try connection.requests.request(
                    checksum: expected, boundary: body.boundary, allowsCellular: allowsCellular)
                let job = UploadJob(
                    assetID: id, resource: resource.type, attempt: UUID(), bodyFileName: body.bodyFile.lastPathComponent,
                    checksum: expected, allowsCellular: request.allowsCellularAccess)
                try await transport.enqueue(job, request: request)
                sent = true
            } catch {
                staging.remove(body.bodyFile)
                if case BackupTransportError.redirectBlocked = error { await transport.cancelAll() }
                try await stop(with: error, id, entry)
            }
        }
        return .started
    }

    /// Joins a Live Photo whose halves are both on the server. A failure that retrying can fix counts
    /// towards the item's back-off, as an upload's does.
    private func link(_ id: String, _ entry: BackupEntry) async throws -> Attempt {
        let types = Set(entry.checksums.keys)
        guard let photo = types.first(where: { !Self.isMotion($0) }), let motion = types.first(where: Self.isMotion),
              let photoID = entry.serverIDs[photo], let motionID = entry.serverIDs[motion] else { return .finished }
        do {
            try await service.linkLivePhoto(photoID: photoID, motionID: motionID)
        } catch {
            switch Self.classify(error) {
            case .cancelled, .stop, .outOfSpace:
                try await stop(with: error, id, entry)
            case let .retry(holdsRun):
                let now = clock.date()
                await write(id, from: entry) {
                    $0.state = .pending(reason: .needsUpload)
                    Self.noteFailure(
                        of: &$0, holdsRun: holdsRun, offline: ImmichServiceError.isConnectivityFailure(error), at: now,
                        error: error.localizedDescription)
                }
                try await index.saveIfChanged()
                return .started
            case .failed:
                await write(id, from: entry) {
                    $0.state = .failed(reason: Self.linkFailedReason(error))
                    $0.retry = nil
                }
                try await index.saveIfChanged()
                return .finished
            }
        }
        let main = Self.mainType(of: types)
        await write(id, from: entry) {
            $0.needsLink = false
            $0.retry = nil
            if let main, let serverID = $0.serverIDs[main] { $0.state = .backedUp(serverAssetID: serverID) }
        }
        try await index.saveIfChanged()
        return .finished
    }

    /// Links every Live Photo whose halves are both on the server and that is still waiting to be joined
    /// (`needsLink`), outside a run: at a background wake, say. Items waiting out a back-off and items with
    /// an upload in flight are left for later; a run links its own items, so this does nothing during one.
    public func linkPending() async {
        guard !isRunning, !isReuploading else { return }
        await clampRetryTimes()
        let now = clock.date()
        let busy = Set(await index.jobs.map(\.assetID))
        let waiting = await index.entries(where: { entry in
            entry.needsLink && entry.state == .pending(reason: .needsUpload)
                && entry.checksums.keys.allSatisfy { entry.serverIDs[$0] != nil }
                && (entry.retry.map { $0.notBefore <= now } ?? true)
        })
        for (id, entry) in waiting.sorted(by: { $0.0 < $1.0 }) where !busy.contains(id) {
            if Task.isCancelled { return }
            do {
                _ = try await link(id, entry)
            } catch {
                return // no connection the server accepts, or cancelled: the next wake tries again
            }
        }
    }

    /// Records what the stopped attempt leaves behind and rethrows: cancellation as `CancellationError`, a full
    /// disk as `notEnoughSpace` after failing the item.
    private func stop(with error: Error, _ id: String, _ entry: BackupEntry) async throws -> Never {
        switch Self.classify(error) {
        case .outOfSpace:
            await write(id, from: entry) {
                $0.state = .failed(reason: Self.notEnoughSpaceReason)
                $0.retry = nil
            }
            try? await index.saveIfChanged()
            throw BackupStagingError.notEnoughSpace
        case .cancelled:
            await write(id, from: entry) { $0.state = .pending(reason: .needsUpload) }
            try? await index.saveIfChanged()
            throw CancellationError()
        default:
            await write(id, from: entry) { $0.state = .pending(reason: .needsUpload) }
            try? await index.saveIfChanged()
            throw error
        }
    }

    /// Checks, before anything is enqueued, that the server answers at its own address: a request with the key
    /// that can't follow a redirect to another server (`SameOriginRedirects`, and `protectsAPIKey`). A
    /// background upload follows redirects on its own, so this is where they are caught first. Failing because
    /// of a redirect cancels what is in flight. Done again after `preflightInterval`.
    ///
    /// A redirect block the transport set is never lifted here, even when the check passes: a proxy that
    /// redirects only the uploads would otherwise get the key once per run. While blocked nothing is enqueued
    /// (`BackupTransportError.redirectBlocked`); only the user lifts it (`BackupModel.retryAfterRedirect`).
    private func preflight(_ transport: any BackupTransport) async throws {
        if transport.isRedirectBlocked { throw BackupTransportError.redirectBlocked }
        let now = clock.date()
        if let lastPreflight, now.timeIntervalSince(lastPreflight) < Self.preflightInterval { return }
        do {
            try await service.ping()
        } catch {
            if Self.isRedirect(error) { await transport.cancelAll() }
            throw error
        }
        lastPreflight = now
    }

    /// A refused redirect arrives as its 3xx status; plain http to a host outside the user's network is refused
    /// before anything is sent.
    private static func isRedirect(_ error: Error) -> Bool {
        switch error {
        case ImmichServiceError.unexpectedStatus(300...399), ImmichServiceError.insecureConnection: true
        default: false
        }
    }

    // MARK: - Retry bookkeeping

    /// Counts a failure that retrying can fix towards the item's back-off. A failure that arrives while the
    /// item already waits one out (the other half of a Live Photo, sent at the same time) isn't counted again.
    static func noteFailure(
        of entry: inout BackupEntry, holdsRun: Bool, offline: Bool, at now: Date, error: String? = nil
    ) {
        var retry = entry.retry ?? BackupRetryState(failures: 0, notBefore: now, wasOffline: false, holdsRun: false)
        retry.lastError = error ?? retry.lastError
        if retry.failures > 0, retry.notBefore > now {
            // Not counted again, but what it says holds: the server being down, or no connection.
            retry.holdsRun = retry.holdsRun || holdsRun
            retry.wasOffline = retry.wasOffline || offline
            entry.retry = retry
            return
        }
        retry.failures += 1
        retry.wasOffline = offline
        retry.holdsRun = holdsRun
        retry.notBefore = retry.failures <= retryDelays.count
            ? now.addingTimeInterval(seconds(retryDelays[retry.failures - 1]))
            : now.addingTimeInterval(givenUpPause)
        entry.retry = retry
    }

    /// Failed too often to be tried again before its pause is over.
    static func isGivenUp(_ retry: BackupRetryState?, at now: Date) -> Bool {
        guard let retry else { return false }
        return retry.failures > retryDelays.count && retry.notBefore > now
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The network came back: every item waiting out a back-off may go now, items whose last failure was no
    /// connection get their tries back (also those given up on), and the hold on the run ends. A run in a
    /// back-off wait doesn't notice: the caller pauses it (`shouldPause`) and starts the next.
    public func networkReturned() async {
        let now = clock.date()
        await index.updateAll(where: { $0.retry != nil && Self.isQueued($0.state) }) { entry in
            guard var retry = entry.retry else { return }
            if retry.wasOffline {
                entry.retry = nil
            } else if retry.failures <= Self.retryDelays.count {
                retry.notBefore = min(retry.notBefore, now)
                entry.retry = retry
            }
        }
        try? await index.saveIfChanged()
    }

    // MARK: - Try Again and Re-upload

    /// Sends failed items back to the scanner (`pending(.notChecked)`), keeping their checksums: the next
    /// scan asks the server about them again without reading them and queues them. Other states are left alone.
    public func retryFailed(_ ids: [String]) async {
        for id in ids {
            guard let entry = await index.entry(for: id), case .failed = entry.state else { continue }
            await write(id, from: entry) {
                $0.state = .pending(reason: .notChecked)
                $0.retry = nil
            }
        }
        try? await index.saveIfChanged()
    }

    /// The user's Re-upload for items deleted on the server: copies in the server's trash are restored,
    /// a Live Photo half that is gone is sent now (and linked to the other half once it is on the server),
    /// and an item gone entirely goes back to `pending(.needsUpload)` for the next run. A half the server
    /// still has is never uploaded. Other states are left alone. Rethrows what `restoreAssets` throws
    /// (`editingOff` while Allow Changes is off), `unauthorized` and cancellation; the index is saved after
    /// each item. Shares the index and the transport with `run`, so it does nothing (changes nothing, throws
    /// nothing) while a run or another `reupload` is going; the runner takes turns, and a direct caller must too.
    public func reupload(_ ids: [String]) async throws {
        guard !isRunning, !isReuploading else { return }
        isReuploading = true
        defer { isReuploading = false }
        for id in ids {
            do {
                try Task.checkCancellation()
                try await reuploadItem(id)
            } catch {
                try? await index.saveIfChanged()
                throw error
            }
            try await index.saveIfChanged()
        }
    }

    private func reuploadItem(_ id: String) async throws {
        guard let entry = await index.entry(for: id), case let .deletedOnServer(trashed, wasGone) = entry.state else { return }
        var gone = wasGone
        // A trashed copy without a known ID can't be restored; it is uploaded like a gone one.
        let restorable = trashed.compactMap { type in entry.serverIDs[type].map { (type: type, id: $0) } }
        gone.formUnion(trashed.filter { entry.serverIDs[$0] == nil })
        var stillTrashed: Set<DeviceResourceType> = []
        if !restorable.isEmpty {
            let result = try await service.restoreAssets(assetIDs: restorable.map(\.id))
            let confirmed = Set(result.confirmedIDs)
            stillTrashed = Set(restorable.filter { !confirmed.contains($0.id) }.map(\.type))
        }
        let serverIDs = entry.serverIDs.filter { !gone.contains($0.key) }
        let types = Set(entry.checksums.keys)
        let present = types.subtracting(gone).subtracting(stillTrashed)

        if !stillTrashed.isEmpty {
            // Not restored this time: nothing is uploaded next to a copy that is still in the trash.
            await write(id, from: entry) {
                $0.serverIDs = serverIDs
                $0.state = .deletedOnServer(trashed: stillTrashed, gone: gone)
            }
            return
        }
        if gone.isEmpty {
            await write(id, from: entry) {
                $0.serverIDs = serverIDs
                // Restored, but still to be joined: the run links it.
                $0.state = $0.needsLink ? .pending(reason: .needsUpload)
                    : Self.mainType(of: types).flatMap { serverIDs[$0] }.map { .backedUp(serverAssetID: $0) }
                        ?? .pending(reason: .needsUpload)
            }
            return
        }
        let needsUpload: (inout BackupEntry) -> Void = {
            $0.serverIDs = serverIDs
            $0.state = .pending(reason: .needsUpload)
            $0.retry = nil
        }
        guard !present.isEmpty, present.allSatisfy({ serverIDs[$0] != nil }) else {
            // Gone entirely: uploaded by the next run like any other item.
            await write(id, from: entry, needsUpload)
            return
        }

        // Part of a Live Photo is gone: upload just that part.
        guard let asset = await source.asset(id) else {
            // Gone from the phone as well: only the restore could be done.
            await write(id, from: entry) {
                $0.serverIDs = serverIDs
                $0.state = .deletedOnServer(trashed: [], gone: gone)
            }
            return
        }
        let resources = BackupResourcePolicy.upload(from: asset.resources)
        guard asset.modificationDate == entry.modificationDate, Set(resources.map(\.type)) == types,
              Self.hasChecksums(entry, for: resources) else {
            await sendBack(id, from: entry)
            return
        }
        await write(id, from: entry, needsUpload)
        try await index.saveIfChanged()
        guard let connection else { return } // the run sends it
        guard await connection.transport.inFlight().allSatisfy({ $0.assetID != id }) else { return }
        guard try await attempt(id, connection: connection) == .started else { return }
        // A transport that has the result already: joined now, else by the next run (or `linkPending`).
        if await index.jobs(for: id).isEmpty, let current = await index.entry(for: id),
           current.state == .pending(reason: .needsUpload), current.needsLink, current.retry == nil,
           current.checksums.keys.allSatisfy({ current.serverIDs[$0] != nil }) {
            _ = try await link(id, current)
        }
    }

    // MARK: - Staging

    /// The form fields of `resource`: the motion video of a Live Photo goes up hidden, and is joined to its
    /// photo once both are on the server (the photo is sent without `livePhotoVideoId`, as the motion's ID
    /// may not be known when it is sent).
    private static func fields(for resource: DeviceResource, of asset: DeviceAsset) -> MultipartFields {
        let isVideoFile = asset.isVideo && (resource.type == .video || resource.type == .fullSizeVideo)
        return MultipartFields(
            filename: uploadFilename(for: resource, in: asset), mimeType: mimeType(for: resource),
            createdAt: asset.creationDate, modifiedAt: asset.modificationDate, isFavorite: asset.isFavorite,
            duration: isVideoFile ? asset.duration : nil, livePhotoVideoID: nil, hidden: isMotion(resource.type))
    }

    // MARK: - Index

    /// Applies `change` to the item's current entry if it still describes the version `snapshot` did
    /// (same modification date and checksums): the scanner may have recorded a newer one meanwhile.
    /// The check and the change happen in one step inside the index, on the entry as it is then.
    private func write(_ id: String, from snapshot: BackupEntry, _ change: (inout BackupEntry) -> Void) async {
        await index.update(id, ifModificationDate: snapshot.modificationDate, checksums: snapshot.checksums, change)
    }

    /// Before anything of a Live Photo is sent, records (and saves) that its halves may need joining, so
    /// a link that fails or never happens (the app stopped in between) is still made later.
    private func markForLinking(_ id: String, _ entry: BackupEntry, _ resources: [DeviceResource]) async throws {
        guard !entry.needsLink, resources.contains(where: { Self.isMotion($0.type) }),
              resources.contains(where: { !Self.isMotion($0.type) }) else { return }
        await write(id, from: entry) { $0.needsLink = true }
        try await index.saveIfChanged()
    }

    /// The item changed since it was hashed: the scanner hashes and checks it again.
    private func sendBack(_ id: String, from snapshot: BackupEntry) async {
        await write(id, from: snapshot) {
            $0.state = .pending(reason: .notChecked)
            $0.checksums = [:]
            $0.retry = nil
        }
    }

    // MARK: - Helpers

    static var notEnoughSpaceReason: String { tr("Not enough free space on the iPhone.") }

    static func linkFailedReason(_ error: Error) -> String {
        tr("Couldn't join the photo and video of this Live Photo on the server: %@", error.localizedDescription)
    }

    private static func isQueued(_ state: BackupState) -> Bool {
        state == .pending(reason: .needsUpload) || state == .pending(reason: .waitingForWiFi)
    }

    private static func hasChecksums(_ entry: BackupEntry, for resources: [DeviceResource]) -> Bool {
        resources.allSatisfy { entry.checksums[$0.type] != nil }
    }

    private static func isMotion(_ type: DeviceResourceType) -> Bool {
        type == .pairedVideo || type == .fullSizePairedVideo
    }

    private static func isLivePhoto(_ resources: [DeviceResource]) -> Bool {
        resources.contains { isMotion($0.type) } && resources.contains { !isMotion($0.type) }
    }

    /// The resource whose server ID stands for the item: the photo, or the video.
    static func mainType(of types: Set<DeviceResourceType>) -> DeviceResourceType? {
        let order: [DeviceResourceType] = [.fullSizePhoto, .photo, .fullSizeVideo, .video, .fullSizePairedVideo, .pairedVideo]
        return order.first { types.contains($0) }
    }

    enum ErrorKind {
        case cancelled
        /// No item can get past it: stop the run.
        case stop
        case outOfSpace
        case retry(holdsRun: Bool)
        case failed(String)
    }

    /// Shared with `BackupResultRecorder`, which passes `cancelled: false`: the recorder's own task being
    /// cancelled says nothing about the upload it records.
    static func classify(_ error: Error, cancelled: Bool = Task.isCancelled) -> ErrorKind {
        if error is CancellationError || cancelled { return .cancelled }
        if BackupStaging.isOutOfSpace(error) { return .outOfSpace }
        switch error {
        case let BackupUploadError.rejected(status, message):
            return .failed(message.isEmpty ? ImmichServiceError.unexpectedStatus(status).localizedDescription : message)
        case let error as ImmichServiceError:
            switch error {
            case .unauthorized, .insecureConnection, .invalidServerURL:
                return .stop
            // The server (or the proxy in front of it) is down or busy: every item would fail alike.
            case .network, .unexpectedStatus(429), .unexpectedStatus(502), .unexpectedStatus(503), .unexpectedStatus(504):
                return .retry(holdsRun: true)
            case .unexpectedStatus(408), .unexpectedStatus(500...599), .invalidResponse:
                return .retry(holdsRun: false)
            case .unexpectedStatus, .editingOff:
                return .failed(error.localizedDescription)
            }
        default:
            return .failed(error.localizedDescription)
        }
    }

    /// The MIME type from the resource's uniform type, else from its filename extension.
    static func mimeType(for resource: DeviceResource) -> String {
        if let identifier = resource.uniformTypeIdentifier, let mime = UTType(identifier)?.preferredMIMEType { return mime }
        let ext = (resource.filename as NSString).pathExtension
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    /// The filename the server shows. An edit's file is called `FullSizeRender…` in PhotoKit; it is
    /// uploaded under the original's name with the edit's extension, as the Photos app exports it.
    static func uploadFilename(for resource: DeviceResource, in asset: DeviceAsset) -> String {
        let originalType: DeviceResourceType? = switch resource.type {
        case .fullSizePhoto: .photo
        case .fullSizeVideo: .video
        case .fullSizePairedVideo: .pairedVideo
        default: nil
        }
        guard let originalType, let original = asset.resources.first(where: { $0.type == originalType }) else {
            return resource.filename
        }
        let stem = (original.filename as NSString).deletingPathExtension
        guard !stem.isEmpty else { return resource.filename }
        let ext = (resource.filename as NSString).pathExtension
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

/// Wakes a run waiting for an upload's result. A wake while nobody waits is kept for the next wait, so none
/// is lost; several coalesce into one.
final class UploaderSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var stopError: Error?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?

    func fire() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let waiter else {
                pending = true
                return nil
            }
            self.waiter = nil
            return waiter.continuation
        }
        waiting?.resume()
    }

    /// Fires, and keeps `error` for the run to throw (the first one, until `reset()`).
    func fire(stopping error: Error) {
        lock.withLock { if stopError == nil { stopError = error } }
        fire()
    }

    func takeStop() -> Error? {
        lock.withLock {
            defer { stopError = nil }
            return stopError
        }
    }

    /// Forgets wakes and errors from before (a new run starts).
    func reset() {
        lock.withLock {
            pending = false
            stopError = nil
        }
    }

    /// Returns at the next `fire()` (at once if one came since the last wait), or when the task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if pending || Task.isCancelled {
                        pending = false
                        return true
                    }
                    waiter = (id, continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let waiter, waiter.id == id else { return nil }
                self.waiter = nil
                return waiter.continuation
            }
            waiting?.resume()
        }
    }
}
