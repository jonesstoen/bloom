import ImmichKit
import Observation

/// Preserves each page's lightweight asset state, while keeping decoded media only for
/// the current photo and its two nearest neighbours on either side.
@MainActor @Observable
final class ViewerStore {
    /// Whether pages other than the current one may load (see `AssetViewer.neighboursMayLoad`).
    var neighboursMayLoad = true
    @ObservationIgnored private var retainedIDs: Set<String>?
    @ObservationIgnored private var models: [String: ViewerAssetModel] = [:]
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let loader: ImageLoader
    @ObservationIgnored private let thumbnails: ThumbnailImageCache?

    init(service: any ImmichService, loader: ImageLoader, thumbnails: ThumbnailImageCache? = nil) {
        self.service = service
        self.loader = loader
        self.thumbnails = thumbnails
    }

    /// Clear media on the existing models: lazy pages may still hold references to them.
    func updateSelection(index: Int, assets: [Asset]) {
        guard assets.indices.contains(index) else { return }
        let range = max(0, index - 2)..<min(assets.count, index + 3)
        let retained = Set(assets[range].map(\.id))
        // Only the small old/new windows need updates on each swipe. A standalone
        // permissive store may contain older models when its policy is first configured.
        let previous = retainedIDs ?? Set(models.keys)
        retainedIDs = retained
        for id in previous.subtracting(retained) {
            models[id]?.setPreviewRetained(false)
        }
        for id in retained.subtracting(previous) {
            models[id]?.setPreviewRetained(true)
        }
    }

    func stopLivePhotos() {
        // Models outside the window already released playback during eviction.
        for id in retainedIDs ?? Set(models.keys) { models[id]?.stopLivePhotoPlayback() }
    }

    func model(for asset: Asset) -> ViewerAssetModel {
        if let model = models[asset.id] { return model }
        let retainsPreview = retainedIDs?.contains(asset.id) ?? true
        let thumbnail = retainsPreview ? thumbnails?.image(for: ImageKey(assetID: asset.id, size: .thumbnail)) : nil
        let model = ViewerAssetModel(asset: asset, service: service, loader: loader, placeholder: thumbnail)
        model.setPreviewRetained(retainsPreview)
        models[asset.id] = model
        return model
    }
}
