import Foundation
import XCTest
@testable import ImmichKit
@testable import ImmichUI

final class ConnectionTesterTests: XCTestCase {
    private func tester(_ mock: MockImmichService, seen: SeenCredentials? = nil) -> ConnectionTester {
        ConnectionTester { credentials in
            seen?.set(credentials)
            return mock
        }
    }

    func testSuccessReturnsNormalizedCredentialsAndVersion() async throws {
        let mock = MockImmichService(library: .small)
        let seen = SeenCredentials()
        let info = try await tester(mock, seen: seen).test(server: "  photos.example.com/api/ ", apiKey: " key \n")
        XCTAssertEqual(info.credentials.serverURL.absoluteString, "https://photos.example.com")
        XCTAssertEqual(info.credentials.apiKey, "key")
        XCTAssertEqual(info.version, ServerVersion(major: 3, minor: 4, patch: 0, featureLevel: 1))
        XCTAssertEqual(seen.value, info.credentials)
        let requests = await mock.requests
        XCTAssertEqual(requests, [.ping, .serverVersion, .albums], "must call an authenticated endpoint")
    }

    func testEmptyFieldsFailWithoutNetwork() async {
        let mock = MockImmichService()
        await assertLoginError(.missingServer) { try await self.tester(mock).test(server: "  ", apiKey: "key") }
        await assertLoginError(.missingAPIKey) { try await self.tester(mock).test(server: "photos.example.com", apiKey: " ") }
        let requests = await mock.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidURL() async {
        let mock = MockImmichService()
        await assertLoginError(.invalidServerURL) { try await self.tester(mock).test(server: "ftp://photos.example.com", apiKey: "key") }
        await assertLoginError(.invalidServerURL) { try await self.tester(mock).test(server: "https://", apiKey: "key") }
    }

    func testWrongKey() async {
        let mock = MockImmichService(library: .small)
        await mock.setRejectsAPIKey(true)
        await assertLoginError(.invalidAPIKey) { try await self.tester(mock).test(server: "photos.example.com", apiKey: "bad") }
    }

    func testUnreachableServer() async {
        let mock = MockImmichService()
        await mock.setFailure(.network("offline"))
        await assertLoginError(.serverUnreachable("offline")) { try await self.tester(mock).test(server: "photos.example.com", apiKey: "k") }
    }

    func testNotImmichServer() async {
        for failure: ImmichServiceError in [.invalidResponse, .unexpectedStatus(404), .unauthorized] {
            let mock = MockImmichService()
            await mock.setFailure(failure)
            await assertLoginError(.notImmichServer) { try await self.tester(mock).test(server: "example.com", apiKey: "k") }
        }
    }

    func testServerError() async {
        let mock = MockImmichService()
        await mock.setFailure(.unexpectedStatus(502))
        await assertLoginError(.serverError(502)) { try await self.tester(mock).test(server: "example.com", apiKey: "k") }
    }

    func testErrorMapping() {
        XCTAssertEqual(LoginError.fromAuthenticated(ImmichServiceError.unauthorized), .invalidAPIKey)
        XCTAssertEqual(LoginError.fromAuthenticated(ImmichServiceError.unexpectedStatus(400)), .serverError(400))
        XCTAssertEqual(LoginError.fromAuthenticated(ImmichServiceError.unexpectedStatus(500)), .serverError(500))
        XCTAssertEqual(LoginError.fromAuthenticated(ImmichServiceError.network("x")), .serverUnreachable("x"))
        XCTAssertEqual(LoginError.fromUnauthenticated(ImmichServiceError.unauthorized), .notImmichServer)
        // A refused redirect (SameOriginRedirects) arrives as its 3xx status.
        XCTAssertEqual(LoginError.fromUnauthenticated(ImmichServiceError.unexpectedStatus(302)), .redirected)
        XCTAssertEqual(LoginError.fromAuthenticated(ImmichServiceError.unexpectedStatus(301)), .redirected)
    }

    @MainActor
    func testPlainHTTPAddressesAreFlagged() {
        let login = RootModel(store: CredentialStore(storage: InMemorySecureStorage()), makeService: { _ in MockImmichService() })
            .makeLoginModel()
        login.server = "http://192.168.1.10:2283"
        XCTAssertTrue(login.isUnencrypted)
        XCTAssertFalse(login.isRefusedHTTP, "own network")
        login.server = "http://photos.example.com"
        XCTAssertTrue(login.isRefusedHTTP)
        login.server = "https://photos.example.com"
        XCTAssertFalse(login.isUnencrypted)
        login.server = "photos.example.com"
        XCTAssertFalse(login.isUnencrypted, "no scheme means https")
    }

    func testMessagesNeverContainKey() {
        let errors: [LoginError] = [
            .missingServer, .missingAPIKey, .invalidServerURL, .serverUnreachable("x"),
            .notImmichServer, .invalidAPIKey, .serverError(500), .saveFailed, .redirected, .insecureServer,
        ]
        for error in errors {
            XCTAssertFalse(error.title.isEmpty)
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
        XCTAssertNotEqual(LoginError.invalidAPIKey.title, LoginError.notImmichServer.title)
    }

    func testConnectSavesOnlyOnSuccess() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        let bad = MockImmichService(library: .small)
        await bad.setRejectsAPIKey(true)
        await assertLoginError(.invalidAPIKey) {
            try await self.tester(bad).connect(server: "photos.example.com", apiKey: "bad", store: store)
        }
        XCTAssertNil(try store.load())

        let good = MockImmichService(library: .small)
        let info = try await tester(good).connect(server: "photos.example.com", apiKey: "good", store: store)
        XCTAssertEqual(try store.load(), info.credentials)
    }

    func testConnectReportsSaveFailure() async {
        let store = CredentialStore(storage: FailingStorage())
        await assertLoginError(.saveFailed) {
            try await self.tester(MockImmichService()).connect(server: "photos.example.com", apiKey: "k", store: store)
        }
    }

    func testRejectsAPIKeyLeavesPingAndVersionWorking() async throws {
        let mock = MockImmichService(library: .small)
        await mock.setRejectsAPIKey(true)
        try await mock.ping()
        _ = try await mock.serverVersion()
        do {
            _ = try await mock.albums()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }
}

@MainActor
final class LoginModelTests: XCTestCase {
    func testSuccessfulLoginSavesAndCallsBack() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        var connected: ServerCredentials?
        let model = LoginModel(
            server: "photos.example.com", apiKey: "key", store: store,
            tester: ConnectionTester { _ in MockImmichService(library: .small) },
            onConnect: { connected = $0 }
        )
        XCTAssertTrue(model.canConnect)
        await model.connectNow()
        guard case .connected(let info) = model.phase else { return XCTFail("phase \(model.phase)") }
        XCTAssertEqual(connected, info.credentials)
        XCTAssertEqual(try store.load(), info.credentials)
        XCTAssertNil(model.error)
    }

    func testWrongKeyShowsErrorAndEditingClearsIt() async throws {
        let mock = MockImmichService(library: .small)
        await mock.setRejectsAPIKey(true)
        let store = CredentialStore(storage: InMemorySecureStorage())
        var called = false
        let model = LoginModel(
            server: "photos.example.com", apiKey: "bad", store: store,
            tester: ConnectionTester { _ in mock }, onConnect: { _ in called = true }
        )
        await model.connectNow()
        XCTAssertEqual(model.error, .invalidAPIKey)
        XCTAssertFalse(called)
        XCTAssertNil(try store.load())

        model.apiKey = "better"
        XCTAssertNil(model.error)
        XCTAssertEqual(model.phase, .editing)
    }

    func testCanConnectNeedsBothFields() {
        let model = LoginModel(store: CredentialStore(storage: InMemorySecureStorage()))
        XCTAssertFalse(model.canConnect)
        model.server = "photos.example.com"
        XCTAssertFalse(model.canConnect)
        model.apiKey = "  "
        XCTAssertFalse(model.canConnect)
        model.apiKey = "k"
        XCTAssertTrue(model.canConnect)
    }

    func testConnectingStateWhileTesting() async throws {
        let mock = MockImmichService(library: .small, latency: .milliseconds(200))
        let model = LoginModel(
            server: "photos.example.com", apiKey: "k",
            store: CredentialStore(storage: InMemorySecureStorage()),
            tester: ConnectionTester { _ in mock }
        )
        model.connect()
        XCTAssertTrue(model.isConnecting || model.phase == .editing)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.isConnecting)
        XCTAssertFalse(model.canConnect)
        model.cancel()
        XCTAssertEqual(model.phase, .editing)
    }
}

// MARK: - Helpers

private final class SeenCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ServerCredentials?
    var value: ServerCredentials? { lock.withLock { _value } }
    func set(_ value: ServerCredentials) { lock.withLock { _value = value } }
}

private struct FailingStorage: SecureStorage {
    func data(for account: String) throws -> Data? { nil }
    func set(_ data: Data, for account: String) throws { throw CredentialStoreError.keychain(-25300) }
    func remove(account: String) throws {}
}

private func assertLoginError(
    _ expected: LoginError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Any
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? LoginError, expected, file: file, line: line)
    }
}
