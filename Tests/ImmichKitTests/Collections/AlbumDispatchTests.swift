import XCTest
import ImmichKit

/// Album edits must reach the service's own implementation also through `any ImmichService`
/// (how the UI holds the service). Methods only in a protocol extension are dispatched
/// statically, which would always hit the refusing default.
final class AlbumDispatchTests: XCTestCase {
    func testAlbumEditsDispatchThroughTheExistential() async throws {
        let service: any ImmichService = MockImmichService(library: .standard)
        let asset = MockLibrary.standard.assets[0]
        let id = try await service.createAlbum(name: "Trip", assetIDs: [asset.id])
        XCTAssertFalse(id.isEmpty)
        let result = try await service.addAssets(toAlbum: id, assetIDs: [MockLibrary.standard.assets[1].id])
        XCTAssertEqual(result.addedIDs, [MockLibrary.standard.assets[1].id])
    }
}
