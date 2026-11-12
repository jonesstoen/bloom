import XCTest
import ImmichKit

/// Bloom is read-only until the user turns on Allow Changes. The service refuses every write
/// while it is off, whatever the UI shows, and nothing reaches the wrapped service.
final class EditingPermissionTests: XCTestCase {
    private let asset = MockLibrary.standard.assets[0]

    private func make(allowed: Bool) -> (service: any ImmichService, mock: MockImmichService, permission: EditingPermission) {
        let mock = MockImmichService(library: .standard)
        let permission = EditingPermission(isAllowed: allowed)
        return (EditGuardedService(base: mock, permission: permission), mock, permission)
    }

    func testEveryWriteIsRefusedWhileEditingIsOff() async throws {
        let (service, mock, _) = make(allowed: false)
        await assertRefused { _ = try await service.setFavorite(assetID: self.asset.id, isFavorite: true) }
        await assertRefused { _ = try await service.moveToTrash(assetIDs: [self.asset.id]) }
        await assertRefused { _ = try await service.restoreAssets(assetIDs: [self.asset.id]) }
        await assertRefused { _ = try await service.createAlbum(name: "Trip", assetIDs: []) }
        await assertRefused { _ = try await service.addAssets(toAlbum: "album", assetIDs: [self.asset.id]) }
        // Nothing changed behind the guard.
        let after = try await mock.asset(id: asset.id)
        XCTAssertEqual(after.isFavorite, asset.isFavorite)
        XCTAssertFalse(after.isTrashed)
        let albums = try await mock.albums(shared: nil)
        XCTAssertFalse(albums.contains { $0.name == "Trip" })
    }

    func testReadsAlwaysPassThrough() async throws {
        let (service, _, _) = make(allowed: false)
        let buckets = try await service.timeBuckets(options: .library)
        XCTAssertFalse(buckets.isEmpty)
        let detail = try await service.asset(id: asset.id)
        XCTAssertEqual(detail.id, asset.id)
        _ = try await service.thumbnail(assetID: asset.id, size: .thumbnail)
    }

    func testTurningEditingOnAllowsWritesAtOnce() async throws {
        let (service, _, permission) = make(allowed: false)
        permission.isAllowed = true
        let updated = try await service.setFavorite(assetID: asset.id, isFavorite: !asset.isFavorite)
        XCTAssertEqual(updated.isFavorite, !asset.isFavorite)
        let albumID = try await service.createAlbum(name: "Trip", assetIDs: [asset.id])
        XCTAssertFalse(albumID.isEmpty)
        permission.isAllowed = false
        await assertRefused { _ = try await service.setFavorite(assetID: self.asset.id, isFavorite: true) }
    }

    func testRefusalExplainsHowToTurnEditingOn() {
        XCTAssertNotNil(ImmichServiceError.editingOff.errorDescription)
    }

    private func assertRefused(_ body: @escaping () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("Expected the write to be refused", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .editingOff, file: file, line: line)
        }
    }
}
