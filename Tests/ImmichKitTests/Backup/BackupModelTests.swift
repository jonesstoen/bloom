import XCTest
@testable import ImmichKit
@testable import ImmichUI

private struct FixedNetwork: NetworkConditions {
    let isOnCellular: Bool
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
        XCTAssertEqual(model.counts.total, model.counts.backedUp + model.remaining + model.counts.failed)
        XCTAssertEqual(model.selectionSummary, "Recents · 1 excluded")
    }
}
