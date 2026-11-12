import XCTest
@testable import ImmichUI

/// The viewer's pager builds only the pages around the current one. Jumping deep into a lazy
/// pager of the whole library took ~0.35 s on the simulator with 12 600 photos (the newest are
/// at the end), most of the delay when opening a photo.
final class ViewerPageWindowTests: XCTestCase {
    func testWindowIsCentredAndClamped() {
        XCTAssertEqual(ViewerPageWindow.around(12_597, count: 12_600, radius: 50), 12_547..<12_600)
        XCTAssertEqual(ViewerPageWindow.around(3, count: 12_600, radius: 50), 0..<54)
        XCTAssertEqual(ViewerPageWindow.around(500, count: 12_600, radius: 50), 450..<551)
        XCTAssertEqual(ViewerPageWindow.around(0, count: 1, radius: 50), 0..<1)
        XCTAssertEqual(ViewerPageWindow.around(0, count: 0, radius: 50), 0..<0)
    }

    func testRecentresOnlyNearAnEdgeThatIsNotTheLibrarysEnd() {
        let window = 450..<551
        XCTAssertNil(ViewerPageWindow.recentred(window, index: 500, count: 12_600))
        XCTAssertNil(ViewerPageWindow.recentred(window, index: 466, count: 12_600), "16 pages from the edge is fine")
        XCTAssertEqual(ViewerPageWindow.recentred(window, index: 460, count: 12_600), 410..<511)
        XCTAssertEqual(ViewerPageWindow.recentred(window, index: 540, count: 12_600), 490..<591)
        // At the ends of the library there is nothing more to add.
        XCTAssertNil(ViewerPageWindow.recentred(0..<54, index: 1, count: 12_600))
        XCTAssertNil(ViewerPageWindow.recentred(12_547..<12_600, index: 12_599, count: 12_600))
    }

    func testAJumpOutsideTheWindowRecentresOnTheTarget() {
        XCTAssertEqual(ViewerPageWindow.recentred(450..<551, index: 700, count: 12_600), 650..<751)
    }
}
