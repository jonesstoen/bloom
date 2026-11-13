import XCTest
import HTTPTypes
import OpenAPIRuntime
@testable import ImmichKit

/// A server must not be able to exhaust memory by streaming an endless JSON body.
final class ResponseSizeLimitTests: XCTestCase {
    private func service(limit: Int, body: String) throws -> LiveImmichService {
        let transport = RecordingTransport { _ in (200, "application/json", body) }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        return LiveImmichService(credentials: credentials, transport: transport, maxJSONBytes: limit)
    }

    func testBodiesOverTheLimitAreRejected() async throws {
        let body = #"[{"timeBucket":"2024-03-01","count":12}"# + String(repeating: #",{"timeBucket":"2024-03-01","count":1}"#, count: 100) + "]"
        let service = try service(limit: 1024, body: body)
        do {
            _ = try await service.timeBuckets(options: .library)
            XCTFail("an oversized body was decoded")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testBodiesWithinTheLimitStillDecode() async throws {
        let service = try service(limit: 1024, body: #"[{"timeBucket":"2024-03-01","count":12}]"#)
        let buckets = try await service.timeBuckets(options: .library)
        XCTAssertEqual(buckets.map(\.count), [12])
    }

    func testDefaultLimitLeavesRoomForLargeLibraries() {
        XCTAssertGreaterThanOrEqual(LiveImmichService.maxJSONBytes, 32 * 1024 * 1024)
    }
}
