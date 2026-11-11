import AVKit
import Combine
import ImmichKit
import SwiftUI

struct VideoPlaybackView: View {
    private let request: MediaRequest
    @State private var player: AVPlayer
    @State private var failed = false

    init(request: MediaRequest) {
        self.request = request
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: request.avURLAssetOptions))
        _player = State(initialValue: AVPlayer(playerItem: item))
    }

    var body: some View {
        Group {
            if request.url.host == "mock.immich.invalid" {
                ContentUnavailableView("Preview Video", systemImage: "video", description: Text("Mock videos have no playable media. Connect to your server to play videos."))
            } else if failed {
                ContentUnavailableView("Video Unavailable", systemImage: "video.slash", description: Text("Close this item and try again."))
            } else if let item = player.currentItem {
                VideoPlayer(player: player)
                    .onReceive(item.publisher(for: \.status)) { failed = $0 == .failed }
            }
        }
        .onDisappear { player.pause() }
    }
}

#Preview("Video placeholder") {
    let _ = MockImmichService.preview
    VideoPlaybackView(request: MediaRequest(kind: .videoPlayback, assetID: "preview", url: URL(string: "https://mock.immich.invalid/video")!))
}
