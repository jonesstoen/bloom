#if os(iOS)
import ImageIO
import ImmichKit
import SwiftUI
import UIKit

/// A photo that zooms like Photos: pinch, double-tap to zoom in on the tapped point, pan while
/// zoomed. Backed by `UIScrollView` so it nests correctly inside the horizontal pager: at 1×
/// it does not scroll, so horizontal swipes go to the pager.
struct ZoomableImage: UIViewRepresentable {
    let image: CGImage
    let isActive: Bool
    /// What VoiceOver reads for the image.
    var accessibilityText = tr("Photo")
    var onSingleTap: () -> Void = {}
    var livePhotoEnabled = false
    var onLivePhotoHold: (Bool) -> Void = { _ in }
    var onZoomChanged: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.setImage(image)
        view.setAccessibilityText(accessibilityText)
        view.onSingleTap = onSingleTap
        view.onLivePhotoHold = onLivePhotoHold
        view.onZoomChanged = onZoomChanged
        view.livePhotoEnabled = isActive && livePhotoEnabled
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.setImage(image)
        view.setAccessibilityText(accessibilityText)
        view.onSingleTap = onSingleTap
        view.onLivePhotoHold = onLivePhotoHold
        view.onZoomChanged = onZoomChanged
        view.livePhotoEnabled = isActive && livePhotoEnabled
        if !isActive { view.resetZoom() }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    var onSingleTap: (() -> Void)?
    var onLivePhotoHold: ((Bool) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    var livePhotoEnabled = false
    private lazy var liveHold = UILongPressGestureRecognizer(target: self, action: #selector(handleLiveHold(_:)))
    private var reportedZoomed = false
    private var holdOrigin: CGPoint = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        isScrollEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = tr("Photo")
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: liveHold)
        addGestureRecognizer(singleTap)

        liveHold.minimumPressDuration = 0.3
        liveHold.allowableMovement = 10
        liveHold.cancelsTouchesInView = false
        liveHold.delegate = self
        addGestureRecognizer(liveHold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAccessibilityText(_ text: String) {
        if imageView.accessibilityLabel != text { imageView.accessibilityLabel = text }
    }

    func setImage(_ cgImage: CGImage) {
        guard imageView.image?.cgImage !== cgImage else { return }
        imageView.image = UIImage(cgImage: cgImage)
        laidOutSize = .zero
        setNeedsLayout()
    }

    func resetZoom() {
        if zoomScale != minimumZoomScale { setZoomScale(minimumZoomScale, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
        }
        centerContent()
    }

    private func fittedSize() -> CGSize {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return bounds.size }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        // Only pan while zoomed; at 1× swipes belong to the pager.
        let zoomed = zoomScale > minimumZoomScale + 0.01
        isScrollEnabled = zoomed
        if zoomed != reportedZoomed {
            reportedZoomed = zoomed
            // resetZoom can be called from updateUIView: report after that update finishes.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onZoomChanged?(self.window != nil && zoomed)
            }
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === liveHold {
            return livePhotoEnabled && zoomScale <= minimumZoomScale + 0.01
                && (pinchGestureRecognizer?.numberOfTouches ?? 0) < 2
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === liveHold || otherGestureRecognizer === liveHold
    }

    @objc private func handleLiveHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard livePhotoEnabled, zoomScale <= minimumZoomScale + 0.01 else { return }
            holdOrigin = gesture.location(in: window)
            onLivePhotoHold?(true)
        case .changed:
            let point = gesture.location(in: window)
            let distance = hypot(point.x - holdOrigin.x, point.y - holdOrigin.y)
            // Scroll and pinch recognizers remain free to take over from a hold.
            if panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed
                || (pinchGestureRecognizer?.numberOfTouches ?? 0) > 1 || distance > 12 {
                onLivePhotoHold?(false)
            }
        case .ended, .cancelled, .failed:
            onLivePhotoHold?(false)
        default: break
        }
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

#Preview("Zoomable photo") {
    let _ = MockImmichService.preview
    let data = PlaceholderImage.jpegData(assetID: "preview", size: .preview, aspectRatio: 0.75)
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return ZoomableImage(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!, isActive: true)
        .background(.black)
}
#endif
