import ImmichKit
import MapKit
import SwiftUI

/// A group of nearby photos shown as one pin on the map.
public struct MapCluster: Identifiable, Hashable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    /// Asset ids in the cluster, in marker order (the first is the cover).
    public let assetIDs: [String]

    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// Groups markers into square cells of `cellSize` degrees. Each cluster sits at the mean
    /// position of its markers, so pins land where the photos are rather than on a grid.
    public static func make(_ markers: [ImmichKit.MapMarker], cellSize: Double) -> [MapCluster] {
        guard cellSize.isFinite, cellSize > 0 else { return [] }
        var cells: [String: (lat: Double, lon: Double, ids: [String])] = [:]
        var order: [String] = []
        for marker in markers where marker.latitude.isFinite && marker.longitude.isFinite {
            let key = "\(Int((marker.latitude / cellSize).rounded(.down))):\(Int((marker.longitude / cellSize).rounded(.down)))"
            if cells[key] == nil { order.append(key); cells[key] = (0, 0, []) }
            cells[key]!.lat += marker.latitude
            cells[key]!.lon += marker.longitude
            cells[key]!.ids.append(marker.id)
        }
        return order.map { key in
            let cell = cells[key]!
            let count = Double(cell.ids.count)
            return MapCluster(id: key, latitude: cell.lat / count, longitude: cell.lon / count, assetIDs: cell.ids)
        }
    }
}

/// Photos on a map, like the Map collection in Photos. Pins group nearby photos depending on
/// the zoom level; tapping a pin opens its photos in the viewer.
public struct PhotoMapView: View {
    let service: any ImmichService
    let loader: ImageLoader
    @State private var markers: [ImmichKit.MapMarker] = []
    @State private var clusters: [MapCluster] = []
    @State private var cellSize: Double = 1
    @State private var failed = false
    @State private var opening: MapCluster?
    @State private var viewerAssets: ViewerAssets?

    /// Pins load at most this many photos into the viewer.
    static let maxAssetsPerPin = 100

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
    }

    public var body: some View {
        Map(initialPosition: .automatic) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate, anchor: .center) {
                    Button { Task { await open(cluster) } } label: {
                        MapPin(cluster: cluster, loader: loader, isOpening: opening == cluster)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { context in
            let size = max(context.region.span.latitudeDelta, 0.0005) / 7
            if abs(size - cellSize) / cellSize > 0.25 {
                cellSize = size
                clusters = MapCluster.make(markers, cellSize: size)
            }
        }
        .overlay {
            if failed {
                ContentUnavailableView {
                    Label("Can't Load Map", systemImage: "map")
                } description: { Text("Photo locations couldn't be loaded.") } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .background(.regularMaterial)
            }
        }
        .navigationTitle("Map")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewerAssets) { item in
            AssetViewer(assets: item.assets, selectedID: item.assets[0].id, service: service, loader: loader)
        }
        #else
        .sheet(item: $viewerAssets) { item in
            AssetViewer(assets: item.assets, selectedID: item.assets[0].id, service: service, loader: loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .task { if markers.isEmpty { await load() } }
    }

    private func load() async {
        failed = false
        do {
            markers = try await service.mapMarkers()
            clusters = MapCluster.make(markers, cellSize: cellSize)
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    private func open(_ cluster: MapCluster) async {
        guard opening == nil else { return }
        opening = cluster
        defer { opening = nil }
        let ids = Array(cluster.assetIDs.prefix(Self.maxAssetsPerPin))
        let assets = await withTaskGroup(of: (Int, Asset?).self) { group in
            var results = [Asset?](repeating: nil, count: ids.count)
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let index = next, id = ids[index]
                next += 1
                group.addTask { (index, try? await service.asset(id: id)) }
            }
            for _ in 0..<6 { add() }
            while let (index, asset) = await group.next() {
                results[index] = asset
                add()
            }
            return results.compactMap { $0 }
        }
        let sorted = assets.sorted { $0.takenAt > $1.takenAt }
        if !sorted.isEmpty { viewerAssets = ViewerAssets(assets: sorted) }
    }
}

private struct ViewerAssets: Identifiable {
    let id = UUID()
    let assets: [Asset]
}

/// A rounded photo pin with a count badge.
private struct MapPin: View {
    let cluster: MapCluster
    let loader: ImageLoader
    let isOpening: Bool

    var body: some View {
        CollectionThumbnail(key: cluster.assetIDs.first.map { ImageKey(assetID: $0, size: .thumbnail) }, loader: loader)
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2.5)
            }
            .overlay { if isOpening { ProgressView().tint(.white) } }
            .overlay(alignment: .topTrailing) {
                if cluster.assetIDs.count > 1 {
                    Text(cluster.assetIDs.count.formatted())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                        .offset(x: 10, y: -8)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityLabel("\(cluster.assetIDs.count) photos")
    }
}

#Preview("Map") {
    NavigationStack { PhotoMapView(service: MockImmichService.preview) }
}
