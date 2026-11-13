import ImmichKit
import SwiftUI

/// A photo filling its frame, loaded through the shared image loader.
struct CoverImage: View {
    let asset: Asset?
    let loader: ImageLoader
    var size: ImageSize = .preview
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: asset?.id) {
                guard let asset,
                      let data = try? await loader.data(for: ImageKey(assetID: asset.id, size: size)),
                      !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: size == .preview ? 1000 : 400)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = decoded } }
            }
    }
}
