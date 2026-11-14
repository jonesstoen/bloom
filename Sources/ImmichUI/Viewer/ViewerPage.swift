import ImmichKit
import SwiftUI

/// One item in the pager. Loads its preview and full details when it is built, so the
/// neighbours the lazy pager builds ahead are ready before you swipe to them.
struct ViewerPage: View {
    let model: ViewerAssetModel
    let store: ViewerStore
    let isActive: Bool
    var livePlaybackAllowed = true
    let onTap: () -> Void
    @State private var playbackAllowed = false

    private struct LoadID: Hashable {
        let mayLoad: Bool
        let retentionGeneration: Int
    }

    var body: some View {
        ZStack {
            if model.asset.isVideo, let request = model.playback {
                VideoPlaybackView(request: request, isActive: isActive && livePlaybackAllowed)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else if let image = model.displayImage {
                #if os(iOS)
                ZoomableImage(image: image, isActive: isActive,
                              accessibilityText: ViewerAccessibility.label(for: model.asset, place: model.placeTitle),
                              onSingleTap: onTap,
                              livePhotoEnabled: livePlaybackAllowed && model.asset.isLivePhoto && model.playback != nil,
                              onLivePhotoHold: { held in
                                  if held && playbackAllowed { model.startLivePhotoPlayback() }
                                  else { model.stopLivePhotoPlayback() }
                              }, onZoomChanged: model.setLivePhotoZoomed)
                    .overlay {
                        if isActive, livePlaybackAllowed, model.isLivePhotoPlaying, let request = model.playback {
                            let generation = model.livePhotoPlaybackGeneration
                            LivePhotoPlaybackView(request: request) { failed in
                                model.finishLivePhotoPlayback(generation: generation, failed: failed)
                            }
                            .id(generation)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                #else
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .onTapGesture(perform: onTap)
                #endif
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    if !model.isMissing { Button(tr("Try Again")) { Task { await model.load() } } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // The preview failed while the thumbnail is showing: say so rather than leave it blurry.
            if model.image == nil, model.placeholder != nil, !model.asset.isVideo, let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    if !model.isMissing { Button(tr("Try Again")) { Task { await model.load() } } }
                }
                .padding()
                .photosGlass(in: RoundedRectangle(cornerRadius: 16), interactive: false)
                .padding(.horizontal, 32)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.livePhotoPlaybackError, isActive {
                VStack(spacing: 8) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button(tr("Try Again")) { retryLivePhoto() }
                }
                .padding()
                .photosGlass(in: RoundedRectangle(cornerRadius: 16), interactive: false)
                .padding(.horizontal, 32)
                .padding(.bottom, 180)
            }
        }
        .onAppear {
            playbackAllowed = isActive && livePlaybackAllowed
        }
        .onChange(of: livePlaybackAllowed) { _, allowed in
            playbackAllowed = isActive && allowed
            if !allowed { model.stopLivePhotoPlayback() }
        }
        .onChange(of: isActive) { _, active in
            playbackAllowed = active && livePlaybackAllowed
            if !active {
                model.stopLivePhotoPlayback()
                model.setLivePhotoZoomed(false)
            }
        }
        .onDisappear {
            playbackAllowed = false
            model.stopLivePhotoPlayback()
            model.setLivePhotoZoomed(false)
        }
        .task(id: LoadID(mayLoad: model.retainsPreview && (isActive || store.neighboursMayLoad),
                         retentionGeneration: model.previewRetentionGeneration)) {
            if model.retainsPreview && (isActive || store.neighboursMayLoad) && !model.isLoaded {
                await model.load()
            }
        }
    }

    private func retryLivePhoto() {
        Task {
            if model.playback == nil { await model.load() }
            guard playbackAllowed else { return }
            #if os(iOS)
            model.startLivePhotoPlayback()
            #endif
        }
    }
}

#Preview("Viewer page") {
    let mock = MockImmichService.preview
    let loader = ImageLoader(service: mock, disk: nil)
    ViewerPage(model: ViewerAssetModel(asset: MockLibrary.standard.assets[0], service: mock, loader: loader),
               store: ViewerStore(service: mock, loader: loader), isActive: true, onTap: {})
}
