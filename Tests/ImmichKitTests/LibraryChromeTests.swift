import XCTest
import ImmichKit
@testable import ImmichUI

/// The Years / Months / All switcher like Photos on iOS 26: hidden at the newest photos, shown
/// once you scroll away from them (between the minimized tab button and Search).
@MainActor
final class LibraryChromeTests: XCTestCase {

    // MARK: Away from the newest photos

    /// From the cells SwiftUI reports on screen, not from the scroll offset: LazyVGrid only
    /// estimates the height of rows it hasn't built, so offsets don't map to rows after a jump.
    func testAwayWhenMoreThanARowOfNewerPhotosIsOffScreen() {
        // 100 photos, 5 columns, oldest first: the newest is index 99.
        XCTAssertFalse(LibraryChrome.isAway(visible: 50...99, itemCount: 100, columns: 5, newestFirst: false))
        XCTAssertFalse(LibraryChrome.isAway(visible: 45...94, itemCount: 100, columns: 5, newestFirst: false),
                       "One row under the tab bar is still at the newest photos")
        XCTAssertTrue(LibraryChrome.isAway(visible: 40...89, itemCount: 100, columns: 5, newestFirst: false))
    }

    func testNewestFirstIsAwayFromTheTop() {
        XCTAssertFalse(LibraryChrome.isAway(visible: 0...49, itemCount: 100, columns: 5, newestFirst: true))
        XCTAssertFalse(LibraryChrome.isAway(visible: 5...54, itemCount: 100, columns: 5, newestFirst: true))
        XCTAssertTrue(LibraryChrome.isAway(visible: 10...59, itemCount: 100, columns: 5, newestFirst: true))
    }

    // MARK: When the switcher shows

    func testSwitcherIsHiddenAtTheNewestPhotosInAll() {
        let chrome = LibraryChrome()
        chrome.isAvailable = true
        XCTAssertFalse(chrome.wantsSwitcher, "At the newest photos only the tabs show, like Photos")
        chrome.isAwayFromNewest = true
        XCTAssertTrue(chrome.wantsSwitcher)
    }

    func testYearsAndMonthsAlwaysShowTheSwitcherSoYouCanGetBack() {
        let chrome = LibraryChrome()
        chrome.isAvailable = true
        chrome.scale = .years
        XCTAssertTrue(chrome.wantsSwitcher)
        chrome.scale = .months
        XCTAssertTrue(chrome.wantsSwitcher)
    }

    func testNoSwitcherWhileTheLibraryIsUnavailable() {
        // Loading, empty, failed or selecting: the selection toolbar owns the bottom instead.
        let chrome = LibraryChrome()
        chrome.isAwayFromNewest = true
        chrome.scale = .months
        XCTAssertFalse(chrome.wantsSwitcher)
    }

    // MARK: Tab bar

    func testLibraryMinimizesTheTabBarWhenScrollingTowardOlderPhotos() {
        XCTAssertEqual(LibraryChrome.tabBarMinimizeDirection(libraryTab: true, newestFirst: false), .up)
        XCTAssertEqual(LibraryChrome.tabBarMinimizeDirection(libraryTab: true, newestFirst: true), .down)
        XCTAssertEqual(LibraryChrome.tabBarMinimizeDirection(libraryTab: false, newestFirst: false), .down)
    }
}
