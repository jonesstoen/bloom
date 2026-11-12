import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class RestoreSelectionTests: XCTestCase {
    func testRecentlyDeletedSelectionCapturesTargetAndCancellationDoesNotRestore() async throws {
        let (selection, mock, trashed) = try await fixture()
        selection.start()
        selection.toggle(trashed[0])

        selection.requestRestore()
        selection.cancelRestoreConfirmation()
        let requests = await mock.requests

        XCTAssertNil(selection.pendingRestoreAssets)
        XCTAssertEqual(selection.selectedIDs, [trashed[0].id])
        XCTAssertFalse(requests.contains { if case .restoreAssets = $0 { true } else { false } })
    }

    func testRestoreCapturesImmutableSelectionAndBlocksOtherBatchActions() async throws {
        let (selection, mock, trashed) = try await fixture()
        selection.start()
        selection.toggle(trashed[0])
        selection.toggle(trashed[1])

        selection.requestRestore()
        selection.toggle(trashed[2])
        await selection.setFavorites(true)
        await selection.prepareShare()

        XCTAssertEqual(selection.pendingRestoreAssets?.map(\.id), [trashed[0].id, trashed[1].id])
        XCTAssertEqual(selection.selectedIDs, Set([trashed[0].id, trashed[1].id]))
        let requests = await mock.requests
        XCTAssertFalse(requests.contains { if case .restoreAssets = $0 { true } else { false } })
        XCTAssertFalse(requests.contains { if case .setFavorite = $0 { true } else { false } })
    }

    func testRestoreCannotBeRequestedFromTheMainLibraryContext() async throws {
        let assets = (1...2).map { month in
            Asset(id: "active-\(month)", kind: .image,
                  takenAt: Asset.localCalendar.date(from: DateComponents(year: 2024, month: month, day: 4))!)
        }
        let mock = MockImmichService(assets: assets)
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await library.load()
        await library.loadAllMonths()
        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(assets[0])
        selection.requestRestore()

        XCTAssertNil(selection.pendingRestoreAssets)
        let requests = await mock.requests
        XCTAssertFalse(requests.contains { if case .restoreAssets = $0 { true } else { false } })
    }

    func testConfirmedRestoreRemovesSuccessAndKeepsFailedIDsForExplicitRetry() async throws {
        let (selection, mock, trashed) = try await fixture()
        await mock.setRestoreFailures([trashed[1].id])
        selection.start()
        selection.toggle(trashed[0])
        selection.toggle(trashed[1])

        selection.requestRestore()
        await selection.confirmRestore()

        XCTAssertEqual(selection.selectedIDs, [trashed[1].id])
        XCTAssertEqual(selection.selectedAssets.map(\.id), [trashed[1].id])
        XCTAssertNotNil(selection.error)
        XCTAssertNil(selection.pendingRestoreAssets)
        let firstWrites = await mock.requestCount(.restoreAssets(trashed[0].id))
        let failedWrites = await mock.requestCount(.restoreAssets(trashed[1].id))
        XCTAssertEqual(firstWrites, 1)
        XCTAssertEqual(failedWrites, 1)

        await mock.setRestoreFailures([])
        selection.requestRestore()
        await selection.confirmRestore()

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.error)
        let firstWritesAfterRetry = await mock.requestCount(.restoreAssets(trashed[0].id))
        let failedWritesAfterRetry = await mock.requestCount(.restoreAssets(trashed[1].id))
        XCTAssertEqual(firstWritesAfterRetry, 1)
        XCTAssertEqual(failedWritesAfterRetry, 2)
    }

    func testRestoreConfirmationOnlyAvailableForAllTrashedAssets() async throws {
        let (selection, mock, trashed) = try await fixture()
        selection.start()
        selection.toggle(trashed[0])
        selection.requestRestore()
        XCTAssertEqual(selection.pendingRestoreAssets?.map(\.id), [trashed[0].id])
        selection.cancelRestoreConfirmation()
        let requests = await mock.requests
        XCTAssertFalse(requests.contains { if case .restoreAssets = $0 { true } else { false } })
    }

    func testDuplicateConfirmationWhileBusyDoesNotIssueSecondRestore() async throws {
        let (selection, mock, trashed) = try await fixture()
        await mock.setLatency(.milliseconds(80))
        selection.start()
        selection.toggle(trashed[0])
        selection.requestRestore()

        let first = Task { await selection.confirmRestore() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !selection.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(selection.isBusy)
        await selection.confirmRestore()
        await first.value

        let writes = await mock.requestCount(.restoreAssets(trashed[0].id))
        XCTAssertEqual(writes, 1)
    }

    private func fixture() async throws -> (LibrarySelectionModel, MockImmichService, [Asset]) {
        let dates = (1...3).map { Asset.localCalendar.date(from: DateComponents(year: 2024, month: $0, day: 4))! }
        let trashed = dates.enumerated().map { index, date in
            Asset(id: "restore-\(index)", kind: .image, takenAt: date, isTrashed: true)
        }
        let mock = MockImmichService(assets: trashed)
        var options = TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false)
        options.isFavorite = nil
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await library.setOptions(options)
        await library.load()
        await library.loadAllMonths()
        return (LibrarySelectionModel(library: library), mock, trashed)
    }
}
