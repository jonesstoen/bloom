import CoreGraphics
import Foundation

/// Exact positions for the Months view, like `GridLayout` for All: every month's height follows
/// from its tile layout, so the view builds only the months near the screen and a jump to a
/// month lands exactly in one scroll.
struct MonthsLayout {
    struct Month {
        let id: String
        let plan: MonthHighlights.Plan
        let isLoaded: Bool
        /// "Oct 2026".
        var title = ""
    }

    static let titleSpacing: CGFloat = 10
    static let monthSpacing: CGFloat = 26
    static let bottomPadding: CGFloat = 90

    let months: [Month]
    /// Top of each month (its title), from the top of the content.
    let offsets: [CGFloat]
    /// Each month's title and mosaic.
    let heights: [CGFloat]
    let contentHeight: CGFloat
    private let indexByID: [String: Int]

    init(months: [Month], width: CGFloat, titleHeight: CGFloat) {
        self.months = months
        var offsets: [CGFloat] = []
        var heights: [CGFloat] = []
        var y: CGFloat = 0
        for (i, month) in months.enumerated() {
            if i > 0 { y += Self.monthSpacing }
            let height = titleHeight + Self.titleSpacing + MonthMosaic.height(plan: month.plan, isLoaded: month.isLoaded, width: width)
            offsets.append(y)
            heights.append(height)
            y += height
        }
        self.offsets = offsets
        self.heights = heights
        contentHeight = months.isEmpty ? 0 : y + Self.bottomPadding
        indexByID = Dictionary(months.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func index(of id: String) -> Int? { indexByID[id] }

    /// The months overlapping content y `top...bottom`, widened by `margin` each way.
    func visible(top: CGFloat, bottom: CGFloat, margin: CGFloat) -> Range<Int> {
        guard !months.isEmpty else { return 0..<0 }
        let low = top - margin, high = bottom + margin
        // First month whose bottom is below `low`.
        var lower = 0, upper = months.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if offsets[mid] + heights[mid] < low { lower = mid + 1 } else { upper = mid }
        }
        let first = lower
        // First month whose top is below `high`.
        lower = first; upper = months.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if offsets[mid] <= high { lower = mid + 1 } else { upper = mid }
        }
        return first..<max(first, lower)
    }
}
