#if os(iOS)
import AVFoundation
import ImmichKit
import SwiftUI
import UIKit

/// A motion layer over the still image. It exists only for the active playback session;
/// tearing it down also cancels a play request that is still waiting for its first frame.
struct LivePhotoPlaybackView: UIViewRepresentable {
    let request: MediaRequest
    let onFinish: (_ failed: Bool) -> Void

    func makeUIView(context: Context) -> LivePhotoPlayerView {
        let view = LivePhotoPlayerView()
        view.start(request: request, onFinish: onFinish)
        return view
    }

    func updateUIView(_ view: LivePhotoPlayerView, context: Context) {}

    static func dismantleUIView(_ view: LivePhotoPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class LivePhotoPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var session = UUID()
    private var onFinish: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start(request: MediaRequest, onFinish: @escaping (Bool) -> Void) {
        stop()
        self.onFinish = onFinish
        let started = session
        // Mock previews never attempt a network stream.
        guard request.url.host != "mock.immich.invalid" else {
            Task { @MainActor [weak self] in self?.finish(session: started, failed: true) }
            return
        }
        let item = AVPlayerItem(asset: GuardedMediaAsset(request: request))
        let player = AVPlayer(playerItem: item)
        playerLayer.player = player
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            guard failed else { return }
            Task { @MainActor [weak self] in self?.finish(session: started, failed: true) }
        }
        displayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.session == started else { return }
                self.playerLayer.isHidden = !self.playerLayer.isReadyForDisplay
            }
        }
        for (name, failed) in [(AVPlayerItem.didPlayToEndTimeNotification, false),
                               (AVPlayerItem.failedToPlayToEndTimeNotification, true)] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(session: started, failed: failed) }
            })
        }
        player.play()
    }

    func stop() {
        session = UUID()
        onFinish = nil
        statusObservation = nil
        displayObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let player = playerLayer.player {
            player.pause()
            player.seek(to: .zero)
            player.replaceCurrentItem(with: nil)
        }
        playerLayer.player = nil
        playerLayer.isHidden = true
    }

    private func finish(session: UUID, failed: Bool) {
        guard self.session == session else { return }
        let completion = onFinish
        stop()
        completion?(failed)
    }
}

#Preview("Live Photo motion") {
    let _ = MockImmichService.preview
    LivePhotoPlaybackView(request: MediaRequest(kind: .videoPlayback, assetID: "preview",
                                               url: URL(string: "https://mock.immich.invalid/live")!)) { _ in }
        .background(.black)
}
#endif
