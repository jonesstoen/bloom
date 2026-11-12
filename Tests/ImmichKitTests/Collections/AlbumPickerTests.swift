import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Regression coverage for the two-step create-then-add flow in the album picker.
final class AlbumPickerTests: XCTestCase {
    private let a1 = "11111111-1111-4111-8111-111111111111"
    private let a2 = "22222222-2222-4222-8222-222222222222"
    private let a3 = "33333333-3333-4333-8333-333333333333"
    private let albumID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    @MainActor
    func testCreateAlbumUsesAddReceiptForPartialSuccessCounts() async throws {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let (service, transport) = live { request, _ in
            if request.method == .post {
                return (201, "{\"id\":\"\(self.albumID)\",\"albumName\":\"Trip\"}")
            }
            return (200, """
            [{"id":"\(self.a1)","success":true},
             {"id":"\(self.a2)","success":false,"error":"duplicate"},
             {"id":"\(self.a3)","success":false,"error":"no_permission"}]
            """)
        }
        let model = AlbumPickerModel(service: service, assetIDs: [a1, a2, a3])

        await model.createAlbum(named: " Trip ")

        XCTAssertEqual(transport.requests.map(\.method), [.post, .put])
        XCTAssertEqual(transport.requests.map(\.path), ["/albums", "/albums/\(albumID)/assets"])
        let createJSON = try XCTUnwrap(transport.bodies.first.flatMap { $0 }.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(createJSON["albumName"] as? String, "Trip")
        XCTAssertEqual(createJSON["assetIds"] as? [String], [])
        XCTAssertEqual(model.outcome, "Created «Trip». Added 1 items to «Trip». 1 were already there. 1 couldn't be added.")
    }

    @MainActor
    func testCreateAlbumReportsUnconfirmedAdditionWhenAddRequestThrows() async {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let (service, transport) = live { request, _ in
            if request.method == .post {
                return (201, "{\"id\":\"\(self.albumID)\",\"albumName\":\"Trip\"}")
            }
            return (500, "server error")
        }
        let model = AlbumPickerModel(service: service, assetIDs: [a1])

        await model.createAlbum(named: "Trip")

        XCTAssertEqual(transport.requests.map(\.method), [.post, .put])
        XCTAssertEqual(model.outcome, "Created «Trip», but couldn't confirm the added items. Open the album before trying again.")
    }

    @MainActor
    func testCreateAlbumWithNoSelectedAssetsDoesNotSendAddRequest() async throws {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let (service, transport) = live { _, _ in (201, "{\"id\":\"\(self.albumID)\",\"albumName\":\"Trip\"}") }
        let model = AlbumPickerModel(service: service, assetIDs: [])

        await model.createAlbum(named: "Trip")

        XCTAssertEqual(transport.requests.map(\.method), [.post])
        let json = try XCTUnwrap(transport.bodies.first.flatMap { $0 }.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(json["assetIds"] as? [String], [])
    }

    @MainActor
    func testCreateFailureDoesNotAttemptToAddAssets() async {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let (service, transport) = live { _, _ in (500, "server error") }
        let model = AlbumPickerModel(service: service, assetIDs: [a1])

        await model.createAlbum(named: "Trip")

        XCTAssertEqual(transport.requests.map(\.method), [.post])
        XCTAssertEqual(model.outcome, "Couldn't create the album. Please try again.")
    }

    @MainActor
    func testBlankNameDoesNotSendCreateRequest() async {
        let (service, transport) = live { _, _ in (201, "{}") }
        let model = AlbumPickerModel(service: service, assetIDs: [a1])

        await model.createAlbum(named: "  \n ")

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(model.outcome)
    }

    @MainActor
    func testLoadIncludesOwnedSharedAndEditorAlbumsButNotViewerAlbums() async {
        let (service, transport) = live { request, _ in
            if request.path?.contains("isOwned=true") == true {
                return (200, Self.albumList([Self.albumJSON(id: "owned", name: "Owned shared", shared: true, ownerRole: "owner", authRole: "viewer")]))
            }
            if request.path?.contains("isOwned=false") == true {
                return (200, Self.albumList([
                    Self.albumJSON(id: "editor", name: "Shared editor", shared: true, ownerRole: "owner", authRole: "editor"),
                    Self.albumJSON(id: "viewer", name: "Shared viewer", shared: true, ownerRole: "owner", authRole: "viewer", thirdRole: "editor"),
                    Self.albumJSON(id: "missing", name: "Missing member", shared: true, ownerRole: "owner")
                ]))
            }
            return (200, Self.albumList([
                Self.albumJSON(id: "owned", name: "Owned shared", shared: true, ownerRole: "owner"),
                Self.albumJSON(id: "editor", name: "Shared editor", shared: true, ownerRole: "owner", authRole: "editor"),
                Self.albumJSON(id: "viewer", name: "Shared viewer", shared: true, ownerRole: "owner", authRole: "viewer")
            ]))
        }
        let permission = EditingPermission(isAllowed: false)
        let model = AlbumPickerModel(service: EditGuardedService(base: service, permission: permission), assetIDs: [a1])

        await model.load()

        XCTAssertEqual(Set(model.albums.map(\.id)), Set(["owned", "editor"]))
        XCTAssertNil(model.loadError)
        XCTAssertEqual(transport.requests.count, 2, "Fetch owned and shared lists without per-album lookups")
        XCTAssertTrue(transport.requests.allSatisfy { $0.path?.hasPrefix("/albums?") == true })
    }

    private func live(_ handler: @escaping @Sendable (HTTPRequest, Data?) -> (Int, String)) -> (LiveImmichService, AlbumPickerTransport) {
        let transport = AlbumPickerTransport(handler: handler)
        let credentials = try! ServerCredentials(server: "https://photos.example.invalid", apiKey: "unit-test-placeholder")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    private static func albumList(_ albums: [String]) -> String { "[\(albums.joined(separator: ","))]" }

    private static func albumJSON(id: String, name: String, shared: Bool, ownerRole: String, authRole: String? = nil, thirdRole: String? = nil) -> String {
        func user(_ id: String, _ name: String) -> [String: Any] {
            ["id": id, "name": name, "email": "\(id)@example.invalid", "profileImagePath": "",
             "avatarColor": "blue", "profileChangedAt": "2026-01-01T00:00:00Z"]
        }
        var users: [[String: Any]] = [["role": ownerRole, "user": user("owner", "Owner")]]
        if let authRole { users.append(["role": authRole, "user": user("auth", "Auth")]) }
        if let thirdRole { users.append(["role": thirdRole, "user": user("other", "Other")]) }
        let album: [String: Any] = [
            "albumName": name, "albumUsers": users, "assetCount": 1,
            "createdAt": "2026-01-01T00:00:00Z", "description": "", "hasSharedLink": false,
            "id": id, "isActivityEnabled": false, "shared": shared, "updatedAt": "2026-01-01T00:00:00Z"
        ]
        let data = try! JSONSerialization.data(withJSONObject: album)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class AlbumPickerTransport: ClientTransport, @unchecked Sendable {
    let handler: @Sendable (HTTPRequest, Data?) -> (Int, String)
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private(set) var bodies: [Data?] = []

    init(handler: @escaping @Sendable (HTTPRequest, Data?) -> (Int, String)) { self.handler = handler }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data: Data? = if let body { try await Data(collecting: body, upTo: 1 << 20) } else { nil }
        lock.withLock { requests.append(request); bodies.append(data) }
        let (status, text) = handler(request, data)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }
}
