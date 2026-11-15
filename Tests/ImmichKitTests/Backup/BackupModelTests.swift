import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImmichKit
@testable import ImmichUI

private struct FixedNetwork: NetworkConditions {
    let isOnCellular: Bool
    /// Doesn't observe the network: the stream ends at once.
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}

private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: FakeTransport?
    var value: FakeTransport? { lock.withLock { transport } }
    func set(_ transport: FakeTransport) { lock.withLock { self.transport = transport } }
}

@MainActor
final class BackupModelTests: XCTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        Localization.languageOverride = "en"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        for url in directories { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        directories = []
        suites = []
        super.tearDown()
    }

    // MARK: Helpers

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupModelTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BackupModelTests-\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func addAsset(_ id: String, to library: FakePhotoLibrary) {
        let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
        library.setData([Data("content of \(id)".utf8)], for: resource)
        library.addAsset(DeviceAsset(
            id: id, isVideo: false, creationDate: Self.date, modificationDate: Self.date,
            isFavorite: false, duration: 0, resources: [resource]))
    }

    /// Recents holds a1...a`count`; "Holiday" holds a1 and a2.
    private func makeLibrary(count: Int = 4, access: PhotoAccess = .full) -> FakePhotoLibrary {
        let library = FakePhotoLibrary(access: access)
        let ids = (1...count).map { "a\($0)" }
        for id in ids { addAsset(id, to: library) }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        library.addAlbum(id: "holiday", title: "Holiday", assetIDs: ["a1", "a2"])
        return library
    }

    private func makeModel(
        _ library: FakePhotoLibrary,
        service: MockImmichService = MockImmichService(library: MockLibrary(assetCount: 1, years: 1)),
        directory: URL? = nil,
        defaults: UserDefaults? = nil,
        cellular: Bool = false
    ) -> BackupModel {
        BackupModel(
            source: library, service: service, directory: directory ?? makeDirectory(),
            network: FixedNetwork(isOnCellular: cellular), defaults: defaults ?? makeDefaults())
    }

    /// Checksum requests, not counting the one-item probe that a scan reading photos sends first.
    private func checkRequests(_ service: MockImmichService) async -> Int {
        let all = await service.requests.filter {
            if case .bulkUploadCheck = $0 { return true } else { return false }
        }.count
        return max(0, all - 1)
    }

    private var recents: DeviceAlbum { DeviceAlbum(id: "recents", title: "Recents", count: 4) }

    // MARK: Tests

    func testScanPublishesCounts() async {
        let library = makeLibrary(count: 4)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        // Nothing is on the server yet, so everything still needs uploading.
        XCTAssertEqual(model.counts.total, 4)
        XCTAssertEqual(model.counts.backedUp, 0)
        XCTAssertEqual(model.remaining, 4)
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.progress)
        XCTAssertNil(model.error)
    }

    func testScanCountsPhotosAlreadyOnTheServer() async {
        let library = makeLibrary(count: 3)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        var sha = SHA1Stream()
        sha.update(Data("content of a1".utf8))
        await service.setServerChecksums([sha.base64()])
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(model.counts.total, 3)
        XCTAssertEqual(model.counts.backedUp, 1)
        XCTAssertEqual(model.remaining, 2)
    }

    func testCheckNowScansTheSavedSelection() async {
        let library = makeLibrary(count: 3)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.setSelection(BackupSelection(included: ["recents"]))
        try? await index.save()

        let model = makeModel(library, service: service, directory: directory)
        await model.load()
        XCTAssertEqual(model.selection.included, ["recents"])
        XCTAssertEqual(model.albums.map(\.title), ["Recents", "Holiday"])
        XCTAssertEqual(model.counts.total, 3)
        let before = await checkRequests(service)
        XCTAssertEqual(before, 0, "opening the screen doesn't talk to the server")

        await model.scan()
        let after = await checkRequests(service)
        XCTAssertEqual(after, 1)
        XCTAssertEqual(model.remaining, 3)
    }

    func testSelectionChangePersistsAndTriggersARescan() async {
        let library = makeLibrary(count: 4)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let directory = makeDirectory()
        let model = makeModel(library, service: service, directory: directory)
        await model.load()

        model.cycle(recents)
        XCTAssertEqual(model.state(of: recents), .included, "the choice shows at once")
        await model.settle()
        XCTAssertEqual(model.counts.total, 4)
        let first = await checkRequests(service)
        XCTAssertEqual(first, 1)

        // A fresh index on the same directory sees the saved selection.
        let reopened = BackupIndex(directory: directory)
        let saved = await reopened.selection()
        XCTAssertEqual(saved, BackupSelection(included: ["recents"]))

        model.cycle(DeviceAlbum(id: "holiday", title: "Holiday", count: 2))
        model.cycle(DeviceAlbum(id: "holiday", title: "Holiday", count: 2)) // now excluded
        await model.settle()
        XCTAssertEqual(model.selection, BackupSelection(included: ["recents"], excluded: ["holiday"]))
        XCTAssertEqual(model.counts.total, 2, "a1 and a2 are excluded")
        let saved2 = await BackupIndex(directory: directory).selection()
        XCTAssertEqual(saved2, model.selection)
    }

    func testCyclingGoesIncludedExcludedNeither() {
        let model = makeModel(makeLibrary())
        XCTAssertEqual(model.state(of: recents), .neither)
        model.cycle(recents)
        XCTAssertEqual(model.state(of: recents), .included)
        model.cycle(recents)
        XCTAssertEqual(model.state(of: recents), .excluded)
        model.cycle(recents)
        XCTAssertEqual(model.state(of: recents), .neither)
    }

    func testDeniedAccessShowsDeniedAndDoesNotScan() async {
        let library = makeLibrary(access: .denied)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let model = makeModel(library, service: service)
        await model.load()
        XCTAssertEqual(model.access, .denied)
        XCTAssertTrue(model.albums.isEmpty)
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.scan()
        await model.settle()
        XCTAssertEqual(model.access, .denied)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.counts, BackupCounts())
        XCTAssertEqual(library.batchLookups, [])
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, 0)
    }

    func testFirstLoadAsksForAccessAndScansWhenGranted() async {
        let library = makeLibrary(access: .notDetermined)
        let model = makeModel(library)
        await model.load()
        XCTAssertEqual(library.authorizationRequests, 1)
        XCTAssertEqual(model.access, .full)
        XCTAssertEqual(model.albums.map(\.title), ["Recents", "Holiday"])
        model.setSelection(BackupSelection(included: ["recents"]))
        XCTAssertTrue(model.canCheck)
        await model.settle()
        XCTAssertEqual(model.counts.total, 4)
    }

    func testFirstLoadAsksForAccessAndDoesNotScanWhenDenied() async {
        let library = makeLibrary(access: .notDetermined)
        library.setAccessAfterRequest(.denied)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let model = makeModel(library, service: service)
        await model.load()
        XCTAssertEqual(library.authorizationRequests, 1)
        XCTAssertEqual(model.access, .denied)
        XCTAssertTrue(model.albums.isEmpty)
        model.setSelection(BackupSelection(included: ["recents"]))
        XCTAssertFalse(model.canCheck)
        await model.scan()
        await model.settle()
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.counts, BackupCounts())
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, 0)
    }

    func testAnUndecidedAccessNeverScans() async {
        // The request leaves the answer open (as when the prompt is dismissed some other way).
        let library = makeLibrary(access: .notDetermined)
        library.setAccessAfterRequest(.notDetermined)
        let model = makeModel(library)
        await model.load()
        XCTAssertEqual(model.access, .notDetermined)
        model.setSelection(BackupSelection(included: ["recents"]))
        XCTAssertFalse(model.canCheck)
        await model.scan()
        await model.settle()
        XCTAssertEqual(model.counts, BackupCounts())
        XCTAssertEqual(library.batchLookups, [])
    }

    func testAlreadyGrantedAccessIsNotAskedAgain() async {
        let library = makeLibrary(access: .full)
        let model = makeModel(library)
        await model.load()
        await model.load()
        XCTAssertEqual(library.authorizationRequests, 0)
        XCTAssertEqual(model.access, .full)
    }

    func testTheNewestChoiceIsTheOneSavedWhenChoicesComeInQuickly() async {
        let library = makeLibrary(count: 4)
        let directory = makeDirectory()
        let model = makeModel(library, directory: directory)
        // Both land while the index is still loading.
        model.setSelection(BackupSelection(included: ["recents"]))
        model.setSelection(BackupSelection(included: ["holiday"]))
        await model.settle()
        XCTAssertEqual(model.selection, BackupSelection(included: ["holiday"]))
        let saved = await BackupIndex(directory: directory).selection()
        XCTAssertEqual(saved, BackupSelection(included: ["holiday"]))
        XCTAssertEqual(model.counts.total, 2)
    }

    func testStopLeavesNothingSavingAfterwards() async {
        let library = makeLibrary(count: 4)
        let directory = makeDirectory()
        let model = makeModel(library, directory: directory)
        model.setSelection(BackupSelection(included: ["recents"]))
        model.setSelection(BackupSelection(included: ["holiday"]))
        await model.stop()
        // Nothing may write once stop() has returned: the directory can be removed now.
        try? FileManager.default.removeItem(at: directory)
        await model.settle()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLimitedAccessStillScans() async {
        let model = makeModel(makeLibrary(access: .limited))
        await model.load()
        XCTAssertEqual(model.access, .limited)
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(model.counts.total, 4)
    }

    func testCancelStopsTheScanAndClearsProgress() async {
        let library = makeLibrary(count: 6)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setLatency(.milliseconds(300))
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        // Let the rescan reach the scan itself.
        for _ in 0..<200 where !model.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isScanning)
        model.cancel()
        await model.settle()
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.progress)
        XCTAssertNil(model.error, "cancelling isn't an error")
        XCTAssertEqual(model.counts.backedUp, 0)
        XCTAssertEqual(model.counts.total, 6, "what was learned stays counted")
    }

    func testStopWaitsForTheScanAndPreventsNewOnes() async {
        let library = makeLibrary(count: 4)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setLatency(.milliseconds(200))
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        for _ in 0..<200 where !model.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
        await model.stop()
        XCTAssertFalse(model.isScanning)
        await model.scan()
        XCTAssertFalse(model.isScanning, "no scan starts after stop()")
    }

    func testKeyWithoutBackupPermissionShowsASpecificMessage() async {
        let library = makeLibrary(count: 3)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setFailure(.unauthorized)
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(
            model.error,
            "This API key can't check backups. Create a key with the View, Organize and Back Up permissions and sign in with it.")
        XCTAssertTrue(library.reads.isEmpty, "nothing is read before the key is known to work")
    }

    /// Owner's phone: Wi-Fi off showed a red "Couldn't check your photos: Could not reach the server".
    func testUnreachableServerShowsAStatusInsteadOfAnError() async {
        let library = makeLibrary(count: 2)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setFailure(.network("The Internet connection appears to be offline.", code: .notConnectedToInternet))
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertNil(model.error, "no connection isn't shown as an error")
        XCTAssertTrue(model.cannotReachServer)
        XCTAssertEqual(model.connectionStatus, .serverUnreachable, "With the switch off nothing waits for the network")

        // The connection is back: the next scan that succeeds clears the status.
        await service.setFailure(nil)
        let completed = await model.scan()
        XCTAssertTrue(completed)
        XCTAssertFalse(model.cannotReachServer)
        XCTAssertNil(model.connectionStatus)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.counts.total, 2)
    }

    func testOtherScanFailuresStillShowAnError() async {
        let library = makeLibrary(count: 2)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setFailure(.network("offline", code: .timedOut))
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertTrue(model.cannotReachServer)

        // Reachable now, but the server fails: the red error is back and the status goes.
        await service.setFailure(.unexpectedStatus(500))
        await model.scan()
        XCTAssertEqual(
            model.error, "Couldn't check your photos: \(ImmichServiceError.unexpectedStatus(500).localizedDescription)")
        XCTAssertFalse(model.cannotReachServer)
        XCTAssertNil(model.connectionStatus)
    }

    /// A broken TLS setup reaches the server's address but can never work: an error, not a calm status.
    func testCertificateFailureIsAnError() async {
        let library = makeLibrary(count: 2)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let failure = ImmichServiceError.network("The certificate for this server is invalid.", code: .serverCertificateUntrusted)
        await service.setFailure(failure)
        let model = makeModel(library, service: service)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(model.error, "Couldn't check your photos: \(failure.localizedDescription)")
        XCTAssertFalse(model.cannotReachServer)
    }

    func testCellularSwitchRechecksItemsWaitingForWiFi() async {
        let library = makeLibrary(count: 2)
        library.markICloudOnly(DeviceResource(type: .photo, filename: "a1.jpg"))
        let model = makeModel(library, cellular: true)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(model.counts.waitingForWiFi, 1)

        model.settings.photosOnCellular = true
        await model.settle()

        XCTAssertEqual(model.counts.waitingForWiFi, 0)
        XCTAssertEqual(model.counts.total, 2)
        XCTAssertEqual(model.remaining, 2)
    }

    func testCellularSwitchWithoutSelectionDoesNotScan() async {
        let library = makeLibrary(count: 2)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let model = makeModel(library, service: service, cellular: true)
        await model.load()
        model.settings.photosOnCellular = true
        await model.settle()
        XCTAssertTrue(library.reads.isEmpty)
        XCTAssertFalse(model.isScanning)
    }

    func testSetSelectionAfterStopWritesNothing() async {
        let directory = makeDirectory()
        let model = makeModel(makeLibrary(), directory: directory)
        await model.stop()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(model.selection, BackupSelection(), "the choice is ignored")
    }

    func testUnavailableIndexIsReopenedForTheNextScan() async throws {
        let library = makeLibrary(count: 4)
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = BackupIndex(directory: directory)
        try await writer.save()
        let file = directory.appendingPathComponent("index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path), "file is readable despite permissions (running as root)")

        let model = makeModel(library, directory: directory)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()
        XCTAssertEqual(model.error, "Bloom couldn't open its backup records. Unlock your device and try again.")

        // The device is unlocked again.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await model.scan()

        XCTAssertNil(model.error)
        XCTAssertEqual(model.counts.total, 4)
        let saved = await BackupIndex(directory: directory).selection()
        XCTAssertEqual(saved, BackupSelection(included: ["recents"]), "the choice made meanwhile is kept")
    }

    func testCellularSettingsDefaultOffAndPersist() {
        let defaults = makeDefaults()
        let model = makeModel(makeLibrary(), defaults: defaults)
        XCTAssertFalse(model.settings.photosOnCellular)
        XCTAssertFalse(model.settings.videosOnCellular)
        model.settings.photosOnCellular = true
        XCTAssertTrue(BackupSettings.load(from: defaults).photosOnCellular)
        XCTAssertFalse(BackupSettings.load(from: defaults).videosOnCellular)
    }

    func testItemsWithoutAFileAreListedAsFailed() async {
        let library = makeLibrary(count: 2)
        library.addAsset(DeviceAsset(
            id: "empty", isVideo: false, creationDate: Self.date, modificationDate: Self.date,
            isFavorite: false, duration: 0, resources: []))
        library.addAlbum(id: "odd", title: "Odd", assetIDs: ["empty"])
        let model = makeModel(library)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents", "odd"]))
        await model.settle()
        XCTAssertEqual(model.counts.failed, 1)
        XCTAssertEqual(model.failedItems.map(\.id), ["empty"])
        XCTAssertFalse(model.failedItems[0].reason.isEmpty)
    }

    func testSummaryAndSuggestion() async {
        let model = makeModel(makeLibrary())
        await model.load()
        XCTAssertEqual(model.suggestedAlbumID, "recents")
        XCTAssertEqual(model.selectionSummary, "None")
        model.setSelection(BackupSelection(included: ["recents"], excluded: ["holiday"]))
        await model.settle()
        XCTAssertNil(model.suggestedAlbumID)
        XCTAssertEqual(model.selectionSummary, "Recents · 1 excluded")
    }

    func testSavedSelectionIsShownAndEnablesCheckNow() async {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.setSelection(BackupSelection(included: ["recents"], excluded: ["holiday"]))
        try? await index.save()

        let model = makeModel(makeLibrary(), directory: directory)
        XCTAssertFalse(model.canCheck, "nothing is known before loading")
        await model.load()
        XCTAssertEqual(model.selection, BackupSelection(included: ["recents"], excluded: ["holiday"]))
        XCTAssertEqual(model.selectionSummary, "Recents · 1 excluded")
        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(model.counts.total, 2)
    }

    func testLoadingDoesNotUndoAChoiceMadeMeanwhile() async {
        let model = makeModel(makeLibrary())
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.load()
        XCTAssertEqual(model.selection.included, ["recents"])
        XCTAssertTrue(model.canCheck)
        await model.settle()
        XCTAssertEqual(model.counts.total, 4)
    }

    func testScanningThePreviewLibraryListsItsFailedItem() async {
        let model = BackupModel.preview(selected: ["recents"], excluded: ["screenshots"])
        await model.load()
        await model.scan()
        await model.settle()
        XCTAssertGreaterThan(model.counts.failed, 0)
        XCTAssertFalse(model.failedItems.isEmpty)
        XCTAssertEqual(model.failedItems.count, model.counts.failed)
        XCTAssertTrue(model.failedItems.allSatisfy { $0.date != nil }, "Each problem shows when the photo was taken")
        XCTAssertEqual(model.counts.total,
                       model.counts.backedUp + model.remaining + model.counts.deletedOnServer + model.counts.failed)
        XCTAssertEqual(model.selectionSummary, "Recents · 1 excluded")
    }
    func testLoadingOnlyListsFailuresForUnchangedExistingAssets() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let library = FakePhotoLibrary()
        for id in ["current", "edited", "removed"] {
            await index.set(BackupEntry(modificationDate: Self.date, checksums: [:],
                                        state: .failed(reason: "Old read failure")), for: id)
            if id != "removed" {
                let date = id == "edited" ? Self.date.addingTimeInterval(60) : Self.date
                library.addAsset(DeviceAsset(
                    id: id, isVideo: false, creationDate: Self.date, modificationDate: date,
                    isFavorite: false, duration: 0,
                    resources: [DeviceResource(type: .photo, filename: "\(id).jpg")]))
            }
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: ["current", "edited", "removed"])
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(library, directory: directory)
        await model.load()

        XCTAssertEqual(model.counts.total, 2, "Missing assets are not counted")
        XCTAssertEqual(model.counts.pending, 1, "An edited asset needs a new check")
        XCTAssertEqual(model.counts.failed, 1)
        XCTAssertEqual(model.failedItems.map(\.id), ["current"],
                       "Old failures for edited or missing assets must not appear")
        XCTAssertEqual(model.failedItems.first?.reason, "Old read failure")
        XCTAssertTrue(library.reads.isEmpty, "Opening the list must not read photo files")
        await model.stop()
    }

    /// The model's one pass over the selection must count exactly as the scanner does, for every state.
    func testOnePassCountsMatchTheScannersCounts() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let library = FakePhotoLibrary()
        let states: [String: BackupState] = [
            "backed": .backedUp(serverAssetID: "s1"),
            "queued": .pending(reason: .needsUpload),
            "wifi": .pending(reason: .waitingForWiFi),
            "unchecked": .pending(reason: .notChecked),
            "failed": .failed(reason: "Broken"),
            "deleted": .deletedOnServer(trashed: [.photo], gone: []),
            "stale": .backedUp(serverAssetID: "s2"),
            "gone": .backedUp(serverAssetID: "s3"),
        ]
        for (id, state) in states {
            await index.set(BackupEntry(modificationDate: Self.date, checksums: [.photo: id], state: state), for: id)
        }
        var ids = Array(states.keys) + ["new"]
        ids.removeAll { $0 == "gone" }
        for id in ids {
            let modified = id == "stale" ? Self.date.addingTimeInterval(60) : Self.date
            library.addAsset(DeviceAsset(
                id: id, isVideo: false, creationDate: Self.date, modificationDate: modified,
                isFavorite: false, duration: 0, resources: [DeviceResource(type: .photo, filename: "\(id).jpg")]))
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids + ["gone"]))
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(library, directory: directory)
        await model.load()

        let scanner = BackupScanner(
            source: library, service: MockImmichService(), index: BackupIndex(directory: directory),
            network: FixedNetwork(isOnCellular: false), settings: BackupSettings())
        let expected = await scanner.counts()
        XCTAssertEqual(model.counts, expected)
        XCTAssertEqual(expected, BackupCounts(total: 8, backedUp: 1, pending: 5, failed: 1, deletedOnServer: 1, waitingForWiFi: 1))
        XCTAssertEqual(model.failedItems.map(\.id), ["failed"])
        XCTAssertEqual(model.deletedItems.map(\.id), ["deleted"])
        XCTAssertEqual(Set(model.remainingItems.map(\.id)), ["queued", "wifi", "unchecked", "stale", "new"])
        await model.stop()
    }

    // MARK: Uploads, Deleted on Server, Try Again

    /// An index holding `states` for assets of the fake library, with Recents saved as the selection.
    private func seededDirectory(
        _ states: [String: BackupState], serverIDs: [String: [DeviceResourceType: String]] = [:]
    ) async throws -> URL {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for (id, state) in states {
            await index.set(
                BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-\(id)"], state: state,
                            serverIDs: serverIDs[id] ?? [:]),
                for: id)
        }
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        return directory
    }

    private func trashedAssets(_ ids: [String]) -> [Asset] {
        ids.map { Asset(id: "srv-\($0)", kind: .image, takenAt: Self.date, isTrashed: true) }
    }

    func testCountsRowAddsUpWithDeletedOnServer() async throws {
        let library = makeLibrary(count: 6)
        let directory = try await seededDirectory([
            "a1": .backedUp(serverAssetID: "s1"),
            "a2": .pending(reason: .needsUpload),
            "a3": .failed(reason: "Couldn't read a3.jpg"),
            "a4": .deletedOnServer(trashed: [.photo], gone: []),
            "a5": .deletedOnServer(trashed: [], gone: [.photo]),
            "a6": .deletedOnServer(trashed: [.photo], gone: [.pairedVideo]),
        ])
        let model = makeModel(library, directory: directory)
        await model.load()

        let counts = model.counts
        XCTAssertEqual(counts.deletedOnServer, 3)
        XCTAssertEqual(counts.total, counts.backedUp + model.remaining + counts.deletedOnServer + counts.failed)
        XCTAssertEqual(counts.total, 6)
        XCTAssertEqual(model.deletedItems.count, counts.deletedOnServer)
        XCTAssertEqual(Set(model.deletedItems.map(\.id)), ["a4", "a5", "a6"])
        let byID = Dictionary(uniqueKeysWithValues: model.deletedItems.map { ($0.id, $0) })
        XCTAssertEqual(byID["a4"]?.isTrashed, true, "Every missing half is in the trash")
        XCTAssertEqual(byID["a5"]?.isTrashed, false)
        XCTAssertEqual(byID["a6"]?.isTrashed, false, "One half is gone for good")
        XCTAssertEqual(byID["a4"]?.date, Self.date)
        await model.stop()
    }

    /// A 2x2 PNG.
    private func pngData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testThumbnailsAreDecodedOnDemandAndMissesRemembered() async throws {
        let library = makeLibrary(count: 2)
        library.thumbnails = ["a1": try pngData()]
        let model = makeModel(library)
        await model.load()

        let first = await model.thumbnail(for: "a1")
        XCTAssertEqual(first?.width, 2)
        // Served from the cache: the photo library isn't asked again.
        library.thumbnails = [:]
        let again = await model.thumbnail(for: "a1")
        XCTAssertNotNil(again)

        let missing = await model.thumbnail(for: "a2")
        XCTAssertNil(missing)
        library.thumbnails = ["a2": try pngData()]
        let stillMissing = await model.thumbnail(for: "a2")
        XCTAssertNil(stillMissing, "A photo without a thumbnail isn't asked for again")
        await model.stop()
    }

    func testLoadingDoesNotFetchThumbnails() async throws {
        let library = makeLibrary(count: 2)
        library.thumbnails = ["a1": try pngData()]
        let directory = try await seededDirectory(["a1": .deletedOnServer(trashed: [.photo], gone: [])])
        let model = makeModel(library, directory: directory)
        await model.load()
        XCTAssertEqual(model.deletedItems.map(\.id), ["a1"])
        // Thumbnails come per row: nothing was cached by loading, so a later change shows up.
        library.thumbnails = [:]
        let thumbnail = await model.thumbnail(for: "a1")
        XCTAssertNil(thumbnail)
        await model.stop()
    }

    func testDeletedListKeepsTheNewestWhenOverTheLimit() async throws {
        let count = BackupModel.deletedItemLimit + 3
        let ids = (1...count).map { "a\($0)" }
        let library = FakePhotoLibrary()
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for (offset, id) in ids.enumerated() {
            // a1 is the oldest, the last the newest.
            let date = Self.date.addingTimeInterval(TimeInterval(offset))
            let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
            library.addAsset(DeviceAsset(
                id: id, isVideo: false, creationDate: date, modificationDate: date,
                isFavorite: false, duration: 0, resources: [resource]))
            await index.set(
                BackupEntry(modificationDate: date, checksums: [.photo: "sum-\(id)"],
                            state: .deletedOnServer(trashed: [], gone: [.photo])),
                for: id)
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(library, directory: directory)
        await model.load()

        XCTAssertEqual(model.counts.deletedOnServer, count)
        XCTAssertEqual(model.deletedItems.count, BackupModel.deletedItemLimit)
        XCTAssertEqual(model.deletedItems.first?.id, "a\(count)", "Newest first")
        XCTAssertFalse(model.deletedItems.contains { ["a1", "a2", "a3"].contains($0.id) }, "The oldest are cut")
        await model.stop()
    }

    func testDeletedListIsLimitedButReuploadAllCoversEveryItem() async throws {
        let count = BackupModel.deletedItemLimit + 5
        let ids = (1...count).map { "a\($0)" }
        let library = makeLibrary(count: count)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setAssets(trashedAssets(ids))
        let directory = try await seededDirectory(
            Dictionary(uniqueKeysWithValues: ids.map { ($0, .deletedOnServer(trashed: [.photo], gone: [])) }),
            serverIDs: Dictionary(uniqueKeysWithValues: ids.map { ($0, [.photo: "srv-\($0)"]) }))
        let model = makeModel(library, service: service, directory: directory)
        await model.load()
        XCTAssertEqual(model.counts.deletedOnServer, count)
        XCTAssertEqual(model.deletedItems.count, BackupModel.deletedItemLimit)

        await model.reuploadAll()

        let restored = await service.requests.filter { if case .restoreAssets = $0 { true } else { false } }
        XCTAssertEqual(Set(restored), Set(ids.map { .restoreAssets("srv-\($0)") }),
                       "Re-upload All is not limited to the items on screen")
        XCTAssertEqual(model.counts.deletedOnServer, 0)
        XCTAssertEqual(model.counts.backedUp, count)
        XCTAssertTrue(model.deletedItems.isEmpty)
        XCTAssertNil(model.error)
        await model.stop()
    }

    func testReuploadRestoresOnlyTheChosenItems() async throws {
        let library = makeLibrary(count: 3)
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await service.setAssets(trashedAssets(["a1", "a2", "a3"]))
        let state = BackupState.deletedOnServer(trashed: [.photo], gone: [])
        let directory = try await seededDirectory(
            ["a1": state, "a2": state, "a3": state],
            serverIDs: ["a1": [.photo: "srv-a1"], "a2": [.photo: "srv-a2"], "a3": [.photo: "srv-a3"]])
        let model = makeModel(library, service: service, directory: directory)
        await model.load()

        await model.reupload(["a2"])

        let restored = await service.requests.filter { if case .restoreAssets = $0 { true } else { false } }
        XCTAssertEqual(restored, [.restoreAssets("srv-a2")])
        XCTAssertEqual(Set(model.deletedItems.map(\.id)), ["a1", "a3"])
        XCTAssertEqual(model.counts.backedUp, 1)
        await model.stop()
    }

    func testReuploadWithAllowChangesOffAsksToTurnItOn() async throws {
        let library = makeLibrary(count: 1)
        let mock = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        await mock.setAssets(trashedAssets(["a1"]))
        let service = EditGuardedService(base: mock, permission: EditingPermission(isAllowed: false))
        let directory = try await seededDirectory(
            ["a1": .deletedOnServer(trashed: [.photo], gone: [])], serverIDs: ["a1": [.photo: "srv-a1"]])
        let model = BackupModel(
            source: library, service: service, directory: directory,
            network: FixedNetwork(isOnCellular: false), defaults: makeDefaults())
        await model.load()

        await model.reuploadAll()

        XCTAssertEqual(model.error, "Turn on Allow Changes in the account menu to restore photos from the server's trash.")
        XCTAssertEqual(model.counts.deletedOnServer, 1, "Nothing was restored")
        await model.stop()
    }

    func testReuploadCancelledByStopShowsNoError() async throws {
        let library = makeLibrary(count: 1)
        let directory = try await seededDirectory(
            ["a1": .deletedOnServer(trashed: [.photo], gone: [])], serverIDs: ["a1": [.photo: "srv-a1"]])
        let model = makeModel(library, directory: directory)
        await model.load()
        await model.stop()

        await model.reuploadAll()

        XCTAssertNil(model.error)
    }

    func testRetryAllRequeuesFailedItems() async throws {
        let count = BackupModel.failedItemLimit + 3
        let ids = (1...count).map { "a\($0)" }
        let library = makeLibrary(count: count)
        let directory = try await seededDirectory(
            Dictionary(uniqueKeysWithValues: ids.map { ($0, .failed(reason: "Couldn't read \($0).jpg")) }))
        let model = makeModel(library, directory: directory)
        await model.load()
        XCTAssertEqual(model.counts.failed, count)
        XCTAssertEqual(model.failedItems.count, BackupModel.failedItemLimit)

        await model.retryAll()

        XCTAssertEqual(model.counts.failed, 0, "Try All Again is not limited to the items on screen")
        XCTAssertEqual(model.remaining, count)
        XCTAssertTrue(model.failedItems.isEmpty)
        let saved = BackupIndex(directory: directory)
        for id in ids {
            let state = await saved.entry(for: id)?.state
            XCTAssertEqual(state, .pending(reason: .notChecked), id)
        }
        await model.stop()
    }

    func testRetryRequeuesOnlyTheChosenItem() async throws {
        let library = makeLibrary(count: 2)
        let directory = try await seededDirectory(["a1": .failed(reason: "x"), "a2": .failed(reason: "y")])
        let model = makeModel(library, directory: directory)
        await model.load()

        await model.retry(["a2"])

        XCTAssertEqual(model.failedItems.map(\.id), ["a1"])
        XCTAssertEqual(model.counts.failed, 1)
        XCTAssertEqual(model.remaining, 1)
        await model.stop()
    }

    func testTurningOnWithoutAlbumsAsksForAlbums() async {
        let model = makeModel(makeLibrary())
        await model.load()
        XCTAssertFalse(model.needsAlbumChoice)

        model.setBackupEnabled(true)

        XCTAssertTrue(model.settings.isEnabled, "The switch is on; choosing an album starts the first run")
        XCTAssertTrue(model.needsAlbumChoice)
        await model.stop()
    }

    func testTurningOnWithAnAlbumDoesNotAskForAlbums() async {
        let model = makeModel(makeLibrary())
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await model.settle()

        model.setBackupEnabled(true)

        XCTAssertTrue(model.settings.isEnabled)
        XCTAssertFalse(model.needsAlbumChoice)
        await model.stop()
    }

    func testTurningOffNeverAsksForAlbums() async {
        let model = makeModel(makeLibrary())
        await model.load()
        model.setBackupEnabled(false)
        XCTAssertFalse(model.needsAlbumChoice)
        await model.stop()
    }

    func testSwitchPersists() async {
        let defaults = makeDefaults()
        let model = makeModel(makeLibrary(), defaults: defaults)
        XCTAssertFalse(model.settings.isEnabled)
        model.setBackupEnabled(true)
        XCTAssertTrue(BackupSettings.load(from: defaults).isEnabled)
        model.setBackupEnabled(false)
        XCTAssertFalse(BackupSettings.load(from: defaults).isEnabled)
        model.setBackupEnabled(true)
        let reopened = makeModel(makeLibrary(), defaults: defaults)
        XCTAssertTrue(reopened.settings.isEnabled)
        await model.stop()
        await reopened.stop()
    }

    // MARK: Background status

    /// A model with an upload connection on a fake transport (jobs wait until finished), on a directory whose
    /// index was seeded with `jobs` and their entries.
    private func makeUploadModel(
        jobs: [UploadJob] = [], now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> (model: BackupModel, transport: FakeTransport, recorder: BackupResultRecorder, directory: URL) {
        let directory = makeDirectory()
        let seeded = BackupIndex(directory: directory)
        for job in jobs {
            await seeded.set(
                BackupEntry(modificationDate: Self.date, checksums: [job.resource: job.checksum], state: .pending(reason: .needsUpload)),
                for: job.assetID)
            await seeded.addJob(job)
        }
        try await seeded.save()
        let box = TransportBox()
        let uploads = BackupModel.Uploads(requests: .test) { index, staging, recorder in
            let made = FakeTransport(
                index: index, staging: staging, recorder: recorder, service: MockImmichService(), mode: .manual)
            box.set(made)
            return made
        }
        let model = BackupModel(
            source: makeLibrary(), service: MockImmichService(), directory: directory,
            network: FixedNetwork(isOnCellular: false), defaults: makeDefaults(), uploads: uploads)
        let clock = BackupRetryClock(now: { ContinuousClock.now }, sleep: { _ in }, date: { now })
        let made = await model.uploadConnection(clock: clock)
        let connection = try XCTUnwrap(made)
        return (model, try XCTUnwrap(box.value), connection.recorder, directory)
    }

    private func makeJob(_ asset: String) -> UploadJob {
        UploadJob(assetID: asset, resource: .photo, attempt: UUID(), bodyFileName: "\(UUID().uuidString).multipart", checksum: "aa")
    }

    // MARK: Remaining list

    func testRemainingListShowsEachStateAndMarksInFlight() async throws {
        let retryAt = Date().addingTimeInterval(600)
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let entries: [(String, BackupState, BackupRetryState?)] = [
            ("a1", .pending(reason: .needsUpload), nil),
            ("a2", .pending(reason: .waitingForWiFi), nil),
            ("a3", .pending(reason: .notChecked), nil),
            ("a4", .pending(reason: .needsUpload), BackupRetryState(
                failures: 5, notBefore: retryAt, wasOffline: false, holdsRun: false, lastError: "The server is busy")),
            ("a5", .pending(reason: .needsUpload), nil),
            ("a6", .backedUp(serverAssetID: "s6"), nil),
            ("a7", .pending(reason: .needsUpload), BackupRetryState(failures: 1, notBefore: Date().addingTimeInterval(-60), wasOffline: false, holdsRun: false)),
        ]
        for (id, state, retry) in entries {
            await index.set(
                BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-\(id)"], state: state, retry: retry), for: id)
        }
        await index.setSelection(BackupSelection(included: ["recents"]))
        let job = makeJob("a5")
        await index.addJob(job)
        try await index.save()
        let box = TransportBox()
        let uploads = BackupModel.Uploads(requests: .test) { index, staging, recorder in
            let made = FakeTransport(index: index, staging: staging, recorder: recorder, service: MockImmichService(), mode: .manual)
            box.set(made)
            return made
        }
        let model = BackupModel(
            source: makeLibrary(count: 7), service: MockImmichService(), directory: directory,
            network: FixedNetwork(isOnCellular: false), defaults: makeDefaults(), uploads: uploads)
        await model.load()
        XCTAssertEqual(model.remainingItems.count, 6, "Everything not on the server and not failed")
        XCTAssertFalse(model.remainingItems.contains { $0.id == "a6" })
        XCTAssertEqual(model.remainingItems.first { $0.id == "a5" }?.status, .waiting, "Not in flight until the status is read")

        await model.refreshBackgroundStatus()

        let byID = Dictionary(uniqueKeysWithValues: model.remainingItems.map { ($0.id, $0.status) })
        XCTAssertEqual(byID["a1"], .waiting)
        XCTAssertEqual(byID["a2"], .waitingForWiFi)
        XCTAssertEqual(byID["a3"], .notChecked)
        XCTAssertEqual(byID["a4"], .retrying(at: retryAt, failures: 5, reason: "The server is busy"))
        XCTAssertEqual(byID["a5"], .uploading)
        XCTAssertEqual(byID["a7"], .waiting, "A retry time that has passed no longer counts")
        await model.stop()
    }

    func testRemainingListIsNewestFirstAndLimited() async throws {
        let count = BackupModel.remainingItemLimit + 3
        let ids = (1...count).map { "a\($0)" }
        let library = FakePhotoLibrary()
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for (offset, id) in ids.enumerated() {
            let date = Self.date.addingTimeInterval(TimeInterval(offset))
            let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
            library.addAsset(DeviceAsset(
                id: id, isVideo: false, creationDate: date, modificationDate: date,
                isFavorite: false, duration: 0, resources: [resource]))
            await index.set(
                BackupEntry(modificationDate: date, checksums: [.photo: "sum-\(id)"], state: .pending(reason: .needsUpload)),
                for: id)
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(library, directory: directory)
        await model.load()

        XCTAssertEqual(model.counts.pending, count)
        XCTAssertEqual(model.remainingItems.count, BackupModel.remainingItemLimit)
        XCTAssertEqual(model.remainingTotal, count, "The total is of everything, so the footer shows")
        XCTAssertEqual(model.remainingItems.first?.id, "a\(count)", "Newest first")
        XCTAssertEqual(model.remainingItems.map(\.date), model.remainingItems.map(\.date).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
        XCTAssertFalse(model.remainingItems.contains { ["a1", "a2", "a3"].contains($0.id) }, "The oldest are cut")
        await model.stop()
    }

    /// `counts()` treats an asset with no entry, or a stale one, as not checked yet: so must the list.
    func testRemainingListIncludesUncheckedAndStaleItemsAsNotChecked() async throws {
        let library = makeLibrary(count: 4)
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        // a1 has no entry at all; a2's entry is older than the photo; a3 is queued; a4 is on the server.
        await index.set(
            BackupEntry(modificationDate: Self.date.addingTimeInterval(-100), checksums: [.photo: "old"], state: .backedUp(serverAssetID: "s2")),
            for: "a2")
        await index.set(
            BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-a3"], state: .pending(reason: .needsUpload)), for: "a3")
        await index.set(
            BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-a4"], state: .backedUp(serverAssetID: "s4")), for: "a4")
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(library, directory: directory)
        await model.load()

        XCTAssertEqual(model.remaining, 3)
        let byID = Dictionary(uniqueKeysWithValues: model.remainingItems.map { ($0.id, $0.status) })
        XCTAssertEqual(Set(byID.keys), ["a1", "a2", "a3"])
        XCTAssertEqual(byID["a1"], .notChecked)
        XCTAssertEqual(byID["a2"], .notChecked)
        XCTAssertEqual(byID["a3"], .waiting)
        XCTAssertEqual(model.remainingTotal, model.remainingItems.count, "Everything is listed, so no footer")
        XCTAssertEqual(model.remainingTotal, model.counts.pending)
        await model.stop()
    }

    func testRemainingTotalCountsItemsWithoutAnEntry() async throws {
        let library = makeLibrary(count: 5)
        let model = makeModel(library, directory: try await seededDirectory([:]))
        await model.load()
        XCTAssertEqual(model.remainingTotal, 5, "All unchecked")
        XCTAssertEqual(model.remainingItems.count, 5)
        await model.stop()
    }

    func testUploadFractionsAreByAssetAndCombineLivePhotoHalves() {
        func job(_ asset: String, _ resource: DeviceResourceType) -> UploadJob {
            UploadJob(assetID: asset, resource: resource, attempt: UUID(), bodyFileName: "x", checksum: "aa")
        }
        let photo = job("live", .photo), video = job("live", .pairedVideo)
        let plain = job("plain", .photo), quiet = job("quiet", .photo)
        let half = job("half", .photo), otherHalf = job("half", .pairedVideo)
        let stale = UUID()
        let progress: [UUID: UploadBytes] = [
            photo.attempt: UploadBytes(sent: 100, expected: 100),
            video.attempt: UploadBytes(sent: 100, expected: 300),
            plain.attempt: UploadBytes(sent: 1, expected: 4),
            half.attempt: UploadBytes(sent: 50, expected: 100),
            stale: UploadBytes(sent: 1, expected: 2),
        ]
        let fractions = BackupModel.uploadFractions(jobs: [photo, video, plain, quiet, half, otherHalf], progress: progress)

        XCTAssertEqual(fractions.count, 3, "One per asset; an asset without progress yet has none (indeterminate)")
        XCTAssertEqual(fractions["live"]!, 0.5, accuracy: 0.0001, "Both halves of a Live Photo by bytes: 200 of 400")
        XCTAssertEqual(fractions["plain"]!, 0.25, accuracy: 0.0001)
        XCTAssertEqual(fractions["half"]!, 0.25, accuracy: 0.0001, "A half not started yet counts as nothing sent")
        XCTAssertNil(fractions["quiet"])
    }

    func testRetryReasonSaysNoConnectionElseTheLastError() {
        let at = Date()
        XCTAssertEqual(BackupModel.retryReason(BackupRetryState(
            failures: 2, notBefore: at, wasOffline: true, holdsRun: true, lastError: "timed out")), "No connection to the server.")
        XCTAssertEqual(BackupModel.retryReason(BackupRetryState(
            failures: 2, notBefore: at, wasOffline: false, holdsRun: false, lastError: "Bad gateway")), "Bad gateway")
        XCTAssertNil(BackupModel.retryReason(BackupRetryState(failures: 1, notBefore: at, wasOffline: false, holdsRun: false)))
    }

    func testRetryLineCountsFailuresAndNamesTheDayWhenNotToday() {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(RemainingItemRow.retryLine(at: now.addingTimeInterval(60), failures: 1, now: now).hasPrefix("Trying again at "))
        XCTAssertTrue(RemainingItemRow.retryLine(at: now.addingTimeInterval(60), failures: 5, now: now).hasPrefix("Failed 5 times · trying again at "))
        let tomorrow = RemainingItemRow.retryLine(at: now.addingTimeInterval(86_400), failures: 5, now: now)
        let weekday = now.addingTimeInterval(86_400).formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en")))
        XCTAssertTrue(tomorrow.contains(weekday), tomorrow)
    }

    func testRemainingSectionsGroupByStateInOrderNewestFirst() {
        let retryAt = Date().addingTimeInterval(600)
        func item(_ id: String, _ offset: TimeInterval?, _ status: BackupModel.RemainingItem.Status) -> BackupModel.RemainingItem {
            BackupModel.RemainingItem(id: id, date: offset.map { Self.date.addingTimeInterval($0) }, status: status)
        }
        let items = [
            item("n1", 1, .notChecked), item("w1", 2, .waiting), item("u1", 3, .uploading), item("r1", 4, .retrying(at: retryAt, failures: 1, reason: nil)),
            item("f1", 5, .waitingForWiFi), item("w2", 9, .waiting), item("w3", nil, .waiting),
        ]
        let sections = BackupModel.remainingSections(items)

        XCTAssertEqual(sections.map(\.kind), [.uploading, .waiting, .waitingForWiFi, .retrying, .notChecked])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["u1"], ["w2", "w1", "w3"], ["f1"], ["r1"], ["n1"]])
        XCTAssertTrue(BackupModel.remainingSections([item("w1", 1, .waiting)]).allSatisfy { !$0.items.isEmpty }, "Empty sections are left out")
    }

    func testRemainingCapNeverCutsInFlightItemsAndProgressIsByAsset() async throws {
        let count = BackupModel.remainingItemLimit + 3
        let ids = (1...count).map { "a\($0)" }
        let library = FakePhotoLibrary()
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for (offset, id) in ids.enumerated() {
            let date = Self.date.addingTimeInterval(TimeInterval(offset))
            let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
            library.addAsset(DeviceAsset(
                id: id, isVideo: false, creationDate: date, modificationDate: date,
                isFavorite: false, duration: 0, resources: [resource]))
            await index.set(
                BackupEntry(modificationDate: date, checksums: [.photo: "sum-\(id)"], state: .pending(reason: .needsUpload)),
                for: id)
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: Set(ids))
        await index.setSelection(BackupSelection(included: ["recents"]))
        // The oldest item, which the cut would drop, is uploading: both halves of a Live Photo.
        let photo = makeJob("a1")
        let video = UploadJob(assetID: "a1", resource: .pairedVideo, attempt: UUID(), bodyFileName: "v.multipart", checksum: "bb")
        await index.addJob(photo)
        await index.addJob(video)
        try await index.save()
        let box = TransportBox()
        let uploads = BackupModel.Uploads(requests: .test) { index, staging, recorder in
            let made = FakeTransport(index: index, staging: staging, recorder: recorder, service: MockImmichService(), mode: .manual)
            box.set(made)
            return made
        }
        let model = BackupModel(
            source: library, service: MockImmichService(), directory: directory,
            network: FixedNetwork(isOnCellular: false), defaults: makeDefaults(), uploads: uploads)
        await model.load()
        await model.refreshBackgroundStatus()

        XCTAssertEqual(model.remainingItems.count, BackupModel.remainingItemLimit, "Still capped in total")
        XCTAssertEqual(model.remainingItems.filter { $0.id == "a1" }.map(\.status), [.uploading], "One row for both halves, never cut")
        XCTAssertFalse(model.remainingItems.contains { ["a2", "a3", "a4"].contains($0.id) }, "The oldest others make room")
        XCTAssertEqual(model.remainingTotal, count)
        XCTAssertTrue(model.isRemainingCut, "The footer shows when the real total is larger")
        XCTAssertEqual(model.remainingSections.first?.kind, .uploading)
        XCTAssertEqual(model.remainingSections.first?.items.map(\.id), ["a1"])

        XCTAssertEqual(model.uploadProgress.fractions, [:], "No progress reported yet")
        try XCTUnwrap(box.value).setProgress([
            photo.attempt: UploadBytes(sent: 30, expected: 100), video.attempt: UploadBytes(sent: 10, expected: 100),
        ])
        await model.refreshUploadProgress()
        XCTAssertEqual(model.uploadProgress.fractions["a1"]!, 0.2, accuracy: 0.0001)
        await model.stop()
    }

    func testShownProgressNeverGoesBackWhileTheAssetIsInFlight() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for id in ["a1", "a2"] {
            await index.set(
                BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-\(id)"], state: .pending(reason: .needsUpload)), for: id)
        }
        await index.setSelection(BackupSelection(included: ["recents"]))
        let photo = makeJob("a1")
        let video = UploadJob(assetID: "a1", resource: .pairedVideo, attempt: UUID(), bodyFileName: "v.multipart", checksum: "bb")
        let plain = makeJob("a2")
        for job in [photo, video, plain] { await index.addJob(job) }
        try await index.save()
        let box = TransportBox()
        let uploads = BackupModel.Uploads(requests: .test) { index, staging, recorder in
            let made = FakeTransport(index: index, staging: staging, recorder: recorder, service: MockImmichService(), mode: .manual)
            box.set(made)
            return made
        }
        let model = BackupModel(
            source: makeLibrary(count: 2), service: MockImmichService(), directory: directory,
            network: FixedNetwork(isOnCellular: false), defaults: makeDefaults(), uploads: uploads)
        await model.load()
        await model.refreshBackgroundStatus()
        let transport = try XCTUnwrap(box.value)
        transport.setProgress([
            photo.attempt: UploadBytes(sent: 100, expected: 100), video.attempt: UploadBytes(sent: 0, expected: 100),
            plain.attempt: UploadBytes(sent: 100, expected: 100),
        ])
        await model.refreshUploadProgress()
        XCTAssertEqual(model.uploadProgress.fractions["a1"]!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(model.uploadProgress.fractions["a2"]!, 1, accuracy: 0.0001)

        // The photo half and the plain asset finished: their reports are gone before the job list is read again.
        transport.setProgress([video.attempt: UploadBytes(sent: 10, expected: 100)])
        await model.refreshUploadProgress()
        XCTAssertEqual(
            model.uploadProgress.fractions["a1"]!, 0.55, accuracy: 0.0001,
            "Doesn't drop back while still in flight: the finished half keeps its 100 bytes, 110 of 200")
        XCTAssertEqual(model.uploadProgress.fractions["a2"]!, 1, accuracy: 0.0001, "Doesn't turn indeterminate")

        transport.setProgress([video.attempt: UploadBytes(sent: 80, expected: 100)])
        await model.refreshUploadProgress()
        XCTAssertEqual(
            model.uploadProgress.fractions["a1"]!, 0.9, accuracy: 0.0001,
            "A finished half counts with its last bytes while the asset is in flight: 180 of 200")

        await transport.finish(where: { $0.assetID == "a2" }, with: .uploaded(AssetUploadResult(id: "S2", status: .created)))
        await model.refreshBackgroundStatus()
        await model.refreshUploadProgress()
        XCTAssertNil(model.uploadProgress.fractions["a2"], "An asset no longer in flight is dropped")
        await model.stop()
    }

    func testRemainingSummaryFractionIsBackedUpOverBackedUpAndPending() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        for number in 0..<4 {
            let state: BackupState = number == 0 ? .pending(reason: .needsUpload) : .backedUp(serverAssetID: "s\(number)")
            await index.set(BackupEntry(modificationDate: Self.date, checksums: [.photo: "sum-\(number)"], state: state), for: "a\(number + 1)")
        }
        await index.setSelection(BackupSelection(included: ["recents"]))
        try await index.save()
        let model = makeModel(makeLibrary(count: 4), directory: directory)
        await model.load()
        XCTAssertEqual(model.backedUpFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertFalse(model.isRemainingCut)
        await model.stop()
    }

    func testRemainingListIsEmptyWhenEverythingIsBackedUp() async throws {
        let library = makeLibrary(count: 2)
        let directory = try await seededDirectory(["a1": .backedUp(serverAssetID: "s1"), "a2": .backedUp(serverAssetID: "s2")])
        let model = makeModel(library, directory: directory)
        await model.load()
        XCTAssertTrue(model.remainingItems.isEmpty)
        await model.stop()
    }

    func testInFlightCountShowsUploadingInTheBackground() async throws {
        let setup = try await makeUploadModel(jobs: [makeJob("a1"), makeJob("a2")])
        XCTAssertEqual(setup.model.inFlightCount, 0, "Nothing is read before the status is refreshed")

        await setup.model.refreshBackgroundStatus()

        XCTAssertEqual(setup.model.inFlightCount, 2)
        await setup.model.stop()
    }

    func testRedirectBlockIsShownAndCleared() async throws {
        let setup = try await makeUploadModel()
        await setup.model.refreshBackgroundStatus()
        XCTAssertFalse(setup.model.isRedirectBlocked)

        setup.transport.setRedirectBlocked(true)
        await setup.model.refreshBackgroundStatus()
        XCTAssertTrue(setup.model.isRedirectBlocked)

        setup.transport.setRedirectBlocked(false)
        await setup.model.refreshBackgroundStatus()
        XCTAssertFalse(setup.model.isRedirectBlocked)
        await setup.model.stop()
    }

    /// Turning a cellular switch off cancels exactly the uploads in flight that were sent with cellular access
    /// and are no longer allowed on it; uploads already held for Wi-Fi are left alone.
    func testCellularSwitchOffCancelsThoseUploads() async throws {
        let onCellular = UploadJob(
            assetID: "a1", resource: .photo, attempt: UUID(), bodyFileName: "\(UUID().uuidString).multipart",
            checksum: "aa", allowsCellular: true)
        let wifiOnly = UploadJob(
            assetID: "a2", resource: .photo, attempt: UUID(), bodyFileName: "\(UUID().uuidString).multipart",
            checksum: "aa", allowsCellular: false)
        let setup = try await makeUploadModel(jobs: [onCellular, wifiOnly])
        setup.model.settings.photosOnCellular = true
        await setup.model.cellularCancel?.value
        XCTAssertEqual(setup.transport.cancelledAttempts, [], "Turning a switch on cancels nothing")

        setup.model.settings.photosOnCellular = false
        await setup.model.cellularCancel?.value

        XCTAssertEqual(setup.transport.cancelledAttempts, [[onCellular.attempt]])
        let left = await setup.transport.inFlight().map(\.attempt)
        XCTAssertEqual(left, [wifiOnly.attempt], "The cancelled job went back through the recorder")
        await setup.model.stop()
    }

    /// Only the user lifts a redirect block: refreshing the status leaves it, Try Again clears it.
    func testRetryAfterRedirectLiftsTheBlock() async throws {
        let setup = try await makeUploadModel()
        setup.transport.setRedirectBlocked(true)
        await setup.model.refreshBackgroundStatus()
        XCTAssertTrue(setup.model.isRedirectBlocked)
        await setup.model.refreshBackgroundStatus()
        XCTAssertTrue(setup.transport.isRedirectBlocked, "Not lifted without the user")

        await setup.model.retryAfterRedirect()

        XCTAssertFalse(setup.transport.isRedirectBlocked)
        XCTAssertFalse(setup.model.isRedirectBlocked)
        XCTAssertEqual(setup.transport.clearCount, 1)
        await setup.model.stop()
    }

    func testLastBackupComesFromTheLastRecordedSuccess() async throws {
        let first = makeJob("a1")
        let second = makeJob("a2")
        let recordedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let setup = try await makeUploadModel(jobs: [first, second], now: recordedAt)
        await setup.model.refreshBackgroundStatus()
        XCTAssertNil(setup.model.lastBackup, "No upload has succeeded yet")

        // A failure is not a backup.
        await setup.recorder.record(first, .failed(.service(.unexpectedStatus(503))))
        await setup.model.refreshBackgroundStatus()
        XCTAssertNil(setup.model.lastBackup)

        await setup.recorder.record(second, .uploaded(AssetUploadResult(id: "srv-2", status: .created)))
        await setup.model.refreshBackgroundStatus()
        XCTAssertEqual(setup.model.lastBackup, recordedAt)
        await setup.model.stop()
    }

    func testLastBackupSurvivesReopeningTheIndex() async throws {
        let job = makeJob("a1")
        let recordedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let setup = try await makeUploadModel(jobs: [job], now: recordedAt)
        await setup.recorder.record(job, .uploaded(AssetUploadResult(id: "srv-1", status: .created)))
        await setup.model.stop()

        let reopened = BackupIndex(directory: setup.directory)
        let last = await reopened.lastSuccess
        XCTAssertEqual(last, recordedAt)
    }

    func testRefreshOffHintShowsWhenDenied() async throws {
        let model = makeModel(makeLibrary())
        XCTAssertFalse(model.isBackgroundRefreshOff)

        model.backgroundRefreshIsDenied = { true }
        await model.refreshBackgroundStatus()
        XCTAssertTrue(model.isBackgroundRefreshOff)

        model.backgroundRefreshIsDenied = { false }
        await model.refreshBackgroundStatus()
        XCTAssertFalse(model.isBackgroundRefreshOff)
        await model.stop()
    }
}
