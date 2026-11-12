import Foundation
import Observation

/// State the Library tab shares with the tab bar, so the Years / Months / All switcher can live in
/// the tab bar like Photos on iOS 26: hidden at the newest photos, and shown once you scroll away
/// from them, between the minimized tab button and Search.
///
/// The grid writes `isAvailable`, `isAwayFromNewest` and `newestFirst`; the tab view reads them.
/// `isAwayFromNewest` is only written when it changes, so scrolling doesn't re-render the tab view.
@MainActor
@Observable
public final class LibraryChrome {
    public init() {}

    /// Years / Months / All.
    var scale: LibraryScale = .all
    /// The library has photos and nothing else owns the bottom (not loading, empty or selecting).
    var isAvailable = false
    /// Scrolled clearly away from the newest photos.
    var isAwayFromNewest = false
    /// The grid's sort order puts the newest photos at the top.
    var newestFirst = false
    /// A trash/restore/selection operation is running: the switcher shows but can't be used.
    var isBlocked = false

    /// The switcher shows away from the newest photos, and always in Years and Months so you can
    /// get back to All.
    var wantsSwitcher: Bool {
        isAvailable && (scale != .all || isAwayFromNewest)
    }

    // MARK: Scroll position

    /// More than one row of newer photos is off screen. Decided from the cells SwiftUI reports on
    /// screen rather than the scroll offset: LazyVGrid only estimates the height of rows it hasn't
    /// built, so after a jump (opening at the newest photos, a pinch) offsets don't map to rows.
    /// The tab bar's inset changing when the switcher appears can't flip it back: a taller bar only
    /// hides more of the newest row.
    static func isAway(visible: ClosedRange<Int>, itemCount: Int, columns: Int, newestFirst: Bool) -> Bool {
        let hiddenNewer = newestFirst ? visible.lowerBound : (itemCount - 1) - visible.upperBound
        return hiddenNewer > max(1, columns)
    }

    // MARK: Tab bar

    enum MinimizeDirection: Equatable { case up, down }

    /// Photos minimizes the tab bar as you scroll toward older photos. With the oldest at the top
    /// that is scrolling up; other tabs (and newest-first sorting) minimize when scrolling down.
    static func tabBarMinimizeDirection(libraryTab: Bool, newestFirst: Bool) -> MinimizeDirection {
        libraryTab && !newestFirst ? .up : .down
    }
}
