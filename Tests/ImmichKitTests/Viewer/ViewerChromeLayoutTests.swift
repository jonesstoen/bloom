import SwiftUI
import XCTest
@testable import ImmichUI

/// Video controls sit a small gap above the viewer's bottom bar, measured in global coordinates.
final class ViewerChromeLayoutTests: XCTestCase {
    func testControlsEndAGapAboveTheBar() {
        // A page reaching the bottom of an 874 pt screen, the bar (strip + buttons) from y 690.
        XCTAssertEqual(ViewerChromeLayout.padding(containerBottom: 874, barTop: 690), 874 - 690 + ViewerChromeLayout.gap)
    }

    func testHiddenOrUnmeasuredBarsGiveNoControls() {
        XCTAssertNil(ViewerChromeLayout.padding(containerBottom: 874, barTop: nil))
        XCTAssertNil(ViewerChromeLayout.padding(containerBottom: 874, barTop: 0))
        XCTAssertNil(ViewerChromeLayout.padding(containerBottom: 0, barTop: 690))
    }

    func testABarBelowThePageNeverGivesNegativePadding() {
        XCTAssertEqual(ViewerChromeLayout.padding(containerBottom: 600, barTop: 700), 0)
    }
}
