import Foundation

/// Which pages the viewer's pager builds: the ones around the current item, moved along as you
/// swipe. A lazy pager has to lay out every page before the one it opens at, which is slow deep
/// into a large library (the newest photos are at the end). `scrollPosition(id:)` keeps the
/// current page in place when the window moves.
enum ViewerPageWindow {
    /// `index` and up to `radius` items on each side.
    static func around(_ index: Int, count: Int, radius: Int = 50) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let index = min(max(index, 0), count - 1)
        return max(0, index - radius)..<min(count, index + radius + 1)
    }

    /// A new window centred on `index` when it is within `margin` items of an edge that isn't the
    /// end of the list (or outside the window); `nil` when the window can stay.
    static func recentred(_ window: Range<Int>, index: Int, count: Int, radius: Int = 50, margin: Int = 15) -> Range<Int>? {
        guard window.contains(index) else { return around(index, count: count, radius: radius) }
        let nearStart = index - window.lowerBound < margin && window.lowerBound > 0
        let nearEnd = window.upperBound - 1 - index < margin && window.upperBound < count
        return nearStart || nearEnd ? around(index, count: count, radius: radius) : nil
    }
}
