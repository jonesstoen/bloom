import AVKit
import Combine
import ImmichKit
import SwiftUI

/// Video page. Like Photos, it starts playing as soon as its page is the current one and
/// pauses when you swipe away or close the viewer.
struct VideoPlaybackView: View {
    private let request: MediaRequest
    private let isActive: Bool
    @State private var player: AVPlayer
    @State private var failed = false

    init(request: MediaRequest, isActive: Bool = true) {
        self.request = request
        self.isActive = isActive
        let item = AVPlayerItem(asset: GuardedMediaAsset(request: request))
        _player = State(initialValue: AVPlayer(playerItem: item))
    }

    var body: some View {
        Group {
            if request.url.host == "mock.immich.invalid" {
                ContentUnavailableView(tr("Preview Video"), systemImage: "video", description: Text(tr("Mock videos have no playable media. Connect to your server to play videos.")))
            } else if failed {
                ContentUnavailableView(tr("Video Unavailable"), systemImage: "video.slash", description: Text(tr("Close this item and try again.")))
            } else if let item = player.currentItem {
                VideoPlayer(player: player)
                    .onReceive(item.publisher(for: \.status)) { failed = $0 == .failed }
                    .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)) { _ in
                        // Back to the start, ready to play again, like Photos.
                        player.seek(to: .zero)
                    }
            }
        }
        .onAppear { updatePlayback(isActive) }
        .onChange(of: isActive) { _, active in updatePlayback(active) }
        .onDisappear { player.pause() }
    }

    private func updatePlayback(_ active: Bool) {
        if active && !failed { player.play() } else { player.pause() }
    }
}

#Preview("Video placeholder") {
    let _ = MockImmichService.preview
    VideoPlaybackView(request: MediaRequest(kind: .videoPlayback, assetID: "preview", url: URL(string: "https://mock.immich.invalid/video")!))
}
