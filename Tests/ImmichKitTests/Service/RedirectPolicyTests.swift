import XCTest
@testable import ImmichKit

/// URLSession copies request headers, including `x-api-key`, onto a redirected request (verified
/// with two local servers: the second host received the key). Bloom only follows redirects that
/// stay on the same scheme, host and port.
final class RedirectPolicyTests: XCTestCase {
    private func allows(_ from: String, _ to: String?) -> Bool {
        SameOriginRedirects.allows(from: URL(string: from), to: to.flatMap(URL.init(string:)))
    }

    func testRedirectsWithinTheServerAreFollowed() {
        XCTAssertTrue(allows("https://photos.example.com/api/assets", "https://photos.example.com/api/assets/"))
        XCTAssertTrue(allows("https://Photos.Example.com/api/a", "https://photos.example.com/api/b"))
        XCTAssertTrue(allows("https://photos.example.com/api/a", "https://photos.example.com:443/api/b"), "default port")
        XCTAssertTrue(allows("http://192.168.1.10:2283/api/a", "http://192.168.1.10:2283/api/b"))
    }

    func testRedirectsElsewhereAreRefused() {
        XCTAssertFalse(allows("https://photos.example.com/api/a", "https://evil.example.net/api/a"), "other host")
        XCTAssertFalse(allows("http://127.0.0.1:18771/api/a", "http://127.0.0.1:18772/api/a"), "other port")
        XCTAssertFalse(allows("https://photos.example.com/api/a", "http://photos.example.com/api/a"), "downgrade to http")
        XCTAssertFalse(allows("http://photos.example.com/api/a", "https://photos.example.com/api/a"),
                       "upgrade: enter the https address instead")
        XCTAssertFalse(allows("https://photos.example.com/api/a", "https://photos.example.com.evil.net/api/a"))
        XCTAssertFalse(allows("https://photos.example.com/api/a", nil))
        XCTAssertFalse(allows("https://photos.example.com/api/a", "file:///etc/passwd"))
    }
}

extension RedirectPolicyTests {
    /// Code that sends the key outside the generated client (share downloads) uses this session.
    func testTheSharedImmichSessionRefusesForeignRedirects() {
        XCTAssertTrue(SameOriginRedirects.guards(ImmichNetwork.session))
        XCTAssertFalse(SameOriginRedirects.guards(URLSession.shared))
    }
}
