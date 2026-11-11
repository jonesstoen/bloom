import ImmichKit
import SwiftUI

/// One square grid cell: the asset's thumbnail cropped to fill, with a duration badge for
/// videos and a heart for favorites, like the Photos grid.
struct ThumbnailCell: View {
    let asset: Asset
    let loader: ImageLoader
    let images: ThumbnailImageCache
    var size: ImageSize = .thumbnail

    @State private var image: CGImage?

    private var key: ImageKey { ImageKey(assetID: asset.id, size: size) }

    var body: some View {
        Color(white: 0.5, opacity: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = image ?? images.image(for: key) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) { badges }
            .clipped()
            .contentShape(Rectangle())
            .task(id: asset.id) { await load() }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var badges: some View {
        if asset.isFavorite || asset.isVideo {
            HStack(alignment: .bottom) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                }
                Spacer(minLength: 0)
                if asset.isVideo {
                    Text(asset.duration.map(LibraryGridModel.durationText) ?? "")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(.horizontal, 5)
            .padding(.bottom, 3)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var accessibilityText: Text {
        var parts: [String] = [asset.isVideo ? "Video" : "Photo"]
        parts.append(asset.localDateTime.formatted(Self.dateStyle))
        if asset.isFavorite { parts.append("Favorite") }
        return Text(parts.joined(separator: ", "))
    }

    private static let dateStyle: Date.FormatStyle = {
        Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).day().month(.wide).year()
    }()

    private func load() async {
        let key = self.key
        if let cached = images.image(for: key) {
            image = cached
            return
        }
        image = nil
        guard let data = try? await loader.data(for: key), !Task.isCancelled,
              let decoded = await ThumbnailDecoder.decode(data), !Task.isCancelled
        else { return }
        images.insert(decoded, for: key)
        withAnimation(.easeOut(duration: 0.15)) { image = decoded }
    }
}

/// Grey square standing in for an asset of a month that has not loaded yet.
struct PlaceholderCell: View {
    var body: some View {
        Color(white: 0.5, opacity: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

#Preview("Thumbnail and placeholder") {
    let mock = MockImmichService.preview
    return HStack {
        ThumbnailCell(asset: MockLibrary.standard.assets[0], loader: ImageLoader(service: mock, disk: nil), images: ThumbnailImageCache())
        PlaceholderCell()
    }.frame(width: 240)
}
