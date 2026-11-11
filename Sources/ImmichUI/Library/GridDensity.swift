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
}
