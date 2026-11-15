import Foundation
import ImmichKit
import os

/// One signed-in account's backup machinery, built without any UI: the index, staging folder, result
/// recorder, background-session transport and uploader of that account. iOS may launch Bloom in the
/// background with no window (to deliver a session's events, or for a scheduled task); the engine is built
/// then from the Keychain credentials and the account's backup directory alone. When the app is open, the
/// Backup screen's model works on the same engine (`BackupModel(engine:)`), so there is one per account per
/// process: one index in memory, one background session, one uploader.
///
/// Get it from `BackupEngine.forSessionIdentifier(_:)` (cold launch) or `BackupEngineRegistry.engine(for:)`
/// (the app at sign-in or launch).
public final class BackupEngine: Sendable {
    /// The account's background `URLSession` identifier (see `BackgroundSessionTransport.sessionIdentifier`).
    public let sessionIdentifier: String
    /// Hand it the completion handler iOS passes for this session (`handleEvents(completion:)`).
    public let transport: BackgroundSessionTransport
    /// The account's backup directory: the index, the staging folder, the redirect block and the change token.
    let directory: URL
    let source: any PhotoLibrarySource
    let service: any ImmichService
    let network: any NetworkConditions
    /// The switches, read fresh for each run and each item (the app saves them as they change).
    let settings: @Sendable () -> BackupSettings
    let index: BackupIndex
    let staging: BackupStaging
    let recorder: BackupResultRecorder
    let connection: BackupUploadConnection
    let uploader: BackupUploader
    /// Whose turn it is to scan or upload: this engine's runs or the Backup screen's (see `BackupGate`).
    let gate = BackupGate()
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())
    /// Called once `close()` has finished (the registry forgets the engine).
    private let onClose: @Sendable (BackupEngine) -> Void

    private struct Lifecycle {
        var closed = false
        var runs: [UUID: Task<Bool, Never>] = [:]
    }

    /// The change token file in the account's directory (see `PhotoLibrarySource.changedAssetIDs(since:)`).
    static let changeTokenName = "change-token"
    /// How long a run waits for the first network path report before it starts (a path monitor made at a
    /// cold launch reports cellular until then, which would hold everything for Wi-Fi).
    static let networkWait: Duration = .seconds(2)

    /// `makeTransport` gets the account directory, index, staging folder and recorder and makes the account's
    /// transport; it is called once, here (before anything can stage, see `BackgroundSessionTransport`).
    init(
        credentials: ServerCredentials, directory: URL, sessionIdentifier: String,
        source: any PhotoLibrarySource, service: any ImmichService, network: any NetworkConditions,
        settings: @escaping @Sendable () -> BackupSettings,
        freeSpace: (@Sendable () -> Int64)? = nil,
        onClose: @escaping @Sendable (BackupEngine) -> Void = { _ in },
        makeTransport: (URL, BackupIndex, BackupStaging, BackupResultRecorder) -> BackgroundSessionTransport
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.directory = directory
        self.source = source
        self.service = service
        self.network = network
        self.settings = settings
        self.onClose = onClose
        index = BackupIndex(directory: directory)
        let stagingDirectory = directory.appendingPathComponent("Staging", isDirectory: true)
        staging = BackupStaging(
            directory: stagingDirectory,
            freeSpace: freeSpace ?? { BackupStaging.availableCapacity(at: stagingDirectory) })
        let clock = BackupRetryClock.live
        recorder = BackupResultRecorder(index: index, staging: staging, now: clock.date)
        transport = makeTransport(directory, index, staging, recorder)
        connection = BackupUploadConnection(
            transport: transport, recorder: recorder, requests: BackupUploadRequests(credentials: credentials))
        uploader = BackupUploader(
            source: source, service: service, index: index, staging: staging, settings: settings, network: network,
            clock: clock, connection: connection)
    }

    /// The engine of the signed-in account whose background session is called `identifier`, made on first use
    /// (from the Keychain credentials, so this may read the Keychain and the account's index). Nil when no
    /// signed-in account has that session: the caller then invalidates that session, so its results are
    /// ignored. Also nil while the Keychain can't be read.
    public static func forSessionIdentifier(_ identifier: String) -> BackupEngine? {
        BackupEngineRegistry.shared.engine(forSessionIdentifier: identifier)
    }

    // MARK: - Background runs

    /// The short refresh task: checks only the assets the photo library reports as new or changed since the
    /// last run (all of them when it can't tell: no token yet, or an expired one), and only small photos that
    /// are already on the phone (`BackupRefreshPolicy`: no iCloud downloads, no videos). Then enqueues such
    /// items until `budget` has passed and returns without waiting for the uploads, and links Live Photos
    /// whose halves are both on the server. Does nothing while the Backup switch is off or without photo
    /// access. Waits for its turn (the app may be scanning or uploading) only within `budget`; a scan that
    /// runs past it stops and leaves the token as it was. Stops on cancellation. Returns whether it ran to
    /// the end.
    @discardableResult
    public func runIncremental(budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        return await perform(until: deadline) { engine in try await engine.incremental(until: deadline) }
    }

    /// The nightly processing task (on power): a full scan of the selection (hashing, iCloud downloads and
    /// videos allowed), then enqueues as much as the staging budget allows, returns without waiting for the
    /// uploads, and links Live Photos. Does nothing while the switch is off or without photo access. Waits
    /// for its turn while the app scans or uploads. Stops on cancellation. Returns whether it ran to the end.
    @discardableResult
    public func runProcessing() async -> Bool {
        await perform(until: nil) { engine in try await engine.processing() }
    }

    /// Runs `work` on its turn (`gate`), waiting for it until `deadline` at most.
    private func perform(
        until deadline: ContinuousClock.Instant?, _ work: @escaping @Sendable (BackupEngine) async throws -> Void
    ) async -> Bool {
        let id = UUID()
        let task = lifecycle.withLock { state -> Task<Bool, Never>? in
            guard !state.closed else { return nil }
            let task = Task { [self] in
                // The app holding it does the work itself; a refresh doesn't wait past its own deadline.
                guard await gate.acquire(until: deadline) else { return false }
                let finished: Bool
                do {
                    try await work(self)
                    finished = !Task.isCancelled
                } catch {
                    finished = false
                }
                await gate.release()
                return finished
            }
            state.runs[id] = task
            return task
        }
        guard let task else { return false }
        let finished = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        lifecycle.withLock { _ = $0.runs.removeValue(forKey: id) }
        return finished
    }

    private func incremental(until deadline: ContinuousClock.Instant) async throws {
        guard try await prepare() else { return }
        let (changed, token) = await source.changedAssetIDs(since: storedChangeToken())
        try Task.checkCancellation()
        if changed.map({ !$0.isEmpty }) ?? true {
            let scanner = BackupScanner(source: source, service: service, index: index, network: network, settings: settings())
            // Stops at the deadline (throwing), so the token stays and the next refresh checks the same changes.
            try await Self.before(deadline) {
                try await scanner.scan(only: changed, smallLocalOnly: true) { _, _ in }
            }
        }
        // Only after the scan got through: a run that stopped checks the same changes next time.
        storeChangeToken(token)
        try await upload(.refresh, until: deadline)
        try Task.checkCancellation()
        await uploader.linkPending()
    }

    private func processing() async throws {
        guard try await prepare() else { return }
        // Read before the scan: whatever changes during it is found by the next refresh.
        let (_, token) = await source.changedAssetIDs(since: nil)
        let scanner = BackupScanner(source: source, service: service, index: index, network: network, settings: settings())
        try await scanner.scan { _, _ in }
        storeChangeToken(token)
        try await upload(.processing, until: nil)
        try Task.checkCancellation()
        await uploader.linkPending()
    }

    /// Whether a background run may go ahead; waits for the network report and the transport's startup.
    private func prepare() async throws -> Bool {
        guard settings().isEnabled else { return false }
        let access = await source.authorization()
        guard access == .full || access == .limited else { return false }
        await waitForNetworkPath()
        // The transport's startup reconcile cleans the staging folder: it comes before anything is staged.
        _ = await transport.inFlight()
        try Task.checkCancellation()
        return true
    }

    private struct DeadlineReached: Error {}

    /// `work`'s result, or `DeadlineReached` once `deadline` passes (`work` is cancelled then).
    private static func before(
        _ deadline: ContinuousClock.Instant, _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await work(); return true }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); return false }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw DeadlineReached() }
        }
    }

    private func upload(_ options: BackupRunOptions, until deadline: ContinuousClock.Instant?) async throws {
        try await uploader.run(options: options, progress: { _ in }, shouldPause: {
            if Task.isCancelled { return true }
            guard let deadline else { return false }
            return ContinuousClock.now >= deadline
        })
    }

    private func waitForNetworkPath() async {
        let network = network
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in network.changes() { return }
            }
            group.addTask { try? await Task.sleep(for: Self.networkWait) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Change token

    private var changeTokenURL: URL { directory.appendingPathComponent(Self.changeTokenName, isDirectory: false) }

    func storedChangeToken() -> Data? {
        guard let token = try? Data(contentsOf: changeTokenURL) else { return nil }
        #if os(iOS)
        // A file written before it got this class keeps `.complete` (unreadable while locked) until replaced.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: changeTokenURL.path)
        #endif
        return token
    }

    /// Kept in the account's directory, readable while the phone is locked after its first unlock. Never
    /// written after sign-out (it would recreate the directory). The Backup screen's full scans store theirs too.
    func storeChangeToken(_ token: Data?) {
        guard let token, !lifecycle.withLock({ $0.closed }) else { return }
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? token.write(to: changeTokenURL, options: options)
    }

    // MARK: - Sign-out

    var isClosed: Bool { lifecycle.withLock { $0.closed } }

    /// The first step of `close()`, which sign-out takes before the Backup screen's model stops (so a background
    /// run doesn't stage into the folder the model's runner then empties): no new background run starts, and
    /// the running ones are cancelled and waited for. Calling it again does nothing more.
    func cancelRuns() async {
        let runs = lifecycle.withLock { state -> [Task<Bool, Never>] in
            state.closed = true
            return Array(state.runs.values)
        }
        for run in runs { run.cancel() }
        for run in runs { _ = await run.value }
    }

    /// Sign-out, after `cancelRuns()` and the Backup screen's model has stopped (`BackupModel.stop()`, which
    /// ends the app's own scans and runs). In this order:
    /// 1. no new background run starts, and the running ones are cancelled and waited for (scheduled
    ///    background tasks are cancelled here as well once they exist);
    /// 2. the transport is invalidated: iOS cancels the account's uploads, nothing more is enqueued, and a
    ///    redirect seen afterwards isn't written;
    /// 3. the index is closed: results that still arrive (cancellations among them) find no job to record
    ///    and can't save, so the recorder changes nothing for this account and no other account's index is
    ///    touched;
    /// 4. the staging folder and the account's directory are removed. Nothing recreates them: every save of
    ///    the index, the redirect block and the change token is refused from steps 2–3 on.
    /// The registry then forgets the engine, so `forSessionIdentifier` won't return it.
    func close() async {
        await cancelRuns()
        transport.invalidate()
        await index.close()
        await staging.removeAll()
        try? FileManager.default.removeItem(at: directory)
        onClose(self)
    }
}

/// The process's backup engines, one per signed-in account (in practice one: Bloom has one account at a time).
/// Holds them so the app and a background launch in the same process get the same engine.
final class BackupEngineRegistry: @unchecked Sendable {
    /// Makes an engine for the account (credentials, directory, session identifier), using `service` when the
    /// app has one for it (nil on a cold launch) and `onClose` when it signs out.
    typealias Factory = @Sendable (
        _ credentials: ServerCredentials, _ directory: URL, _ identifier: String, _ service: (any ImmichService)?,
        _ onClose: @escaping @Sendable (BackupEngine) -> Void
    ) -> BackupEngine

    /// The app's: the Keychain, `<Application Support>/Bloom/Backup`, live sessions and the photo library.
    static let shared = BackupEngineRegistry(store: CredentialStore(), root: RootModel.backupRoot)

    /// Allow Changes for the app and for engines made without the app (a cold launch): one setting per process,
    /// so a Re-upload that restores from the trash honours it whichever made the engine.
    let editing: EditingPermission
    private let store: CredentialStore
    private let root: URL
    private let make: Factory
    private let lock = NSLock()
    /// Held while an engine is made (never together with a lookup's wait on `lock`).
    private let building = NSLock()
    private var engines: [String: BackupEngine] = [:]

    init(store: CredentialStore, root: URL, editing: EditingPermission? = nil, make: Factory? = nil) {
        self.store = store
        self.root = root
        let editing = editing ?? EditingPermission(isAllowed: LibraryChanges.storedValue)
        self.editing = editing
        self.make = make ?? Self.live(editing: editing)
    }

    /// The session identifier of an account: its canonical server URL from the credentials, and the account's
    /// digest (the name of its backup directory) in place of a user ID, which a cold launch can't ask the server
    /// for. A one-way hash either way: the identifier holds no secret.
    static func sessionIdentifier(for credentials: ServerCredentials) -> String {
        BackgroundSessionTransport.sessionIdentifier(
            serverURL: credentials.serverURL, userID: RootModel.accountDigest(for: credentials))
    }

    func directory(for credentials: ServerCredentials) -> URL {
        root.appendingPathComponent(RootModel.accountDigest(for: credentials), isDirectory: true)
    }

    /// The account's engine, made on first use. `service` is used only when it is made here.
    func engine(for credentials: ServerCredentials, service: (any ImmichService)? = nil) -> BackupEngine {
        let identifier = Self.sessionIdentifier(for: credentials)
        if let engine = lock.withLock({ engines[identifier] }) { return engine }
        // Made outside `lock` (lookups and `forget` don't wait for it): it reads the account's index, which can be
        // large. Builds take turns on `building` instead, so a second builder finds the first one's engine
        // rather than making a second background session with the same identifier (made at once, see
        // `BackgroundSessionTransport`).
        return building.withLock {
            if let engine = lock.withLock({ engines[identifier] }) { return engine }
            let made = make(credentials, directory(for: credentials), identifier, service) { [weak self] closed in
                self?.forget(closed)
            }
            lock.withLock { engines[identifier] = made }
            return made
        }
    }

    /// The signed-in account's engine if its session is called `identifier`; nil otherwise (signed out, another
    /// account, or the Keychain can't be read).
    func engine(forSessionIdentifier identifier: String) -> BackupEngine? {
        guard let credentials = try? store.load(), Self.sessionIdentifier(for: credentials) == identifier else { return nil }
        return engine(for: credentials)
    }

    private func forget(_ engine: BackupEngine) {
        lock.withLock {
            if engines[engine.sessionIdentifier] === engine { engines[engine.sessionIdentifier] = nil }
        }
    }

    private static func live(editing: EditingPermission) -> Factory {
        { credentials, directory, identifier, service, onClose in
            BackupEngine(
                credentials: credentials, directory: directory, sessionIdentifier: identifier,
                source: photoLibrary,
                service: service ?? EditGuardedService(base: LiveImmichService(credentials: credentials), permission: editing),
                network: PathMonitorNetwork(), settings: { BackupSettings.load() }, onClose: onClose
            ) { directory, index, staging, recorder in
                BackgroundSessionTransport(
                    identifier: identifier, directory: directory, index: index, staging: staging, recorder: recorder)
            }
        }
    }

    /// The device's photo library on iOS; the preview library where PhotoKit isn't available.
    static var photoLibrary: any PhotoLibrarySource {
        #if os(iOS)
        PhotoKitLibrarySource()
        #else
        PreviewPhotoLibrary()
        #endif
    }
}

/// One account's turn to scan or upload: the engine's background runs and the Backup screen's scans and upload
/// runs take it, so two never hash, check or write the same items at once. First come, first served; a waiter
/// that is cancelled (or whose deadline passes) leaves the queue without getting it. No busy waiting.
actor BackupGate {
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Waiters given up on before they queued (the cancellation handler can run first).
    private var abandoned: Set<UUID> = []

    /// Waits for the gate. Returns false, without it, when the task is cancelled or `deadline` passes first.
    /// Each `true` must be paired with one `release()`.
    func acquire(until deadline: ContinuousClock.Instant? = nil) async -> Bool {
        if !held {
            held = true
            return true
        }
        let id = UUID()
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.abandon(id)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if abandoned.remove(id) != nil || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Hands the gate to the longest waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func abandon(_ id: UUID) {
        if let position = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: position).continuation.resume(returning: false)
        } else {
            abandoned.insert(id)
        }
    }
}
