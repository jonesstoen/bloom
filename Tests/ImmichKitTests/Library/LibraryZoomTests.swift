import XCTest
@testable import ImmichUI

/// Switching Years / Months / All zooms like Photos (measured frame by frame in a recording):
/// both levels show during the change, the coarser one smaller and the finer one larger.
final class LibraryZoomTests: XCTestCase {
    func testTheShownLevelIsAtFullSize() {
        for level in LibraryScale.allCases {
            XCTAssertEqual(level.zoom(showing: level).scale, 1)
            XCTAssertEqual(level.zoom(showing: level).opacity, 1)
        }
    }

    func testCoarserLevelsHideSmallerAndFinerLevelsLarger() {
        // Showing Months: Years (coarser) waits small, All (finer) waits large.
        XCTAssertLessThan(LibraryScale.years.zoom(showing: .months).scale, 1)
        XCTAssertGreaterThan(LibraryScale.all.zoom(showing: .months).scale, 1)
        // Months is finer than Years and coarser than All, so it leaves the other way round.
        XCTAssertGreaterThan(LibraryScale.months.zoom(showing: .years).scale, 1)
        XCTAssertLessThan(LibraryScale.months.zoom(showing: .all).scale, 1)
        for level in LibraryScale.allCases {
            for shown in LibraryScale.allCases where shown != level {
                XCTAssertEqual(level.zoom(showing: shown).opacity, 0)
            }
        }
    }
}
