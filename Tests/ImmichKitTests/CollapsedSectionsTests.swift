import XCTest
import ImmichKit
@testable import ImmichUI

/// Collections sections fold away with the chevron button, like Photos, and stay folded.
@MainActor
final class CollapsedSectionsTests: XCTestCase {
    override func tearDown() { Localization.languageOverride = nil; super.tearDown() }

    func testEverySectionStartsOpen() {
        let sections = CollapsedSections(rawValue: "")
        for section in CollectionSection.allCases { XCTAssertFalse(sections.contains(section)) }
    }

    func testTogglingFoldsAndOpensOneSection() {
        var sections = CollapsedSections(rawValue: "")
        sections.toggle(.albums)
        XCTAssertTrue(sections.contains(.albums))
        XCTAssertFalse(sections.contains(.people))
        sections.toggle(.albums)
        XCTAssertFalse(sections.contains(.albums))
    }

    func testStoredValueSurvivesARelaunchAndIgnoresUnknownSections() {
        var sections = CollapsedSections(rawValue: "")
        sections.toggle(.people)
        sections.toggle(.memories)
        let restored = CollapsedSections(rawValue: sections.rawValue)
        XCTAssertEqual(restored, sections)
        XCTAssertTrue(restored.contains(.people) && restored.contains(.memories))
        // A section removed in a later version must not break the rest.
        let old = CollapsedSections(rawValue: "people,removedSection")
        XCTAssertTrue(old.contains(.people))
        XCTAssertEqual(old.rawValue, "people")
    }

    func testButtonLabelsSayWhatTheyDo() {
        Localization.languageOverride = "nb"
        XCTAssertEqual(CollectionSection.toggleLabel(title: "Album", isCollapsed: false), "Skjul Album")
        XCTAssertEqual(CollectionSection.toggleLabel(title: "Album", isCollapsed: true), "Vis Album")
    }
}
