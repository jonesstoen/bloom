import AVFoundation
import XCTest
@testable import ImmichKit

/// Videos and Live Photo clips play through GuardedMediaAsset: AVFoundation never sees the key,
/// and a redirect to another server is refused instead of carrying the key along.
final class GuardedMediaTests: XCTestCase {
    /// A 16×16, half-second H.264 clip (generated with ffmpeg, faststart).
    static let clip = Data(base64Encoded: "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMobW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAfQAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAlN0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAfQAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAH0AAAAAAABAAAAAAHLbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAIABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABdm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAATZzdGJsAAAAtnN0c2QAAAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBQsAK/+EAFWdCwAraewEQAAADABAAAAMAgPEiagEABGjOD8gAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAncAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAEAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAAm4AAAAJAAAAFHN0Y28AAAAAAAAAAQAAA1gAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAyAAAACGZyZWUAAAJ/bWRhdAAAAlMGBf//T9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MjUwIGtleWludF9taW49NCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAE2WIhDoRigACGPHAAED2OAAIeWAAAAAFQZogEKU=")!

    private var sessions: [URLSession] = []

    override func tearDown() {
        sessions.forEach { $0.invalidateAndCancel() }
        sessions = []
        MediaStub.reset()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaStub.self]
        let session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
        sessions.append(session)
        return session
    }

    private func request(_ url: String) -> MediaRequest {
        MediaRequest(kind: .videoPlayback, assetID: "v1", url: URL(string: url)!, headers: ["x-api-key": "test-key"])
    }

    func testPlaysThroughRangeRequestsWithTheKey() async throws {
        MediaStub.handler = { request in
            guard request.url?.host == "photos.example.com" else { return .status(404) }
            return .media(GuardedMediaTests.clip, mimeType: "video/mp4")
        }
        let asset = GuardedMediaAsset(request: request("https://photos.example.com/api/assets/v1/video/playback"), session: session())
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let seen = MediaStub.seen
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0.host == "photos.example.com" && $0.key == "test-key" && $0.range != nil })
    }

    func testRedirectToAnotherServerIsRefusedAndNeverReceivesTheKey() async {
        MediaStub.handler = { request in
            if request.url?.host == "photos.example.com" { return .redirect(to: "https://evil.example/clip.mp4") }
            return .media(GuardedMediaTests.clip, mimeType: "video/mp4")
        }
        let asset = GuardedMediaAsset(request: request("https://photos.example.com/api/assets/v1/video/playback"), session: session())
        do {
            _ = try await asset.load(.duration)
            XCTFail("a redirected stream must not play")
        } catch {}
        XCTAssertFalse(MediaStub.seen.contains { $0.host == "evil.example" }, "the other server got a request")
    }

    func testSameServerRedirectIsFollowed() async throws {
        MediaStub.handler = { request in
            if request.url?.path == "/old" { return .redirect(to: "https://photos.example.com/new") }
            return .media(GuardedMediaTests.clip, mimeType: "application/octet-stream")
        }
        let asset = GuardedMediaAsset(request: request("https://photos.example.com/old"), session: session())
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.2, "a generic content type still plays as a movie")
        XCTAssertTrue(MediaStub.seen.allSatisfy { $0.host == "photos.example.com" && $0.key == "test-key" })
    }

    func testServerErrorsFailPlayback() async {
        MediaStub.handler = { _ in .status(500) }
        let asset = GuardedMediaAsset(request: request("https://photos.example.com/v"), session: session())
        do {
            _ = try await asset.load(.duration)
            XCTFail("expected a failure")
        } catch {}
    }

}

/// Serves canned media for URLSession, honouring Range like Immich does.
final class MediaStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case media(Data, mimeType: String)
        case redirect(to: String)
        case status(Int)
    }
    struct Seen: Sendable { let host: String?; let key: String?; let range: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var handler: (@Sendable (URLRequest) -> Reply)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _handler = nil; _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.lock.withLock {
            Self._seen.append(Seen(host: request.url?.host, key: request.value(forHTTPHeaderField: "x-api-key"),
                                   range: request.value(forHTTPHeaderField: "Range")))
        }
        let url = request.url!
        switch Self.handler?(request) ?? .status(404) {
        case .status(let code):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var next = request
            next.url = URL(string: target)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .media(let data, let mimeType):
            var body = data
            var status = 200
            var headers = ["Content-Type": mimeType, "Content-Length": "\(data.count)"]
            if let range = request.value(forHTTPHeaderField: "Range"),
               let spec = range.split(separator: "=").last {
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(parts[0]) ?? 0
                let end = min(parts.count > 1 ? Int(parts[1]) ?? (data.count - 1) : data.count - 1, data.count - 1)
                body = data.subdata(in: start..<(end + 1))
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
                headers["Content-Length"] = "\(body.count)"
                headers["Accept-Ranges"] = "bytes"
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
