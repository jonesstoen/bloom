import XCTest
@testable import ImmichKit

/// The documented key permissions must cover every operation Bloom calls, per the checked-in spec.
final class APIKeyPermissionTests: XCTestCase {
    /// Every Immich operation Bloom calls (generated client and hand-written requests), and whether
    /// the lowest access level that needs it. Add new operations here when the app starts calling them.
    static let operations: [(id: String, level: APIKeyAccess)] = [
        ("getTimeBuckets", .view), ("getTimeBucket", .view), ("getAssetInfo", .view), ("viewAsset", .view),
        ("downloadAsset", .view), ("playAssetVideo", .view), ("getAllAlbums", .view), ("getAlbumInfo", .view),
        ("getAllPeople", .view), ("getPerson", .view), ("getPersonThumbnail", .view), ("searchSmart", .view),
        ("searchAssets", .view), ("getSearchSuggestions", .view), ("getMapMarkers", .view), ("searchMemories", .view),
        ("updateAsset", .organize), ("deleteAssets", .organize), ("restoreAssets", .organize), ("createAlbum", .organize),
        ("addAssetsToAlbum", .organize), ("checkBulkUpload", .backup), ("uploadAsset", .backup),
        // Public, need no permission.
        ("pingServer", .view), ("getServerVersion", .view), ("getServerFeatures", .view), ("getServerConfig", .view),
    ]

    private func spec() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmichAPI/openapi.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let paths = try XCTUnwrap(json["paths"] as? [String: [String: Any]])
        var byID: [String: [String: Any]] = [:]
        for methods in paths.values {
            for case let operation as [String: Any] in methods.values {
                if let id = operation["operationId"] as? String { byID[id] = operation }
            }
        }
        return byID
    }

    func testDocumentedPermissionsCoverEveryOperation() throws {
        let operations = try spec()
        let readOnly = Set(APIKeyPermissions.readOnly)
        let all = readOnly.union(APIKeyPermissions.changes).union(APIKeyPermissions.backup)
        var used: Set<String> = []
        for (id, level) in Self.operations {
            let operation = try XCTUnwrap(operations[id], "\(id) is not in the spec")
            guard let permission = operation["x-immich-permission"] as? String else {
                // Public operations have no (or an empty) security requirement in the spec.
                let security = operation["security"]
                XCTAssertTrue(security == nil || security is NSNull || (security as? [Any])?.isEmpty == true,
                              "\(id) has no permission but is not public")
                continue
            }
            used.insert(permission)
            XCTAssertTrue(level.permissions.contains(permission), "\(id) needs \(permission)")
        }
        XCTAssertEqual(used, all, "every listed permission is needed by some operation, and no more")
    }

    func testReadOnlyKeyCannotChangeAnything() {
        let readOnly = Set(APIKeyPermissions.readOnly)
        XCTAssertTrue(readOnly.isDisjoint(with: APIKeyPermissions.changes))
        XCTAssertFalse(readOnly.contains { $0.hasSuffix(".delete") || $0.hasSuffix(".update") || $0.hasSuffix(".create") || $0 == "all" })
    }
}

final class APIKeyAccessTests: XCTestCase {
    func testLevelsBuildOnEachOther() {
        XCTAssertEqual(APIKeyAccess.view.permissions, APIKeyPermissions.readOnly)
        XCTAssertEqual(Set(APIKeyAccess.organize.permissions), Set(APIKeyPermissions.readOnly + APIKeyPermissions.changes))
        XCTAssertFalse(APIKeyAccess.organize.permissions.contains("all"))
        XCTAssertEqual(APIKeyAccess.backup.permissions,
                       APIKeyPermissions.readOnly + APIKeyPermissions.changes + ["asset.upload"])
        XCTAssertEqual(APIKeyPermissions.backup, ["asset.upload"])
        XCTAssertFalse(APIKeyAccess.backup.permissions.contains("all"))
    }
}
