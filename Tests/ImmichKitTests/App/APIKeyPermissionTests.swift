import XCTest
@testable import ImmichKit

/// The documented key permissions must cover every operation Bloom calls, per the checked-in spec.
final class APIKeyPermissionTests: XCTestCase {
    /// Every Immich operation Bloom calls (generated client and hand-written requests), and whether
    /// only Allow Changes uses it. Add new operations here when the app starts calling them.
    static let operations: [(id: String, changes: Bool)] = [
        ("getTimeBuckets", false), ("getTimeBucket", false), ("getAssetInfo", false), ("viewAsset", false),
        ("downloadAsset", false), ("playAssetVideo", false), ("getAllAlbums", false), ("getAlbumInfo", false),
        ("getAllPeople", false), ("getPerson", false), ("getPersonThumbnail", false), ("searchSmart", false),
        ("searchAssets", false), ("getSearchSuggestions", false), ("getMapMarkers", false), ("searchMemories", false),
        ("updateAsset", true), ("deleteAssets", true), ("restoreAssets", true), ("createAlbum", true),
        ("addAssetsToAlbum", true),
        // Public, need no permission.
        ("pingServer", false), ("getServerVersion", false), ("getServerFeatures", false), ("getServerConfig", false),
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
        let all = readOnly.union(APIKeyPermissions.changes)
        var used: Set<String> = []
        for (id, changes) in Self.operations {
            let operation = try XCTUnwrap(operations[id], "\(id) is not in the spec")
            guard let permission = operation["x-immich-permission"] as? String else {
                // Public operations have no (or an empty) security requirement in the spec.
                let security = operation["security"]
                XCTAssertTrue(security == nil || security is NSNull || (security as? [Any])?.isEmpty == true,
                              "\(id) has no permission but is not public")
                continue
            }
            used.insert(permission)
            XCTAssertTrue((changes ? all : readOnly).contains(permission), "\(id) needs \(permission)")
        }
        XCTAssertEqual(used, all, "every listed permission is needed by some operation, and no more")
    }

    func testReadOnlyKeyCannotChangeAnything() {
        let readOnly = Set(APIKeyPermissions.readOnly)
        XCTAssertTrue(readOnly.isDisjoint(with: APIKeyPermissions.changes))
        XCTAssertFalse(readOnly.contains { $0.hasSuffix(".delete") || $0.hasSuffix(".update") || $0.hasSuffix(".create") || $0 == "all" })
    }
}
