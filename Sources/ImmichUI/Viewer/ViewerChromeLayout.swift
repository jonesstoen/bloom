import SwiftUI

/// The space the viewer's own bars cover, beyond the safe area. Videos pass it to the system player
/// as extra safe area, so its scrubber sits above the thumbnail strip and buttons instead of behind
/// them (measured on iOS 26: the transport bar moves by exactly the extra inset while the picture
/// and the centre buttons stay put).
struct ViewerChromeLayout: Equatable {
    struct Screen: Equatable {
        var height: CGFloat = 0
        var safeArea = EdgeInsets()
    }

    var screen = Screen()
    var topBarBottom: CGFloat = 0
    var bottomBarTop: CGFloat = 0

    /// Small gap so the system controls don't touch the bars.
    static let gap: CGFloat = 8

    var insets: EdgeInsets {
        let top = topBarBottom > 0 ? max(0, topBarBottom - screen.safeArea.top + Self.gap) : 0
        let safeBottom = screen.height - screen.safeArea.bottom
        let bottom = bottomBarTop > 0 && screen.height > 0 ? max(0, safeBottom - bottomBarTop + Self.gap) : 0
        return EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0)
    }
}

extension EnvironmentValues {
    /// Extra insets for content that draws its own controls under the viewer's bars (videos).
    /// Zero while the bars are hidden.
    @Entry var viewerChromeInsets = EdgeInsets()
}

/// Tells the viewer when the current page's video starts or stops playing, so the bars fade out
/// during playback and come back when it pauses or ends, like Photos.
struct ViewerVideoPlayback {
    var changed: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var viewerVideoPlayback = ViewerVideoPlayback()
}
