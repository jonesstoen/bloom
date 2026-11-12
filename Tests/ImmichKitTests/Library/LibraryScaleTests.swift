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

    func testCoverIsThePhotoOfTheFeaturedTile() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        let cover = try XCTUnwrap(model.coverAsset(ofMonth: loaded.id))
        XCTAssertTrue(loaded.assets.contains(cover))
        if loaded.assets.contains(where: { !$0.isVideo }) { XCTAssertFalse(cover.isVideo) }
        XCTAssertEqual(cover, model.monthPlan(ofMonth: loaded.id).featured?.cover, "Years opens Months at the same photo")
        XCTAssertNil(model.coverAsset(ofMonth: model.months[0].id), "not loaded yet")
        XCTAssertNil(model.coverAsset(ofMonth: "missing"))
    }

    func testMonthPlanTilesAreDaysOfTheMonth() async throws {
        let model = await loadedModel()
        let loaded = try XCTUnwrap(model.months.last)
        let days = try XCTUnwrap(loaded.days)
        let plan = model.monthPlan(ofMonth: loaded.id)
        XCTAssertFalse(plan.tiles.isEmpty)
        XCTAssertEqual(Set(plan.tiles.map(\.id)).count, plan.tiles.count, "each day once")
        for tile in plan.tiles {
            let day = try XCTUnwrap(days.first { $0.id == tile.id })
            XCTAssertEqual(tile.day, day.day)
            XCTAssertTrue(day.assets.contains(tile.cover))
        }
        XCTAssertTrue(model.monthPlan(ofMonth: model.months[0].id).tiles.isEmpty, "not loaded yet")
    }

    func testYearCoverIsOneOfItsMonthsAndRotates() async throws {
        let model = await loadedModel(MockImmichService(library: .standard))
        let year = try XCTUnwrap(model.years.first { $0.monthIDs.count >= 4 })
        // Until all its months are loaded: its most recent month.
        XCTAssertEqual(model.coverMonthID(ofYear: year), year.monthIDs.last)
        await model.loadAllMonths()
        var seen: Set<String> = []
        for day in 20_000..<20_030 {
            model.highlightDay = day
            let month = try XCTUnwrap(model.coverMonthID(ofYear: year))
            XCTAssertTrue(year.monthIDs.contains(month))
            XCTAssertEqual(model.coverMonthID(ofYear: year), month, "stable within a day")
            seen.insert(month)
        }
        XCTAssertGreaterThan(seen.count, 1, "the cover takes turns between days")
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

    func testLoadingMonthsWithOtherCountsReportsHowTheCentrePhotoMoved() async throws {
        let mock = MockImmichService(library: .standard)
        // The server's bucket counts are 2 lower than what the months contain.
        await mock.setBucketCountOffset(-2)
        let model = await loadedModel(mock)
        let last = try XCTUnwrap(model.months.last)
        let anchor = try XCTUnwrap(last.assets.first)
        model.assetAppeared(anchor.id)
        let before = try XCTUnwrap(model.gridIndex(ofAsset: anchor.id))
        let unloadedBefore = model.months.dropLast().filter { !$0.isLoaded }.count
        XCTAssertNil(model.gridShift)
        await model.loadAllMonths()
        let shift = try XCTUnwrap(model.gridShift)
        XCTAssertEqual(shift.anchorID, anchor.id)
        XCTAssertEqual(shift.oldIndex, before)
        XCTAssertEqual(shift.newIndex, before + 2 * unloadedBefore, "each month before it grew by 2")
        XCTAssertEqual(model.gridIndex(ofAsset: anchor.id), shift.newIndex)
        model.stopPrefetching()
    }

    func testNoShiftWhenCountsMatch() async throws {
        let model = await loadedModel(MockImmichService(library: .standard))
        let anchor = try XCTUnwrap(model.months.last?.assets.first)
        model.assetAppeared(anchor.id)
        await model.loadAllMonths()
        XCTAssertNil(model.gridShift)
        model.stopPrefetching()
    }

    // MARK: Header date range

    private func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Asset.localCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testDateRangeTitleLikePhotos() {
        let en = Locale(identifier: "en_US"), nb = Locale(identifier: "nb_NO")
        let sameMonth = LibraryGridModel.dateRangeTitle(from: utcDate(2026, 10, 23), to: utcDate(2026, 10, 29), locale: en)
        XCTAssertTrue(sameMonth.contains("23") && sameMonth.contains("29") && sameMonth.contains("Oct") && sameMonth.contains("2026"), sameMonth)
        XCTAssertEqual(sameMonth.components(separatedBy: "2026").count, 2, "year once: \(sameMonth)")
        let norwegian = LibraryGridModel.dateRangeTitle(from: utcDate(2026, 10, 23), to: utcDate(2026, 10, 29), locale: nb)
        XCTAssertTrue(norwegian.contains("23") && norwegian.contains("29") && norwegian.lowercased().contains("okt"), norwegian)
        let oneDay = LibraryGridModel.dateRangeTitle(from: utcDate(2026, 10, 4), to: utcDate(2026, 10, 4).addingTimeInterval(3600), locale: en)
        XCTAssertTrue(oneDay.contains("4") && !oneDay.contains("–") && !oneDay.contains("-"), oneDay)
        let acrossYears = LibraryGridModel.dateRangeTitle(from: utcDate(2025, 12, 30), to: utcDate(2026, 1, 2), locale: en)
        XCTAssertTrue(acrossYears.contains("2025") && acrossYears.contains("2026"), acrossYears)
    }

    func testHeaderRangeFollowsTheCellsOnScreen() async throws {
        let model = await loadedModel()
        XCTAssertNil(model.visibleDateRangeTitle)
        let last = model.gridItemCount - 1
        model.screenRangeChanged((last - 9)...last)
        let first = try XCTUnwrap(model.gridAsset(atGridIndex: last - 9))
        let newest = try XCTUnwrap(model.gridAsset(atGridIndex: last))
        let expected = LibraryGridModel.dateRangeTitle(from: min(first.localDateTime, newest.localDateTime),
                                                       to: max(first.localDateTime, newest.localDateTime))
        XCTAssertEqual(model.visibleDateRangeTitle, expected)
        // Only placeholders on screen: keep the last title rather than showing nothing.
        model.screenRangeChanged(0...5)
        XCTAssertEqual(model.visibleDateRangeTitle, expected)
    }

    func testCellLookupsMatchMonthsIncludingEmptyOnes() async throws {
        let mock = MockImmichService(library: .standard)
        let model = await loadedModel(mock)
        await model.loadAllMonths()
        var index = 0
        for month in model.months {
            for asset in month.assets {
                XCTAssertEqual(model.gridIndex(ofAsset: asset.id), index)
                XCTAssertEqual(model.gridAsset(atGridIndex: index)?.id, asset.id)
                index += 1
            }
        }
        XCTAssertEqual(model.gridItemCount, index)
        XCTAssertNil(model.gridAsset(atGridIndex: index))
        // A month with a count of 0 (here: bucket counts lowered to 0 while unloaded) takes no cells.
        await mock.setBucketCountOffset(-1_000)
        var options = model.options
        options.isFavorite = true
        await model.setOptions(options)
        XCTAssertEqual(model.gridItemCount, model.months.filter(\.isLoaded).reduce(0) { $0 + $1.assets.count })
        if model.gridItemCount > 0 {
            XCTAssertNotNil(model.gridItemID(atGridIndex: 0))
            XCTAssertNotNil(model.gridItemID(atGridIndex: model.gridItemCount - 1))
        }
    }
}
