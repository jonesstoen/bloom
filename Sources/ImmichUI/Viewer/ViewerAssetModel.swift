import CoreGraphics
import Foundation
import ImmichKit
import Observation

@MainActor @Observable
public final class ViewerAssetModel {
    public private(set) var asset: Asset
    /// The preview, sharp enough to fill the screen. `nil` until it has loaded.
    public private(set) var image: CGImage?
    /// The small grid thumbnail, shown until the preview arrives so opening a photo is instant.
    public private(set) var placeholder: CGImage?
    /// What the page shows: the preview, or the thumbnail while it loads.
    public var displayImage: CGImage? { image ?? placeholder }
    public private(set) var playback: MediaRequest?
    public private(set) var error: String?
    public private(set) var isLoading = false
    public private(set) var isLoaded = false
    /// Whether this page may retain or load decoded media in the current viewer window.
    public private(set) var retainsPreview = true
    /// Changes even if a rapid away/back jump coalesces the permission back to `true`.
    public private(set) var previewRetentionGeneration = 0
    public private(set) var isLivePhotoPlaying = false
    public private(set) var livePhotoPlaybackGeneration = 0
    public private(set) var livePhotoPlaybackError: String?
    public private(set) var isLivePhotoZoomed = false
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let loader: ImageLoader
    @ObservationIgnored private var generation = 0

    public init(asset: Asset, service: any ImmichService, loader: ImageLoader, placeholder: CGImage? = nil) {
        self.asset = asset
        self.placeholder = placeholder
        self.service = service
        self.loader = loader
    }

    /// Flips the favorite flag right away, like Photos, and rolls back if the server refuses.
    public func toggleFavorite() async {
        let target = !asset.isFavorite
        asset.isFavorite = target
        do {
            let updated = try await service.setFavorite(assetID: asset.id, isFavorite: target)
            guard asset.id == updated.id else { return }
            asset.isFavorite = updated.isFavorite
        } catch {
            asset.isFavorite = !target
            self.error = target ? tr("Couldn't add to Favorites.") : tr("Couldn't remove from Favorites.")
        }
    }

    /// Short place name for the viewer title ("Oslo"), when the asset has a location.
    public var placeTitle: String? {
        guard let exif = asset.exif else { return nil }
        return exif.city?.nilIfEmpty ?? exif.state?.nilIfEmpty ?? exif.country?.nilIfEmpty
    }

    public func startLivePhotoPlayback() {
        guard asset.isLivePhoto, !asset.isVideo, playback != nil, isLoaded, !isLoading,
              !isLivePhotoZoomed, !isLivePhotoPlaying else { return }
        livePhotoPlaybackGeneration += 1
        livePhotoPlaybackError = nil
        isLivePhotoPlaying = true
    }

    public func stopLivePhotoPlayback() {
        guard isLivePhotoPlaying else { return }
        livePhotoPlaybackGeneration += 1
        isLivePhotoPlaying = false
    }

    public func finishLivePhotoPlayback(generation: Int, failed: Bool = false) {
        guard isLivePhotoPlaying, generation == livePhotoPlaybackGeneration else { return }
        stopLivePhotoPlayback()
        if failed { livePhotoPlaybackError = tr("Couldn't play this Live Photo. Try again.") }
    }

    public func setLivePhotoZoomed(_ zoomed: Bool) {
        isLivePhotoZoomed = zoomed
        if zoomed { stopLivePhotoPlayback() }
    }

    /// Invalidates suspended loads before releasing media, including loads owned by pages
    /// SwiftUI still retains outside the preview window. Keep favorite and EXIF state intact.
    func setPreviewRetained(_ retained: Bool) {
        guard retainsPreview != retained else { return }
        retainsPreview = retained
        previewRetentionGeneration += 1
        guard !retained else { return }
        generation += 1
        stopLivePhotoPlayback()
        isLivePhotoZoomed = false
        image = nil
        placeholder = nil
        playback = nil
        error = nil
        livePhotoPlaybackError = nil
        isLoading = false
        isLoaded = false
    }

    public func load() async {
        guard retainsPreview else { return }
        stopLivePhotoPlayback()
        livePhotoPlaybackError = nil
        generation += 1
        let started = generation
        isLoading = true
        isLoaded = false
        error = nil
        defer { if generation == started { isLoading = false } }
        if displayImage == nil, let data = await loader.memoryData(for: ImageKey(assetID: asset.id, size: .thumbnail)),
           !Task.isCancelled {
            let thumbnail = await ThumbnailDecoder.decode(data)
            if !Task.isCancelled, generation == started, image == nil { placeholder = thumbnail }
        }
        do {
            try Task.checkCancellation()
            guard generation == started, retainsPreview else { return }
            // Detail or motion retries can reuse the sharp preview until the page releases it.
            if image == nil {
                let data = try await loader.data(for: ImageKey(assetID: asset.id, size: .preview))
                try Task.checkCancellation()
                guard generation == started else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 2560)
                try Task.checkCancellation()
                guard generation == started else { return }
                image = decoded
            }
            let detail = try await service.asset(id: asset.id)
            try Task.checkCancellation()
            guard generation == started else { return }
            var request: MediaRequest?
            var motionFailed = false
            do {
                request = try await service.playbackRequest(for: detail)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A motion failure must never hide a Live Photo's still image.
                guard detail.isLivePhoto, !detail.isVideo else { throw error }
                motionFailed = true
            }
            try Task.checkCancellation()
            guard generation == started else { return }
            asset = detail
            playback = request
            if motionFailed { livePhotoPlaybackError = tr("Couldn't play this Live Photo. Try again.") }
            isLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard generation == started else { return }
            // Do not surface transport diagnostics containing authenticated media URLs.
            self.error = tr("Couldn't load this item. Please try again.")
        }
    }
}

enum ViewerGesture {
    static func canStartDismiss(x: Double, y: Double, isZoomed: Bool, blocked: Bool) -> Bool {
        !blocked && !isZoomed && y > 0 && y > abs(x) * 1.5
    }

    static func shouldDismiss(x: Double, y: Double, zoom: Double) -> Bool {
        zoom == 1 && y > 100 && y > abs(x) * 1.5
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
