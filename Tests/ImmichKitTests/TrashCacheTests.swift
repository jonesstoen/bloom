import Foundation
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class TrashCacheTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func month(assetID: String) -> TimelineMonth {
        let date = Asset.localCalendar.date(from: DateComponents(year: 2024, month: 3, day: 4))!
        let asset = Asset(id: assetID, kind: .image, takenAt: date)
        let day = TimelineDay(year: 2024, month: 3, day: 4, assets: [asset])
        return TimelineMonth(bucket: TimeBucket(id: "2024-03-01", year: 2024, month: 3, count: 1), days: [day])
    }

    func testClearAllAdvancesRevisionAndRemovesPersistedSnapshot() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: [month(assetID: "before-trash")], options: .library)
        let before = await store.load(options: .library)
        XCTAssertNotNil(before)

        let revision = await store.clearAll()

        XCTAssertEqual(revision, 1)
        let storedRevision = await store.revision
        let afterClear = await store.load(options: .library)
        XCTAssertEqual(storedRevision, revision)
        XCTAssertNil(afterClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStaleTimelineSaveTokenCannotRecreateSnapshotAfterTrashClear() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let oldRevision = await store.revision
        let newRevision = await store.clearAll()

        await store.save(months: [month(assetID: "stale")], options: .library, expectedRevision: oldRevision)
        let afterStaleWrite = await store.load(options: .library)
        XCTAssertNil(afterStaleWrite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        await store.save(months: [month(assetID: "fresh")], options: .library, expectedRevision: newRevision)
        let restored = await store.load(options: .library)
        XCTAssertEqual(restored?.flatMap(\.assets).map(\.id), ["fresh"])
    }

    func testClearAllRemovesEveryOptionsPartitionAndStaysEmptyAfterReopen() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        var trash = TimelineOptions.library
        trash.isTrashed = true
        trash.visibility = nil
        var favorite = TimelineOptions.library
        favorite.isFavorite = true
        var recentlyAdded = TimelineOptions.library
        recentlyAdded.sortsByDateAdded = true
        let options = [TimelineOptions.library, trash, favorite, recentlyAdded,
                       TimelineOptions(visibility: .archive)]
        for (index, option) in options.enumerated() {
            await store.save(months: [month(assetID: "option-\(index)")], options: option)
        }

        _ = await store.clearAll()
        let reopened = TimelineSnapshotStore(directory: directory)

        for option in options {
            let snapshot = await reopened.load(options: option)
            XCTAssertNil(snapshot, "Trash must invalidate every timeline options partition")
        }
    }

    func testConfirmedGridTrashAdvancesTrashRevisionAndRemovesAssetFromGrid() async throws {
        let (library, mock, assets) = await selectionFixture()
        let initialRevision = library.trashRevision
        let result = try await library.moveToTrash([assets[0]])

        XCTAssertEqual(result.confirmedIDs, [assets[0].id])
        XCTAssertEqual(library.trashRevision, initialRevision + 1)
        XCTAssertNil(library.gridIndex(ofAsset: assets[0].id))
        XCTAssertEqual(library.gridItemCount, assets.count - 1)
        let serverAsset = try await mock.asset(id: assets[0].id)
        XCTAssertTrue(serverAsset.isTrashed)
    }

    func testConfirmedTrashClearsPersistedTimelineSnapshot() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let assets = [monthAsset(id: "cached-photo")]
        let mock = MockImmichService(assets: assets)
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil), snapshotStore: store)
        await library.load()
        await library.loadAllMonths()
        await store.save(months: library.months, options: library.options)
        let cachedBeforeTrash = await store.load(options: library.options)
        XCTAssertNotNil(cachedBeforeTrash)

        _ = try await library.moveToTrash(assets)

        let cachedAfterTrash = await store.load(options: library.options)
        XCTAssertNil(cachedAfterTrash)
        let revision = await store.revision
        XCTAssertEqual(revision, 1)
    }

    func testCacheIsAlreadyClearedWhileServerMutationIsInFlight() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let assets = [monthAsset(id: "in-flight-photo")]
        let mock = MockImmichService(assets: assets)
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil), snapshotStore: store)
        await library.load()
        await library.loadAllMonths()
        var trashOptions = TimelineOptions.library
        trashOptions.isTrashed = true
        trashOptions.visibility = nil
        var favoriteOptions = TimelineOptions.library
        favoriteOptions.isFavorite = true
        var addedOptions = TimelineOptions.library
        addedOptions.sortsByDateAdded = true
        let options = [library.options, trashOptions, favoriteOptions, addedOptions,
                       TimelineOptions(visibility: .archive)]
        for option in options {
            await store.save(months: library.months, options: option)
        }
        let cachedBefore = await store.load(options: library.options)
        XCTAssertNotNil(cachedBefore)
        await mock.setLatency(.milliseconds(250))

        let mutation = Task { try await library.moveToTrash(assets) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !library.isTrashing && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(library.isTrashing)
        for option in options {
            let snapshotDuringMutation = await store.load(options: option)
            XCTAssertNil(snapshotDuringMutation, "A force quit after server success must not reopen a stale snapshot")
        }
        _ = try await mutation.value
        let snapshotAfterMutation = await TimelineSnapshotStore(directory: directory).load(options: library.options)
        XCTAssertNil(snapshotAfterMutation)
    }

    func testAllFailedTrashDoesNotRestoreOldCachedGrid() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let asset = monthAsset(id: "failed-trash")
        let mock = MockImmichService(assets: [asset])
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil), snapshotStore: store)
        await library.load()
        await library.loadAllMonths()
        await store.save(months: library.months, options: library.options)
        await mock.setTrashFailures([asset.id])

        let result = try await library.moveToTrash([asset])

        XCTAssertTrue(result.confirmedIDs.isEmpty)
        XCTAssertEqual(result.failedIDs, [asset.id])
        let snapshotAfterFailure = await store.load(options: library.options)
        XCTAssertNil(snapshotAfterFailure, "Even an uncertain failure cannot leave the old pre-action snapshot reusable")
    }

    func testExplicitRefreshCanRestoreAssetAfterExternalUntrash() async throws {
        let (library, mock, assets) = await selectionFixture()
        let target = assets[0]
        _ = try await library.moveToTrash([target])
        XCTAssertNil(library.gridIndex(ofAsset: target.id))
        await mock.setAssets(assets)

        await library.load()
        await library.loadAllMonths()

        XCTAssertNotNil(library.gridIndex(ofAsset: target.id))
        XCTAssertEqual(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: target.id)))?.isTrashed, false)
    }

    func testBackgroundLoadAllDoesNotDropUnconfirmedItemsAfterUnknownTrashOutcome() async throws {
        let assets = (1...3).map { (month: Int) in
            Asset(id: "unknown-\(month)", kind: .image,
                  takenAt: Asset.localCalendar.date(from: DateComponents(year: 2024, month: month, day: 4))!)
        }
        let mock = MockImmichService(assets: assets)
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await library.load()
        XCTAssertFalse(library.allMonthsLoaded)
        let target = assets[2]
        await mock.setTrashFailures([target.id])
        let result = try await library.moveToTrash([target])
        XCTAssertEqual(result.failedIDs, [target.id])
        let before = library.months.flatMap(\.assets).map(\.id)

        // The Library's initial background warmup may finish after a failed move. Its
        // replacement Timeline has no authoritative buckets until an explicit refresh.
        await library.loadAllMonths()

        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), before)
        XCTAssertNotNil(library.gridIndex(ofAsset: target.id))
    }

    func testSignOutDoesNotDiscardSessionWhileTrashMutationIsInFlight() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        try store.save(ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder"))
        let mock = MockImmichService.preview
        let root = RootModel(store: store, makeService: { _ in mock })
        await root.restore()
        let library = try XCTUnwrap(root.session?.library)
        await library.load()
        let asset = try XCTUnwrap(library.months.flatMap(\.assets).first)
        await mock.setLatency(.milliseconds(150))

        let mutation = Task { try await library.moveToTrash([asset]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !library.isTrashing && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(library.isTrashing)
        await root.signOut()

        XCTAssertEqual(root.phase, .signedIn)
        XCTAssertNotNil(root.session)
        XCTAssertNotNil(try store.load())
        _ = try await mutation.value
    }

    func testSearchResultsInvalidateAfterTrashWhileQueryAndRecentHistoryRemain() async throws {
        let mock = MockImmichService.preview
        let search = SearchModel(service: mock, pageSize: 2)
        search.selectCity("Oslo")
        await search.search()
        XCTAssertFalse(search.assets.isEmpty)
        XCTAssertNotNil(search.next)
        let queryBefore = search.query
        let textBefore = search.text
        let historyBefore = search.recentSearches
        let trashedID = try XCTUnwrap(search.assets.first?.id)

        search.invalidateAfterLibraryMutation()

        XCTAssertTrue(search.assets.isEmpty)
        XCTAssertNil(search.next)
        XCTAssertFalse(search.hasSearched)
        XCTAssertEqual(search.query, queryBefore)
        XCTAssertEqual(search.text, textBefore)
        XCTAssertEqual(search.recentSearches, historyBefore)
        await mock.setAssets(mock.assets.map { asset in
            var updated = asset
            if updated.id == trashedID { updated.isTrashed = true }
            return updated
        })
        await search.search()
        XCTAssertFalse(search.assets.contains { $0.id == trashedID })
    }

    private func monthAsset(id: String) -> Asset {
        let date = Asset.localCalendar.date(from: DateComponents(year: 2024, month: 3, day: 4))!
        return Asset(id: id, kind: .image, takenAt: date)
    }
}
