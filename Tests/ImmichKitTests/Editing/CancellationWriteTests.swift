import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

final class CancellationWriteTests: XCTestCase {
    func testCancelledTrashWriteStillReconcilesStateWithoutRetrying() async throws {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            for serverAppliedWrite in [false, true] {
                let transport = CancellationWriteTransport(
                    operation: .trash, writeError: error, serverAppliedWrite: serverAppliedWrite
                )
                let result = try await Self.service(transport).moveToTrash(assetIDs: [Self.assetID])

                XCTAssertEqual(result.confirmedIDs, serverAppliedWrite ? [Self.assetID] : [])
                XCTAssertEqual(result.failedIDs, serverAppliedWrite ? [] : [Self.assetID])
                XCTAssertEqual(transport.requests.filter { $0.method == .delete }.count, 1)
                XCTAssertEqual(transport.requests.filter { $0.method == .get && $0.path == "/assets/\(Self.assetID)" }.count, 2)
            }
        }
    }

    func testCancelledRestoreWriteStillReconcilesStateWithoutRetrying() async throws {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            for serverAppliedWrite in [false, true] {
                let transport = CancellationWriteTransport(
                    operation: .restore, writeError: error, serverAppliedWrite: serverAppliedWrite
                )
                let result = try await Self.service(transport).restoreAssets(assetIDs: [Self.assetID])

                XCTAssertEqual(result.confirmedIDs, serverAppliedWrite ? [Self.assetID] : [])
                XCTAssertEqual(result.failedIDs, serverAppliedWrite ? [] : [Self.assetID])
                XCTAssertEqual(transport.requests.filter { $0.method == .post && $0.path == "/trash/restore/assets" }.count, 1)
                XCTAssertEqual(transport.requests.filter { $0.method == .get && $0.path == "/assets/\(Self.assetID)" }.count, 2)
            }
        }
    }

    fileprivate static let assetID = "93b43fae-e4ef-4b73-9a36-334f65d4cb61"

    private static func service(_ transport: CancellationWriteTransport) throws -> LiveImmichService {
        LiveImmichService(
            credentials: try ServerCredentials(server: "https://photos.example.com", apiKey: "test-placeholder"),
            transport: transport
        )
    }
}

/// Simulates a lost/cancelled write response while leaving the test Task active for reconciliation.
private final class CancellationWriteTransport: ClientTransport, @unchecked Sendable {
    enum Operation: Equatable { case trash, restore }

    private let lock = NSLock()
    private let operation: Operation
    private let writeError: any Error
    private let serverAppliedWrite: Bool
    private var applied = false
    private var recorded: [(method: HTTPRequest.Method, path: String?)] = []

    var requests: [(method: HTTPRequest.Method, path: String?)] { lock.withLock { recorded } }

    init(operation: Operation, writeError: any Error, serverAppliedWrite: Bool) {
        self.operation = operation
        self.writeError = writeError
        self.serverAppliedWrite = serverAppliedWrite
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path
        let state: Bool? = lock.withLock {
            recorded.append((request.method, path))
            switch (operation, request.method, path) {
            case (.trash, .get, "/server/features"), (.trash, .get, "/server/config"):
                return nil
            case (.trash, .delete, "/assets"), (.restore, .post, "/trash/restore/assets"):
                applied = serverAppliedWrite
                return nil
            case (.trash, .get, "/assets/\(CancellationWriteTests.assetID)"),
                 (.restore, .get, "/assets/\(CancellationWriteTests.assetID)"):
                return applied
            default:
                return nil
            }
        }

        if (operation == .trash && request.method == .delete)
            || (operation == .restore && request.method == .post) {
            throw writeError
        }

        let text: String
        if path == "/server/features" {
            text = #"{"trash":true}"#
        } else if path == "/server/config" {
            text = #"{"trashDays":30}"#
        } else if path == "/trash/restore/assets" {
            text = #"{"count":1}"#
        } else if let state {
            text = Self.assetJSON(trashed: operation == .trash ? state : !state)
        } else {
            text = "{}"
        }

        var response = HTTPResponse(status: .init(code: 200))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }

    private static func assetJSON(trashed: Bool) -> String {
        """
        {"id":"\(CancellationWriteTests.assetID)","checksum":"abc=","type":"IMAGE","createdAt":"2024-06-02T08:00:00.000Z",
         "fileCreatedAt":"2024-06-01T18:30:00.000Z","fileModifiedAt":"2024-06-01T18:30:00.000Z",
         "localDateTime":"2024-06-01T20:30:00.000Z","updatedAt":"2024-06-02T08:00:00.000Z",
         "hasMetadata":true,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,
         "isTrashed":\(trashed),"visibility":"timeline","originalFileName":"IMG_0001.HEIC",
         "originalMimeType":"image/heic","originalPath":"/upload/IMG_0001.HEIC","ownerId":"u1",
         "width":3024,"height":4032,"duration":0,"livePhotoVideoId":null,"thumbhash":null,
         "exifInfo":{"make":"Apple","model":"iPhone 15 Pro","fNumber":1.78,"iso":64,
                     "exposureTime":"1/250","latitude":59.91,"longitude":10.75,
                     "city":"Oslo","country":"Norway","fileSizeInByte":2456789}}
        """
    }
}
