import XCTest
import ImmichKit
@testable import ImmichUI

/// The Years / Months / All switcher like Photos on iOS 26: hidden at the newest photos, shown
/// once you scroll away from them (between the minimized tab button and Search).
@MainActor
final class LibraryChromeTests: XCTestCase {

    // MARK: Distance from the newest photos

    func testDistanceIsZeroAtTheBottomIncludingTheBottomInset() {
        // Oldest first: the newest photos are at the bottom, under the tab bar's inset.
        let atBottom = LibraryChrome.distanceFromNewest(contentHeight: 5000, insetTop: 96, insetBottom: 90,
                                                         visibleMinY: 4090 - 800, visibleMaxY: 5090, newestFirst: false)
        XCTAssertEqual(atBottom, 0, accuracy: 0.001)
        let scrolledUp = LibraryChrome.distanceFromNewest(contentHeight: 5000, insetTop: 96, insetBottom: 90,
                                                           visibleMinY: 2000, visibleMaxY: 2800, newestFirst: false)
        XCTAssertEqual(scrolledUp, 2290, accuracy: 0.001)
    }

    func testNewestFirstMeasuresFromTheTop() {
        let atTop = LibraryChrome.distanceFromNewest(contentHeight: 5000, insetTop: 96, insetBottom: 90,
                                                      visibleMinY: -96, visibleMaxY: 700, newestFirst: true)
        XCTAssertEqual(atTop, 0, accuracy: 0.001)
        let scrolledDown = LibraryChrome.distanceFromNewest(contentHeight: 5000, insetTop: 96, insetBottom: 90,
                                                             visibleMinY: 404, visibleMaxY: 1200, newestFirst: true)
        XCTAssertEqual(scrolledDown, 500, accuracy: 0.001)
    }

    func testAwayUsesHysteresisSoTheSwitcherDoesNotFlicker() {
        // Turning on needs a clear scroll; turning off needs a return almost to the edge.
        XCTAssertFalse(LibraryChrome.isAway(distance: 50, wasAway: false))
        XCTAssertTrue(LibraryChrome.isAway(distance: 120, wasAway: false))
        XCTAssertTrue(LibraryChrome.isAway(distance: 50, wasAway: true))
        XCTAssertFalse(LibraryChrome.isAway(distance: 10, wasAway: true))
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
