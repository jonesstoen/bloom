import XCTest
import ImmichKit
@testable import ImmichUI

final class GridDensityTests: XCTestCase {
    func testPinchChangesOneStepAndClampsAtLimits() {
        XCTAssertEqual(GridDensity.three.pinched(by: 0.6), .five)
        XCTAssertEqual(GridDensity.five.pinched(by: 0.6), .seven)
        XCTAssertEqual(GridDensity.seven.pinched(by: 0.6), .seven)
        XCTAssertEqual(GridDensity.seven.pinched(by: 1.4), .five)
        XCTAssertEqual(GridDensity.five.pinched(by: 1.4), .three)
        XCTAssertEqual(GridDensity.three.pinched(by: 1.4), .three)
    }

    func testSmallAndInvalidGesturesDoNotChangeDensity() {
        for value in [0.95, 1.0, 1.05, 0, -1, .nan, .infinity] {
            XCTAssertEqual(GridDensity.five.pinched(by: value), .five)
        }
    }
}

final class GridPinchAnchorTests: XCTestCase {
    private let width = 393.0, spacing = 1.5

    /// The item's top edge on screen, for checking that it stays put.
    private func screenY(of index: Int, columns: Int, offset: Double) -> Double {
        let pitch = GridPinchAnchor.cellSize(width: width, spacing: spacing, columns: columns) + spacing
        return Double(index / columns) * pitch - offset
    }

    func testItemUnderTheFocalPointKeepsItsScreenPosition() throws {
        let focalY = 400.0
        for (old, new) in [(3, 5), (5, 7), (7, 5), (5, 3), (3, 7)] {
            for offset in [0.0, 1234.5, 98_765.4] {
                let result = try XCTUnwrap(GridPinchAnchor.anchor(offset: offset, focalX: width / 2, focalY: focalY,
                                                                 width: width, spacing: spacing, from: old, to: new, itemCount: 20_000))
                // The focal point sits at the same fraction of the item's row before and after.
                let oldPitch = GridPinchAnchor.cellSize(width: width, spacing: spacing, columns: old) + spacing
                let newPitch = GridPinchAnchor.cellSize(width: width, spacing: spacing, columns: new) + spacing
                let before = (focalY - screenY(of: result.index, columns: old, offset: offset)) / oldPitch
                let after = (focalY - screenY(of: result.index, columns: new, offset: result.offset)) / newPitch
                XCTAssertEqual(before, after, accuracy: 0.000_1, "\(old)→\(new) at \(offset)")
                XCTAssertTrue((0..<1).contains(before))
            }
        }
    }

    func testPicksTheItemInTheFocalColumn() throws {
        let cell = GridPinchAnchor.cellSize(width: width, spacing: spacing, columns: 3)
        // Row 10 starts at 10 pitches; aim at the right-hand column.
        let offset = 10 * (cell + spacing)
        let right = try XCTUnwrap(GridPinchAnchor.anchor(offset: offset, focalX: width - 1, focalY: 1, width: width,
                                                        spacing: spacing, from: 3, to: 5, itemCount: 1000))
        XCTAssertEqual(right.index, 32)
        let left = try XCTUnwrap(GridPinchAnchor.anchor(offset: offset, focalX: 0, focalY: 1, width: width,
                                                       spacing: spacing, from: 3, to: 5, itemCount: 1000))
        XCTAssertEqual(left.index, 30)
    }

    func testClampsAtTheEdgesAndRejectsBadInput() throws {
        let top = try XCTUnwrap(GridPinchAnchor.anchor(offset: -500, focalX: 10, focalY: 100, width: width,
                                                      spacing: spacing, from: 3, to: 5, itemCount: 100))
        XCTAssertEqual(top.index, 0)
        let bottom = try XCTUnwrap(GridPinchAnchor.anchor(offset: 1e9, focalX: width, focalY: 100, width: width,
                                                         spacing: spacing, from: 3, to: 5, itemCount: 100))
        XCTAssertEqual(bottom.index, 99)
        XCTAssertNil(GridPinchAnchor.anchor(offset: 0, focalX: 0, focalY: 0, width: width, spacing: spacing,
                                            from: 3, to: 5, itemCount: 0))
        XCTAssertNil(GridPinchAnchor.anchor(offset: .nan, focalX: 0, focalY: 0, width: width, spacing: spacing,
                                            from: 3, to: 5, itemCount: 10))
        XCTAssertNil(GridPinchAnchor.anchor(offset: 0, focalX: 0, focalY: 0, width: 0, spacing: spacing,
                                            from: 3, to: 5, itemCount: 10))
    }
}

final class GridScrollAnchorTests: XCTestCase {
    /// Values measured from SwiftUI's `scrollTo(_:anchor:)` with a 96 pt top and 40 pt bottom
    /// margin in a 600 pt tall scroll view (visible height 464) and a 50 pt item.
    func testUnitAnchorMatchesHowScrollToPlacesItems() {
        for (top, expected) in [(96.0, 0.0), (199.5, 0.25), (303.0, 0.5), (510.0, 1.0)] {
            XCTAssertEqual(GridPinchAnchor.unitAnchorY(itemTop: top, itemHeight: 50, insetTop: 96, visibleHeight: 464),
                           expected, accuracy: 0.000_1)
        }
        // Outside the visible area it clamps; degenerate sizes fall back to the centre.
        XCTAssertEqual(GridPinchAnchor.unitAnchorY(itemTop: 0, itemHeight: 50, insetTop: 96, visibleHeight: 464), 0)
        XCTAssertEqual(GridPinchAnchor.unitAnchorY(itemTop: 900, itemHeight: 50, insetTop: 96, visibleHeight: 464), 1)
        XCTAssertEqual(GridPinchAnchor.unitAnchorY(itemTop: 10, itemHeight: 500, insetTop: 0, visibleHeight: 400), 0.5)
    }
}

@MainActor
final class GridIndexTests: XCTestCase {
    func testGridIndexMapsToAssetsAndPlaceholders() async throws {
        let mock = MockImmichService.preview
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        let total = model.gridItemCount
        XCTAssertEqual(total, model.months.reduce(0) { $0 + ($1.isLoaded ? $1.assets.count : $1.bucket.count) })
        // The newest months are loaded: the last cells are their assets, in order.
        let last = try XCTUnwrap(model.months.last)
        XCTAssertEqual(model.assetID(atGridIndex: total - 1), last.assets.last?.id)
        XCTAssertEqual(model.assetID(atGridIndex: total - last.assets.count), last.assets.first?.id)
        // The oldest month is not loaded yet: its cells are placeholders.
        XCTAssertFalse(model.months[0].isLoaded)
        XCTAssertNil(model.assetID(atGridIndex: 0))
        XCTAssertNil(model.assetID(atGridIndex: total))
        XCTAssertNil(model.assetID(atGridIndex: -1))
        // Every cell has a scroll ID: assets by id, placeholders by month and position.
        XCTAssertEqual(model.gridItemID(atGridIndex: total - 1), AnyHashable(last.assets.last!.id))
        XCTAssertEqual(model.gridItemID(atGridIndex: 1), AnyHashable(PlaceholderSlots.Slot(monthID: model.months[0].id, index: 1)))
        XCTAssertNil(model.gridItemID(atGridIndex: total))
    }
}

final class PlaceholderSlotsTests: XCTestCase {
    /// Every cell in the one continuous grid needs a unique ID, also placeholders of different
    /// months (repeated IDs made LazyVGrid render the library black).
    func testPlaceholderIDsAreUniqueAcrossMonths() {
        let months = MockLibrary.standard.assets.reduce(into: [String: Int]()) { counts, asset in
            let components = Asset.localCalendar.dateComponents([.year, .month], from: asset.localDateTime)
            counts["\(components.year!)-\(components.month!)", default: 0] += 1
        }
        let ids = months.flatMap { PlaceholderSlots(monthID: $0.key, count: $0.value).map(\.id) }
        XCTAssertEqual(ids.count, MockLibrary.standard.assets.count)
        XCTAssertEqual(Set(ids).count, ids.count)
        let slots = PlaceholderSlots(monthID: "2026-01", count: 3)
        XCTAssertEqual(slots.map(\.index), [0, 1, 2])
        XCTAssertTrue(PlaceholderSlots(monthID: "x", count: 0).isEmpty)
    }
}
