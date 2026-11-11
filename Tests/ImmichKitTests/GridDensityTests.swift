import XCTest
@testable import ImmichUI

final class GridDensityTests: XCTestCase {
    func testPinchChangesOneStepAndClampsAtLimits() {
        XCTAssertEqual(GridDensity.three.pinched(by: 0.6), .five)
        XCTAssertEqual(GridDensity.five.pinched(by: 0.6), .seven)
        XCTAssertEqual(GridDensity.seven.pinched(by: 0.6), .seven)
        XCTAssertEqual(GridDensity.seven.pinched(by: 1.4), .five)
        XCTAssertEqual(GridDensity.five.pinched(by: 1.4), .three)
        XCTAssertEqual(GridDensity.three.pinched(by: 1.4), .three)
    }

    func testSmallAndInvalidGesturesDoNotChangeDensity() {
        for value in [0.95, 1.0, 1.05, 0, -1, .nan, .infinity] {
            XCTAssertEqual(GridDensity.five.pinched(by: value), .five)
        }
    }
}
