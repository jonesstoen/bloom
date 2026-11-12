import Foundation
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class TrashRaceTests: XCTestCase {
    private func assets() -> [Asset] {
        (1...4).map { month in
            let date = Asset.localCalendar.date(from: DateComponents(year: 2024, month: month, day: 4))!
            return Asset(id: "race-\(month)", kind: .image, takenAt: date, isFavorite: true)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrashRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func model(_ service: TrashRaceService, store: TimelineSnapshotStore? = nil) -> LibraryGridModel {
        LibraryGridModel(service: service, loader: ImageLoader(service: service, disk: nil), snapshotStore: store)
    }

    private func awaitBlocked(_ service: TrashRaceService) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await service.isBlocked) && ContinuousClock.now < deadline { await Task.yield() }
        let blocked = await service.isBlocked
        XCTAssertTrue(blocked, "The stale response must be captured before trash starts")
    }

    func testOldBucketCompletionAfterTrashCannotReplaceFilteredPresentation() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let library = model(service)
        await library.load()
        await library.loadAllMonths()
        await service.arm(.buckets)
        let oldLoad = Task { await library.load() }
        await awaitBlocked(service)

        _ = try await library.moveToTrash([input[3]])
        let idsAfterTrash = library.months.flatMap(\.assets).map(\.id)
        await service.release()
        await oldLoad.value

        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), idsAfterTrash)
        XCTAssertNil(library.gridIndex(ofAsset: input[3].id))
        XCTAssertEqual(library.gridItemCount, 3)
    }

    func testOldMonthCompletionAfterTrashCannotResurrectDeletedID() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let library = model(service)
        await library.load() // Only the newest two months load initially.
        let oldest = try XCTUnwrap(library.months.first)
        XCTAssertFalse(oldest.isLoaded)
        await service.arm(.month(oldest.id))
        let oldMonth = Task { await library.loadMonth(oldest.id) }
        await awaitBlocked(service)

        _ = try await library.moveToTrash([input[0]])
        await service.release()
        await oldMonth.value

        XCTAssertNil(library.gridIndex(ofAsset: input[0].id))
        XCTAssertFalse(library.month(id: oldest.id)?.isLoaded ?? true,
                       "The old actor's completion must not publish any pre-write month")
    }

    func testOldLoadAllCompletionCannotPublishItsPreTrashMonths() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let library = model(service)
        await library.load()
        let oldest = try XCTUnwrap(library.months.first)
        await service.arm(.month(oldest.id))
        let oldLoadAll = Task { await library.loadAllMonths() }
        await awaitBlocked(service)

        _ = try await library.moveToTrash([input[0], input[3]])
        let idsAfterTrash = library.months.flatMap(\.assets).map(\.id)
        await service.release()
        await oldLoadAll.value

        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), idsAfterTrash)
        XCTAssertNil(library.gridIndex(ofAsset: input[0].id))
        XCTAssertNil(library.gridIndex(ofAsset: input[3].id))
    }

    func testTombstoneSurvivesFilterAndSortSwitchesAndOfflineDiskReopen() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let url = try directory()
        let store = TimelineSnapshotStore(directory: url)
        let library = model(service, store: store)
        await library.load()
        await library.loadAllMonths()
        _ = try await library.moveToTrash([input[3]])
        var favorite = library.options
        favorite.isFavorite = true
        var added = library.options
        added.sortsByDateAdded = true
        let partitions = [favorite, added, library.options]
        // The fixture deliberately keeps serving pre-write assets, modelling stale reads.
        for partition in partitions {
            await library.setOptions(partition)
            await library.loadAllMonths()
            XCTAssertNil(library.gridIndex(ofAsset: input[3].id))
            XCTAssertEqual(library.gridItemCount, 3)
            let disk = await store.load(options: library.options)
            XCTAssertFalse(disk?.flatMap(\.assets).contains { $0.id == input[3].id } ?? false)
        }
        await service.setOffline()
        let reopened = model(service, store: TimelineSnapshotStore(directory: url))
        await reopened.load()
        XCTAssertEqual(reopened.gridItemCount, 3, "A useful filtered snapshot should still open offline")
        XCTAssertNil(reopened.gridIndex(ofAsset: input[3].id))
    }

    func testUnknownOutcomeCannotPersistOldAssetsAfterFavoriteDebounce() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let url = try directory()
        let store = TimelineSnapshotStore(directory: url)
        let library = model(service, store: store)
        await library.load()
        await library.loadAllMonths()
        await service.failTrash()
        let result = try await library.moveToTrash([input[3]])
        XCTAssertEqual(result.failedIDs, [input[3].id])
        var favorite = input[0]
        favorite.isFavorite = false
        library.applyFavoriteUpdates([favorite])
        // Cross the actual persistence debounce, then probe a newly opened store. This is
        // the only time-dependent check: it detects resurrection by a later favorite save.
        try await Task.sleep(for: .milliseconds(400))
        let reopened = TimelineSnapshotStore(directory: url)
        let disk = await reopened.load(options: library.options)
        XCTAssertNil(disk)
        await service.setOffline()
        let offline = model(service, store: reopened)
        await offline.load()
        XCTAssertEqual(offline.gridItemCount, 0)
    }

    func testDeletedVisibleCenterAnchorsNearestSurvivorAndOnlyAssetLeavesEmptyGrid() async throws {
        let input = assets()
        let service = TrashRaceService(assets: input)
        let library = model(service)
        await library.load()
        await library.loadAllMonths()
        library.assetAppeared(input[1].id)
        _ = try await library.moveToTrash([input[1]])
        XCTAssertEqual(library.gridShift?.anchorID, input[0].id, "Ties choose the previous surviving item")
        XCTAssertEqual(library.gridShift?.oldIndex, 0)
        XCTAssertEqual(library.gridShift?.newIndex, 0)
        XCTAssertNil(library.gridIndex(ofAsset: input[1].id))

        let singleService = TrashRaceService(assets: [input[0]])
        let single = model(singleService)
        await single.load()
        single.assetAppeared(input[0].id)
        _ = try await single.moveToTrash([input[0]])
        XCTAssertEqual(single.gridItemCount, 0)
        XCTAssertTrue(single.isEmpty)
        XCTAssertNil(single.visibleCenterID)
        XCTAssertTrue(single.viewerAssets(around: input[0].id).isEmpty)
    }
}

/// Captures a real response before suspension, then returns it even after the write.
/// The timeline mock intentionally remains unchanged to exercise stale server reads too.
private actor TrashRaceService: ImmichService {
    enum Gate: Equatable { case buckets, month(String) }
    private let mock: MockImmichService
    private var gate: Gate?
    private var continuation: CheckedContinuation<Void, Never>?
    private var offline = false
    private var trashFails = false
    var isBlocked: Bool { continuation != nil }

    init(assets: [Asset]) { mock = MockImmichService(assets: assets) }
    func arm(_ gate: Gate) { self.gate = gate }
    func release() { continuation?.resume(); continuation = nil }
    func setOffline() { offline = true }
    func failTrash() { trashFails = true }
    private func pause(_ operation: Gate) async {
        guard gate == operation else { return }
        gate = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        guard !offline else { throw ImmichServiceError.network("offline fixture") }
        let captured = try await mock.timeBuckets(options: options)
        await pause(.buckets)
        return captured
    }
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] {
        guard !offline else { throw ImmichServiceError.network("offline fixture") }
        let captured = try await mock.timeBucketAssets(bucketID: bucketID, options: options)
        await pause(.month(bucketID))
        return captured
    }
    func moveToTrash(assetIDs: [String]) async throws -> TrashResult {
        TrashResult(confirmedIDs: trashFails ? [] : assetIDs, failedIDs: trashFails ? assetIDs : [])
    }
    func ping() async throws { try await mock.ping() }
    func serverVersion() async throws -> ServerVersion { try await mock.serverVersion() }
    func thumbnail(assetID: String, size: ImageSize) async throws -> Data { try await mock.thumbnail(assetID: assetID, size: size) }
    func albums(shared: Bool?) async throws -> [Album] { try await mock.albums(shared: shared) }
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
}
