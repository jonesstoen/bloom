import XCTest
@testable import ImmichUI

final class ViewerInfoPullTests: XCTestCase {
    func testPullFromTopClosesOnlyOncePastThreshold() {
        var pull = ViewerInfoPull()
        XCTAssertFalse(pull.updateOffset(0))
        pull.begin()
        XCTAssertFalse(pull.updateOffset(-100))
        XCTAssertTrue(pull.updateOffset(-101))
        XCTAssertFalse(pull.updateOffset(-130))
        XCTAssertFalse(pull.updateOffset(0))
        XCTAssertFalse(pull.updateOffset(-120))
    }

    func testGestureStartedBelowTopOnlyScrollsEvenAfterReachingTop() {
        var pull = ViewerInfoPull()
        XCTAssertFalse(pull.updateOffset(160))
        pull.begin()
        XCTAssertFalse(pull.updateOffset(0))
        XCTAssertFalse(pull.updateOffset(-140))
        pull.end()
        XCTAssertFalse(pull.updateOffset(0))
        pull.begin()
        XCTAssertTrue(pull.updateOffset(-110))
    }

    func testInactiveAndEndedUpdatesCannotClose() {
        var pull = ViewerInfoPull()
        XCTAssertFalse(pull.updateOffset(-120))
        XCTAssertFalse(pull.updateOffset(0))
        pull.begin()
        XCTAssertFalse(pull.updateOffset(-60))
        pull.end()
        XCTAssertFalse(pull.updateOffset(-120))
    }

    func testTopToleranceAcceptsOnePointButRejectsLowerStart() {
        var pull = ViewerInfoPull()
        XCTAssertFalse(pull.updateOffset(1))
        pull.begin()
        XCTAssertTrue(pull.updateOffset(-110))
        pull.end()
        XCTAssertFalse(pull.updateOffset(1.1))
        pull.begin()
        XCTAssertFalse(pull.updateOffset(-110))
    }
}
