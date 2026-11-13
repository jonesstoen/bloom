import XCTest
@testable import ImmichUI

final class ViewerInfoPolicyTests: XCTestCase {
    func testUpwardStartIsOptInAndBlockedWhileZoomedOrModal() {
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: -120, isZoomed: false, blocked: false))
        XCTAssertTrue(ViewerGesture.canStartDismiss(x: 0, y: -120, isZoomed: false, blocked: false, allowsUp: true))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 100, y: -120, isZoomed: false, blocked: false, allowsUp: true))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: -120, isZoomed: true, blocked: false, allowsUp: true))
        XCTAssertFalse(ViewerGesture.canStartDismiss(x: 0, y: -120, isZoomed: false, blocked: true, allowsUp: true))
    }

    func testDownClosesInformationBeforeDismissingViewer() {
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: -120, isZoomed: false, blocked: false, infoShown: false), .openInfo)
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: 120, isZoomed: false, blocked: false, infoShown: true), .closeInfo)
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: 120, isZoomed: false, blocked: false, infoShown: false), .dismiss)
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: -120, isZoomed: false, blocked: false, infoShown: true), .none)
        for (x, y) in [(0.0, 100.0), (0, -100), (140, 120)] {
            XCTAssertEqual(ViewerGesture.verticalAction(x: x, y: y, isZoomed: false, blocked: false, infoShown: false), .none)
        }
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: -150, isZoomed: true, blocked: false, infoShown: false), .none)
        XCTAssertEqual(ViewerGesture.verticalAction(x: 0, y: 150, isZoomed: false, blocked: true, infoShown: true), .none)
    }
}
