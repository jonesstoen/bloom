import ImmichKit
import SwiftUI

/// The row of small thumbnails above the viewer's toolbar, like Photos: the current item is
/// wider and centred, tapping another item jumps to it.
struct ThumbnailStrip: View {
    let assets: ArraySlice<Asset>
    let selectedID: String
    let loader: ImageLoader
    let onSelect: (String) -> Void

    /// The strip only shows the items around the current one: rebuilding a strip of thousands
    /// of items on every swipe is what made paging stutter. The window moves in steps of
    /// `step` so it stays put (and doesn't jump) while you swipe within it.
    static func window(of assets: [Asset], around index: Int, radius: Int = 120, step: Int = 60) -> ArraySlice<Asset> {
        guard !assets.isEmpty else { return [] }
        let clamped = min(max(index, 0), assets.count - 1)
        let center = (clamped / step) * step + step / 2
        let lower = max(0, center - radius)
        let upper = min(assets.count, center + radius)
        return assets[lower..<upper]
    }

    private static let height: CGFloat = 40
    private static let width: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 2) {
                        ForEach(assets) { asset in
                            let selected = asset.id == selectedID
                            StripThumbnail(assetID: asset.id, loader: loader)
                                .frame(width: selected ? Self.height * max(0.6, min(1.6, asset.aspectRatio)) : Self.width,
                                       height: Self.height)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(.horizontal, selected ? 6 : 0)
                                .id(asset.id)
                                .onTapGesture { onSelect(asset.id) }
                                .accessibilityLabel(selected ? "Current item" : "Show item")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.horizontal, geometry.size.width / 2)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
                .onChange(of: selectedID) { _, id in
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: Self.height)
    }
}

private struct StripThumbnail: View {
    let assetID: String
    let loader: ImageLoader
    @State private var image: CGImage?

    var body: some View {
        Rectangle().fill(.white.opacity(0.12))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let data = try? await loader.data(for: ImageKey(assetID: assetID, size: .thumbnail)),
                      !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 120)
                if !Task.isCancelled { image = decoded }
            }
    }
}

#Preview("Thumbnail strip") {
    let mock = MockImmichService.preview
    let assets = Array(MockLibrary.standard.assets.prefix(40))
    ThumbnailStrip(assets: assets[...], selectedID: assets[10].id, loader: ImageLoader(service: mock, disk: nil)) { _ in }
        .background(.black)
}
