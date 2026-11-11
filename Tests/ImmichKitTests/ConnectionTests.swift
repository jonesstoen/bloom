import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

/// Transport that records requests and answers from a closure. No network.
final class RecordingTransport: ClientTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> (Int, String, String)

    private let lock = NSLock()
    private var _requests: [(HTTPRequest, URL)] = []
    private let handler: Handler

    var requests: [(HTTPRequest, URL)] { lock.withLock { _requests } }

    /// `handler` returns (status, content type, body).
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { _requests.append((request, baseURL)) }
        let (status, contentType, text) = try handler(request)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = contentType
        return (response, HTTPBody(text))
    }
}

final class LiveImmichServiceTests: XCTestCase {
    private let key = "test-key-123"

    private func service(_ handler: @escaping RecordingTransport.Handler) throws -> (LiveImmichService, RecordingTransport) {
        let transport = RecordingTransport(handler: handler)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: key)
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    func testPingSendsAPIKeyHeaderToApiBaseURL() async throws {
        let (service, transport) = try service { _ in (200, "application/json", #"{"res":"pong"}"#) }
        try await service.ping()
        let (request, baseURL) = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/server/ping")
        XCTAssertEqual(request.headerFields[APIKeyMiddleware.headerName], key)
        XCTAssertEqual(baseURL.absoluteString, "https://photos.example.com/api")
    }

    func testPingWithWrongAnswerIsInvalidResponse() async throws {
        let (service, _) = try service { _ in (200, "application/json", #"{"res":"nope"}"#) }
        await assertThrows(ImmichServiceError.invalidResponse) { try await service.ping() }
    }

    func testHTMLPageIsInvalidResponse() async throws {
        let (service, _) = try service { _ in (200, "text/html", "<html></html>") }
        await assertThrows(ImmichServiceError.invalidResponse) { try await service.ping() }
    }

    func testUnauthorizedStatus() async throws {
        let (service, _) = try service { _ in (401, "application/json", #"{"message":"Invalid API key"}"#) }
        await assertThrows(ImmichServiceError.unauthorized) { _ = try await service.serverVersion() }
    }

    func testUnexpectedStatus() async throws {
        let (service, _) = try service { _ in (404, "application/json", "{}") }
        await assertThrows(ImmichServiceError.unexpectedStatus(404)) { try await service.ping() }
    }

    func testNetworkError() async throws {
        let (service, _) = try service { _ in throw URLError(.cannotFindHost) }
        do {
            try await service.ping()
            XCTFail("expected an error")
        } catch let error as ImmichServiceError {
            guard case .network = error else { return XCTFail("got \(error)") }
        }
    }

    func testServerVersion() async throws {
        let (service, transport) = try service { _ in
            (200, "application/json", #"{"major":3,"minor":4,"patch":0,"prerelease":null,"featureLevel":7}"#)
        }
        let version = try await service.serverVersion()
        XCTAssertEqual(version, ServerVersion(major: 3, minor: 4, patch: 0, featureLevel: 7))
        XCTAssertEqual(version.description, "3.4.0")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.0.path, "/server/version")
    }

    func testServerVersionWithoutFeatureLevelFallsBack() async throws {
        let (service, transport) = try service { _ in
            (200, "application/json", #"{"major":1,"minor":135,"patch":3}"#)
        }
        let version = try await service.serverVersion()
        XCTAssertEqual(version, ServerVersion(major: 1, minor: 135, patch: 3))
        XCTAssertNil(version.featureLevel)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.0.headerFields[APIKeyMiddleware.headerName], key)
    }

    private func assertThrows(
        _ expected: ImmichServiceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, expected, "got \(error)", file: file, line: line)
        }
    }
}

final class ServerCredentialsTests: XCTestCase {
    func testNormalization() throws {
        let cases: [(String, String)] = [
            ("https://photos.example.com", "https://photos.example.com"),
            ("https://photos.example.com/", "https://photos.example.com"),
            ("https://photos.example.com/api", "https://photos.example.com"),
            ("https://photos.example.com/api/", "https://photos.example.com"),
            ("photos.example.com", "https://photos.example.com"),
            ("  http://192.168.1.10:2283  ", "http://192.168.1.10:2283"),
            ("HTTPS://example.com/immich/", "https://example.com/immich"),
        ]
        for (input, expected) in cases {
            let credentials = try ServerCredentials(server: input, apiKey: "k")
            XCTAssertEqual(credentials.serverURL.absoluteString, expected, input)
            XCTAssertEqual(credentials.apiBaseURL.absoluteString, expected + "/api", input)
        }
    }

    func testInvalidURLs() {
        for input in ["", "   ", "ftp://example.com", "https://", "http:///path"] {
            XCTAssertThrowsError(try ServerCredentials(server: input, apiKey: "k"), input) { error in
                XCTAssertEqual(error as? ImmichServiceError, .invalidServerURL)
            }
        }
    }

    func testDescriptionRedactsKey() throws {
        let credentials = try ServerCredentials(server: "https://x.example", apiKey: "super-secret")
        XCTAssertFalse(credentials.description.contains("super-secret"))
        XCTAssertFalse(String(describing: credentials).contains("super-secret"))
        XCTAssertFalse(String(reflecting: credentials).contains("super-secret"))
    }

    func testAPIKeyIsTrimmed() throws {
        let credentials = try ServerCredentials(server: "x.example", apiKey: "  abc\n")
        XCTAssertEqual(credentials.apiKey, "abc")
    }
}

final class CredentialStoreTests: XCTestCase {
    func testRoundTripInMemory() throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        XCTAssertNil(try store.load())
        let credentials = try ServerCredentials(server: "https://a.example", apiKey: "k1")
        try store.save(credentials)
        XCTAssertEqual(try store.load(), credentials)
        let updated = try ServerCredentials(server: "https://b.example", apiKey: "k2")
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        try store.clear()
        XCTAssertNil(try store.load())
        try store.clear() // clearing twice is fine
    }

    func testCorruptDataThrows() throws {
        let storage = InMemorySecureStorage()
        try storage.set(Data("not json".utf8), for: CredentialStore.account)
        XCTAssertThrowsError(try CredentialStore(storage: storage).load()) { error in
            XCTAssertEqual(error as? CredentialStoreError, .corruptData)
        }
    }

    /// Exercises the real Keychain under a test-only service name. Skips if the Keychain is unavailable.
    func testRoundTripKeychain() throws {
        let storage = KeychainStorage(service: "no.immichkit.tests.\(UUID().uuidString)")
        let store = CredentialStore(storage: storage)
        do {
            try store.clear()
        } catch CredentialStoreError.keychain(let status) {
            throw XCTSkip("Keychain unavailable (OSStatus \(status))")
        }
        defer { try? store.clear() }
        let credentials = try ServerCredentials(server: "https://k.example", apiKey: "keychain-test-key")
        do {
            try store.save(credentials)
        } catch CredentialStoreError.keychain(let status) {
            throw XCTSkip("Keychain unavailable (OSStatus \(status))")
        }
        XCTAssertEqual(try store.load(), credentials)
        let updated = try ServerCredentials(server: "https://k2.example", apiKey: "keychain-test-key-2")
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        try store.clear()
        XCTAssertNil(try store.load())
    }
}

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
final class ConnectionIntegrationTests: XCTestCase {
    private func liveService() throws -> LiveImmichService {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        return LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
    }

    func testPingAndVersion() async throws {
        let service = try liveService()
        try await service.ping()
        let version = try await service.serverVersion()
        XCTAssertGreaterThanOrEqual(version.major, 1)
        print("Immich server version: \(version)")
    }
}
