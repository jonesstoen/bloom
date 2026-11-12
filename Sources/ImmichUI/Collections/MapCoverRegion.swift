import Foundation
import ImmichKit

/// The area the pinned Map card shows: where most photos were taken. The outer 10 % on each side
/// are left out, so one far trip doesn't zoom the card out to a whole continent.
public struct MapCoverRegion: Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    /// A single place still shows its surroundings (about a city).
    static let minimumDelta = 0.05

    public init?(markers: [MapMarker]) {
        guard !markers.isEmpty else { return nil }
        let latitudes = markers.map(\.latitude).sorted()
        let longitudes = markers.map(\.longitude).sorted()
        func bounds(_ sorted: [Double]) -> (Double, Double) {
            let trim = sorted.count >= 10 ? sorted.count / 10 : 0
            return (sorted[trim], sorted[sorted.count - 1 - trim])
        }
        let (south, north) = bounds(latitudes)
        let (west, east) = bounds(longitudes)
        latitude = (south + north) / 2
        longitude = (west + east) / 2
        // Some room around the photos, like Photos' map card.
        latitudeDelta = min(170, max(Self.minimumDelta, (north - south) * 1.4))
        longitudeDelta = min(360, max(Self.minimumDelta, (east - west) * 1.4))
    }
}
