import XCTest
@testable import ImmichUI

final class ViewerInfoPullTests: XCTestCase {
    func testPullFromTopClosesOnlyOncePastThreshold() {
        var pull = ViewerInfoPull()
        pull.updateOffset(0)
        pull.begin()
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 100)))
        XCTAssertTrue(pull.updateDrag(CGSize(width: 0, height: 101)))
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 130)))
        XCTAssertFalse(pull.updateDrag(.zero))
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 120)))
    }

    func testGestureStartedBelowTopOnlyScrollsEvenAfterReachingTop() {
        var pull = ViewerInfoPull()
        pull.updateOffset(160)
        XCTAssertFalse(pull.canStart)
        pull.begin()
        pull.updateOffset(0)
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 140)))
        pull.end()
        pull.begin()
        XCTAssertTrue(pull.updateDrag(CGSize(width: 0, height: 110)))
    }

    func testInactiveAndEndedUpdatesCannotClose() {
        var pull = ViewerInfoPull()
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 120)))
        pull.updateOffset(0)
        pull.begin()
        XCTAssertTrue(pull.isActive)
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 60)))
        pull.end()
        XCTAssertFalse(pull.isActive)
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 120)))
    }

    func testTopToleranceAcceptsOnePointButRejectsLowerStart() {
        var pull = ViewerInfoPull()
        pull.updateOffset(1)
        XCTAssertTrue(pull.canStart)
        pull.begin()
        XCTAssertTrue(pull.updateDrag(CGSize(width: 0, height: 110)))
        pull.end()
        pull.updateOffset(1.1)
        XCTAssertFalse(pull.canStart)
        pull.begin()
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: 110)))
    }

    func testHorizontalAndUpwardDragsDoNotClose() {
        var pull = ViewerInfoPull()
        pull.begin()
        XCTAssertFalse(pull.updateDrag(CGSize(width: 0, height: -140)))
        XCTAssertFalse(pull.updateDrag(CGSize(width: 140, height: 110)))
        XCTAssertFalse(pull.updateDrag(CGSize(width: -80, height: 110)))
        XCTAssertTrue(pull.updateDrag(CGSize(width: 60, height: 110)))
    }
}
