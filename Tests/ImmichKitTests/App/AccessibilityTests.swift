import XCTest
import ImmichKit
@testable import ImmichUI

final class AccessibilityTests: XCTestCase {
    /// With Reduce Motion the levels only cross-fade; nothing scales.
    func testReduceMotionKeepsLevelsAtFullSize() {
        for level in LibraryScale.allCases {
            for shown in LibraryScale.allCases {
                XCTAssertEqual(level.zoom(showing: shown, reduceMotion: true).scale, 1)
                XCTAssertEqual(level.zoom(showing: shown, reduceMotion: true).opacity,
                               level.zoom(showing: shown).opacity)
            }
        }
    }

    /// A day tile in Months reads its full date, not just "Day 8".
    func testDayTilesReadTheirDate() throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first)
        let label = MonthMosaic.accessibilityLabel(for: asset, locale: Locale(identifier: "en_US"))
        let year = Asset.localCalendar.component(.year, from: asset.localDateTime)
        XCTAssertTrue(label.contains(String(year)), label)
        XCTAssertGreaterThan(label.count, 8, label)
    }

    /// The viewer's photo reads what it is, when and where.
    func testViewerPhotoLabel() throws {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let photo = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let label = ViewerAccessibility.label(for: photo, place: "Oslo", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(label.hasPrefix("Photo"), label)
        XCTAssertTrue(label.hasSuffix("Oslo"), label)
        let year = Asset.localCalendar.component(.year, from: photo.localDateTime)
        XCTAssertTrue(label.contains(String(year)), label)
        XCTAssertFalse(ViewerAccessibility.label(for: photo, place: nil, locale: Locale(identifier: "en_US")).contains("nil"))
    }
}
