import XCTest
import ImmichKit
@testable import ImmichUI

/// Pinned Favorites and Map show a real preview, like Photos: the newest favorite photo and a map
/// around where the photos were taken.
@MainActor
final class PinnedCoversTests: XCTestCase {

    func testFavoritesCoverIsTheNewestFavoritePhoto() async throws {
        let mock = MockImmichService(library: .standard)
        let model = CollectionsModel(service: mock)
        await model.loadPinnedCovers()

        // Every favorite the Favorites grid would show, newest by capture date.
        let options = TimelineOptions(isFavorite: true, newestFirst: false)
        var favorites: [Asset] = []
        for bucket in try await mock.timeBuckets(options: options) {
            favorites += try await mock.timeBucketAssets(bucketID: bucket.id, options: options)
        }
        let newest = try XCTUnwrap(favorites.max { $0.localDateTime < $1.localDateTime })
        XCTAssertEqual(model.favoritesCoverID, newest.id)
        XCTAssertTrue(model.loadedPinnedCovers)
    }

    func testNoFavoritesOrNoGeotagsLeaveTheColouredCards() async {
        let mock = MockImmichService(assets: [])
        let model = CollectionsModel(service: mock)
        await model.loadPinnedCovers()
        XCTAssertNil(model.favoritesCoverID)
        XCTAssertNil(model.mapCoverRegion)
        XCTAssertTrue(model.loadedPinnedCovers)
    }

    func testAFailingServerLeavesTheColouredCards() async {
        let mock = MockImmichService(library: .standard)
        await mock.setFailure(.network("offline"))
        let model = CollectionsModel(service: mock)
        await model.loadPinnedCovers()
        XCTAssertNil(model.favoritesCoverID)
        XCTAssertNil(model.mapCoverRegion)
        XCTAssertTrue(model.loadedPinnedCovers, "A bonus preview: a failure must not keep it loading")
    }

    func testMapCoverIsLoadedFromTheMarkers() async throws {
        let mock = MockImmichService(library: .standard)
        let model = CollectionsModel(service: mock)
        await model.loadPinnedCovers()
        let markers = try await mock.mapMarkers()
        XCTAssertEqual(model.mapCoverRegion, MapCoverRegion(markers: markers))
        XCTAssertNotNil(model.mapCoverRegion)
    }

    // MARK: Map region

    private func marker(_ lat: Double, _ lon: Double) -> MapMarker {
        MapMarker(id: UUID().uuidString, latitude: lat, longitude: lon)
    }

    func testRegionCoversWhereMostPhotosWereTakenNotOneFarTrip() throws {
        // Twenty photos around Oslo and one from New York.
        var markers = (0..<20).map { i in marker(59.90 + Double(i) * 0.005, 10.70 + Double(i) * 0.01) }
        markers.append(marker(40.71, -74.0))
        let region = try XCTUnwrap(MapCoverRegion(markers: markers))
        XCTAssertEqual(region.latitude, 59.95, accuracy: 0.1)
        XCTAssertEqual(region.longitude, 10.8, accuracy: 0.2)
        XCTAssertLessThan(region.longitudeDelta, 5, "New York must not zoom the map out to the Atlantic")
    }

    func testOnePlaceStillShowsAReadableArea() throws {
        let region = try XCTUnwrap(MapCoverRegion(markers: [marker(59.91, 10.75), marker(59.91, 10.75)]))
        XCTAssertEqual(region.latitude, 59.91, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(region.latitudeDelta, MapCoverRegion.minimumDelta)
        XCTAssertGreaterThanOrEqual(region.longitudeDelta, MapCoverRegion.minimumDelta)
    }

    func testNoMarkersNoRegion() {
        XCTAssertNil(MapCoverRegion(markers: []))
    }
}
