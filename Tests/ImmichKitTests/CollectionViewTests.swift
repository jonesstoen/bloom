import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class CollectionViewTests: XCTestCase {
    func testAlbumsAndPeopleLoadIndependentlyAndRetry() async {
        let mock = MockImmichService.preview
        let model = CollectionsModel(service: mock)
        await model.loadAlbums()
        XCTAssertFalse(model.albums.isEmpty)
        await mock.setFailure(.unauthorized)
        await model.loadPeople()
        XCTAssertNotNil(model.peopleError)
        XCTAssertFalse(model.albums.isEmpty)
        await mock.setFailure(nil)
        await model.loadPeople()
        XCTAssertNil(model.peopleError)
        XCTAssertFalse(model.people.isEmpty)
        XCTAssertTrue(model.people.allSatisfy { !$0.isHidden })
    }

    func testDetailGridRespectsCollectionMembership() async throws {
        let library = MockLibrary.standard
        let mock = MockImmichService(library: library)
        let album = try XCTUnwrap(library.albums.first)
        let grid = LibraryGridModel(service: mock, options: .album(album.id), loader: ImageLoader(service: mock, disk: nil))
        await grid.load()
        for month in grid.months { await grid.loadMonth(month.id) }
        let ids = Set(grid.months.flatMap(\.assets).map(\.id))
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(ids, Set(library.albumAssetIDs[album.id] ?? []))
        let person = try XCTUnwrap(library.people.first)
        let faces = LibraryGridModel(service: mock, options: .person(person.id), loader: ImageLoader(service: mock, disk: nil))
        await faces.load()
        for month in faces.months { await faces.loadMonth(month.id) }
        let faceIDs = Set(faces.months.flatMap(\.assets).map(\.id))
        XCTAssertFalse(faceIDs.isEmpty)
        XCTAssertTrue(faceIDs.isSubset(of: library.personAssetIDs[person.id] ?? []))
    }
}
