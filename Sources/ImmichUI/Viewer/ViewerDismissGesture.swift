import ImmichKit
import Observation
import SwiftUI

/// Drag frames update only the small presentation modifiers, never the pager's page tree.
@MainActor @Observable
final class ViewerDismissMotion {
    var offset: CGFloat = 0
    var progress: Double { min(Double(offset / 400), 1) }
}

struct ViewerDismissTransform: ViewModifier {
    let motion: ViewerDismissMotion

    func body(content: Content) -> some View {
        content.scaleEffect(1 - motion.progress * 0.15)
            .offset(y: motion.offset)
    }
}

struct ViewerDismissChromeOpacity: ViewModifier {
    let motion: ViewerDismissMotion

    func body(content: Content) -> some View {
        content.opacity(1 - motion.progress)
    }
}

#Preview("Dismiss transform") {
    let assets = MockLibrary.standard.assets
    let motion = ViewerDismissMotion()
    motion.offset = 100
    return AssetViewer(assets: assets, selectedID: assets[0].id, service: MockImmichService.preview)
        .modifier(ViewerDismissTransform(motion: motion))
}

#Preview("Dismiss chrome opacity") {
    let _ = MockImmichService.preview
    let motion = ViewerDismissMotion()
    motion.offset = 100
    return Image(systemName: "chevron.left")
        .modifier(ViewerDismissChromeOpacity(motion: motion))
}

#if os(iOS)
import UIKit

/// A one-finger vertical gesture beside the pager's horizontal pan and the photo's pinch.
/// Attached through SwiftUI's native recognizer API, so it also covers video and loading pages.
struct ViewerDismissGesture: UIGestureRecognizerRepresentable {
    var isZoomed: Bool
    var blocked: Bool
    var allowsUp = false
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isZoomed: isZoomed, blocked: blocked, allowsUp: allowsUp)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        makeRecognizer(coordinator: context.coordinator)
    }

    func makeRecognizer(coordinator: Coordinator) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.name = "BloomViewerDismissPan"
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = coordinator
        recognizer.isEnabled = !isZoomed && !blocked
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        configure(recognizer, coordinator: context.coordinator)
    }

    func configure(_ recognizer: UIPanGestureRecognizer, coordinator: Coordinator) {
        coordinator.isZoomed = isZoomed
        coordinator.blocked = blocked
        coordinator.allowsUp = allowsUp
        // Disabling a live recognizer cancels its drag, including when a modal opens.
        recognizer.isEnabled = !isZoomed && !blocked
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        dispatch(recognizer)
    }

    func dispatch(_ recognizer: UIPanGestureRecognizer) {
        // Use a fixed coordinate space while the pager itself follows the finger.
        let translation = recognizer.translation(in: recognizer.view?.window)
        let offset = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began, .changed:
            onChanged(offset)
        case .ended:
            onEnded(offset)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isZoomed: Bool
        var blocked: Bool
        var allowsUp: Bool

        init(isZoomed: Bool, blocked: Bool, allowsUp: Bool = false) {
            self.isZoomed = isZoomed
            self.blocked = blocked
            self.allowsUp = allowsUp
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return ViewerGesture.canStartDismiss(x: velocity.x, y: velocity.y,
                                                 isZoomed: isZoomed, blocked: blocked, allowsUp: allowsUp)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // The pager, pinch and Live Photo hold keep their own recognizers. Direction and
            // zoom gating decide when this gesture participates instead of stealing touches.
            true
        }
    }
}
#endif
