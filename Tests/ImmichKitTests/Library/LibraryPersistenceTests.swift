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
}
