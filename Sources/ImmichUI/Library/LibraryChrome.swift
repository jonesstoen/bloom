import Foundation
import Observation

/// State the Library tab shares with the tab bar, so the Years / Months / All switcher can live in
/// the tab bar like Photos on iOS 26: hidden at the newest photos, and shown once you scroll away
/// from them, between the minimized tab button and Search.
///
/// The grid writes `isAvailable`, `isAwayFromNewest` and `newestFirst`; the tab view reads them.
/// `isAwayFromNewest` changes only when it crosses a threshold, so scrolling doesn't re-render the
/// tab view.
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

    /// Points between the visible area and the newest edge of the content, insets included (at
    /// the edge it is 0 even though the content continues under the tab bar).
    static func distanceFromNewest(contentHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat,
                                   visibleMinY: CGFloat, visibleMaxY: CGFloat, newestFirst: Bool) -> CGFloat {
        newestFirst
            ? max(0, visibleMinY + insetTop)
            : max(0, contentHeight + insetBottom - visibleMaxY)
    }

    /// On after a clear scroll, off only near the edge again: the tab bar's own inset changes when it
    /// minimizes or the switcher appears, which must not toggle the switcher back and forth.
    static func isAway(distance: CGFloat, wasAway: Bool) -> Bool {
        wasAway ? distance > 24 : distance > 80
    }

    // MARK: Tab bar

    enum MinimizeDirection: Equatable { case up, down }

    /// Photos minimizes the tab bar as you scroll toward older photos. With the oldest at the top
    /// that is scrolling up; other tabs (and newest-first sorting) minimize when scrolling down.
    static func tabBarMinimizeDirection(libraryTab: Bool, newestFirst: Bool) -> MinimizeDirection {
        libraryTab && !newestFirst ? .up : .down
    }
}
