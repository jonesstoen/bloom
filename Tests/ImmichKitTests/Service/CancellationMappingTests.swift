import Foundation
import XCTest
@testable import ImmichKit

final class CancellationMappingTests: XCTestCase {
    func testDirectCancellationIsPreserved() async {
        await assertCancellation { try await LiveImmichService.mapErrors { throw CancellationError() } }
    }

    func testGeneratedClientPreservesTransportCancellation() async throws {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let service = try service(error: error)
            await assertCancellation { try await service.ping() }
        }
    }

    func testRawRequestsPreserveTransportCancellation() async throws {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let service = try service(error: error)
            await assertCancellation { _ = try await service.rawGET(path: "/server/features", operationID: "test") }
        }
    }

    private func service(error: any Error) throws -> LiveImmichService {
        let transport = RecordingTransport { _ in throw error }
        return LiveImmichService(credentials: try ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder"), transport: transport)
    }

    private func assertCancellation(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {} catch {
            XCTFail("Cancellation became \(type(of: error))", file: file, line: line)
        }
    }
}
