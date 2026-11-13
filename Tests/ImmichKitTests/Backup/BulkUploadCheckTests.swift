import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

/// Transport that answers from a closure and keeps the request bodies. No network.
private final class BodyRecordingTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(HTTPRequest, Data)] = []
    private let responseBody: String

    var requests: [(HTTPRequest, Data)] { lock.withLock { _requests } }

    init(responseBody: String) { self.responseBody = responseBody }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { for try await chunk in body { data.append(contentsOf: chunk) } }
        lock.withLock { _requests.append((request, data)) }
        var response = HTTPResponse(status: .init(code: 200))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(responseBody))
    }
}

final class BulkUploadCheckTests: XCTestCase {
    private func service(_ response: String) throws -> (LiveImmichService, BodyRecordingTransport) {
        let transport = BodyRecordingTransport(responseBody: response)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key-123")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    func testLiveRequestAndDecoding() async throws {
        let (service, transport) = try service(
            #"{"results":[{"id":"0","action":"reject","reason":"duplicate","assetId":"s1","isTrashed":false},{"id":"1","action":"accept"}]}"#)
        let results = try await service.checkBulkUpload([
            BulkUploadCheckItem(id: "0", checksum: "a"), BulkUploadCheckItem(id: "1", checksum: "b"),
        ])
        let (request, body) = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/assets/bulk-upload-check")
        XCTAssertEqual(request.method, .post)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]])
        XCTAssertEqual(json["assets"], [["id": "0", "checksum": "a"], ["id": "1", "checksum": "b"]])
        XCTAssertEqual(results, [
            BulkUploadCheckResult(id: "0", isDuplicate: true, serverAssetID: "s1", isTrashed: false),
            BulkUploadCheckResult(id: "1", isDuplicate: false, serverAssetID: nil, isTrashed: false),
        ])
        XCTAssertEqual(results.map(\.isRejected), [false, false], "a duplicate and an accept are not rejections")
    }

    func testRejectForUnsupportedFormatIsNotADuplicate() async throws {
        let (service, _) = try service(#"{"results":[{"id":"0","action":"reject","reason":"unsupported-format"}]}"#)
        let results = try await service.checkBulkUpload([BulkUploadCheckItem(id: "0", checksum: "a")])
        XCTAssertEqual(results.map(\.isDuplicate), [false])
        XCTAssertEqual(results.first?.serverAssetID, nil)
        XCTAssertEqual(results.map(\.isRejected), [true], "refused, not missing")
    }

    func testTrashedDuplicateIsReported() async throws {
        let (service, _) = try service(
            #"{"results":[{"id":"0","action":"reject","reason":"duplicate","assetId":"s1","isTrashed":true}]}"#)
        let results = try await service.checkBulkUpload([BulkUploadCheckItem(id: "0", checksum: "a")])
        XCTAssertEqual(results, [BulkUploadCheckResult(id: "0", isDuplicate: true, serverAssetID: "s1", isTrashed: true)])
    }

    func testMalformedResponseIsInvalid() async throws {
        let (service, _) = try service(#"{"nope":1}"#)
        do {
            _ = try await service.checkBulkUpload([BulkUploadCheckItem(id: "0", checksum: "a")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testMockMarksKnownChecksums() async throws {
        let mock = MockImmichService(assets: [])
        await mock.setServerChecksums(["a"])
        let results = try await mock.checkBulkUpload([
            BulkUploadCheckItem(id: "0", checksum: "a"), BulkUploadCheckItem(id: "1", checksum: "b"),
        ])
        XCTAssertEqual(results.map(\.isDuplicate), [true, false])
        XCTAssertEqual(results.map(\.id), ["0", "1"])
        let requests = await mock.requests
        XCTAssertEqual(requests, [.bulkUploadCheck(2)])
    }

    func testEditGuardForwardsTheCheckEvenWhenChangesAreOff() async throws {
        let mock = MockImmichService(assets: [])
        await mock.setServerChecksums(["a"])
        let guarded = EditGuardedService(base: mock, permission: EditingPermission(isAllowed: false))
        let results = try await guarded.checkBulkUpload([BulkUploadCheckItem(id: "0", checksum: "a")])
        XCTAssertEqual(results.map(\.isDuplicate), [true])
    }
}
