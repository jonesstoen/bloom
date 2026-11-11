import CoreGraphics
import Foundation
import ImmichKit
import Observation

@MainActor @Observable
public final class ViewerAssetModel {
    public private(set) var asset: Asset
    public private(set) var image: CGImage?
    public private(set) var playback: MediaRequest?
    public private(set) var error: String?
    public private(set) var isLoading = false
    public private(set) var isLoaded = false
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let loader: ImageLoader
    @ObservationIgnored private var generation = 0

    public init(asset: Asset, service: any ImmichService, loader: ImageLoader) {
        self.asset = asset
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
            self.error = target ? "Couldn't add to Favorites." : "Couldn't remove from Favorites."
        }
    }

    /// Short place name for the viewer title ("Oslo"), when the asset has a location.
    public var placeTitle: String? {
        guard let exif = asset.exif else { return nil }
        return exif.city?.nilIfEmpty ?? exif.state?.nilIfEmpty ?? exif.country?.nilIfEmpty
    }

    public func load() async {
        generation += 1
        let started = generation
        isLoading = true
        isLoaded = false
        error = nil
        defer { if generation == started { isLoading = false } }
        do {
            let data = try await loader.data(for: ImageKey(assetID: asset.id, size: .preview))
            let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 2560)
            try Task.checkCancellation()
            guard generation == started else { return }
            image = decoded
            let detail = try await service.asset(id: asset.id)
            let request = detail.isVideo ? try await service.playbackRequest(for: detail) : nil
            try Task.checkCancellation()
            guard generation == started else { return }
            asset = detail
            playback = request
            isLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard generation == started else { return }
            // Do not surface transport diagnostics containing authenticated media URLs.
            self.error = "Couldn't load this item. Please try again."
        }
    }
}

enum ViewerGesture {
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
