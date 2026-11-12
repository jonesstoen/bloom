import Foundation
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class RestoreModelTests: XCTestCase {
    func testRestoreFromTrashRemovesOnlyConfirmedIDsAndKeepsTrashRevisionStable() async throws {
        let trashed = fixtureAssets()
        let mock = MockImmichService(assets: trashed)
        await mock.setRestoreFailures([trashed[1].id])
        let model = try await grid(mock, options: trashOptions())
        let initialTrashRevision = model.trashRevision

        let result = try await model.restoreFromTrash(trashed)

        XCTAssertEqual(result.confirmedIDs, [trashed[0].id, trashed[2].id])
        XCTAssertEqual(result.failedIDs, [trashed[1].id])
        XCTAssertNil(model.gridIndex(ofAsset: trashed[0].id))
        XCTAssertNotNil(model.gridIndex(ofAsset: trashed[1].id))
        XCTAssertNil(model.gridIndex(ofAsset: trashed[2].id))
        XCTAssertEqual(model.trashRevision, initialTrashRevision)
        let firstWrites = await mock.requestCount(.restoreAssets(trashed[0].id))
        let failedWrites = await mock.requestCount(.restoreAssets(trashed[1].id))
        XCTAssertEqual(firstWrites, 1)
        XCTAssertEqual(failedWrites, 1)
    }

    func testMainLibraryRestoreInvalidatesCacheBeforeWriteAndReloadsCurrentFilter() async throws {
        let trashed = fixtureAssets(favorites: true)
        let regular = Asset(id: "regular", kind: .image,
                            takenAt: date(year: 2024, month: 4), isFavorite: true)
        let mock = MockImmichService(assets: [regular] + trashed)
        var options = TimelineOptions.library
        options.isFavorite = true
        options.sortsByDateAdded = true
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let model = try await grid(mock, options: options, store: store)
        await model.loadAllMonths()
        await store.save(months: model.months, options: options)
        let cachedBefore = await store.load(options: options)
        XCTAssertNotNil(cachedBefore)
        let oldRestoreRevision = model.restoreRevision
        let oldTrashRevision = model.trashRevision
        await mock.setLatency(.milliseconds(120))

        let restore = Task { try await model.restoreToLibrary([trashed[0]]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.isMutating && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.isMutating)
        let cachedDuring = await store.load(options: options)
        XCTAssertNil(cachedDuring, "A pre-restore snapshot must be invalidated before the write")
        let result = try await restore.value

        XCTAssertEqual(result.confirmedIDs, [trashed[0].id])
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertFalse(model.isMutating)
        XCTAssertEqual(model.restoreRevision, oldRestoreRevision + 1)
        XCTAssertEqual(model.trashRevision, oldTrashRevision)
        XCTAssertEqual(model.options, options, "The restored timeline must retain favorite and recently-added options")
        XCTAssertNotNil(model.gridIndex(ofAsset: trashed[0].id))
        XCTAssertNil(model.gridIndex(ofAsset: trashed[1].id), "A server-side filter still excludes assets that do not match")
        let cacheDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var cached = await store.load(options: options)
        while cached == nil && ContinuousClock.now < cacheDeadline {
            try await Task.sleep(for: .milliseconds(30))
            cached = await store.load(options: options)
        }
        XCTAssertNotNil(cached)
        XCTAssertTrue(cached?.flatMap(\.assets).contains { $0.id == trashed[0].id } == true)
        let restoreWrites = await mock.requestCount(.restoreAssets(trashed[0].id))
        XCTAssertEqual(restoreWrites, 1)
    }

    func testFailedMainRestoreUsesFreshServerTimelineAndLaterExternalRestoreAppearsOnRefresh() async throws {
        let trashed = fixtureAssets()
        let mock = MockImmichService(assets: trashed)
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let model = try await grid(mock, options: .library, store: store)
        await model.loadAllMonths()
        await store.save(months: model.months, options: .library)
        await mock.setRestoreFailures([trashed[0].id])

        let result = try await model.restoreToLibrary([trashed[0]])

        XCTAssertTrue(result.confirmedIDs.isEmpty)
        XCTAssertEqual(result.failedIDs, [trashed[0].id])
        XCTAssertFalse(model.needsMutationRefresh, "A successful fresh timeline response resolves the uncertain write")
        XCTAssertEqual(model.gridItemCount, 0)
        await mock.setAssets(trashed.map { asset in
            var restored = asset
            restored.isTrashed = false
            return restored
        })
        await model.load()
        await model.loadAllMonths()
        XCTAssertNotNil(model.gridIndex(ofAsset: trashed[0].id))
        XCTAssertFalse(model.needsMutationRefresh)
        let cacheDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var cacheAfterRefresh = await store.load(options: .library)
        while cacheAfterRefresh == nil && ContinuousClock.now < cacheDeadline {
            try await Task.sleep(for: .milliseconds(30))
            cacheAfterRefresh = await store.load(options: .library)
        }
        XCTAssertNotNil(cacheAfterRefresh)
    }

    func testWrongContextAndEmptyTargetsDoNotCallService() async throws {
        let trashed = fixtureAssets()
        let mock = MockImmichService(assets: trashed)
        let main = try await grid(mock, options: .library)
        let wrong = try await main.restoreToLibrary([Asset(id: "active", kind: .image, takenAt: date(year: 2024, month: 2))])
        let emptyMain = try await main.restoreToLibrary([])

        XCTAssertTrue(wrong.confirmedIDs.isEmpty)
        XCTAssertTrue(emptyMain.confirmedIDs.isEmpty)
        let trash = try await grid(mock, options: trashOptions())
        let wrongTrash = try await trash.restoreFromTrash([Asset(id: "active", kind: .image, takenAt: date(year: 2024, month: 2))])
        let emptyTrash = try await trash.restoreFromTrash([])
        let wrongMainContext = try await main.restoreFromTrash(trashed)
        let wrongTrashContext = try await trash.restoreToLibrary(trashed)
        XCTAssertTrue(wrongTrash.confirmedIDs.isEmpty)
        XCTAssertTrue(emptyTrash.confirmedIDs.isEmpty)
        XCTAssertTrue(wrongMainContext.confirmedIDs.isEmpty)
        XCTAssertTrue(wrongTrashContext.confirmedIDs.isEmpty)
        let requests = await mock.requests
        XCTAssertFalse(requests.contains { if case .restoreAssets = $0 { true } else { false } })
    }

    private func fixtureAssets(favorites: Bool = false) -> [Asset] {
        (1...3).map { month in
            Asset(id: "restore-model-\(month)", kind: .image, takenAt: date(year: 2024, month: month),
                  isFavorite: favorites, isTrashed: true)
        }
    }

    private func date(year: Int, month: Int) -> Date {
        Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: 4))!
    }

    private func trashOptions() -> TimelineOptions {
        TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false)
    }

    private func grid(_ service: MockImmichService, options: TimelineOptions,
                      store: TimelineSnapshotStore? = nil) async throws -> LibraryGridModel {
        let model = LibraryGridModel(service: service, options: options,
                                     loader: ImageLoader(service: service, disk: nil), snapshotStore: store)
        await model.load()
        await model.loadAllMonths()
        return model
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
