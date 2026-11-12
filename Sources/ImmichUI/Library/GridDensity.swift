import Foundation

public enum GridDensity: Int, CaseIterable, Sendable {
    case three = 3, five = 5, seven = 7

    /// One step per completed pinch, with a dead zone to avoid accidental changes.
    public func pinched(by magnification: Double) -> GridDensity {
        guard magnification.isFinite, magnification > 0 else { return self }
        if magnification < 0.85 {
            switch self { case .three: return .five; case .five, .seven: return .seven }
        }
        if magnification > 1.15 {
            switch self { case .seven: return .five; case .five, .three: return .three }
        }
        return self
    }
}

/// Where to scroll a uniform square grid after its column count changes, so the item under the
/// pinch stays exactly where it is on screen (the same row fraction under the same focal point).
public enum GridPinchAnchor {
    public struct Result: Equatable, Sendable {
        /// The new content offset, measured from the top of the grid.
        public var offset: Double
        /// Index of the item that stays under the focal point.
        public var index: Int
    }

    /// Side length of a cell for `columns` columns in a grid of `width` with `spacing` between cells.
    public static func cellSize(width: Double, spacing: Double, columns: Int) -> Double {
        let columns = max(1, columns)
        return max(0, (width - Double(columns - 1) * spacing) / Double(columns))
    }

    /// - Parameters:
    ///   - offset: current content offset from the top of the grid (negative above it).
    ///   - focal: the anchor point in the visible area (from its top-left corner).
    public static func anchor(offset: Double, focalX: Double, focalY: Double, width: Double, spacing: Double,
                              from old: Int, to new: Int, itemCount: Int) -> Result? {
        guard itemCount > 0, width > 0, old > 0, new > 0, offset.isFinite, focalX.isFinite, focalY.isFinite else { return nil }
        let oldPitch = cellSize(width: width, spacing: spacing, columns: old) + spacing
        let newPitch = cellSize(width: width, spacing: spacing, columns: new) + spacing
        guard oldPitch > 0, newPitch > 0 else { return nil }
        let rows = Double((itemCount + old - 1) / old)
        let rowPosition = min(max(0, (offset + focalY) / oldPitch), rows - 0.000_1)
        let row = rowPosition.rounded(.down)
        let fraction = rowPosition - row
        let column = min(old - 1, max(0, Int(focalX / oldPitch)))
        let index = min(itemCount - 1, Int(row) * old + column)
        let newRow = Double(index / new)
        return Result(offset: (newRow + fraction) * newPitch - focalY, index: index)
    }

    /// Whether the item the offset maths found is among the cells SwiftUI reports on screen.
    /// LazyVGrid only estimates the height of rows it hasn't built, so after a jump (opening at the
    /// newest photos, a previous pinch) the maths can point far away; then it must not be used.
    /// Without a report yet there is nothing to check against.
    public static func isOnScreen(index: Int, visible: ClosedRange<Int>?) -> Bool {
        visible?.contains(index) ?? true
    }

    /// The item in the middle of the cells on screen (middle row, middle column), the anchor when
    /// the offset maths can't be trusted. Stays inside `visible` and before `itemCount`.
    public static func centerIndex(of visible: ClosedRange<Int>, columns: Int, itemCount: Int) -> Int {
        let columns = max(1, columns)
        let middleRow = (visible.lowerBound / columns + visible.upperBound / columns) / 2
        let index = middleRow * columns + columns / 2
        return min(max(index, visible.lowerBound), visible.upperBound, max(0, itemCount - 1))
    }

    /// The `UnitPoint.y` for `ScrollViewProxy.scrollTo(_:anchor:)` that puts an item's top edge at
    /// `itemTop` (measured from the top of the scroll view's frame). `scrollTo` aligns the anchor
    /// inside the area between the content insets: top = insetTop + y × (visibleHeight − itemHeight),
    /// where `visibleHeight` excludes the insets (`ScrollGeometry.containerSize.height`).
    public static func unitAnchorY(itemTop: Double, itemHeight: Double, insetTop: Double, visibleHeight: Double) -> Double {
        let range = visibleHeight - itemHeight
        guard range > 0, itemTop.isFinite else { return 0.5 }
        return min(1, max(0, (itemTop - insetTop) / range))
    }
}
