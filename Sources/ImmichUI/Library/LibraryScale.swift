import ImmichKit
import SwiftUI

/// The Library's zoom levels, like the Years / Months / All switcher in Photos.
public enum LibraryScale: String, CaseIterable, Identifiable, Sendable {
    case years, months, all
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .years: tr("Years")
        case .months: tr("Months")
        case .all: tr("All")
        }
    }

    /// Years 0, Months 1, All 2: higher is finer.
    private var depth: Int {
        switch self {
        case .years: 0
        case .months: 1
        case .all: 2
        }
    }

    /// How this level looks while `shown` is on screen. Like Photos, a level that isn't shown
    /// waits faded out, smaller if it is coarser than the shown one and larger if finer, so a
    /// switch zooms both levels in the same direction while they cross-fade.
    /// With Reduce Motion the levels only cross-fade.
    func zoom(showing shown: LibraryScale, reduceMotion: Bool = false) -> (scale: CGFloat, opacity: Double) {
        if self == shown { return (1, 1) }
        return (reduceMotion ? 1 : (depth < shown.depth ? 0.85 : 1.15), 0)
    }

    /// The switch between levels (Photos takes about a third of a second).
    static let switchAnimation = Animation.smooth(duration: 0.35)
}

/// Shows one Library level according to the level on screen (see `LibraryScale.zoom`).
struct LibraryZoomLayer: ViewModifier {
    let level: LibraryScale
    let shown: LibraryScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let zoom = level.zoom(showing: shown, reduceMotion: reduceMotion)
        content
            .scaleEffect(zoom.scale)
            .opacity(zoom.opacity)
            .allowsHitTesting(level == shown)
            .accessibilityHidden(level != shown)
    }
}

/// The Years / Months / All switcher: floating glass at the bottom of the Library, or (iOS 26.1+)
/// inside the tab bar's accessory, which brings its own glass.
struct LibraryScaleSwitcher: View {
    @Binding var scale: LibraryScale
    /// Off in the tab bar accessory: the system draws the glass there.
    var showsGlass = true
    /// Between the minimized tab button and Search there is less room.
    var isCompact = false
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryScale.allCases) { option in
                Button {
                    withAnimation(LibraryScale.switchAnimation) { scale = option }
                } label: {
                    Text(option.title)
                        .font((isCompact ? Font.footnote : .subheadline).weight(.semibold))
                        .foregroundStyle(scale == option ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, isCompact ? 10 : 16)
                        .padding(.vertical, isCompact ? 6 : 9)
                        .background {
                            // A clear lighter capsule behind the current level, like Photos.
                            if scale == option {
                                Capsule().fill(.primary.opacity(0.24))
                                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scale == option ? .isSelected : [])
                // Capped like the tab bar it sits in; a long press shows it large instead.
                .accessibilityShowsLargeContentViewer()
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(showsGlass ? 4 : 2)
        .modifier(SwitcherGlass(isOn: showsGlass))
    }
}

private struct SwitcherGlass: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn { content.photosGlass(in: Capsule()) } else { content }
    }
}

#Preview("Scale switcher") {
    let _ = MockImmichService.preview
    LibraryScaleSwitcher(scale: .constant(.all)).padding().background(.gray)
}
