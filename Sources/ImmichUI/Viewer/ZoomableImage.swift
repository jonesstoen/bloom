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
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.setImage(image)
        view.onSingleTap = onSingleTap
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.setImage(image)
        view.onSingleTap = onSingleTap
        if !isActive { view.resetZoom() }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    var onSingleTap: (() -> Void)?

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
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        isScrollEnabled = zoomScale > minimumZoomScale + 0.01
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
