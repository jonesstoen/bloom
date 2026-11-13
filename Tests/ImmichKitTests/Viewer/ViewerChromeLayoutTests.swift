import SwiftUI
import XCTest
@testable import ImmichUI

/// The system video controls get the space the viewer's bars cover beyond the safe area.
final class ViewerChromeLayoutTests: XCTestCase {
    func testInsetsCoverTheBarsBeyondTheSafeArea() {
        var layout = ViewerChromeLayout()
        // iPhone 17 Pro: 874 pt tall, 62 pt status area, 34 pt home indicator.
        layout.screen = .init(height: 874, safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
        layout.topBarBottom = 130
        layout.bottomBarTop = 660
        let insets = layout.insets
        XCTAssertEqual(insets.top, 130 - 62 + ViewerChromeLayout.gap)
        XCTAssertEqual(insets.bottom, (874 - 34) - 660 + ViewerChromeLayout.gap)
    }

    func testNothingMeasuredMeansNoExtraInsets() {
        XCTAssertEqual(ViewerChromeLayout().insets, EdgeInsets())
        var layout = ViewerChromeLayout()
        layout.screen = .init(height: 874, safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
        XCTAssertEqual(layout.insets, EdgeInsets())
    }

    func testBarsInsideTheSafeAreaNeverGiveNegativeInsets() {
        var layout = ViewerChromeLayout()
        layout.screen = .init(height: 874, safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
        layout.topBarBottom = 20
        layout.bottomBarTop = 870
        XCTAssertGreaterThanOrEqual(layout.insets.top, 0)
        XCTAssertGreaterThanOrEqual(layout.insets.bottom, 0)
    }
}
