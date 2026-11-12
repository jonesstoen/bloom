import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Creating albums and adding photos to them (POST /albums, PUT /albums/{id}/assets).
final class AlbumEditTests: XCTestCase {
    private let a1 = "11111111-1111-4111-8111-111111111111"
    private let a2 = "22222222-2222-4222-8222-222222222222"
    private let a3 = "33333333-3333-4333-8333-333333333333"
    private let albumID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func live(_ handler: @escaping @Sendable (HTTPRequest, Data?) -> (Int, String)) -> (LiveImmichService, AlbumTransport) {
        let transport = AlbumTransport(handler: handler)
        let credentials = try! ServerCredentials(server: "https://photos.example.invalid", apiKey: "unit-test-placeholder")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    func testCreateAlbumPostsNameAndPhotosAndAcceptsCreated() async throws {
        let (service, transport) = live { _, _ in (201, "{\"id\":\"\(self.albumID)\",\"albumName\":\"Trip\"}") }
        let id = try await service.createAlbum(name: "  Trip ", assetIDs: [a1, a2])
        XCTAssertEqual(id, albumID)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/albums")
        let body = try XCTUnwrap(transport.bodies.first.flatMap { $0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["albumName"] as? String, "Trip", "Name is trimmed")
        XCTAssertEqual(json["assetIds"] as? [String], [a1, a2])
    }

    func testCreateAlbumRejectsAnEmptyNameWithoutWriting() async throws {
        let (service, transport) = live { _, _ in (201, "{}") }
        do {
            _ = try await service.createAlbum(name: "   ", assetIDs: [])
            XCTFail("An empty name must not create an album")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAddingReportsAddedDuplicatesAndFailures() async throws {
        let response = """
        [{"id":"\(a1)","success":true},{"id":"\(a2)","success":false,"error":"duplicate"},
         {"id":"\(a3)","success":false,"error":"no_permission"}]
        """
        let (service, transport) = live { _, _ in (200, response) }
        let result = try await service.addAssets(toAlbum: albumID, assetIDs: [a1, a2, a3])
        XCTAssertEqual(result.addedIDs, [a1])
        XCTAssertEqual(result.alreadyInAlbumIDs, [a2])
        XCTAssertEqual(result.failedIDs, [a3])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.path, "/albums/\(albumID)/assets")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.bodies.first.flatMap { $0 })) as? [String: Any])
        XCTAssertEqual(json["ids"] as? [String], [a1, a2, a3])
    }

    func testIDsMissingFromTheResponseCountAsFailed() async throws {
        let (service, _) = live { _, _ in (200, "[{\"id\":\"\(self.a1)\",\"success\":true}]") }
        let result = try await service.addAssets(toAlbum: albumID, assetIDs: [a1, a2])
        XCTAssertEqual(result.addedIDs, [a1])
        XCTAssertEqual(result.failedIDs, [a2], "No receipt is not a success")
    }

    func testMockCreatesAlbumsAndAddsPhotos() async throws {
        let mock = MockImmichService(library: .standard)
        let photos = Array(MockLibrary.standard.assets.prefix(3).map(\.id))
        let before = try await mock.albums().count
        let id = try await mock.createAlbum(name: "Ny tur", assetIDs: [photos[0]])
        let albums = try await mock.albums()
        XCTAssertEqual(albums.count, before + 1)
        XCTAssertEqual(albums.first { $0.id == id }?.name, "Ny tur")
        let result = try await mock.addAssets(toAlbum: id, assetIDs: photos)
        XCTAssertEqual(result.addedIDs, Array(photos.dropFirst()))
        XCTAssertEqual(result.alreadyInAlbumIDs, [photos[0]])
        let inAlbum = try await mock.albumAssets(albumID: id)
        XCTAssertEqual(Set(inAlbum.map(\.id)), Set(photos))
        let album = try await mock.album(id: id)
        XCTAssertEqual(album.assetCount, 3)
    }

    @MainActor
    func testAddResultMessagesAreNorwegian() {
        Localization.languageOverride = "nb"
        defer { Localization.languageOverride = nil }
        let result = AlbumAddResult(addedIDs: ["a", "b"], alreadyInAlbumIDs: ["c"], failedIDs: [])
        XCTAssertEqual(AlbumPickerModel.message(for: result, albumName: "Tur"), "La til 2 objekter i «Tur». 1 var der allerede.")
    }
}

private final class AlbumTransport: ClientTransport, @unchecked Sendable {
    let handler: @Sendable (HTTPRequest, Data?) -> (Int, String)
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private(set) var bodies: [Data?] = []

    init(handler: @escaping @Sendable (HTTPRequest, Data?) -> (Int, String)) { self.handler = handler }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data: Data? = if let body { try await Data(collecting: body, upTo: 1 << 20) } else { nil }
        lock.withLock { requests.append(request); bodies.append(data) }
        let (status, text) = handler(request, data)
        return (HTTPResponse(status: .init(code: status)), HTTPBody(text))
    }
}
