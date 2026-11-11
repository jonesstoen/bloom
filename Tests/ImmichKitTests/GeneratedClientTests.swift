import Foundation
import HTTPTypes
import ImmichAPI
import OpenAPIRuntime
import XCTest

/// Exercises the generated client against a stub transport (no network).
final class GeneratedClientTests: XCTestCase {
    struct StubTransport: ClientTransport {
        var handler: @Sendable (HTTPRequest) -> (HTTPResponse.Status, String)

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            let (status, json) = handler(request)
            var response = HTTPResponse(status: status)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(json))
        }
    }

    private func makeClient(_ handler: @escaping @Sendable (HTTPRequest) -> (HTTPResponse.Status, String)) -> Client {
        Client(
            serverURL: URL(string: "https://immich.example.com/api")!,
            transport: StubTransport(handler: handler)
        )
    }

    func testPingDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(request.path, "/server/ping")
            return (.ok, #"{"res":"pong"}"#)
        }
        let output = try await client.pingServer()
        XCTAssertEqual(try output.ok.body.json.res, "pong")
    }

    func testServerVersionDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/server/version")
            return (.ok, #"{"major":3,"minor":4,"patch":0,"prerelease":null,"featureLevel":1}"#)
        }
        let version = try await client.getServerVersion().ok.body.json
        XCTAssertEqual(version.major, 3)
        XCTAssertEqual(version.minor, 4)
        XCTAssertEqual(version.patch, 0)
        XCTAssertNil(version.prerelease)
    }

    /// Compile-time check that the filtered operations we rely on were generated.
    func testFilteredOperationsExist() {
        let _: (Client) -> (Operations.GetTimeBuckets.Input) async throws -> Operations.GetTimeBuckets.Output = Client.getTimeBuckets
        let _: (Client) -> (Operations.GetTimeBucket.Input) async throws -> Operations.GetTimeBucket.Output = Client.getTimeBucket
        let _: (Client) -> (Operations.GetAssetInfo.Input) async throws -> Operations.GetAssetInfo.Output = Client.getAssetInfo
        let _: (Client) -> (Operations.ViewAsset.Input) async throws -> Operations.ViewAsset.Output = Client.viewAsset
        let _: (Client) -> (Operations.DownloadAsset.Input) async throws -> Operations.DownloadAsset.Output = Client.downloadAsset
        let _: (Client) -> (Operations.PlayAssetVideo.Input) async throws -> Operations.PlayAssetVideo.Output = Client.playAssetVideo
        let _: (Client) -> (Operations.GetAllAlbums.Input) async throws -> Operations.GetAllAlbums.Output = Client.getAllAlbums
        let _: (Client) -> (Operations.GetAlbumInfo.Input) async throws -> Operations.GetAlbumInfo.Output = Client.getAlbumInfo
        let _: (Client) -> (Operations.GetAllPeople.Input) async throws -> Operations.GetAllPeople.Output = Client.getAllPeople
        let _: (Client) -> (Operations.GetPersonThumbnail.Input) async throws -> Operations.GetPersonThumbnail.Output = Client.getPersonThumbnail
        let _: (Client) -> (Operations.SearchSmart.Input) async throws -> Operations.SearchSmart.Output = Client.searchSmart
        let _: (Client) -> (Operations.SearchAssets.Input) async throws -> Operations.SearchAssets.Output = Client.searchAssets
        let _: (Client) -> (Operations.GetMapMarkers.Input) async throws -> Operations.GetMapMarkers.Output = Client.getMapMarkers
        let _: (Client) -> (Operations.SearchMemories.Input) async throws -> Operations.SearchMemories.Output = Client.searchMemories
    }
}
