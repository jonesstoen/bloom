import ImmichKit
import SwiftUI

/// Album covers and cropped faces share the encoded-image cache with the library.
struct CollectionThumbnail: View {
    let key: ImageKey?
    let loader: ImageLoader
    var symbol = "photo.on.rectangle"
    @State private var image: CGImage?

    var body: some View {
        Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary) }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: key) {
                image = nil
                guard let key, let data = try? await loader.data(for: key), !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data)
                if !Task.isCancelled { image = decoded }
            }
    }
}

#Preview("Collection thumbnail") {
    let mock = MockImmichService.preview
    CollectionThumbnail(key: .person(MockLibrary.standard.people[0].id), loader: ImageLoader(service: mock, disk: nil))
        .clipShape(Circle()).frame(width: 120)
}
