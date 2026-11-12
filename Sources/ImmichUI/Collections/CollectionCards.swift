import ImmichKit
import MapKit
import SwiftUI

/// A rounded square image with its title over the bottom, like album cards in Photos.
struct ImageCard: View {
    let key: ImageKey?
    let loader: ImageLoader
    let title: String
    var symbol = "photo"

    var body: some View {
        CollectionThumbnail(key: key, loader: loader, symbol: symbol)
            .frame(width: 160, height: 160)
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .padding(12)
            }
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// A pinned collection card: a preview (or a coloured background) with a symbol and title.
struct PinnedCard<Background: View>: View {
    let title: String
    let systemImage: String?
    @ViewBuilder let background: Background

    var body: some View {
        background
            .frame(width: 160, height: 160)
            .overlay {
                // Keeps the white title readable on light photos and maps.
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .topTrailing) {
                if let systemImage {
                    Image(systemName: systemImage).font(.title2).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3).padding(12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.headline).foregroundStyle(.white).padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// A place card: the newest photo taken there, with the city name over it.
struct PlaceCard: View {
    let city: String
    let service: any ImmichService
    let loader: ImageLoader
    @State private var coverID: String?

    var body: some View {
        ImageCard(key: coverID.map { ImageKey(assetID: $0, size: .thumbnail) }, loader: loader, title: city, symbol: "mappin.and.ellipse")
            .task(id: city) {
                guard coverID == nil else { return }
                let results = try? await service.metadataSearch(CollectionsView.placeQuery(city), page: nil, size: 1)
                if !Task.isCancelled { coverID = results?.assets.first?.id }
            }
    }
}

/// The pinned Map card's preview: a still map of where most photos were taken.
struct MapCoverView: View {
    let region: MapCoverRegion

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta))),
            interactionModes: [])
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // MapKit's required logo and Legal link sit at the bottom: lift them above the title.
            .safeAreaPadding(.bottom, 34)
            .allowsHitTesting(false)
            // A new region (after a refresh) needs a new map: initialPosition is read once.
            .id(region)
    }
}
