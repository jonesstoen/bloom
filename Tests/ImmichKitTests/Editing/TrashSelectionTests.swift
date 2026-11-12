import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class TrashSelectionTests: XCTestCase {
    func testRequestCapturesConfirmationSnapshotAndDoesNotWriteUntilConfirmed() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[1])

        selection.requestTrash()

        XCTAssertEqual(selection.pendingTrashAssets?.map(\.id), [assets[0].id, assets[1].id])
        selection.toggle(assets[2])
        await selection.setFavorites(true)
        await selection.prepareShare()
        XCTAssertEqual(selection.selectedIDs, Set([assets[0].id, assets[1].id]))
        let requests = await mock.requests
        XCTAssertTrue(requests.filter { if case .moveToTrash = $0 { true } else { false } }.isEmpty)
        XCTAssertFalse(requests.contains { if case .setFavorite = $0 { true } else { false } })
    }

    func testCancelConfirmationLeavesSelectionAndMakesNoTrashRequest() async {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])

        selection.requestTrash()
        selection.cancelTrashConfirmation()

        XCTAssertNil(selection.pendingTrashAssets)
        XCTAssertEqual(selection.selectedIDs, [assets[0].id])
        let writes = await mock.requestCount(.moveToTrash(assets[0].id))
        XCTAssertEqual(writes, 0)
    }

    func testConfirmMovesOnlySuccessfulAssetsAndKeepsFailedItemsSelectedForRetry() async throws {
        let (library, mock, assets) = await selectionFixture()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[1])
        await mock.setTrashFailures([assets[1].id])
        await mock.setLatency(.milliseconds(50))

        selection.requestTrash()
        let confirm = Task { await selection.confirmTrash() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !selection.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(selection.isBusy)
        await selection.confirmTrash()
        await selection.setFavorites(false)
        selection.toggle(assets[2])
        await confirm.value

        XCTAssertNil(library.gridIndex(ofAsset: assets[0].id))
        XCTAssertNotNil(library.gridIndex(ofAsset: assets[1].id))
        XCTAssertEqual(selection.selectedIDs, [assets[1].id])
        XCTAssertNotNil(selection.error)
        let firstWrites = await mock.requestCount(.moveToTrash(assets[0].id))
        let secondWrites = await mock.requestCount(.moveToTrash(assets[1].id))
        XCTAssertEqual(firstWrites, 1)
        XCTAssertEqual(secondWrites, 1)

        await mock.setTrashFailures([])
        selection.requestTrash()
        await selection.confirmTrash()
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
        XCTAssertNil(library.gridIndex(ofAsset: assets[1].id))
        let firstWritesAfterRetry = await mock.requestCount(.moveToTrash(assets[0].id))
        let secondWritesAfterRetry = await mock.requestCount(.moveToTrash(assets[1].id))
        XCTAssertEqual(firstWritesAfterRetry, 1)
        XCTAssertEqual(secondWritesAfterRetry, 2)
    }

    func testCancellationDuringBatchKeepsEarlierConfirmationAndOnlyFailedItemSelected() async throws {
        let (library, mock, assets) = await selectionFixture()
        await mock.setLatency(.milliseconds(250))
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.toggle(assets[1])
        selection.requestTrash()

        let confirmation = Task { await selection.confirmTrash() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await mock.requestCount(.moveToTrash(assets[1].id)) == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        confirmation.cancel()
        await confirmation.value

        XCTAssertNil(selection.pendingTrashAssets)
        XCTAssertNil(library.gridIndex(ofAsset: assets[0].id))
        XCTAssertNotNil(library.gridIndex(ofAsset: assets[1].id))
        XCTAssertEqual(selection.selectedIDs, [assets[1].id])
        let firstAsset = try await mock.asset(id: assets[0].id)
        XCTAssertTrue(firstAsset.isTrashed)
    }

    func testRecentlyDeletedTimelineRefusesTrashFromRequestAndDirectGridAction() async throws {
        let (library, mock, assets) = await selectionFixture()
        await mock.setAssets(assets.map { asset in
            var trashed = asset
            trashed.isTrashed = true
            return trashed
        })
        var options = library.options
        options.isTrashed = true
        options.visibility = nil
        await library.setOptions(options)
        await library.load()
        let trashAsset = try XCTUnwrap(library.months.flatMap(\.assets).first)
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(trashAsset)

        selection.requestTrash()
        let directResult = try await library.moveToTrash([trashAsset])

        XCTAssertNil(selection.pendingTrashAssets)
        XCTAssertTrue(directResult.confirmedIDs.isEmpty)
        XCTAssertTrue(directResult.failedIDs.isEmpty)
        let writes = await mock.requestCount(.moveToTrash(trashAsset.id))
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(assets.contains { $0.id == trashAsset.id })
    }
}
