import Foundation
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class RestoreRaceTests: XCTestCase {
    private func assets() -> [Asset] {
        (1...4).map { (month: Int) -> Asset in
            Asset(id: "restore-race-\(month)", kind: .image,
                  takenAt: Asset.localCalendar.date(from: DateComponents(year: 2024, month: month, day: 4))!,
                  isTrashed: true)
        }
    }
    private var trashOptions: TimelineOptions { TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false) }
    private func model(_ service: RestoreRaceService, trash: Bool = true,
                       store: TimelineSnapshotStore? = nil) -> LibraryGridModel {
        LibraryGridModel(service: service, options: trash ? trashOptions : TimelineOptions(newestFirst: false),
                         loader: ImageLoader(service: service, disk: nil), snapshotStore: store)
    }
    private func waitForGate(_ service: RestoreRaceService) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await service.isBlocked) && ContinuousClock.now < deadline { await Task.yield() }
        let blocked = await service.isBlocked
        XCTAssertTrue(blocked, "Capture the pre-mutation response before restore")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RestoreRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOldTrashBucketCompletionCannotReinsertRestoredID() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let trash = model(service)
        await trash.load()
        await trash.loadAllMonths()
        await service.arm(.buckets)
        let oldLoad = Task { await trash.load() }
        await waitForGate(service)
        _ = try await trash.restoreFromTrash([input[3]])
        let expected = trash.months.flatMap(\.assets).map(\.id)
        await service.release()
        await oldLoad.value
        XCTAssertEqual(trash.months.flatMap(\.assets).map(\.id), expected)
        XCTAssertNil(trash.gridIndex(ofAsset: input[3].id))
        XCTAssertEqual(trash.gridItemCount, 3)
    }

    func testOldTrashMonthCompletionCannotReinsertRestoredID() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let trash = model(service)
        await trash.load()
        let oldest = try XCTUnwrap(trash.months.first)
        XCTAssertFalse(oldest.isLoaded)
        await service.arm(.month(oldest.id))
        let oldLoad = Task { await trash.loadMonth(oldest.id) }
        await waitForGate(service)
        _ = try await trash.restoreFromTrash([input[0]])
        await service.release()
        await oldLoad.value
        XCTAssertNil(trash.gridIndex(ofAsset: input[0].id))
        XCTAssertFalse(trash.month(id: oldest.id)?.isLoaded ?? true)
    }

    func testOldTrashLoadAllCannotPublishPreRestoreMonths() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let trash = model(service)
        await trash.load()
        let oldest = try XCTUnwrap(trash.months.first)
        await service.arm(.month(oldest.id))
        let oldLoad = Task { await trash.loadAllMonths() }
        await waitForGate(service)
        _ = try await trash.restoreFromTrash([input[0], input[3]])
        let expected = trash.months.flatMap(\.assets).map(\.id)
        await service.release()
        await oldLoad.value
        XCTAssertEqual(trash.months.flatMap(\.assets).map(\.id), expected)
        XCTAssertNil(trash.gridIndex(ofAsset: input[0].id))
        XCTAssertNil(trash.gridIndex(ofAsset: input[3].id))
    }

    func testDelegatedRestoreWritesOnceClearsMainTombstoneAndUpdatesBothGridsWithoutTrashRevision() async throws {
        let input = assets()
        var seed = input
        seed[3].isTrashed = false
        let service = RestoreRaceService(assets: seed)
        let main = model(service, trash: false)
        let trash = model(service)
        await main.load()
        XCTAssertNotNil(main.gridIndex(ofAsset: input[3].id))
        _ = try await main.moveToTrash([seed[3]])
        XCTAssertNil(main.gridIndex(ofAsset: input[3].id))
        await trash.load()
        await trash.loadAllMonths()
        let revision = main.trashRevision
        let result = try await trash.restoreFromTrash([input[3]], perform: { try await main.restoreToLibrary($0) })
        XCTAssertEqual(result.confirmedIDs, [input[3].id])
        XCTAssertNotNil(main.gridIndex(ofAsset: input[3].id))
        XCTAssertNil(trash.gridIndex(ofAsset: input[3].id))
        XCTAssertEqual(main.trashRevision, revision)
        XCTAssertEqual(main.restoreRevision, 1)
        XCTAssertEqual(trash.restoreRevision, 1)
        let writes = await service.restoreWrites
        XCTAssertEqual(writes, 1, "The trash model delegates; it must not also send its own write")
    }

    func testCancelledBatchKeepsConfirmedRemovalAndUnconfirmedItem() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let main = model(service, trash: false)
        let trash = model(service)
        await main.load()
        await trash.load()
        await trash.loadAllMonths()
        await service.returnPartialRestore()
        await service.arm(.restore)
        let operation = Task { try await trash.restoreFromTrash([input[2], input[3]], perform: { try await main.restoreToLibrary($0) }) }
        await waitForGate(service)
        operation.cancel()
        await service.release()
        let result = try await operation.value
        XCTAssertEqual(result.confirmedIDs, [input[2].id])
        XCTAssertEqual(result.failedIDs, [input[3].id])
        XCTAssertNil(trash.gridIndex(ofAsset: input[2].id))
        XCTAssertNotNil(trash.gridIndex(ofAsset: input[3].id))
        XCTAssertTrue(main.needsMutationRefresh, "Cancelled follow-up reads require later reconciliation")
        XCTAssertFalse(main.isMutating)
        XCTAssertFalse(trash.isMutating)
        await main.load()
        XCTAssertNotNil(main.gridIndex(ofAsset: input[2].id))
        XCTAssertNil(main.gridIndex(ofAsset: input[3].id))
    }

    func testFollowupReadFailureBlocksOldCacheSavesUntilExplicitRefresh() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let url = try directory()
        let store = TimelineSnapshotStore(directory: url)
        let main = model(service, trash: false, store: store)
        await main.load()
        await store.save(months: main.months, options: main.options)
        await service.failBucketsAfterRestore()
        let result = try await main.restoreToLibrary([input[3]])
        XCTAssertEqual(result.confirmedIDs, [input[3].id])
        XCTAssertTrue(main.needsMutationRefresh)
        XCTAssertNil(main.gridIndex(ofAsset: input[3].id), "A failed read must not synthesize insertion")
        var changed = input[0]
        changed.isFavorite = true
        main.applyFavoriteUpdates([changed])
        // Exercise the real deferred persistence path, rather than only checking immediately.
        try await Task.sleep(for: .milliseconds(400))
        let afterDebounce = await TimelineSnapshotStore(directory: url).load(options: main.options)
        XCTAssertNil(afterDebounce)
        await service.recoverBuckets()
        await main.load()
        XCTAssertFalse(main.needsMutationRefresh)
        XCTAssertNotNil(main.gridIndex(ofAsset: input[3].id))
        let saved = await store.load(options: main.options)
        XCTAssertTrue(saved?.flatMap(\.assets).contains { $0.id == input[3].id } == true)
    }

    func testSessionSignOutIsBlockedWhileDelegatedMainRestoreIsInFlight() async throws {
        let input = assets()
        let service = RestoreRaceService(assets: input)
        let credentials = CredentialStore(storage: InMemorySecureStorage())
        try credentials.save(ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder"))
        let root = RootModel(store: credentials, makeService: { _ in service })
        await root.restore()
        let main = try XCTUnwrap(root.session?.library)
        await main.load()
        let trash = model(service)
        await trash.load()
        await service.arm(.restore)
        let operation = Task { try await trash.restoreFromTrash([input[3]], perform: { try await main.restoreToLibrary($0) }) }
        await waitForGate(service)
        XCTAssertTrue(main.isRestoring)
        await root.signOut()
        XCTAssertEqual(root.phase, .signedIn)
        XCTAssertNotNil(root.session)
        XCTAssertNotNil(try credentials.load())
        await service.release()
        _ = try await operation.value
    }
}

/// Returns captured pre-restore responses after an explicit gate, even across cancellation.
private actor RestoreRaceService: ImmichService {
    enum Gate: Equatable { case buckets, month(String), restore }
    private let mock: MockImmichService
    private var gate: Gate?
    private var continuation: CheckedContinuation<Void, Never>?
    private var partialRestore = false
    private var failAfterRestore = false
    private var bucketsFail = false
    private(set) var restoreWrites = 0
    var isBlocked: Bool { continuation != nil }
    init(assets: [Asset]) { mock = MockImmichService(assets: assets) }
    func arm(_ gate: Gate) { self.gate = gate }
    func release() { continuation?.resume(); continuation = nil }
    func returnPartialRestore() { partialRestore = true }
    func failBucketsAfterRestore() { failAfterRestore = true }
    func recoverBuckets() { bucketsFail = false; failAfterRestore = false }
    private func pause(_ operation: Gate) async {
        guard gate == operation else { return }
        gate = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        guard !bucketsFail else { throw ImmichServiceError.network("offline fixture") }
        let captured = try await mock.timeBuckets(options: options)
        await pause(.buckets)
        return captured
    }
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] {
        let captured = try await mock.timeBucketAssets(bucketID: bucketID, options: options)
        await pause(.month(bucketID))
        return captured
    }
    func restoreAssets(assetIDs: [String]) async throws -> RestoreResult {
        restoreWrites += 1
        let result: RestoreResult
        if partialRestore, let first = assetIDs.first {
            let firstResult = try await mock.restoreAssets(assetIDs: [first])
            result = RestoreResult(confirmedIDs: firstResult.confirmedIDs,
                                   failedIDs: firstResult.failedIDs + Array(assetIDs.dropFirst()))
        } else {
            result = try await mock.restoreAssets(assetIDs: assetIDs)
        }
        if failAfterRestore { bucketsFail = true }
        await pause(.restore)
        return result
    }
    func moveToTrash(assetIDs: [String]) async throws -> TrashResult { try await mock.moveToTrash(assetIDs: assetIDs) }
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
