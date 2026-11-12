import XCTest
import ImmichKit
@testable import ImmichUI

/// The Library grid's own layout: every cell is the same square, so positions are exact (LazyVGrid
/// only estimated rows it hadn't built, which made pinches jump weeks away).
final class GridLayoutTests: XCTestCase {
    /// iPhone 17 Pro width, 5 columns, 1.5 pt spacing: cells of 79.2, rows every 80.7.
    private let layout = GridLayout(width: 402, spacing: 1.5, columns: 5, itemCount: 103)

    func testSizesAndPositionsAreExact() {
        XCTAssertEqual(layout.cell, 79.2, accuracy: 0.0001)
        XCTAssertEqual(layout.pitch, 80.7, accuracy: 0.0001)
        XCTAssertEqual(layout.rowCount, 21, "103 items in rows of 5")
        XCTAssertEqual(layout.height, 21 * 80.7 - 1.5, accuracy: 0.0001)
        XCTAssertEqual(layout.origin(of: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.origin(of: 7).x, 2 * 80.7, accuracy: 0.0001)
        XCTAssertEqual(layout.origin(of: 7).y, 80.7, accuracy: 0.0001)
        XCTAssertEqual(GridLayout(width: 402, spacing: 1.5, columns: 5, itemCount: 0).height, 0)
    }

    func testRenderedRowsCoverTheScreenAndOnlyChangeInChunks() {
        // Screen shows content 1000...1695 (rows 12...21).
        let rows = layout.renderRows(visibleTop: 1000, visibleBottom: 1695, margin: 4, chunk: 8)
        XCTAssertTrue(rows.contains(12) && rows.contains(20))
        XCTAssertEqual(rows.lowerBound % 8, 0, "Starts on a chunk boundary")
        XCTAssertLessThanOrEqual(rows.upperBound, layout.rowCount)
        // Scrolling a few points keeps the same rows: no rebuild.
        XCTAssertEqual(layout.renderRows(visibleTop: 1010, visibleBottom: 1705, margin: 4, chunk: 8), rows)
        XCTAssertEqual(layout.items(inRows: 0..<2), 0..<10)
        XCTAssertEqual(layout.items(inRows: 20..<21), 100..<103, "Last row is partly filled")
    }

    func testScreenRangeCountsCellsAtLeastHalfVisible() {
        // Top edge in the middle of row 1 (y 80.7...159.9): its lower half (≥ half) is visible.
        let range = layout.screenRange(top: 100, height: 300)
        XCTAssertEqual(range?.lowerBound, 5)
        // Bottom edge at 400: row 4 (322.8...402) is 77.2 of 79.2 visible, row 5 isn't.
        XCTAssertEqual(range?.upperBound, 24)
        XCTAssertNil(GridLayout(width: 402, spacing: 1.5, columns: 5, itemCount: 0).screenRange(top: 0, height: 300))
    }

    func testScrollYPutsTheCellWhereAsked() {
        // The visible area between the insets is 695 high; ScrollPosition y = top of that area.
        let top = layout.scrollY(toShow: 50, anchor: 0, visibleHeight: 695)
        XCTAssertEqual(top, layout.origin(of: 50).y, accuracy: 0.0001)
        let centre = layout.scrollY(toShow: 50, anchor: 0.5, visibleHeight: 695)
        XCTAssertEqual(centre, layout.origin(of: 50).y - (695 - layout.cell) / 2, accuracy: 0.0001)
        let bottom = layout.scrollY(toShow: 102, anchor: 1, visibleHeight: 695)
        XCTAssertEqual(bottom + 695, layout.origin(of: 102).y + layout.cell, accuracy: 0.0001,
                       "The last cell's bottom edge meets the bottom of the visible area")
    }

    @MainActor
    func testModelFindsTheFirstCellOfAMonthAndTheMonthOfACell() async throws {
        let mock = MockImmichService(library: .standard)
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        let month = try XCTUnwrap(model.months.dropFirst(2).first)
        let first = try XCTUnwrap(model.firstGridIndex(ofMonth: month.id))
        XCTAssertEqual(model.gridMonthID(atGridIndex: first), month.id)
        XCTAssertEqual(model.gridItemID(atGridIndex: first), model.firstGridID(ofMonth: month.id))
        if first > 0 { XCTAssertNotEqual(model.gridMonthID(atGridIndex: first - 1), month.id) }
        XCTAssertNil(model.firstGridIndex(ofMonth: "no-such-month"))
    }
}
