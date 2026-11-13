import AVKit
import Combine
import ImmichKit
import SwiftUI

/// Video page, like Photos: the video starts when its page becomes current, the bars fade out
/// while it plays, and with the bars shown a glass capsule above the thumbnail strip has play /
/// pause, a progress bar to scrub and mute. There are no system controls on top of the picture.
struct VideoPlaybackView: View {
    private let request: MediaRequest
    private let isActive: Bool
    @State private var transport: VideoTransport
    @State private var failed = false
    @Environment(\.viewerBottomBarTop) private var bottomBarTop
    /// The global y of this page's bottom edge, to place the controls above the viewer's bar.
    @State private var containerBottom: CGFloat = 0
    @Environment(\.viewerVideoPlayback) private var playback
    /// Whether this page last told the viewer it is playing, so leaving the page undoes it.
    @State private var reportedPlaying = false

    init(request: MediaRequest, isActive: Bool = true) {
        self.request = request
        self.isActive = isActive
        let item = AVPlayerItem(asset: GuardedMediaAsset(request: request))
        _transport = State(initialValue: VideoTransport(player: AVPlayer(playerItem: item)))
    }

    private var player: AVPlayer { transport.player }

    var body: some View {
        Group {
            if request.url.host == "mock.immich.invalid" {
                ContentUnavailableView(tr("Preview Video"), systemImage: "video", description: Text(tr("Mock videos have no playable media. Connect to your server to play videos.")))
            } else if failed {
                ContentUnavailableView(tr("Video Unavailable"), systemImage: "video.slash", description: Text(tr("Close this item and try again.")))
            } else if let item = player.currentItem {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { containerBottom = $0 }
                    .overlay(alignment: .bottom) {
                        // Shown with the viewer's bars, just above the thumbnail strip.
                        if let padding = ViewerChromeLayout.padding(containerBottom: containerBottom, barTop: bottomBarTop) {
                            VideoControls(transport: transport)
                                .padding(.horizontal, 16)
                                .padding(.bottom, padding)
                                .ignoresSafeArea(edges: .bottom)
                                .transition(.opacity)
                        }
                    }
                    .onReceive(item.publisher(for: \.status)) { failed = $0 == .failed }
                    .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)) { _ in
                        // Back to the start, ready to play again, like Photos.
                        player.seek(to: .zero)
                    }
            }
        }
        .onAppear {
            transport.start()
            updatePlayback(isActive)
        }
        .onChange(of: isActive) { _, active in
            updatePlayback(active)
            if !active { report(playing: false) }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            // Waiting to play (buffering) counts as playing: the bars shouldn't flicker back.
            guard isActive else { return }
            report(playing: status != .paused)
        }
        .onDisappear {
            player.pause()
            transport.stop()
            report(playing: false)
        }
    }

    private func report(playing: Bool) {
        guard reportedPlaying != playing else { return }
        reportedPlaying = playing
        playback.changed(playing)
    }

    private func updatePlayback(_ active: Bool) {
        if active && !failed { player.play() } else { player.pause() }
    }
}

/// Playback state for the controls: position, length, playing and muted.
@MainActor @Observable
final class VideoTransport {
    let player: AVPlayer
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var isMuted: Bool {
        get { muted }
        set { muted = newValue; player.isMuted = newValue }
    }
    private var muted = false
    /// While the user drags, the bar follows the finger instead of the player.
    private(set) var scrubbing: Double?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
        muted = player.isMuted
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (scrubbing ?? current) / duration))
    }

    func start() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time: time) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    private func update(time: CMTime) {
        if time.isNumeric { current = time.seconds }
        if let length = player.currentItem?.duration, length.isNumeric, length.seconds > 0 { duration = length.seconds }
    }

    func togglePlaying() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func scrub(to fraction: Double) {
        guard duration > 0 else { return }
        let seconds = min(1, max(0, fraction)) * duration
        scrubbing = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func endScrubbing() {
        if let scrubbing { current = scrubbing }
        scrubbing = nil
    }

    func step(by seconds: Double) {
        guard duration > 0 else { return }
        scrub(to: (current + seconds) / duration)
        endScrubbing()
    }
}

/// The glass capsule from Photos: play / pause, a progress bar you can drag, and mute.
private struct VideoControls: View {
    let transport: VideoTransport

    var body: some View {
        HStack(spacing: 14) {
            Button {
                transport.togglePlaying()
            } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(transport.isPlaying ? tr("Pause") : tr("Play"))

            ScrubBar(transport: transport)

            Button {
                transport.isMuted.toggle()
            } label: {
                Image(systemName: transport.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(transport.isMuted ? tr("Unmute") : tr("Mute"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 52)
        .photosGlass(in: Capsule())
    }
}

private struct ScrubBar: View {
    let transport: VideoTransport

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: max(6, geometry.size.width * transport.progress))
            }
            .frame(height: transport.scrubbing == nil ? 6 : 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { transport.scrub(to: $0.location.x / max(1, geometry.size.width)) }
                    .onEnded { _ in transport.endScrubbing() }
            )
            .animation(.easeOut(duration: 0.15), value: transport.scrubbing == nil)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(tr("Playback position"))
        .accessibilityValue(Text(Duration.seconds(transport.scrubbing ?? transport.current)
            .formatted(.time(pattern: .minuteSecond))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: transport.step(by: 5)
            case .decrement: transport.step(by: -5)
            @unknown default: break
            }
        }
    }
}

/// The picture only, scaled to fit, without system controls.
#if os(iOS)
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#else
private struct PlayerLayerView: View {
    let player: AVPlayer
    var body: some View { VideoPlayer(player: player) }
}
#endif

#Preview("Video placeholder") {
    let _ = MockImmichService.preview
    VideoPlaybackView(request: MediaRequest(kind: .videoPlayback, assetID: "preview", url: URL(string: "https://mock.immich.invalid/video")!))
}

#Preview("Video controls") {
    VideoControls(transport: VideoTransport(player: AVPlayer()))
        .padding()
        .background(.black)
}
