import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// The headless backup engine: built from credentials and an account directory (no UI), its background runs
/// on a fake photo library, the mock server and a fake background session, and the registry that gives the
/// app and a background launch the same engine.
final class BackupEngineTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let accountA = try! ServerCredentials(server: "https://photos.example.com", apiKey: "key-of-account-a")
    private let accountB = try! ServerCredentials(server: "https://other.example.org", apiKey: "key-of-account-b")

    // MARK: - Fixture

    private func temporaryDirectory(_ name: String = "BackupEngineTests") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func photo(_ id: String, iCloudOnly: Bool = false, in library: FakePhotoLibrary) -> DeviceAsset {
        let resource = DeviceResource(type: .photo, filename: "\(id).heic", uniformTypeIdentifier: "public.heic")
        let asset = DeviceAsset(
            id: id, isVideo: false, creationDate: date, modificationDate: date, isFavorite: false, duration: 0,
            resources: [resource])
        library.addAsset(asset)
        library.setData([Data("bytes of \(id)".utf8)], for: resource)
        if iCloudOnly { library.markICloudOnly(resource) }
        return asset
    }

    private func video(_ id: String, seconds: TimeInterval, in library: FakePhotoLibrary) -> DeviceAsset {
        let resource = DeviceResource(type: .video, filename: "\(id).mov", uniformTypeIdentifier: "com.apple.quicktime-movie")
        let asset = DeviceAsset(
            id: id, isVideo: true, creationDate: date, modificationDate: date, isFavorite: false, duration: seconds,
            resources: [resource])
        library.addAsset(asset)
        library.setData([Data("bytes of \(id)".utf8)], for: resource)
        return asset
    }

    private func checksum(of id: String) -> String {
        var sha = SHA1Stream()
        sha.update(Data("bytes of \(id)".utf8))
        return sha.base64()
    }

    /// An entry as a finished scan leaves it: hashed, with `state`.
    private func hashedEntry(_ id: String, type: DeviceResourceType = .photo, state: BackupState) -> BackupEntry {
        BackupEntry(modificationDate: date, checksums: [type: checksum(of: id)], state: state)
    }

    /// Writes `index.json` for `directory`: the selection is album "A", plus `entries`.
    private func seedIndex(in directory: URL, entries: [String: BackupEntry] = [:]) async throws {
        let index = BackupIndex(directory: directory)
        await index.setSelection(BackupSelection(included: ["A"]))
        for (id, entry) in entries { await index.set(entry, for: id) }
        try await index.save()
    }

    private func makeEngine(
        directory: URL, library: FakePhotoLibrary, service: MockImmichService, session: EngineFakeSession,
        credentials: ServerCredentials? = nil, identifier: String = "test-session",
        settings: BackupSettings = BackupSettings(isEnabled: true),
        onClose: @escaping @Sendable (BackupEngine) -> Void = { _ in }
    ) -> BackupEngine {
        BackupEngine(
            credentials: credentials ?? accountA, directory: directory, sessionIdentifier: identifier, source: library,
            service: service, network: WiFiNetwork(), settings: { settings }, freeSpace: { 100 * 1024 * 1024 * 1024 },
            onClose: onClose
        ) { directory, index, staging, recorder in
            BackgroundSessionTransport(
                directory: directory, index: index, staging: staging, recorder: recorder, graceDelay: {}
            ) { _ in session }
        }
    }

    /// A registry like the app's, on an in-memory Keychain and a temporary root, making engines on fake sessions.
    private func makeRegistry(store: CredentialStore, sessions: SessionBox) -> BackupEngineRegistry {
        let library = FakePhotoLibrary()
        let service = MockImmichService()
        return BackupEngineRegistry(
            store: store, root: temporaryDirectory("BackupEngineRegistry"), editing: EditingPermission(isAllowed: false)
        ) { credentials, directory, identifier, given, onClose in
            let session = sessions.session(for: identifier)
            return BackupEngine(
                credentials: credentials, directory: directory, sessionIdentifier: identifier, source: library,
                service: given ?? service, network: WiFiNetwork(), settings: { BackupSettings() },
                freeSpace: { 100 * 1024 * 1024 * 1024 }, onClose: onClose
            ) { directory, index, staging, recorder in
                BackgroundSessionTransport(
                    directory: directory, index: index, staging: staging, recorder: recorder, graceDelay: {}
                ) { _ in session }
            }
        }
    }

    private func writeToken(_ token: Data, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try token.write(to: directory.appendingPathComponent(BackupEngine.changeTokenName))
    }

    private func bulkChecks(_ service: MockImmichService) async -> [Int] {
        await service.requests.compactMap { request -> Int? in
            if case let .bulkUploadCheck(count) = request { return count }
            return nil
        }
    }

    private func enqueuedAssets(_ session: EngineFakeSession) -> [String] {
        session.created.compactMap { BackgroundSessionTransport.job(in: $0.taskDescription)?.assetID }
    }

    // MARK: - Change tokens

    func testIncrementalScanChecksOnlyChangedAssets() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        let service = MockImmichService()
        for id in ["a", "b", "c", "d"] { _ = photo(id, in: library) }
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a", "b", "c", "d"])
        await service.setServerChecksums(Set(["a", "b", "c"].map(checksum(of:))))
        try await seedIndex(in: directory, entries: [
            "a": hashedEntry("a", state: .backedUp(serverAssetID: "server-a")),
            "b": hashedEntry("b", state: .backedUp(serverAssetID: "server-b")),
            "c": hashedEntry("c", state: .backedUp(serverAssetID: "server-c")),
        ])
        let before = Data("token-1".utf8), after = Data("token-2".utf8)
        try writeToken(before, in: directory)
        library.setChanges(since: before, ids: ["d", "not-selected"], next: after)
        let session = EngineFakeSession()
        let engine = makeEngine(directory: directory, library: library, service: service, session: session)

        let finished = await engine.runIncremental(budget: .seconds(60))

        XCTAssertTrue(finished)
        XCTAssertEqual(library.changeTokenRequests, [before], "The stored token is the one asked about")
        XCTAssertEqual(Set(library.reads.map(\.assetID)), ["d"], "Only the new photo is read")
        let checks = await bulkChecks(service)
        XCTAssertEqual(checks, [1, 1], "The probe and the new photo; unchanged items aren't checked again")
        XCTAssertEqual(engine.storedChangeToken(), after, "The token moves on once the scan got through")
        XCTAssertEqual(enqueuedAssets(session), ["d"], "The new photo is enqueued")
        let entry = await engine.index.entry(for: "d")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        let jobs = await engine.index.jobs
        XCTAssertEqual(jobs.map(\.assetID), ["d"], "Enqueued and finished: the upload is left to the session")
    }

    func testExpiredTokenFallsBackToFullScan() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        let service = MockImmichService()
        for id in ["a", "b", "c", "d"] { _ = photo(id, in: library) }
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a", "b", "c", "d"])
        await service.setServerChecksums(Set(["a", "b", "c", "d"].map(checksum(of:))))
        try await seedIndex(in: directory, entries: [
            "a": hashedEntry("a", state: .backedUp(serverAssetID: "server-a")),
            "b": hashedEntry("b", state: .backedUp(serverAssetID: "server-b")),
            "c": hashedEntry("c", state: .backedUp(serverAssetID: "server-c")),
        ])
        let expired = Data("expired".utf8), current = Data("current".utf8)
        try writeToken(expired, in: directory)
        library.setCurrentChangeToken(current)
        let engine = makeEngine(directory: directory, library: library, service: service, session: EngineFakeSession())

        let finished = await engine.runIncremental(budget: .seconds(60))

        XCTAssertTrue(finished)
        XCTAssertEqual(library.changeTokenRequests, [expired])
        let checks = await bulkChecks(service)
        XCTAssertEqual(checks, [1, 4], "The whole selection is checked: the probe, then a, b, c and d together")
        XCTAssertEqual(engine.storedChangeToken(), current, "The current token is kept for next time")
        let entry = await engine.index.entry(for: "d")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(checksum(of: "d"))"))

        // No token at all (the first run) is a full scan too, and the next run is incremental from it.
        let fresh = temporaryDirectory()
        try await seedIndex(in: fresh)
        let second = makeEngine(directory: fresh, library: library, service: MockImmichService(), session: EngineFakeSession())
        await second.runIncremental(budget: .seconds(60))
        XCTAssertEqual(library.changeTokenRequests.last, .some(nil))
        XCTAssertEqual(second.storedChangeToken(), current)
    }

    func testRefreshSkipsICloudOnlyAndLargeVideos() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        let service = MockImmichService()
        _ = photo("local", in: library)
        _ = photo("cloud", iCloudOnly: true, in: library)
        _ = video("long", seconds: 120, in: library)
        _ = video("short", seconds: 5, in: library)
        // Hashed earlier with the app open, still waiting for their upload.
        _ = photo("hashed-cloud", iCloudOnly: true, in: library)
        _ = video("hashed-video", seconds: 300, in: library)
        let ids: Set<String> = ["local", "cloud", "long", "short", "hashed-cloud", "hashed-video"]
        library.addAlbum(id: "A", title: "Recents", assetIDs: ids)
        try await seedIndex(in: directory, entries: [
            "hashed-cloud": hashedEntry("hashed-cloud", state: .pending(reason: .needsUpload)),
            "hashed-video": hashedEntry("hashed-video", type: .video, state: .pending(reason: .needsUpload)),
        ])
        let session = EngineFakeSession()
        let engine = makeEngine(directory: directory, library: library, service: service, session: session)

        let finished = await engine.runIncremental(budget: .seconds(60))

        XCTAssertTrue(finished)
        XCTAssertFalse(library.reads.isEmpty)
        XCTAssertTrue(library.reads.allSatisfy { !$0.allowNetwork }, "Nothing is downloaded from iCloud")
        let videoReads = library.reads.filter { ["long", "short", "hashed-video"].contains($0.assetID) }
        XCTAssertEqual(videoReads, [], "No video is read")
        XCTAssertEqual(enqueuedAssets(session), ["local"], "Only the small local photo is enqueued")
        let cloud = await engine.index.entry(for: "cloud")
        XCTAssertNil(cloud, "An iCloud-only photo is left for a full scan, not marked")
        let long = await engine.index.entry(for: "long")
        XCTAssertNil(long, "A video isn't hashed")
        let hashedCloud = await engine.index.entry(for: "hashed-cloud")
        XCTAssertEqual(hashedCloud?.state, .pending(reason: .needsUpload), "Left as it is")
        let hashedVideo = await engine.index.entry(for: "hashed-video")
        XCTAssertEqual(hashedVideo?.state, .pending(reason: .needsUpload), "Left as it is")
        XCTAssertEqual(try stagedFiles(in: directory).count, 1, "Only the photo's body was staged")
    }

    private func stagedFiles(in directory: URL) throws -> [String] {
        let staging = directory.appendingPathComponent("Staging", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }

    func testBackgroundRunsDoNothingWhileTheSwitchIsOff() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("p", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["p"])
        try await seedIndex(in: directory)
        let service = MockImmichService()
        let session = EngineFakeSession()
        let engine = makeEngine(
            directory: directory, library: library, service: service, session: session, settings: BackupSettings())

        await engine.runIncremental(budget: .seconds(60))
        await engine.runProcessing()

        XCTAssertEqual(library.reads, [])
        XCTAssertEqual(session.created.count, 0)
        let requests = await service.requests
        XCTAssertEqual(requests, [])
    }

    func testProcessingScansEverythingAndEnqueuesWithoutWaiting() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("cloud", iCloudOnly: true, in: library)
        _ = video("long", seconds: 120, in: library)
        for index in 0..<5 { _ = photo("p\(index)", in: library) }
        let ids = Set(["cloud", "long"] + (0..<5).map { "p\($0)" })
        library.addAlbum(id: "A", title: "Recents", assetIDs: ids)
        library.setCurrentChangeToken(Data("now".utf8))
        try await seedIndex(in: directory)
        let session = EngineFakeSession()
        let engine = makeEngine(directory: directory, library: library, service: MockImmichService(), session: session)

        let finished = await engine.runProcessing()

        XCTAssertTrue(finished)
        XCTAssertEqual(Set(enqueuedAssets(session)), ids, "All of them, past the foreground's limit of three")
        XCTAssertTrue(library.reads.contains { $0.assetID == "cloud" && $0.allowNetwork }, "iCloud downloads are allowed")
        XCTAssertEqual(engine.storedChangeToken(), Data("now".utf8))
    }

    /// An index file that can't be read when the engine is made (a locked phone) is loaded again once it can.
    func testRunReloadsAnIndexThatWasUnreadableAtStart() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory)
        let file = directory.appendingPathComponent("index.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        let session = EngineFakeSession()
        let engine = makeEngine(directory: directory, library: library, service: MockImmichService(), session: session)
        let unavailable = await engine.index.isAvailable
        XCTAssertFalse(unavailable, "Precondition: the index could not be read")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)

        let finished = await engine.runProcessing()

        let available = await engine.index.isAvailable
        XCTAssertTrue(available)
        XCTAssertTrue(finished)
        XCTAssertEqual(enqueuedAssets(session), ["a"])
    }

    /// The gate tells whether a background run holds it, also when it hands over to a waiter.
    func testGateKnowsWhenABackgroundRunHoldsIt() async {
        let gate = BackupGate()
        var held = await gate.isHeldByBackgroundRun
        XCTAssertFalse(held)
        _ = await gate.acquire(background: true)
        held = await gate.isHeldByBackgroundRun
        XCTAssertTrue(held)
        let screen = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.release()
        let entered = await screen.value
        XCTAssertTrue(entered)
        held = await gate.isHeldByBackgroundRun
        XCTAssertFalse(held, "The screen's turn now")
        await gate.release()
        held = await gate.isHeldByBackgroundRun
        XCTAssertFalse(held)
    }

    /// While a background run holds the turn, the screen's scan says it waits, and stops saying so once it runs.
    @MainActor func testScanWaitingBehindABackgroundRunSaysSo() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory, entries: [:])
        let engine = makeEngine(
            directory: directory, library: library, service: MockImmichService(), session: EngineFakeSession())
        let model = await makeModel(engine: engine)
        _ = await engine.gate.acquire(background: true)

        let scan = Task { await model.scan() }
        for _ in 0..<200 where !model.isWaitingForBackgroundRun { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isWaitingForBackgroundRun)

        await engine.gate.release()
        _ = await scan.value
        XCTAssertFalse(model.isWaitingForBackgroundRun)
    }

    /// Try Again takes the engine's turn like a scan or a run: it waits while a background run holds it.
    func testTryAgainWaitsForTheEnginesTurn() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory, entries: ["a": BackupEntry(
            modificationDate: date, checksums: [.photo: checksum(of: "a")], state: .failed(reason: "boom"))])
        let engine = makeEngine(
            directory: directory, library: library, service: MockImmichService(), session: EngineFakeSession())
        let model = await makeModel(engine: engine)
        let held = await engine.gate.acquire()
        XCTAssertTrue(held)

        let retry = Task { await model.runner.retryFailed(["a"]) }
        try await Task.sleep(for: .milliseconds(300))
        let whileHeld = await engine.index.entry(for: "a")?.state
        XCTAssertEqual(whileHeld, .failed(reason: "boom"), "Waits for the engine's turn")

        await engine.gate.release()
        await retry.value
        let after = await engine.index.entry(for: "a")?.state
        XCTAssertEqual(after, .pending(reason: .notChecked))
    }

    // MARK: - Registry

    func testUnknownSessionIdentifierGivesNoEngine() throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        let registry = makeRegistry(store: store, sessions: SessionBox())
        let identifierA = BackupEngineRegistry.sessionIdentifier(for: accountA)
        let identifierB = BackupEngineRegistry.sessionIdentifier(for: accountB)

        XCTAssertNil(registry.engine(forSessionIdentifier: identifierA), "Nobody is signed in")

        try store.save(accountA)
        XCTAssertNil(registry.engine(forSessionIdentifier: "no.johannesstoen.bloom.backup.0123456789abcdef"))
        XCTAssertNil(registry.engine(forSessionIdentifier: identifierB), "Another account's session")
        let engine = try XCTUnwrap(registry.engine(forSessionIdentifier: identifierA))
        XCTAssertTrue(registry.engine(forSessionIdentifier: identifierA) === engine, "One engine per account")
        XCTAssertEqual(engine.sessionIdentifier, identifierA)
        XCTAssertNotEqual(identifierA, identifierB)
        XCTAssertFalse(identifierA.contains(accountA.apiKey))
        XCTAssertTrue(identifierA.hasPrefix("no.johannesstoen.bloom.backup."))
    }

    /// While sign-out is closing an engine, its identifier belongs to the registry: its own transport is closed
    /// (a second session under the identifier would be made, then ended, for nothing).
    func testClosingHeldTransportInvalidatesTheEnginesOwnSession() throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        let sessions = SessionBox()
        let registry = makeRegistry(store: store, sessions: sessions)
        let identifierA = BackupEngineRegistry.sessionIdentifier(for: accountA)
        XCTAssertFalse(registry.closeTransport(forSessionIdentifier: identifierA), "Holds no engine yet")

        _ = registry.engine(for: accountA)
        let session = sessions.session(for: identifierA)
        XCTAssertFalse(session.isInvalidated)
        XCTAssertTrue(registry.closeTransport(forSessionIdentifier: identifierA))
        XCTAssertTrue(session.isInvalidated, "The engine's own session was closed")
    }

    func testSignedOutAccountResultsAreIgnored() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        let sessions = SessionBox()
        let registry = makeRegistry(store: store, sessions: sessions)
        let identifierA = BackupEngineRegistry.sessionIdentifier(for: accountA)
        let identifierB = BackupEngineRegistry.sessionIdentifier(for: accountB)
        let directoryA = registry.directory(for: accountA)

        // Account A has an upload in flight: its job in the index, its body staged, its task with iOS.
        let body = "\(UUID().uuidString).multipart"
        let job = UploadJob(assetID: "x", resource: .photo, attempt: UUID(), bodyFileName: body, checksum: checksum(of: "x"))
        let index = BackupIndex(directory: directoryA)
        await index.set(hashedEntry("x", state: .pending(reason: .needsUpload)), for: "x")
        await index.addJob(job)
        try await index.save()
        let staging = directoryA.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: staging.appendingPathComponent(body))
        let request = URLRequest(url: URL(string: "https://photos.example.com/api/assets")!)
        let task = EngineFakeTask(id: 1, description: try BackgroundSessionTransport.description(of: job), request: request)
        let redirected = EngineFakeTask(id: 2, description: nil, request: request)
        sessions.session(for: identifierA).report([task, redirected])

        try store.save(accountA)
        let engineA = try XCTUnwrap(registry.engine(forSessionIdentifier: identifierA))
        await engineA.transport.reconcile()
        let jobsBefore = await engineA.index.jobs
        XCTAssertEqual(jobsBefore, [job])

        // Sign-out, as RootModel does it: the credentials first, then the engine.
        try store.clear()
        await engineA.close()
        XCTAssertTrue(sessions.session(for: identifierA).isInvalidated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryA.path), "The account's directory is gone")
        XCTAssertNil(registry.engine(forSessionIdentifier: identifierA))

        // Account B signs in.
        try store.save(accountB)
        let engineB = try XCTUnwrap(registry.engine(forSessionIdentifier: identifierB))
        XCTAssertFalse(engineB === engineA)
        XCTAssertNil(registry.engine(forSessionIdentifier: identifierA), "A's session belongs to nobody now")

        // A's results arrive late: the upload finished, and another one was redirected to another server.
        task.response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)
        engineA.transport.events.didReceive(Data(#"{"id":"srv-x","status":"created"}"#.utf8), for: task)
        engineA.transport.events.didComplete(task, status: 201, error: nil)
        redirected.response = HTTPURLResponse(
            url: URL(string: "https://evil.example.net/api/assets")!, statusCode: 201, httpVersion: nil, headerFields: nil)
        engineA.transport.events.didComplete(redirected, status: 201, error: nil)
        for _ in 0..<200 where engineA.transport.events.hasPendingWork {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryA.path), "Nothing recreates A's directory")
        let entryInA = await engineA.index.entry(for: "x")
        XCTAssertNil(entryInA, "Nothing is recorded for A")
        let entryInB = await engineB.index.entry(for: "x")
        XCTAssertNil(entryInB, "Nothing of A's lands in B's index")
        let jobsInB = await engineB.index.jobs
        XCTAssertEqual(jobsInB, [])
        let directoryB = registry.directory(for: accountB)
        let indexB = BackupIndex(directory: directoryB)
        let savedInB = await indexB.entry(for: "x")
        XCTAssertNil(savedInB)
        let runAfterClose = await engineA.runIncremental(budget: .seconds(10))
        XCTAssertFalse(runAfterClose, "A closed engine runs nothing")
    }

    func testForegroundAndBackgroundShareOneEngine() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        try store.save(accountA)
        let sessions = SessionBox()
        let registry = makeRegistry(store: store, sessions: sessions)
        let mock = MockImmichService()
        let root = await RootModel(store: store, makeService: { _ in mock }, editing: nil, backupEngines: registry)

        await root.restore()

        let backup = try await MainActor.run { try XCTUnwrap(root.session?.backup) }
        let foreground = try await MainActor.run { try XCTUnwrap(backup.engine) }
        let identifier = BackupEngineRegistry.sessionIdentifier(for: accountA)
        let background = try XCTUnwrap(registry.engine(forSessionIdentifier: identifier), "A cold launch's lookup")
        XCTAssertTrue(foreground === background, "One engine per account per process")
        let connection = await backup.uploadConnection()
        XCTAssertTrue((connection?.transport as AnyObject?) === background.transport, "One background session")
        let uploader = await backup.makeUploader()
        XCTAssertTrue(uploader === background.uploader, "One uploader: a foreground and a background run take turns")
        let staging = await MainActor.run { backup.staging }
        XCTAssertTrue(staging === background.staging)
        XCTAssertEqual(sessions.count, 1, "One session made")

        await root.signOut()
        XCTAssertTrue(background.isClosed)
        XCTAssertTrue(sessions.session(for: identifier).isInvalidated)
        XCTAssertNil(registry.engine(forSessionIdentifier: identifier))
    }

    // MARK: - Fix round 1

    /// The Backup screen's model on `engine`, with its own defaults.
    @MainActor private func makeModel(engine: BackupEngine) -> BackupModel {
        let suite = "BackupEngineTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return BackupModel(engine: engine, defaults: defaults)
    }

    func testLiveSessionSendsAtMostThreeUploadsPerHost() {
        let configuration = BackgroundSessionTransport.backgroundConfiguration(identifier: "test-configuration")
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 3)
    }

    func testForegroundScanAndBackgroundRunNeverOverlap() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        let service = MockImmichService()
        for id in ["a", "b"] { _ = photo(id, in: library) }
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a", "b"])
        try await seedIndex(in: directory)
        let probe = OverlapProbe()
        library.setBeforeRead { _ in await probe.enter() }
        let engine = makeEngine(directory: directory, library: library, service: service, session: EngineFakeSession())
        let model = await makeModel(engine: engine)

        let foreground = Task { await model.scan() }
        await probe.waitUntilHeld()
        let background = Task { await engine.runIncremental(budget: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        await probe.release()
        let scanned = await foreground.value
        _ = await background.value

        XCTAssertTrue(scanned)
        let most = await probe.most
        XCTAssertEqual(most, 1, "The background run's scan waits for the foreground scan")
    }

    func testBackgroundRunReturnsAtItsDeadlineWhileTheGateIsHeld() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory)
        library.setCurrentChangeToken(Data("token-1".utf8))
        let engine = makeEngine(
            directory: directory, library: library, service: MockImmichService(), session: EngineFakeSession())
        let held = await engine.gate.acquire()
        XCTAssertTrue(held)

        let start = ContinuousClock.now
        let finished = await engine.runIncremental(budget: .milliseconds(200))
        let elapsed = start.duration(to: .now)
        await engine.gate.release()

        XCTAssertFalse(finished)
        XCTAssertLessThan(elapsed, .seconds(5), "Waits only within its own deadline")
        XCTAssertTrue(library.reads.isEmpty, "Nothing was scanned")
        XCTAssertTrue(library.changeTokenRequests.isEmpty)
        XCTAssertNil(engine.storedChangeToken())
    }

    func testRefreshScanStopsAtTheDeadlineAndKeepsNoToken() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory)
        library.setCurrentChangeToken(Data("token-1".utf8))
        // Hashing takes far longer than the refresh may run.
        library.setBeforeRead { _ in try? await Task.sleep(for: .seconds(30)) }
        let engine = makeEngine(
            directory: directory, library: library, service: MockImmichService(), session: EngineFakeSession())

        let start = ContinuousClock.now
        let finished = await engine.runIncremental(budget: .milliseconds(300))
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(finished)
        XCTAssertLessThan(elapsed, .seconds(10), "The scan stops at the deadline")
        XCTAssertNil(engine.storedChangeToken(), "A scan that didn't get through keeps no token")
    }

    func testForegroundFullScanStoresTheTokenReadBeforeIt() async throws {
        let directory = temporaryDirectory()
        let library = FakePhotoLibrary()
        _ = photo("a", in: library)
        library.addAlbum(id: "A", title: "Recents", assetIDs: ["a"])
        try await seedIndex(in: directory)
        let before = Data("token-1".utf8)
        library.setCurrentChangeToken(before)
        // A change during the scan: the next refresh must still see it.
        library.setBeforeRead { [library] _ in library.setCurrentChangeToken(Data("token-2".utf8)) }
        let engine = makeEngine(
            directory: directory, library: library, service: MockImmichService(), session: EngineFakeSession())
        let model = await makeModel(engine: engine)

        let scanned = await model.scan()

        XCTAssertTrue(scanned)
        XCTAssertEqual(engine.storedChangeToken(), before, "The token read before the scan")
    }
}

/// Counts reads in progress; the first one is held until `release()`.
private actor OverlapProbe {
    private(set) var most = 0
    private var active = 0
    private var held = false
    private var released = false
    private var holders: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        active += 1
        most = max(most, active)
        if !held {
            held = true
            for watcher in watchers { watcher.resume() }
            watchers = []
            if !released { await withCheckedContinuation { holders.append($0) } }
        }
        active -= 1
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func release() {
        released = true
        for holder in holders { holder.resume() }
        holders = []
    }
}

/// Reports `.wifi` at once and never changes.
private struct WiFiNetwork: NetworkConditions {
    var isOnCellular: Bool { get async { false } }
    var isConnected: Bool { get async { true } }
    func changes() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            continuation.yield(NetworkPath(isConnected: true, isOnCellular: false))
            continuation.finish()
        }
    }
}

/// The fake sessions a test registry hands its engines, one per identifier.
private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: EngineFakeSession] = [:]

    func session(for identifier: String) -> EngineFakeSession {
        lock.withLock {
            if let session = sessions[identifier] { return session }
            let made = EngineFakeSession()
            sessions[identifier] = made
            return made
        }
    }

    var count: Int { lock.withLock { sessions.count } }
}

private final class EngineFakeTask: UploadTaskHandle, @unchecked Sendable {
    let taskIdentifier: Int
    let originalRequest: URLRequest?
    private let lock = NSLock()
    private var storedDescription: String?
    private var storedResponse: URLResponse?

    init(id: Int, description: String?, request: URLRequest?) {
        taskIdentifier = id
        storedDescription = description
        originalRequest = request
    }

    var taskDescription: String? {
        get { lock.withLock { storedDescription } }
        set { lock.withLock { storedDescription = newValue } }
    }

    var response: URLResponse? {
        get { lock.withLock { storedResponse } }
        set { lock.withLock { storedResponse = newValue } }
    }

    var currentRequest: URLRequest? { originalRequest }
    func resume() {}
    func cancel() {}
}

/// Stands in for a background `URLSession`: hands out tasks that never finish on their own.
private final class EngineFakeSession: UploadSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [EngineFakeTask] = []
    private var made: [EngineFakeTask] = []
    private var invalidated = false
    private var nextID = 100

    var created: [EngineFakeTask] { lock.withLock { made } }
    var isInvalidated: Bool { lock.withLock { invalidated } }

    /// Tasks iOS has for this session from before the launch.
    func report(_ tasks: [EngineFakeTask]) { lock.withLock { live.append(contentsOf: tasks) } }

    func uploadTask(with request: URLRequest, fromFile file: URL) -> any UploadTaskHandle {
        lock.withLock {
            nextID += 1
            let task = EngineFakeTask(id: nextID, description: nil, request: request)
            made.append(task)
            live.append(task)
            return task
        }
    }

    func allTasks() async -> [any UploadTaskHandle] { lock.withLock { live } }

    func invalidateAndCancel() { lock.withLock { invalidated = true } }
}
