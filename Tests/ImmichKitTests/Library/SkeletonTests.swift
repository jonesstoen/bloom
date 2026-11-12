import XCTest
@testable import ImmichKit
@testable import ImmichUI

final class SkeletonTests: XCTestCase {
    func testModulesLink() {
        XCTAssertEqual(ImmichKitInfo.name, "ImmichKit")
        XCTAssertEqual(ImmichUIInfo.name, "ImmichUI")
    }
}
