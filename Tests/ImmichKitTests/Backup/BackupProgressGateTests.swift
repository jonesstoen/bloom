import XCTest
@testable import ImmichUI

final class BackupProgressGateTests: XCTestCase {
    func testPublishesImmediatelyThenAtMostOncePer200MillisecondWindow() {
        var gate = BackupProgressGate()
        let start = ContinuousClock.now

        XCTAssertTrue(gate.shouldPublish(at: start), "The first progress update is immediate")
        XCTAssertFalse(gate.shouldPublish(at: start.advanced(by: .milliseconds(199))))
        XCTAssertTrue(gate.shouldPublish(at: start.advanced(by: .milliseconds(200))))
        XCTAssertFalse(gate.shouldPublish(at: start.advanced(by: .milliseconds(399))))
        XCTAssertTrue(gate.shouldPublish(at: start.advanced(by: .milliseconds(400))))
    }

    func testNewGatePublishesImmediately() {
        var gate = BackupProgressGate()
        XCTAssertTrue(gate.shouldPublish(at: ContinuousClock.now))
    }
}
