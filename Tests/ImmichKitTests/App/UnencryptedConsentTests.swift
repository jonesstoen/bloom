import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Plain http to a private address or local name sends the API key where anyone on the same Wi-Fi
/// can read it (on a hotel network, "192.168.1.10" and "nas.local" belong to someone else).
/// Sign-in asks first; Tailscale and https don't need to.
@MainActor
final class UnencryptedConsentTests: XCTestCase {
    private func exposes(_ address: String) -> Bool {
        ServerCredentials.exposesAPIKeyOnLocalNetwork(URL(string: address)!)
    }

    func testOnlyLocalNetworkHTTPNeedsConsent() {
        for local in ["http://192.168.1.10:2283", "http://10.0.0.4", "http://nas.local", "http://nas:2283",
                      "http://photos.lan", "http://[fe80::1]", "http://[fd12:3456::1]"] {
            XCTAssertTrue(exposes(local), local)
        }
        for safe in ["https://192.168.1.10", "https://photos.example.com", "http://100.101.102.103:2283",
                     "http://photos.example-tailnet.ts.net", "http://[fd7a:115c:a1e0::1]", "http://localhost:2283",
                     "http://127.0.0.1", "http://[::1]",
                     // Refused outright elsewhere, so no consent is ever asked for these.
                     "http://photos.example.com", "http://8.8.8.8"] {
            XCTAssertFalse(exposes(safe), safe)
        }
    }

    private final class Counter: @unchecked Sendable { var made = 0 }

    private func login(_ counter: Counter) -> LoginModel {
        let tester = ConnectionTester { _ in
            counter.made += 1
            return MockImmichService()
        }
        return LoginModel(apiKey: "k", store: CredentialStore(storage: InMemorySecureStorage()), tester: tester)
    }

    func testLocalHTTPAsksBeforeSendingTheKey() async throws {
        let counter = Counter()
        let model = login(counter)
        model.server = "http://192.168.1.10:2283"
        await model.connectNow()
        XCTAssertTrue(model.asksForUnencryptedConsent)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(counter.made, 0, "nothing may be sent before the user agrees")

        model.declineUnencrypted()
        XCTAssertFalse(model.asksForUnencryptedConsent)
        await model.connectNow()
        XCTAssertTrue(model.asksForUnencryptedConsent, "declining doesn't count as consent")
        XCTAssertEqual(counter.made, 0)

        model.confirmUnencrypted()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.phase == .editing || model.phase == .connecting, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(model.asksForUnencryptedConsent)
        XCTAssertGreaterThan(counter.made, 0)
        if case .connected = model.phase {} else { XCTFail("expected to connect, got \(model.phase)") }
    }

    func testConsentIsForThatServerOnly() async {
        let counter = Counter()
        let model = login(counter)
        model.server = "http://192.168.1.10:2283"
        await model.connectNow()
        model.confirmUnencrypted()
        model.cancel()
        model.server = "http://nas.local"
        await model.connectNow()
        XCTAssertTrue(model.asksForUnencryptedConsent, "a different local server asks again")
    }

    func testTailscaleAndHTTPSConnectWithoutAsking() async {
        for server in ["http://100.101.102.103:2283", "https://photos.example.com"] {
            let counter = Counter()
            let model = login(counter)
            model.server = server
            await model.connectNow()
            XCTAssertFalse(model.asksForUnencryptedConsent, server)
            XCTAssertGreaterThan(counter.made, 0, server)
        }
    }
}
