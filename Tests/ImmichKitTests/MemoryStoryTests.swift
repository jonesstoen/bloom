import XCTest
import ImmichKit
@testable import ImmichUI

/// Contract tests for Memories story grouping and tap-through navigation.
@MainActor
final class MemoryStoryTests: XCTestCase {
    private func date(_ year: Int, _ month: Int = 6, _ day: Int = 15, _ hour: Int = 12) -> Date {
        Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func asset(_ id: String, year: Int, month: Int = 6, day: Int = 15, hour: Int = 12,
                       takenAt: Date? = nil, kind: Asset.Kind = .image) -> Asset {
        Asset(id: id, kind: kind, takenAt: takenAt ?? date(year, month, day, hour),
              localDateTime: date(year, month, day, hour))
    }

    private func memory(_ id: String, declaredYear: Int, assets: [Asset]) -> Memory {
        Memory(id: id, kind: .onThisDay(year: declaredYear), memoryAt: date(declaredYear), assets: assets)
    }

    func testGroupsByCapturedLocalYearRatherThanMemoryYearAndSortsYearsNewestFirst() {
        let memories = [
            memory("source-2020", declaredYear: 2020, assets: [asset("a", year: 2024)]),
            memory("source-2022", declaredYear: 2022, assets: [asset("b", year: 2022)]),
            memory("source-2019", declaredYear: 2019, assets: [asset("c", year: 2024)])
        ]

        let years = MemoryStoryModel.groupedYears(from: memories)
        XCTAssertEqual(years.map(\.year), [2024, 2022])
        XCTAssertEqual(years.map(\.id), [2024, 2022])
        XCTAssertEqual(years[0].assets.map(\.id), ["a", "c"])
    }

    func testBirthdayMemoryUsesAssetCaptureYearInsteadOfBirthdayYear() {
        let birthday = Memory(
            id: "birthday",
            kind: .birthday(personId: "person", personName: "Kari", year: 2050),
            memoryAt: date(2050),
            assets: [asset("captured-2018", year: 2018)]
        )

        let years = MemoryStoryModel.groupedYears(from: [birthday])
        XCTAssertEqual(years.map(\.year), [2018])
        XCTAssertEqual(years.first?.assets.map(\.id), ["captured-2018"])
    }

    func testGroupsByUTCEncodedLocalDateAcrossYearBoundary() {
        // localDateTime is a wall-clock date encoded as UTC; use it even when takenAt falls
        // in another UTC year, as can happen when the capture timezone differs.
        let asset = self.asset("boundary", year: 2025, month: 1, day: 1, hour: 0,
                               takenAt: date(2024, 12, 31, 23))
        let years = MemoryStoryModel.groupedYears(from: [memory("m", declaredYear: 1999, assets: [asset])])
        XCTAssertEqual(years.map(\.year), [2025])
        XCTAssertEqual(years.first?.assets.map(\.id), ["boundary"])
    }

    func testDeduplicatesAssetIDsGloballyKeepingFirstOccurrence() {
        let first = asset("duplicate", year: 2023, month: 2)
        let laterCopy = asset("duplicate", year: 2021, month: 9)
        let years = MemoryStoryModel.groupedYears(from: [
            memory("first", declaredYear: 2020, assets: [first]),
            memory("second", declaredYear: 2021, assets: [laterCopy, asset("other", year: 2021)])
        ])

        XCTAssertEqual(years.map(\.year), [2023, 2021])
        XCTAssertEqual(years[0].assets.map(\.id), ["duplicate"])
        XCTAssertEqual(years[1].assets.map(\.id), ["other"])
    }

    func testSortsAssetsByCaptureDateThenLocalDateAndID() {
        let sameTakenAt = date(2022, 6, 15)
        let assets = [
            asset("z", year: 2022, month: 6, day: 16, takenAt: sameTakenAt),
            asset("b", year: 2022, month: 6, day: 15, takenAt: sameTakenAt),
            asset("a", year: 2022, month: 6, day: 15, takenAt: sameTakenAt),
            asset("earlier", year: 2022, month: 6, day: 14, takenAt: date(2022, 6, 14))
        ]

        let years = MemoryStoryModel.groupedYears(from: [memory("m", declaredYear: 2022, assets: assets)])
        XCTAssertEqual(years.first?.assets.map(\.id), ["earlier", "a", "b", "z"])
    }

    func testInitializerFiltersEmptyYearsSortsAndFallsBackForUnknownStartingYear() {
        let years = [
            MemoryStoryYear(year: 2020, assets: [asset("old", year: 2020)]),
            MemoryStoryYear(year: 2024, assets: []),
            MemoryStoryYear(year: 2022, assets: [asset("newer", year: 2022)])
        ]
        let model = MemoryStoryModel(years: years, startingYear: 2010)

        XCTAssertEqual(model.years.map(\.year), [2022, 2020])
        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "newer")
        XCTAssertEqual(model.assetIndex, 0)
        XCTAssertFalse(model.isFinished)
    }

    func testStartsAtRequestedYearWhenItExists() {
        let model = MemoryStoryModel(years: [
            MemoryStoryYear(year: 2024, assets: [asset("new", year: 2024)]),
            MemoryStoryYear(year: 2022, assets: [asset("chosen", year: 2022, day: 1), asset("last", year: 2022, day: 2)])
        ], startingYear: 2022)

        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "chosen")
    }

    func testNextTraversesAssetsThenOlderYearsAndFinishesOnLastAsset() {
        let model = MemoryStoryModel(years: [
            MemoryStoryYear(year: 2024, assets: [asset("24a", year: 2024, day: 1), asset("24b", year: 2024, day: 2)]),
            MemoryStoryYear(year: 2022, assets: [asset("22a", year: 2022, day: 1)])
        ])

        XCTAssertEqual(model.currentAsset?.id, "24a")
        XCTAssertFalse(model.canGoPrevious)
        model.next()
        XCTAssertEqual(model.currentAsset?.id, "24b")
        model.next()
        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "22a")
        model.next()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "22a")
        model.next()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.currentAsset?.id, "22a")
    }

    func testPreviousTraversesBackToNewerYearAndNoopsAtNewestBoundary() {
        let model = MemoryStoryModel(years: [
            MemoryStoryYear(year: 2024, assets: [asset("24a", year: 2024, day: 1), asset("24b", year: 2024, day: 2)]),
            MemoryStoryYear(year: 2022, assets: [asset("22a", year: 2022, day: 1), asset("22b", year: 2022, day: 2)])
        ])

        model.previous()
        XCTAssertEqual(model.currentAsset?.id, "24a")
        XCTAssertFalse(model.canGoPrevious)
        model.next(); model.next(); model.next()
        XCTAssertEqual(model.currentAsset?.id, "22b")
        model.previous()
        XCTAssertEqual(model.currentAsset?.id, "22a")
        model.previous()
        XCTAssertEqual(model.currentYear?.year, 2024)
        XCTAssertEqual(model.currentAsset?.id, "24b")
    }

    func testPreviousFromFinishedReplayPositionReturnsToLastAssetOnly() {
        let model = MemoryStoryModel(years: [
            MemoryStoryYear(year: 2024, assets: [asset("24", year: 2024)]),
            MemoryStoryYear(year: 2022, assets: [asset("22", year: 2022)])
        ])
        model.next(); model.next()
        XCTAssertTrue(model.isFinished)

        model.previous()
        XCTAssertFalse(model.isFinished)
        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "22")
    }

    func testSelectYearResetsToFirstAssetAndUnknownYearIsNoop() {
        let model = MemoryStoryModel(years: [
            MemoryStoryYear(year: 2024, assets: [asset("24", year: 2024)]),
            MemoryStoryYear(year: 2022, assets: [asset("22a", year: 2022, day: 1), asset("22b", year: 2022, day: 2)])
        ])
        model.next(); model.next(); model.next()
        XCTAssertTrue(model.isFinished)

        model.selectYear(2022)
        XCTAssertEqual(model.currentYear?.year, 2022)
        XCTAssertEqual(model.currentAsset?.id, "22a")
        XCTAssertFalse(model.isFinished)
        let selectedYear = model.currentYear?.year
        let selectedAsset = model.currentAsset?.id
        model.selectYear(1900)
        XCTAssertEqual(model.currentYear?.year, selectedYear)
        XCTAssertEqual(model.currentAsset?.id, selectedAsset)
        XCTAssertFalse(model.isFinished)
    }

    func testYearsRemainStableAcrossNavigation() {
        let input = [
            MemoryStoryYear(year: 2022, assets: [asset("22", year: 2022)]),
            MemoryStoryYear(year: 2024, assets: [asset("24", year: 2024)])
        ]
        let model = MemoryStoryModel(years: input)
        let snapshot = model.years
        model.next(); model.next(); model.previous(); model.selectYear(2022)
        XCTAssertEqual(model.years, snapshot)
        XCTAssertEqual(model.years.map(\.year), [2024, 2022])
    }

    func testEmptyInputIsFinishedAndAllNavigationIsSafeNoop() {
        let grouped = MemoryStoryModel.groupedYears(from: [memory("empty", declaredYear: 2024, assets: [])])
        XCTAssertTrue(grouped.isEmpty)
        let model = MemoryStoryModel(years: [])
        XCTAssertTrue(model.years.isEmpty)
        XCTAssertNil(model.currentYear)
        XCTAssertNil(model.currentAsset)
        XCTAssertTrue(model.isFinished)
        XCTAssertFalse(model.canGoPrevious)

        model.next(); model.previous(); model.selectYear(2024)
        XCTAssertNil(model.currentYear)
        XCTAssertNil(model.currentAsset)
        XCTAssertTrue(model.isFinished)
    }
}
