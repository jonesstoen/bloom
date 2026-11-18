import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class LibrarySelectionTests: XCTestCase {
    func testSelectionRequiresLoadedAssetsAndKeepsIdentityAcrossDensityChanges() async throws {
        let (library, _, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.toggle(assets[0])
        XCTAssertEqual(selection.selectedCount, 0)
        selection.start()
        selection.toggle(assets[1])
        selection.toggle(assets[0])
        var unknown = assets[0]
        unknown.id = "unknown"
        selection.toggle(unknown)
        library.density = .seven
        XCTAssertEqual(selection.selectedIDs, Set([assets[0].id, assets[1].id]))
        XCTAssertEqual(selection.selectedAssets.map(\.id), [assets[1].id, assets[0].id])
        selection.toggle(assets[1])
        XCTAssertEqual(selection.selectedIDs, [assets[0].id])
        selection.cancel()
        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    func testMixedFavoritesUseOneExplicitTargetAndUpdateGridAndViewer() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        assets.forEach(selection.toggle)
        await selection.setFavorites(true)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        for asset in assets {
            let updated = try await mock.asset(id: asset.id)
            XCTAssertTrue(updated.isFavorite)
            let index = try XCTUnwrap(library.gridIndex(ofAsset: asset.id))
            XCTAssertEqual(library.gridAsset(atGridIndex: index)?.isFavorite, true)
        }
        XCTAssertTrue(library.viewerAssets(around: assets[0].id).allSatisfy(\.isFavorite))
        let alreadyFavoriteWrites = await mock.requestCount(.setFavorite(assets[1].id, true))
        XCTAssertEqual(alreadyFavoriteWrites, 0)
        // A later timeline snapshot must not restore its cached favorite flags.
        await library.loadAllMonths()
        for asset in assets {
            let current = try XCTUnwrap(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: asset.id))))
            selection.toggle(current)
        }
        await selection.setFavorites(false)
        for asset in assets {
            let updated = try await mock.asset(id: asset.id)
            XCTAssertFalse(updated.isFavorite)
        }
    }

    func testPartialFavoriteFailureKeepsOnlyFailedItemsForIdempotentRetry() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[2])
        // Remove one selected asset from the mock server after it was loaded in the grid.
        await mock.setAssets(Array(assets.prefix(2)))
        await selection.setFavorites(true)
        XCTAssertEqual(selection.selectedIDs, [assets[2].id])
        XCTAssertNotNil(selection.error)
        XCTAssertEqual(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: assets[0].id)))?.isFavorite, true)
        var restored = assets
        restored[0].isFavorite = true
        await mock.setAssets(restored)
        await selection.setFavorites(true)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
        let completedWrites = await mock.requestCount(.setFavorite(assets[0].id, true))
        let retriedWrites = await mock.requestCount(.setFavorite(assets[2].id, true))
        XCTAssertEqual(completedWrites, 1)
        XCTAssertEqual(retriedWrites, 2)
    }

    func testFavoriteActionIsBusyAgainstDuplicateTapAndCancel() async throws {
        let (library, mock, assets) = await selectionFixture()
        await mock.setLatency(.milliseconds(50))
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        let action = Task { await selection.setFavorites(true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !selection.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(selection.isBusy)
        selection.cancel()
        await selection.setFavorites(false)
        XCTAssertTrue(selection.isSelecting)
        await action.value
        let targetWrites = await mock.requestCount(.setFavorite(assets[0].id, true))
        let oppositeWrites = await mock.requestCount(.setFavorite(assets[0].id, false))
        XCTAssertEqual(targetWrites, 1)
        XCTAssertEqual(oppositeWrites, 0)
    }

    func testFavoriteFailureRetriesExplicitTargetEvenWhenGridSnapshotMatchesIt() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0]) // Timeline snapshot says not favorite.
        await mock.setFailure(.unauthorized)
        await selection.setFavorites(true)
        XCTAssertEqual(selection.selectedIDs, [assets[0].id])
        await mock.setFailure(nil)
        await selection.setFavorites(false) // Must still send: server state is uncertain after failure.
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        let finalState = try await mock.asset(id: assets[0].id)
        XCTAssertFalse(finalState.isFavorite)
        let falseWrites = await mock.requestCount(.setFavorite(assets[0].id, false))
        XCTAssertEqual(falseWrites, 1)
    }

    func testHideRemovesConfirmedAssetsFromGridAndClearsSelection() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[1])

        await selection.setHidden(true)

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
        XCTAssertFalse(selection.isBusy)
        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), [assets[2].id])
        let hidden = try await mock.asset(id: assets[0].id)
        XCTAssertTrue(hidden.isArchived)
    }

    func testHideFailureKeepsFailedAssetSelectedWithError() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[2])
        await mock.setAssets(Array(assets.prefix(2))) // assets[2] is gone on the server

        await selection.setHidden(true)

        XCTAssertEqual(selection.selectedIDs, [assets[2].id])
        XCTAssertEqual(selection.error, tr("Couldn't hide %@ items. Please try again.", "1"))
        XCTAssertNotNil(library.gridIndex(ofAsset: assets[2].id))
        XCTAssertNil(library.gridIndex(ofAsset: assets[0].id))
        // The retry is idempotent: it sends the same write again.
        await mock.setAssets(assets)
        await selection.setHidden(true)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
    }

    func testUnhideFromArchiveGridUsesUnhideError() async throws {
        var archived = Asset(id: "archived", kind: .image,
                             takenAt: ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!)
        archived.isArchived = true
        let mock = MockImmichService(assets: [archived])
        let library = LibraryGridModel(service: mock, options: TimelineOptions(visibility: .archive, newestFirst: false),
                                       loader: ImageLoader(service: mock, disk: nil))
        await library.load()
        await library.loadAllMonths()
        let selection = LibrarySelectionModel(library: library)
        XCTAssertTrue(selection.isArchive)
        selection.start()
        selection.toggle(archived)
        await mock.setFailure(.unauthorized)

        await selection.setHidden(false)

        XCTAssertEqual(selection.selectedIDs, ["archived"])
        XCTAssertEqual(selection.error, tr("Couldn't unhide %@ items. Please try again.", "1"))
        await mock.setFailure(nil)
        await selection.setHidden(false)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertTrue(library.months.flatMap(\.assets).isEmpty)
    }

    func testHideWithoutSelectionDoesNotWrite() async {
        let (library, mock, _) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        await selection.setHidden(true)
        let requests = await mock.requests
        XCTAssertEqual(requests.filter { if case .setHidden = $0 { true } else { false } }.count, 0)
    }

    func testEmptyFavoriteBatchDoesNotWrite() async {
        let (library, mock, _) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        await selection.setFavorites(true)
        XCTAssertFalse(selection.isBusy)
        let requests = await mock.requests
        XCTAssertEqual(requests.filter { if case .setFavorite = $0 { true } else { false } }.count, 0)
    }

    func testFavoritesOnlyRemovalUpdatesCountsAndDoesNotReappearFromCache() async throws {
        let (library, _, _) = await selectionFixture()
        var options = library.options
        options.isFavorite = true
        await library.setOptions(options)
        await library.loadAllMonths()
        let favorite = try XCTUnwrap(library.months.flatMap(\.assets).first)
        let count = library.totalCount
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(favorite)
        await selection.setFavorites(false)
        XCTAssertNil(library.gridIndex(ofAsset: favorite.id))
        XCTAssertEqual(library.totalCount, count - 1)
        await library.loadAllMonths()
        XCTAssertNil(library.gridIndex(ofAsset: favorite.id))
        await library.load()
        XCTAssertNil(library.gridIndex(ofAsset: favorite.id))
        XCTAssertEqual(library.totalCount, count - 1)
    }

    func testNoSelectionDoesNotWriteOrDownload() async {
        let (library, mock, _) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        await selection.setFavorites(true)
        await selection.prepareShare()
        selection.start()
        await selection.setFavorites(false)
        await selection.prepareShare()
        let mutations = await mock.requests.filter {
            switch $0 { case .setFavorite, .mediaRequest, .original: true; default: false }
        }
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertNil(selection.sharedFiles)
    }

    func testRefreshReconcilesLaterServerFavoriteChanges() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        await selection.setFavorites(true)
        _ = try await mock.setFavorite(assetID: assets[0].id, isFavorite: false)
        await library.load()
        await library.loadAllMonths()
        XCTAssertEqual(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: assets[0].id)))?.isFavorite, false)
    }

    func testLaterMonthSnapshotDoesNotRestoreOldFavoriteFlag() async throws {
        let (_, mock, assets) = await selectionFixture()
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await library.load()
        let unloaded = try XCTUnwrap(library.months.first)
        XCTAssertFalse(unloaded.isLoaded)
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[2])
        await selection.setFavorites(true)
        // The Timeline actor still has a cached copy of the newest month from before the write.
        await library.loadMonth(unloaded.id)
        let index = try XCTUnwrap(library.gridIndex(ofAsset: assets[2].id))
        XCTAssertEqual(library.gridAsset(atGridIndex: index)?.isFavorite, true)
        XCTAssertEqual(library.gridItemCount, assets.count)
    }
}

@MainActor
func selectionFixture(names: [String] = ["photo.jpg", "photo.jpg", "../movie.mov"]) async -> (LibraryGridModel, MockImmichService, [Asset]) {
    let dates = ["2026-08-01T12:00:00Z", "2026-09-01T12:00:00Z", "2026-10-01T12:00:00Z"]
    let assets = dates.enumerated().map { index, date in
        Asset(id: "selection-\(index)", kind: index == 2 ? .video : .image,
              takenAt: ISO8601DateFormatter().date(from: date)!, isFavorite: index == 1,
              originalFileName: names[index])
    }
    let mock = MockImmichService(assets: assets)
    let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    await library.load()
    await library.loadAllMonths()
    return (library, mock, assets)
}
