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
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let loader: ImageLoader

    public init(asset: Asset, service: any ImmichService, loader: ImageLoader) {
        self.asset = asset
        self.service = service
        self.loader = loader
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let data = try await loader.data(for: ImageKey(assetID: asset.id, size: .preview))
            let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 2560)
            try Task.checkCancellation()
            image = decoded
            asset = try await service.asset(id: asset.id)
            if asset.isVideo { playback = try await service.playbackRequest(for: asset) }
        } catch is CancellationError {
            return
        } catch {
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
