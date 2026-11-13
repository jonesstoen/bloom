import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit
@testable import ImmichUI

@MainActor
final class AlbumReloadTests: XCTestCase {
    func testChangesDuringAListRequestCoalesceIntoAFreshReload() async throws {
        let started = expectation(description: "Old album list captured")
        let transport = AlbumReloadTransport(started: started)
        let service = LiveImmichService(credentials: try ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder"), transport: transport)
        let model = CollectionsModel(service: service)
        let first = Task { await model.loadAlbums() }
        await fulfillment(of: [started], timeout: 2)
        // Mutation notifications arrive while the old list is still in flight.
        await model.loadAlbums()
        await model.loadAlbums()
        await transport.release()
        await first.value
        XCTAssertEqual(model.albums.map(\.id), ["new-album"])
        XCTAssertNil(model.albumsError)
        XCTAssertTrue(model.loadedAlbums)
        XCTAssertFalse(model.loadingAlbums)
        let count = await transport.requestCount
        XCTAssertEqual(count, 2, "Overlapping invalidations need one fresh request")
    }
    func testQueuedReloadSurvivesCancellationOfTheOlderRequest() async throws {
        let started = expectation(description: "Old album list captured")
        let transport = AlbumReloadTransport(started: started)
        let service = LiveImmichService(credentials: try ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder"), transport: transport)
        let model = CollectionsModel(service: service)
        let first = Task { await model.loadAlbums() }
        await fulfillment(of: [started], timeout: 2)
        // Mutation notifications arrive while the old list is still in flight.
        await model.loadAlbums()
        await model.loadAlbums()
        first.cancel()
        await transport.release()
        await first.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.albums.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.albums.map(\.id), ["new-album"])
        XCTAssertNil(model.albumsError)
        XCTAssertTrue(model.loadedAlbums)
        XCTAssertFalse(model.loadingAlbums)
        let count = await transport.requestCount
        XCTAssertEqual(count, 2, "Overlapping invalidations need one fresh request")
    }
}

private actor AlbumReloadTransport: ClientTransport {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0
    init(started: XCTestExpectation) { self.started = started }
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        requestCount += 1
        let text: String
        if requestCount == 1 {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
            text = "[]"
        } else {
            text = #"[{"id":"new-album","albumName":"New","description":"","albumThumbnailAssetId":null,"albumUsers":[],"assetCount":0,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","hasSharedLink":false,"isActivityEnabled":true,"shared":false}]"#
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }
}
