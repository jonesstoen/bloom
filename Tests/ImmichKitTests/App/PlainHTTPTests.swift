import XCTest
import HTTPTypes
import OpenAPIRuntime
@testable import ImmichKit

/// The API key never travels as plain text over the internet. http is only used for hosts on the
/// user's own network or on Tailscale (whose WireGuard tunnel already encrypts it).
final class PlainHTTPTests: XCTestCase {
    private func protects(_ address: String) -> Bool {
        ServerCredentials.protectsAPIKey(URL(string: address)!)
    }

    func testHTTPSAlwaysProtectsTheKey() {
        XCTAssertTrue(protects("https://photos.example.com"))
        XCTAssertTrue(protects("https://203.0.113.5"))
    }

    func testHTTPIsAllowedOnlyForLocalAndTailscaleHosts() {
        for local in ["http://192.168.1.10:2283", "http://10.0.0.4", "http://172.16.5.1", "http://172.31.255.255",
                      "http://127.0.0.1:2283", "http://169.254.1.1", "http://localhost:2283", "http://nas:2283",
                      "http://immich.local", "http://photos.lan", "http://server.home.arpa", "http://box.internal",
                      "http://100.101.102.103:2283", "http://photos.example-tailnet.ts.net",
                      "http://[::1]:2283", "http://[fd7a:115c:a1e0::1]", "http://[fe80::1]"] {
            XCTAssertTrue(protects(local), local)
        }
        for internet in ["http://photos.example.com", "http://203.0.113.5", "http://172.32.0.1", "http://100.128.0.1",
                         "http://8.8.8.8", "http://[2001:db8::1]", "http://192.169.0.1", "http://local.example.com",
                         "http://example.ts.net.evil.com"] {
            XCTAssertFalse(protects(internet), internet)
        }
    }

    func testLoginRefusesPublicHTTPBeforeSendingAnything() async {
        let tester = ConnectionTester(makeService: { _ in
            XCTFail("No request may be made with the key over public http")
            return MockImmichService()
        })
        do {
            _ = try await tester.test(server: "http://photos.example.com", apiKey: "k")
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? LoginError, .insecureServer)
        }
    }

    func testTheServiceNeverAttachesTheKeyOverPublicHTTP() async throws {
        let transport = CountingTransport()
        let credentials = try ServerCredentials(server: "http://photos.example.com", apiKey: "secret-placeholder")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        do { _ = try await service.albums(shared: nil); XCTFail("Expected a refusal") } catch {
            XCTAssertEqual(error as? ImmichServiceError, .insecureConnection)
        }
        do { _ = try await service.asset(id: "a"); XCTFail("Expected a refusal") } catch {
            XCTAssertEqual(error as? ImmichServiceError, .insecureConnection)
        }
        do { _ = try await service.mediaRequest(.original, assetID: "a"); XCTFail("Expected a refusal") } catch {
            XCTAssertEqual(error as? ImmichServiceError, .insecureConnection)
        }
        XCTAssertEqual(transport.sent, 0)
    }
}

private final class CountingTransport: ClientTransport, @unchecked Sendable {
    var sent = 0
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        sent += 1
        return (HTTPResponse(status: .notFound), nil)
    }
}
