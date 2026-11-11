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

    func testCoverIsTheStillOfTheFeaturedDayTile() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        let cover = try XCTUnwrap(model.coverAsset(ofMonth: loaded.id))
        XCTAssertTrue(loaded.assets.contains(cover))
        if loaded.assets.contains(where: { !$0.isVideo }) { XCTAssertFalse(cover.isVideo) }
        XCTAssertEqual(cover, model.dayTiles(ofMonth: loaded.id).first?.cover, "Years opens Months at the same photo")
        XCTAssertNil(model.coverAsset(ofMonth: model.months[0].id), "not loaded yet")
        XCTAssertNil(model.coverAsset(ofMonth: "missing"))
    }

    func testDayTilesOnePerDayWithItsMiddleStill() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        let days = try XCTUnwrap(loaded.days)
        let tiles = model.dayTiles(ofMonth: loaded.id)
        XCTAssertEqual(Set(tiles.map(\.id)), Set(days.map(\.id)))
        XCTAssertEqual(tiles.count, days.count)
        for tile in tiles {
            let day = try XCTUnwrap(days.first { $0.id == tile.id })
            XCTAssertEqual(tile.day, day.day)
            XCTAssertEqual(tile.cover, LibraryGridModel.representative(of: day.assets))
        }
        // Apart from the featured first tile, days keep the grid's order.
        let rest = tiles.dropFirst().map(\.id)
        XCTAssertEqual(rest, days.map(\.id).filter { rest.contains($0) })
        XCTAssertTrue(model.dayTiles(ofMonth: model.months[0].id).isEmpty, "not loaded yet")
    }

    func testRepresentativePrefersAMiddleStill() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = (0..<5).map { Asset(id: "\($0)", kind: $0 == 2 ? .video : .image, takenAt: base.addingTimeInterval(Double($0))) }
        XCTAssertEqual(LibraryGridModel.representative(of: assets)?.id, "3")
        XCTAssertEqual(LibraryGridModel.representative(of: [assets[2]])?.id, "2")
        XCTAssertNil(LibraryGridModel.representative(of: []))
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

    func testMonthTitlesAreShortLikePhotos() {
        let october = TimeBucket(id: "2026-10-01", year: 2026, month: 10, count: 1)
        XCTAssertEqual(MonthsOverview.title(for: october, locale: Locale(identifier: "en_US")), "Oct 2026")
        let norwegian = MonthsOverview.title(for: october, locale: Locale(identifier: "nb_NO")).lowercased()
        XCTAssertTrue(norwegian.contains("okt") && norwegian.contains("2026"), norwegian)
    }

    func testLoadMonthsAroundATargetLoadsItsNeighbours() async throws {
        let model = await loadedModel(MockImmichService(library: .standard))
        let target = model.months[model.months.count / 2]
        XCTAssertFalse(target.isLoaded)
        await model.loadMonths(around: target.id, radius: 2)
        let index = try XCTUnwrap(model.months.firstIndex { $0.id == target.id })
        for i in max(0, index - 2)...min(model.months.count - 1, index + 2) {
            XCTAssertTrue(model.months[i].isLoaded, "month \(i)")
        }
        if index - 3 >= 0 { XCTAssertFalse(model.months[index - 3].isLoaded) }
        let asset = try XCTUnwrap(model.months[index].assets.first)
        XCTAssertEqual(model.monthID(ofAsset: asset.id), target.id)
        XCTAssertNil(model.monthID(ofAsset: "missing"))
        await model.loadMonths(around: "missing", radius: 2)
    }

    func testLoadAllMonthsOnceForTheMonthsView() async throws {
        let mock = MockImmichService(library: .standard)
        let model = await loadedModel(mock)
        XCTAssertFalse(model.allMonthsLoaded)
        await model.loadAllMonths()
        XCTAssertTrue(model.allMonthsLoaded)
        XCTAssertEqual(model.gridItemCount, model.months.reduce(0) { $0 + $1.assets.count })
        let requests = await mock.requests.count
        await model.loadAllMonths()
        let again = await mock.requests.count
        XCTAssertEqual(again, requests, "already loaded: no requests")
        // Months loaded by a replaced timeline are not applied.
        var options = model.options
        options.isFavorite = true
        await model.setOptions(options)
        XCTAssertTrue(model.months.filter(\.isLoaded).flatMap(\.assets).allSatisfy(\.isFavorite))
    }
}
