import SwiftUI
import XCTest
import ImmichKit
@testable import ImmichUI

/// The Bloom logo drawn in SwiftUI, and the app icon choice in About Bloom.
@MainActor
final class BloomBrandTests: XCTestCase {
    override func tearDown() { Localization.languageOverride = nil; super.tearDown() }

    // MARK: Logo geometry

    func testMarkHasSixSeparateBladesAroundAnOpenCentre() {
        let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        let blades = BloomMarkGeometry.blades(in: rect)
        XCTAssertEqual(blades.count, 6)
        XCTAssertEqual(BloomMarkGeometry.palette.count, 6)
        for blade in blades {
            XCTAssertFalse(blade.isEmpty)
            XCTAssertTrue(rect.contains(blade.boundingRect), "\(blade.boundingRect)")
        }
        // The aperture: the centre belongs to no blade.
        XCTAssertFalse(blades.contains { $0.contains(CGPoint(x: 128, y: 128)) })
        // Blades never overlap (they are separated by gaps), and they fill a good part of the circle.
        var covered = 0
        for x in stride(from: 4.0, to: 256, by: 6) {
            for y in stride(from: 4.0, to: 256, by: 6) {
                let hits = blades.filter { $0.contains(CGPoint(x: x, y: y)) }.count
                XCTAssertLessThanOrEqual(hits, 1, "overlap at \(x),\(y)")
                covered += hits
            }
        }
        XCTAssertGreaterThan(covered, 400)
    }

    func testMarkScalesWithItsFrame() {
        let small = BloomMarkGeometry.blades(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let large = BloomMarkGeometry.blades(in: CGRect(x: 10, y: 20, width: 320, height: 320))
        XCTAssertEqual(small[0].boundingRect.width * 10, large[0].boundingRect.width, accuracy: 0.5)
        XCTAssertEqual(large[0].boundingRect.minX - 10, small[0].boundingRect.minX * 10, accuracy: 0.5)
        // A non-square frame draws a centred square mark.
        let wide = BloomMarkGeometry.blades(in: CGRect(x: 0, y: 0, width: 400, height: 100))
        let bounds = wide.reduce(CGRect.null) { $0.union($1.boundingRect) }
        XCTAssertEqual(bounds.midX, 200, accuracy: 2)
        XCTAssertLessThanOrEqual(bounds.height, 100)
    }

    // MARK: App icon choice

    func testChoicesMapToTheAppTargetsIconSets() {
        XCTAssertEqual(AppIconChoice.allCases, [.automatic, .light, .dark, .tinted])
        XCTAssertNil(AppIconChoice.automatic.alternateIconName)
        XCTAssertEqual(AppIconChoice.light.alternateIconName, "AppIcon-Light")
        XCTAssertEqual(AppIconChoice.dark.alternateIconName, "AppIcon-Dark")
        XCTAssertEqual(AppIconChoice.tinted.alternateIconName, "AppIcon-Tinted")
        for choice in AppIconChoice.allCases {
            XCTAssertEqual(AppIconChoice(alternateIconName: choice.alternateIconName), choice)
        }
        XCTAssertEqual(AppIconChoice(alternateIconName: "SomethingOld"), .automatic)
    }

    func testChoiceTitlesAreNorwegian() {
        Localization.languageOverride = "nb"
        XCTAssertEqual(AppIconChoice.allCases.map(\.title), ["Automatisk", "Lys", "Mørk", "Tonet"])
        XCTAssertEqual(tr("About Bloom"), "Om Bloom")
    }

    func testModelStartsFromTheCurrentIconAndSwitches() async {
        let switcher = InMemoryAppIconSwitcher(current: "AppIcon-Dark")
        let model = AppIconModel(switcher: switcher)
        XCTAssertTrue(model.isSupported)
        XCTAssertEqual(model.selection, .dark)

        await model.select(.tinted)
        XCTAssertEqual(model.selection, .tinted)
        XCTAssertEqual(switcher.current, "AppIcon-Tinted")

        await model.select(.automatic)
        XCTAssertEqual(model.selection, .automatic)
        XCTAssertNil(switcher.current)
        XCTAssertEqual(switcher.requests, ["AppIcon-Tinted", nil])
    }

    func testChoosingTheCurrentIconDoesNothing() async {
        let switcher = InMemoryAppIconSwitcher(current: nil)
        let model = AppIconModel(switcher: switcher)
        await model.select(.automatic)
        XCTAssertTrue(switcher.requests.isEmpty)
    }

    func testFailedSwitchKeepsTheOldIconAndShowsAnError() async {
        Localization.languageOverride = "en"
        let switcher = InMemoryAppIconSwitcher(current: nil)
        switcher.failure = CocoaError(.featureUnsupported)
        let model = AppIconModel(switcher: switcher)
        await model.select(.dark)
        XCTAssertEqual(model.selection, .automatic)
        XCTAssertFalse(model.isChanging)
        XCTAssertNotNil(model.error)
        model.dismissError()
        XCTAssertNil(model.error)
    }

    func testUnsupportedDevicesHideThePicker() {
        let model = AppIconModel(switcher: InMemoryAppIconSwitcher(current: nil, supported: false))
        XCTAssertFalse(model.isSupported)
    }

    func testVersionTextComesFromTheBundleInfo() {
        Localization.languageOverride = "en"
        XCTAssertEqual(AboutBloomView.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]),
                       "Version 1.2 (34)")
        XCTAssertNil(AboutBloomView.versionText(info: [:]))
    }
}
