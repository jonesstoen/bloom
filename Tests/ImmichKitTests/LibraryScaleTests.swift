import XCTest
import ImmichKit
@testable import ImmichUI

/// Years / Months / All and the Library's sort and filter menu.
@MainActor
final class LibraryScaleTests: XCTestCase {
    private func loadedModel(_ mock: MockImmichService = .preview) async -> LibraryGridModel {
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        return model
    }

    func testYearsGroupMonthsInGridOrder() async {
        let model = await loadedModel()
        let years = model.years
        XCTAssertGreaterThan(years.count, 1)
        XCTAssertEqual(years.map(\.year), years.map(\.year).sorted(), "oldest first, like the grid")
        XCTAssertEqual(years.flatMap(\.monthIDs), model.months.map(\.id))
        XCTAssertEqual(years.reduce(0) { $0 + $1.count }, model.totalCount)
        for year in years {
            XCTAssertTrue(year.monthIDs.allSatisfy { model.month(id: $0)?.bucket.year == year.year })
        }
    }

    func testYearsOfEmptyAndNewestFirstMonths() {
        XCTAssertTrue(LibraryGridModel.years(of: []).isEmpty)
        let months = [("2025-02-01", 2025, 2), ("2025-01-01", 2025, 1), ("2024-12-01", 2024, 12)].map {
            TimelineMonth(bucket: TimeBucket(id: $0.0, year: $0.1, month: $0.2, count: 3))
        }
        XCTAssertEqual(LibraryGridModel.years(of: months).map(\.year), [2025, 2024])
        XCTAssertEqual(LibraryGridModel.years(of: months).first?.monthIDs, ["2025-02-01", "2025-01-01"])
    }

    func testCoverIsAStillFromTheMiddleOfALoadedMonth() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        let cover = try XCTUnwrap(model.coverAsset(ofMonth: loaded.id))
        XCTAssertTrue(loaded.assets.contains(cover))
        if loaded.assets.contains(where: { !$0.isVideo }) { XCTAssertFalse(cover.isVideo) }
        XCTAssertNil(model.coverAsset(ofMonth: model.months[0].id), "not loaded yet")
        XCTAssertNil(model.coverAsset(ofMonth: "missing"))
    }

    func testFirstGridIDOfAMonth() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        XCTAssertEqual(model.firstGridID(ofMonth: loaded.id), AnyHashable(loaded.assets[0].id))
        let unloaded = model.months[0]
        XCTAssertEqual(model.firstGridID(ofMonth: unloaded.id), AnyHashable(PlaceholderSlots.Slot(monthID: unloaded.id, index: 0)))
        XCTAssertNil(model.firstGridID(ofMonth: "missing"))
    }

    func testFavoritesFilterReloadsWithOnlyFavorites() async throws {
        let model = await loadedModel(MockImmichService(library: .standard))
        let allCount = model.totalCount
        var options = model.options
        options.isFavorite = true
        await model.setOptions(options)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.options.isFavorite, true)
        let favoriteCount = MockLibrary.standard.assets.filter { $0.isFavorite && !$0.isArchived && !$0.isTrashed }.count
        XCTAssertEqual(model.totalCount, favoriteCount)
        XCTAssertLessThan(model.totalCount, allCount)
        XCTAssertTrue(model.months.filter(\.isLoaded).flatMap(\.assets).allSatisfy(\.isFavorite))

        options.isFavorite = nil
        await model.setOptions(options)
        XCTAssertEqual(model.totalCount, allCount)
    }

    func testSetOptionsKeepsTheGridOrderAndIgnoresNoChange() async {
        let mock = MockImmichService(library: .standard)
        let model = await loadedModel(mock)
        let requestsBefore = await mock.requests.count
        await model.setOptions(model.options)
        let requestsAfter = await mock.requests.count
        XCTAssertEqual(requestsAfter, requestsBefore, "same options: no reload")
        var options = model.options
        options.newestFirst = !model.newestFirst
        options.sortsByDateAdded = true
        await model.setOptions(options)
        XCTAssertEqual(model.options.newestFirst, model.newestFirst, "the grid's order stays")
        XCTAssertTrue(model.options.sortsByDateAdded)
    }
}
