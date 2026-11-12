import XCTest
import ImmichKit
@testable import ImmichUI

/// Months is laid out exactly, like the All grid: a LazyVStack only estimated the months it
/// hadn't built, so a jump to a month landed short and a second scroll 250 ms later moved it
/// again (seen in a screen recording from the phone).
final class MonthsLayoutTests: XCTestCase {
    private let width: CGFloat = 378 // 402 − 2 × 12 margin
    private var cell: CGFloat { (width - 2 * MonthMosaic.spacing) / 3 }

    private func tiles(_ count: Int) -> [LibraryGridModel.DayTile] {
        (0..<count).map { LibraryGridModel.DayTile(id: "d\($0)", day: $0 + 1, cover: MockLibrary.standard.assets[$0]) }
    }

    private func plan(_ count: Int, _ layout: MonthHighlights.Layout) -> MonthHighlights.Plan {
        MonthHighlights.Plan(tiles: tiles(count), layout: layout)
    }

    func testMosaicHeightsFollowTheLayouts() {
        let s = MonthMosaic.spacing
        let big = 2 * cell + s
        XCTAssertEqual(MonthMosaic.height(plan: plan(0, .row), isLoaded: false, width: width), cell, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(0, .row), isLoaded: true, width: width), 0)
        XCTAssertEqual(MonthMosaic.height(plan: plan(1, .row), isLoaded: true, width: width), width * 0.66, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(2, .row), isLoaded: true, width: width), (width - s) / 2, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(3, .row), isLoaded: true, width: width), cell, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(4, .wideTop), isLoaded: true, width: width),
                       width * 0.66 + s + cell, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(1, .wideTop), isLoaded: true, width: width), width * 0.66, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(6, .feature(featuredOnLeft: true)), isLoaded: true, width: width),
                       big + s + cell, accuracy: 0.001)
        XCTAssertEqual(MonthMosaic.height(plan: plan(3, .feature(featuredOnLeft: false)), isLoaded: true, width: width),
                       big, accuracy: 0.001)
    }

    func testMonthsStackWithExactOffsets() {
        let layout = MonthsLayout(months: [.init(id: "a", plan: plan(3, .row), isLoaded: true),
                                           .init(id: "b", plan: plan(0, .row), isLoaded: false),
                                           .init(id: "c", plan: plan(1, .row), isLoaded: true)],
                                  width: width, titleHeight: 30)
        let header = 30 + MonthsLayout.titleSpacing
        XCTAssertEqual(layout.offsets[0], 0)
        XCTAssertEqual(layout.heights[0], header + cell, accuracy: 0.001)
        XCTAssertEqual(layout.offsets[1], layout.heights[0] + MonthsLayout.monthSpacing, accuracy: 0.001)
        XCTAssertEqual(layout.offsets[2], layout.offsets[1] + layout.heights[1] + MonthsLayout.monthSpacing, accuracy: 0.001)
        XCTAssertEqual(layout.contentHeight, layout.offsets[2] + layout.heights[2] + MonthsLayout.bottomPadding, accuracy: 0.001)
        XCTAssertEqual(layout.index(of: "c"), 2)
        XCTAssertNil(layout.index(of: "zz"))
    }

    func testOnlyMonthsNearTheScreenAreBuilt() {
        let months = (0..<100).map { MonthsLayout.Month(id: "m\($0)", plan: plan(3, .row), isLoaded: true) }
        let layout = MonthsLayout(months: months, width: width, titleHeight: 30)
        let pitch = layout.offsets[1]
        // Screen from the top of month 50 down 2.5 months, one screen of margin each way.
        let rows = layout.visible(top: layout.offsets[50], bottom: layout.offsets[50] + 2.5 * pitch, margin: 2.5 * pitch)
        XCTAssertTrue(rows.contains(50) && rows.contains(52))
        XCTAssertTrue(rows.contains(48) && rows.contains(54))
        XCTAssertLessThan(rows.count, 12)
        XCTAssertEqual(layout.visible(top: -500, bottom: -100, margin: 0), 0..<0)
        XCTAssertEqual(MonthsLayout(months: [], width: width, titleHeight: 30).visible(top: 0, bottom: 800, margin: 0), 0..<0)
    }
}
