import CoreGraphics
import Foundation

/// The Library grid's layout. Every cell is the same square, so every position is exact: the grid
/// builds only the rows near the screen and places them itself. (LazyVGrid estimated the height of
/// rows it hadn't built; after a jump or a pinch those estimates were off by up to 40 %, which put
/// pinches and the header's dates weeks away and made scrollTo land in the wrong place.)
public struct GridLayout: Equatable, Sendable {
    public let width: Double
    public let spacing: Double
    public let columns: Int
    public let itemCount: Int

    public init(width: Double, spacing: Double, columns: Int, itemCount: Int) {
        self.width = width
        self.spacing = spacing
        self.columns = max(1, columns)
        self.itemCount = max(0, itemCount)
    }

    public var cell: Double { GridPinchAnchor.cellSize(width: width, spacing: spacing, columns: columns) }
    /// Distance from one row (or column) to the next.
    public var pitch: Double { cell + spacing }
    public var rowCount: Int { (itemCount + columns - 1) / columns }
    public var height: Double { rowCount == 0 ? 0 : Double(rowCount) * pitch - spacing }

    /// Top-left corner of cell `index` in the grid.
    public func origin(of index: Int) -> CGPoint {
        CGPoint(x: Double(index % columns) * pitch, y: Double(index / columns) * pitch)
    }

    /// The cells in `rows`.
    public func items(inRows rows: Range<Int>) -> Range<Int> {
        let lower = min(itemCount, rows.lowerBound * columns)
        return lower..<max(lower, min(itemCount, rows.upperBound * columns))
    }

    /// Rows to build: those on screen plus `margin` rows each way, widened to multiples of `chunk`
    /// rows so that scrolling only rebuilds the cells every `chunk` rows.
    public func renderRows(visibleTop: Double, visibleBottom: Double, margin: Int, chunk: Int) -> Range<Int> {
        guard rowCount > 0, pitch > 0 else { return 0..<0 }
        let chunk = max(1, chunk)
        let first = max(0, Int((visibleTop / pitch).rounded(.down)) - margin)
        let last = min(rowCount - 1, Int((max(visibleTop, visibleBottom) / pitch).rounded(.down)) + margin)
        let lower = min(rowCount, first / chunk * chunk)
        let upper = min(rowCount, (max(first, last) / chunk + 1) * chunk)
        return lower..<max(lower, upper)
    }

    /// The cells at least half visible between content y `top` and `top + height` (the area
    /// between the large title and the tab bar). `nil` when none is.
    public func screenRange(top: Double, height: Double) -> ClosedRange<Int>? {
        guard rowCount > 0, pitch > 0 else { return nil }
        let half = cell / 2
        let first = max(0, Int(((top - half) / pitch).rounded(.up)))
        let last = min(rowCount - 1, Int(((top + height - half) / pitch).rounded(.down)))
        guard first <= last else { return nil }
        let upper = min(itemCount - 1, last * columns + columns - 1)
        return first * columns...upper
    }

    /// The `ScrollPosition` y that puts cell `index` at `anchor` of the visible area between the
    /// insets (0 top, 0.5 middle, 1 bottom). `ScrollPosition.scrollTo(y:)` measures from the top of
    /// that area (measured: y 0 gives `contentOffset` −insetTop).
    public func scrollY(toShow index: Int, anchor: Double, visibleHeight: Double) -> Double {
        Double(origin(of: index).y) - anchor * (visibleHeight - cell)
    }
}

/// A programmatic scroll that hasn't landed yet. After a column switch SwiftUI reports the new
/// content height once with the old layout's offset before the scroll lands (measured), so until
/// the reported offset reaches the target, the target is where the grid really is.
public enum PendingScroll {
    public struct Resolution: Equatable, Sendable {
        /// The content offset to work with.
        public var offset: Double
        /// The target still waited for, `nil` once landed.
        public var pending: Double?
    }

    /// - Parameters:
    ///   - pending: the `contentOffset.y` the last programmatic scroll aims at.
    ///   - reportedOffset: `ScrollGeometry.contentOffset.y`.
    ///   - contentHeight: `ScrollGeometry.contentSize.height`; with the insets and the full frame
    ///     height it gives the offsets the scroll view clamps to.
    public static func resolve(pending: Double?, reportedOffset: Double, contentHeight: Double,
                               frameHeight: Double, insetTop: Double, insetBottom: Double) -> Resolution {
        guard let pending, pending.isFinite else { return Resolution(offset: reportedOffset, pending: nil) }
        let lowest = -insetTop
        let highest = max(lowest, contentHeight + insetBottom - frameHeight)
        let target = min(max(pending, lowest), highest)
        if abs(reportedOffset - target) < 1 { return Resolution(offset: reportedOffset, pending: nil) }
        return Resolution(offset: target, pending: target)
    }
}
