import XCTest
@testable import ImmichUI

final class ViewerDismissPolicyTests: XCTestCase {
    func testDismissStartsOnlyDownwardWithoutZoomOrBlocking() {
        XCTAssertTrue(ViewerGesture.canStartDismiss(x: 0, y: 5, isZoomed: false, blocked: false))
        XCTAssertTrue(ViewerGesture.canStartDismiss(x: 20, y: 100, isZoomed: false, blocked: false))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 100, y: 20, isZoomed: false, blocked: false))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: -100, isZoomed: false, blocked: false))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: 100, isZoomed: true, blocked: false))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: 100, isZoomed: false, blocked: true))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: 0, isZoomed: false, blocked: false))
    }
}
