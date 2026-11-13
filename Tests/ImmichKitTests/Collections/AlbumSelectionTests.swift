import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class AlbumSelectionTests: XCTestCase {
    func testAlbumGridSelectionIsLimitedToItsLoadedAssets() async throws {
        let fixture = MockLibrary.small
        let album = try XCTUnwrap(fixture.albums.first { !(fixture.albumAssetIDs[$0.id] ?? []).isEmpty })
        let albumIDs = Set(fixture.albumAssetIDs[album.id] ?? [])
        let memberID = try XCTUnwrap(albumIDs.first)
        let outside = try XCTUnwrap(fixture.assets.first {
            !albumIDs.contains($0.id) && !$0.isTrashed && !$0.isArchived
        })
        let (library, _) = await loadedAlbum(album.id, fixture: fixture)

        let loadedIDs = Set(library.months.flatMap(\.assets).map(\.id))
        XCTAssertEqual(loadedIDs, albumIDs)
        XCTAssertNotNil(library.gridIndex(ofAsset: memberID))
        XCTAssertNil(library.gridIndex(ofAsset: outside.id))

        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(outside)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.toggle(try XCTUnwrap(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: memberID)))))
        XCTAssertEqual(selection.selectedIDs, [memberID])
    }

    func testFavoriteActionWritesOnlySelectedAlbumAssets() async throws {
        let fixture = MockLibrary.small
        let album = try XCTUnwrap(fixture.albums.first { !(fixture.albumAssetIDs[$0.id] ?? []).isEmpty })
        let albumIDs = Set(fixture.albumAssetIDs[album.id] ?? [])
        let member = try XCTUnwrap(fixture.assets.first { albumIDs.contains($0.id) && !$0.isFavorite })
        let outside = try XCTUnwrap(fixture.assets.first {
            !albumIDs.contains($0.id) && !$0.isFavorite && !$0.isTrashed && !$0.isArchived
        })
        let (library, mock) = await loadedAlbum(album.id, fixture: fixture)
        let loadedMember = try XCTUnwrap(library.gridAsset(atGridIndex: try XCTUnwrap(library.gridIndex(ofAsset: member.id))))

        let selection = LibrarySelectionModel(library: library)
        selection.start()
        selection.toggle(loadedMember)
        selection.toggle(outside)
        XCTAssertEqual(selection.selectedIDs, [member.id])

        await selection.setFavorites(true)

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        let memberWrites = await mock.requestCount(.setFavorite(member.id, true))
        let outsideWrites = await mock.requestCount(.setFavorite(outside.id, true))
        let updatedMember = try await mock.asset(id: member.id)
        let unchangedOutside = try await mock.asset(id: outside.id)
        XCTAssertEqual(memberWrites, 1)
        XCTAssertEqual(outsideWrites, 0)
        XCTAssertTrue(updatedMember.isFavorite)
        XCTAssertFalse(unchangedOutside.isFavorite)
    }

    private func loadedAlbum(_ albumID: String, fixture: MockLibrary) async -> (LibraryGridModel, MockImmichService) {
        let service = MockImmichService(library: fixture)
        let library = LibraryGridModel(
            service: service,
            options: .album(albumID),
            loader: ImageLoader(service: service, disk: nil)
        )
        await library.load()
        await library.loadAllMonths()
        return (library, service)
    }
}
