import Foundation
@testable import ImmichUI
import XCTest
@testable import ImmichKit

@MainActor
final class LibraryPersistenceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func asset(_ id: String, _ year: Int, _ month: Int, _ day: Int, favorite: Bool = false) -> Asset {
        let date = Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Asset(id: id, kind: .image, takenAt: date, isFavorite: favorite)
    }

    private func snapshot(for assets: [Asset]) -> [TimelineMonth] {
        Dictionary(grouping: assets) { asset in
            let parts = Asset.localCalendar.dateComponents([.year, .month], from: asset.localDateTime)
            return TimeBucket.key(year: parts.year!, month: parts.month!)
        }.map { id, bucketAssets in
            let bucket = TimeBucket(key: id, count: bucketAssets.count)!
            return TimelineMonth(bucket: bucket, days: TimelineGrouping.days(from: bucketAssets))
        }.sorted { $0.id > $1.id }
    }

    func testCachedMonthsAppearBeforeSlowNetworkAndRemainAvailableOffline() async throws {
        let directory = try temporaryDirectory()
        let cached = [asset("cached", 2024, 3, 4)]
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: snapshot(for: cached), options: .library)

        let mock = MockImmichService(assets: cached)
        await mock.setLatency(.seconds(2))
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        let loading = Task { await model.load() }
        for _ in 0..<30 where model.months.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["cached"])
        XCTAssertEqual(model.phase, .loaded)

        await mock.setFailure(.network("offline"))
        await loading.value
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["cached"])
        XCTAssertEqual(model.phase, .loaded)
        model.stopPrefetching()
    }

    func testRefreshReplacesChangedMembershipEvenWhenBucketCountIsUnchanged() async throws {
        let directory = try temporaryDirectory()
        let old = [asset("old", 2024, 3, 4)]
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: snapshot(for: old), options: .library)

        let mock = MockImmichService(assets: [asset("new", 2024, 3, 8)])
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        await model.load()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["new"])
        model.stopPrefetching()
    }

    func testRecentlyAddedSnapshotKeepsDaysThatDoNotMatchBucketMonth() async throws {
        let directory = try temporaryDirectory()
        let added = asset("added-in-march", 2024, 3, 8)
        let snapshot = [TimelineMonth(
            bucket: TimeBucket(id: "2024-02-01", year: 2024, month: 2, count: 1),
            days: [TimelineDay(year: 2024, month: 3, day: 8, assets: [added])]
        )]
        let options = TimelineOptions(sortsByDateAdded: true)
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: snapshot, options: options)
        let restored = await TimelineSnapshotStore(directory: directory).load(options: options)
        XCTAssertEqual(restored?.first?.days?.first?.id, "2024-03-08")
        XCTAssertEqual(restored?.first?.bucket.id, "2024-02-01")
    }

    func testModelWritesAllMonthsAndFreshOfflineModelRestoresThem() async throws {
        let directory = try temporaryDirectory()
        let assets = [asset("jan", 2024, 1, 2), asset("feb", 2024, 2, 3), asset("mar", 2024, 3, 4)]
        let store = TimelineSnapshotStore(directory: directory)
        let online = MockImmichService(assets: assets)
        let first = LibraryGridModel(service: online, options: .library, snapshotStore: store)
        await first.load()
        await first.loadAllMonths()
        XCTAssertTrue(first.months.allSatisfy(\.isLoaded))

        let offline = MockImmichService()
        await offline.setFailure(.network("offline"))
        let reopened = LibraryGridModel(
            service: offline, options: .library,
            loader: ImageLoader(service: offline, disk: nil),
            snapshotStore: TimelineSnapshotStore(directory: directory)
        )
        await reopened.load()
        XCTAssertEqual(reopened.months.flatMap(\.assets).map(\.id), first.months.flatMap(\.assets).map(\.id))
        XCTAssertTrue(reopened.months.allSatisfy(\.isLoaded), "cached Months/Years data is complete")
        XCTAssertEqual(reopened.phase, .loaded)
        first.stopPrefetching()
        reopened.stopPrefetching()
    }

    func testFavoriteOverrideIsPersistedAfterDebouncedSave() async throws {
        let directory = try temporaryDirectory()
        let original = asset("favorite-target", 2024, 3, 4)
        let mock = MockImmichService(assets: [original])
        let store = TimelineSnapshotStore(directory: directory)
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        await model.load()
        model.applyFavoriteUpdates([asset("favorite-target", 2024, 3, 4, favorite: true)])

        var persisted: [TimelineMonth]?
        for _ in 0..<30 {
            persisted = await store.load(options: .library)
            if persisted?.flatMap(\.assets).first?.isFavorite == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(persisted?.flatMap(\.assets).first?.isFavorite, true)
        model.stopPrefetching()
    }

    func testRefreshDropsRemovedMonthAndAddsNewServerMonth() async throws {
        let directory = try temporaryDirectory()
        let old = [asset("old", 2024, 1, 4)]
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: snapshot(for: old), options: .library)
        let mock = MockImmichService(assets: [asset("new", 2024, 3, 4)])
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        await model.load()
        XCTAssertEqual(model.months.map(\.id), ["2024-03-01"])
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["new"])
        model.stopPrefetching()
    }

    func testLateAllAssetsResponseCannotRepopulateFavoritesAfterOptionsSwitch() async throws {
        let directory = try temporaryDirectory()
        let assets = [asset("ordinary", 2024, 3, 4), asset("favorite", 2024, 3, 5, favorite: true)]
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: snapshot(for: assets), options: .library)
        let mock = MockImmichService(assets: assets)
        await mock.setLatency(.milliseconds(250))
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        let oldLoad = Task { await model.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.months.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(Set(model.months.flatMap(\.assets).map(\.id)), Set(assets.map(\.id)))
        await model.setOptions(TimelineOptions(isFavorite: true))
        await oldLoad.value
        XCTAssertEqual(model.options.isFavorite, true)
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["favorite"])
        model.stopPrefetching()
    }

    // MARK: Hide and unhide

    private func waitForSnapshot(_ store: TimelineSnapshotStore, options: TimelineOptions) async throws -> [TimelineMonth] {
        for _ in 0..<100 {
            if let months = await store.load(options: options) { return months }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("No snapshot was saved")
        return []
    }

    func testHidingRemovesConfirmedIDsFromGridAndSavedSnapshot() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let assets = [asset("keep", 2024, 3, 4), asset("hide-1", 2024, 3, 5), asset("hide-2", 2024, 4, 6)]
        let mock = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: mock, options: .library, snapshotStore: store)
        await model.load()
        await model.loadAllMonths()
        // Saved before the write: a relaunch would show all three.
        _ = try await waitForSnapshot(store, options: .library)

        let result = await model.setHidden(Array(assets[1...]), hidden: true)

        XCTAssertEqual(Set(result.confirmed), ["hide-1", "hide-2"])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["keep"])
        let hidden = try await mock.asset(id: "hide-1")
        XCTAssertTrue(hidden.isArchived)
        let saved = try await waitForSnapshot(store, options: .library)
        XCTAssertEqual(saved.flatMap(\.assets).map(\.id), ["keep"])
        // A refresh that revalidates months must not bring hidden photos back either.
        await model.revalidate()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["keep"])
        model.stopPrefetching()
    }

    func testUnhidingFromArchiveGridRemovesConfirmedIDs() async throws {
        var archived = asset("archived", 2024, 3, 4)
        archived.isArchived = true
        var other = asset("other", 2024, 3, 5)
        other.isArchived = true
        let mock = MockImmichService(assets: [archived, other, asset("visible", 2024, 3, 6)])
        let model = LibraryGridModel(service: mock, options: TimelineOptions(visibility: .archive, newestFirst: false))
        await model.load()
        await model.loadAllMonths()
        XCTAssertEqual(Set(model.months.flatMap(\.assets).map(\.id)), ["archived", "other"])

        let result = await model.setHidden([archived], hidden: false)

        XCTAssertEqual(result.confirmed, ["archived"])
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["other"])
        let updated = try await mock.asset(id: "archived")
        XCTAssertFalse(updated.isArchived)
        model.stopPrefetching()
    }

    func testHideKeepsFailedAssetsInGridAndReportsThem() async throws {
        let assets = [asset("a", 2024, 3, 4), asset("b", 2024, 3, 5)]
        let mock = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: mock, options: .library)
        await model.load()
        await model.loadAllMonths()
        await mock.setAssets([assets[0]]) // "b" is gone on the server: its write fails

        let result = await model.setHidden(assets, hidden: true)

        XCTAssertEqual(result.confirmed, ["a"])
        XCTAssertEqual(result.failed, ["b"])
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["b"])
        model.stopPrefetching()
    }

    func testHideAndUnhideAreRefusedInTheWrongGrid() async throws {
        let mock = MockImmichService(assets: [asset("a", 2024, 3, 4)])
        let model = LibraryGridModel(service: mock, options: .library)
        await model.load()
        await model.loadAllMonths()

        let result = await model.setHidden([asset("a", 2024, 3, 4)], hidden: false)

        XCTAssertTrue(result.confirmed.isEmpty)
        XCTAssertEqual(result.failed, ["a"])
        let writes = await mock.requestCount(.setHidden("a", false))
        XCTAssertEqual(writes, 0)
        model.stopPrefetching()
    }

    func testAlbumAndPersonGridsOfferNeitherHideNorUnhide() async throws {
        var archived = asset("archived", 2024, 3, 4)
        archived.isArchived = true
        let mock = MockImmichService(assets: [archived, asset("visible", 2024, 3, 5)])
        for options in [TimelineOptions.album("album-1"), .person("person-1")] {
            let model = LibraryGridModel(service: mock, options: options)
            XCTAssertFalse(model.supportsHiding)
            for (target, id) in [(true, "visible"), (false, "archived")] {
                let result = await model.setHidden([asset(id, 2024, 3, 4)], hidden: target)
                XCTAssertTrue(result.confirmed.isEmpty)
                XCTAssertEqual(result.failed, [id])
            }
            let selection = LibrarySelectionModel(library: model)
            XCTAssertFalse(selection.supportsHiding)
        }
        let writes = await mock.requests.filter { if case .setHidden = $0 { true } else { false } }
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(LibraryGridModel(service: mock, options: .library).supportsHiding)
        XCTAssertTrue(LibraryGridModel(service: mock, options: TimelineOptions(visibility: .archive)).supportsHiding)
    }

    func testHideWhoseConfirmingReadFailsStaysSelectedUnsavedAndRetryConfirms() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let assets = [asset("keep", 2024, 3, 4), asset("uncertain", 2024, 3, 5)]
        let mock = MockImmichService(assets: assets)
        let service = HideReadFailsService(mock: mock)
        let model = LibraryGridModel(service: service, options: .library, snapshotStore: store)
        await model.load()
        await model.loadAllMonths()
        _ = try await waitForSnapshot(store, options: .library)
        let selection = LibrarySelectionModel(library: model)
        selection.start()
        selection.toggle(assets[1])
        await service.setReadFails(true)

        await selection.setHidden(true)

        // The server applied the write, but without its answer the app can't know.
        let onServer = try await mock.asset(id: "uncertain")
        XCTAssertTrue(onServer.isArchived)
        XCTAssertEqual(selection.selectedIDs, ["uncertain"])
        XCTAssertNotNil(selection.error)
        XCTAssertNotNil(model.gridIndex(ofAsset: "uncertain"))
        XCTAssertTrue(model.needsMutationRefresh)
        // Nothing is saved until a fresh server load: the snapshot was cleared before the write.
        try await Task.sleep(for: .milliseconds(500))
        let unsaved = await store.load(options: .library)
        XCTAssertNil(unsaved)

        await service.setReadFails(false)
        await selection.setHidden(true) // idempotent retry
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
        XCTAssertNil(model.gridIndex(ofAsset: "uncertain"))
        XCTAssertNotNil(model.gridIndex(ofAsset: "keep"))
        // Still no saving from the uncertain presentation; a fresh load settles it.
        XCTAssertTrue(model.needsMutationRefresh)
        await model.load()
        XCTAssertFalse(model.needsMutationRefresh)
        let saved = try await waitForSnapshot(store, options: .library)
        XCTAssertEqual(saved.flatMap(\.assets).map(\.id), ["keep"])
        model.stopPrefetching()
    }
}

/// The mock server, except that `setHidden` can apply the write and then fail, like a PUT that
/// succeeded whose confirming GET did not.
private struct HideReadFailsService: ImmichService {
    let mock: MockImmichService
    private let state = ReadFailure()

    init(mock: MockImmichService) { self.mock = mock }

    private final class ReadFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    func setReadFails(_ fails: Bool) async { state.isOn = fails }

    func setHidden(assetID: String, hidden: Bool) async throws -> Asset {
        let asset = try await mock.setHidden(assetID: assetID, hidden: hidden)
        if state.isOn { throw ImmichServiceError.network("confirming read failed") }
        return asset
    }

    func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult { try await mock.uploadAsset(request) }
    func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] { try await mock.checkBulkUpload(items) }
    func linkLivePhoto(photoID: String, motionID: String) async throws { try await mock.linkLivePhoto(photoID: photoID, motionID: motionID) }
    func restoreAssets(assetIDs: [String]) async throws -> RestoreResult { try await mock.restoreAssets(assetIDs: assetIDs) }
    func moveToTrash(assetIDs: [String]) async throws -> TrashResult { try await mock.moveToTrash(assetIDs: assetIDs) }
    func serverFeatures() async throws -> ServerFeatures { try await mock.serverFeatures() }
    func ping() async throws { try await mock.ping() }
    func serverVersion() async throws -> ServerVersion { try await mock.serverVersion() }
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] { try await mock.timeBuckets(options: options) }
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] { try await mock.timeBucketAssets(bucketID: bucketID, options: options) }
    func thumbnail(assetID: String, size: ImageSize) async throws -> Data { try await mock.thumbnail(assetID: assetID, size: size) }
    func albums(shared: Bool?) async throws -> [Album] { try await mock.albums(shared: shared) }
    func albumsForAdding() async throws -> [Album] { try await mock.albumsForAdding() }
    func album(id: String) async throws -> Album { try await mock.album(id: id) }
    func people(withHidden: Bool) async throws -> [Person] { try await mock.people(withHidden: withHidden) }
    func person(id: String) async throws -> Person { try await mock.person(id: id) }
    func personThumbnail(personID: String) async throws -> Data { try await mock.personThumbnail(personID: personID) }
    func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults { try await mock.smartSearch(query, page: page, size: size) }
    func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults { try await mock.metadataSearch(query, page: page, size: size) }
    func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String] { try await mock.searchSuggestions(kind, context: context) }
    func asset(id: String) async throws -> Asset { try await mock.asset(id: id) }
    func original(assetID: String) async throws -> Data { try await mock.original(assetID: assetID) }
    func mediaRequest(_ kind: MediaRequest.Kind, assetID: String) async throws -> MediaRequest { try await mock.mediaRequest(kind, assetID: assetID) }
    func mapMarkers(_ options: MapMarkerOptions) async throws -> [MapMarker] { try await mock.mapMarkers(options) }
    func memories(_ query: MemoryQuery) async throws -> [Memory] { try await mock.memories(query) }
    func setFavorite(assetID: String, isFavorite: Bool) async throws -> Asset { try await mock.setFavorite(assetID: assetID, isFavorite: isFavorite) }
    func createAlbum(name: String, assetIDs: [String]) async throws -> String { try await mock.createAlbum(name: name, assetIDs: assetIDs) }
    func addAssets(toAlbum albumID: String, assetIDs: [String]) async throws -> AlbumAddResult { try await mock.addAssets(toAlbum: albumID, assetIDs: assetIDs) }
}
