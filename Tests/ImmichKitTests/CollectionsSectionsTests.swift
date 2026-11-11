import XCTest
import ImmichKit
@testable import ImmichUI

/// Media Types, Other and Places in Collections.
@MainActor
final class CollectionsSectionsTests: XCTestCase {
    private let library = MockLibrary.standard

    func testVideosGridPagesThroughAllVideos() async {
        let mock = MockImmichService(library: library)
        let model = QueryGridModel(query: MetadataSearchQuery(filters: SearchFilters(kind: .video)),
                                   service: mock, pageSize: 5)
        await model.loadMore()
        XCTAssertEqual(model.assets.count, 5)
        XCTAssertTrue(model.canLoadMore)
        while model.canLoadMore { await model.loadMore() }
        let expected = library.assets.filter { $0.isVideo && !$0.isArchived && !$0.isTrashed }
        XCTAssertEqual(Set(model.assets.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(model.assets.count, expected.count, "no duplicates")
        XCTAssertTrue(model.assets.allSatisfy(\.isVideo))
    }

    func testLivePhotosGrid() async {
        let model = QueryGridModel(query: MetadataSearchQuery(filters: SearchFilters(isMotion: true)),
                                   service: MockImmichService(library: library))
        await model.loadMore()
        XCTAssertFalse(model.assets.isEmpty)
        XCTAssertTrue(model.assets.allSatisfy { $0.livePhotoVideoId != nil })
    }

    func testQueryGridShowsErrorAndRetries() async {
        let mock = MockImmichService(library: library)
        await mock.setFailure(.network("Offline"))
        let model = QueryGridModel(query: MetadataSearchQuery(), service: mock)
        await model.loadMore()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasLoaded)
        await mock.setFailure(nil)
        await model.loadMore()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.assets.isEmpty)
    }

    func testPlacesComeFromCitySuggestions() async throws {
        let mock = MockImmichService(library: library)
        let model = CollectionsModel(service: mock)
        await model.loadPlaces()
        XCTAssertTrue(model.loadedPlaces)
        XCTAssertFalse(model.places.isEmpty)
        let city = try XCTUnwrap(model.places.first)
        let grid = QueryGridModel(query: CollectionsView.placeQuery(city), service: mock)
        await grid.loadMore()
        XCTAssertFalse(grid.assets.isEmpty)
        XCTAssertTrue(grid.assets.allSatisfy { $0.exif?.city == city })
    }

    func testPlacesFailureLeavesTheRowOut() async {
        let mock = MockImmichService(library: library)
        await mock.setFailure(.unauthorized)
        let model = CollectionsModel(service: mock)
        await model.loadPlaces()
        XCTAssertTrue(model.loadedPlaces)
        XCTAssertTrue(model.places.isEmpty)
    }

    func testArchiveAndRecentlyDeletedTimelines() async {
        let mock = MockImmichService(library: library)
        let archive = LibraryGridModel(service: mock, options: TimelineOptions(visibility: .archive, newestFirst: false),
                                       loader: ImageLoader(service: mock, disk: nil))
        await archive.load()
        XCTAssertEqual(archive.totalCount, library.assets.filter { $0.isArchived && !$0.isTrashed }.count)
        let trash = LibraryGridModel(service: mock, options: TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false),
                                     loader: ImageLoader(service: mock, disk: nil))
        await trash.load()
        XCTAssertEqual(trash.totalCount, library.assets.filter(\.isTrashed).count)
        XCTAssertGreaterThan(archive.totalCount + trash.totalCount, 0)
    }
}
