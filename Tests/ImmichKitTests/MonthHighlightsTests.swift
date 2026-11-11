import XCTest
import ImmichKit
@testable import ImmichUI

/// The selection of days and photos for the Months and Years views.
final class MonthHighlightsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func photo(_ id: String, live: Bool = true, favorite: Bool = false, ratio: Double = 0.75) -> Asset {
        Asset(id: id, kind: .image, takenAt: base, ratio: ratio, isFavorite: favorite, livePhotoVideoId: live ? "\(id)-motion" : nil)
    }

    private func screenshot(_ id: String) -> Asset { photo(id, live: false, ratio: 1179.0 / 2556.0) }

    private func video(_ id: String) -> Asset { Asset(id: id, kind: .video, takenAt: base) }

    private func days(_ perDay: [[Asset]]) -> [TimelineDay] {
        perDay.enumerated().map { TimelineDay(year: 2026, month: 7, day: $0.offset + 1, assets: $0.element) }
    }

    func testScreenshotsAndVideosRankBelowCameraPhotos() {
        XCTAssertTrue(MonthHighlights.isLikelyScreenshot(screenshot("s")))
        XCTAssertTrue(MonthHighlights.isLikelyScreenshot(photo("landscape", live: false, ratio: 2556.0 / 1179.0)))
        XCTAssertFalse(MonthHighlights.isLikelyScreenshot(photo("live", live: true, ratio: 0.46)), "Live Photos are camera shots")
        XCTAssertFalse(MonthHighlights.isLikelyScreenshot(photo("still", live: false, ratio: 0.75)))
        XCTAssertGreaterThan(MonthHighlights.score(photo("p")), MonthHighlights.score(photo("q", live: false)))
        XCTAssertGreaterThan(MonthHighlights.score(photo("q", live: false)), MonthHighlights.score(screenshot("s")))
        XCTAssertGreaterThan(MonthHighlights.score(photo("f", favorite: true)), MonthHighlights.score(photo("p")))
        XCTAssertLessThan(MonthHighlights.score(video("v")), MonthHighlights.score(photo("q", live: false)))
        for seed in 0..<20 as Range<UInt64> {
            XCTAssertEqual(MonthHighlights.bestPhoto(of: [screenshot("s"), photo("p"), video("v")], seed: seed)?.id, "p")
        }
        XCTAssertEqual(MonthHighlights.bestPhoto(of: [video("v")], seed: 3)?.id, "v", "only videos: still a tile")
        XCTAssertNil(MonthHighlights.bestPhoto(of: [], seed: 1))
    }

    func testFewDaysAreAllShownInOrder() {
        for count in 1...3 {
            let plan = MonthHighlights.plan(days: days((0..<count).map { [photo("d\($0)")] }), seed: 42)
            XCTAssertEqual(plan.layout, .row)
            XCTAssertEqual(plan.tiles.map(\.day), Array(1...count))
        }
    }

    func testAMonthShowsASelectionWithItsBestDayFeatured() {
        // Day 7 has the most good photos and a favorite.
        // 10 days with 3 items each (30+ in the month: six tiles).
        var perDay = (0..<10).map { i in [photo("d\(i)a"), photo("d\(i)b"), screenshot("d\(i)s")] }
        perDay[6] = (0..<8).map { photo("best\($0)", favorite: $0 == 3) }
        perDay[2] = [screenshot("only-screens"), video("clip")]
        for seed in [UInt64(1), 99, 12345] {
            let plan = MonthHighlights.plan(days: days(perDay), seed: seed)
            XCTAssertEqual(plan.tiles.count, 6, "a selection, not all 10 days")
            XCTAssertEqual(plan.featured?.day, 7)
            XCTAssertEqual(plan.featured?.cover.id, "best3", "the favorite")
            guard case .feature = plan.layout else { return XCTFail("\(plan.layout)") }
            XCTAssertFalse(plan.tiles.contains { $0.day == 3 }, "a day of only screenshots and video is left out")
            let rest = plan.tiles.dropFirst().map(\.day)
            XCTAssertEqual(rest, rest.sorted(), "the other days in date order")
            XCTAssertFalse(plan.tiles.contains { MonthHighlights.isLikelyScreenshot($0.cover) })
        }
    }

    func testSmallMonthsGetFourTilesWithAWideFeature() {
        let plan = MonthHighlights.plan(days: days((0..<5).map { [photo("d\($0)")] }), seed: 5)
        XCTAssertEqual(plan.tiles.count, 4)
        XCTAssertEqual(plan.layout, .wideTop)
    }

    func testSelectionIsStableWithinADayAndRotatesBetweenDays() {
        let perDay = (0..<12).map { i in (0..<4).map { photo("d\(i)p\($0)") } }
        let month = days(perDay)
        let today = MonthHighlights.plan(days: month, seed: MonthHighlights.seed(monthID: "2026-07-01", dayNumber: 20_500))
        XCTAssertEqual(today, MonthHighlights.plan(days: month, seed: MonthHighlights.seed(monthID: "2026-07-01", dayNumber: 20_500)))
        let plans = (20_500..<20_520).map { MonthHighlights.plan(days: month, seed: MonthHighlights.seed(monthID: "2026-07-01", dayNumber: $0)) }
        XCTAssertGreaterThan(Set(plans.map { $0.tiles.map(\.cover.id) }).count, 1, "equal days and photos take turns")
        let sides = Set(plans.compactMap { plan -> Bool? in
            if case .feature(let left) = plan.layout { return left } else { return nil }
        })
        XCTAssertEqual(sides, [true, false], "the large tile is sometimes left, sometimes right")
        XCTAssertNotEqual(MonthHighlights.seed(monthID: "2026-07-01", dayNumber: 1), MonthHighlights.seed(monthID: "2026-08-01", dayNumber: 1))
    }
}
