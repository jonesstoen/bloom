import SwiftUI

/// Where the viewer's bottom bar (thumbnail strip and buttons) starts, in global coordinates, so a
/// video page can put its controls just above it, like Photos. `nil` while the bars are hidden.
struct ViewerChromeLayout: Equatable {
    var bottomBarTop: CGFloat = 0

    /// Space between the video controls and the thumbnail strip.
    static let gap: CGFloat = 10

    /// Bottom padding inside a view whose bottom edge is at `containerBottom` (global), so its
    /// bottom-aligned content ends `gap` above the bar. `nil` if the bar hasn't been measured.
    static func padding(containerBottom: CGFloat, barTop: CGFloat?) -> CGFloat? {
        guard let barTop, barTop > 0, containerBottom > 0 else { return nil }
        return max(0, containerBottom - barTop + gap)
    }
}

extension EnvironmentValues {
    /// The global y where the viewer's bottom bar starts, or `nil` while the bars are hidden.
    @Entry var viewerBottomBarTop: CGFloat?
}

/// Tells the viewer when the current page's video starts or stops playing, so the bars fade out
/// during playback and come back when it pauses or ends, like Photos.
struct ViewerVideoPlayback {
    var changed: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var viewerVideoPlayback = ViewerVideoPlayback()
}
