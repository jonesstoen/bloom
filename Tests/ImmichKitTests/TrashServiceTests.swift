import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

final class TrashServiceTests: XCTestCase {
    func testMockDeduplicatesIDsAndConfirmsAlreadyTrashedAssets() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = [
            Asset(id: "first", kind: .image, takenAt: now),
            Asset(id: "already", kind: .image, takenAt: now, isTrashed: true),
        ]
        let mock = MockImmichService(assets: assets)

        let result = try await mock.moveToTrash(assetIDs: ["first", "first", "already"])

        XCTAssertEqual(result.confirmedIDs, ["first", "already"])
        XCTAssertTrue(result.failedIDs.isEmpty)
        let firstWrites = await mock.requestCount(.moveToTrash("first"))
        let alreadyWrites = await mock.requestCount(.moveToTrash("already"))
        XCTAssertEqual(firstWrites, 1)
        XCTAssertEqual(alreadyWrites, 0)
    }

    func testEmptyIDsDoNotWriteAndEmptyIDIsRejectedBeforeAnyWrite() async throws {
        let mock = MockImmichService(assets: [])

        let empty = try await mock.moveToTrash(assetIDs: [])
        XCTAssertTrue(empty.confirmedIDs.isEmpty)
        XCTAssertTrue(empty.failedIDs.isEmpty)
        do {
            _ = try await mock.moveToTrash(assetIDs: ["valid", ""])
            XCTFail("Expected invalid empty asset ID")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
        let requests = await mock.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMockReportsPartialFailuresWithoutRetrying() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockImmichService(assets: [
            Asset(id: "ok", kind: .image, takenAt: now),
            Asset(id: "failed", kind: .image, takenAt: now),
        ])
        await mock.setTrashFailures(["failed"])

        let result = try await mock.moveToTrash(assetIDs: ["ok", "failed"])

        XCTAssertEqual(result.confirmedIDs, ["ok"])
        XCTAssertEqual(result.failedIDs, ["failed"])
        let okWrites = await mock.requestCount(.moveToTrash("ok"))
        let failedWrites = await mock.requestCount(.moveToTrash("failed"))
        let updated = try await mock.asset(id: "ok")
        XCTAssertEqual(okWrites, 1)
        XCTAssertEqual(failedWrites, 1)
        XCTAssertTrue(updated.isTrashed)
    }
}

/// Body-aware transport for checking the non-permanent Immich trash request without network access.
private final class TrashRecordingTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(HTTPRequest, Data)] = []
    private let handler: @Sendable (HTTPRequest, Int) -> (Int, String, String)

    var requests: [(HTTPRequest, Data)] { lock.withLock { recorded } }

    init(handler: @escaping @Sendable (HTTPRequest, Int) -> (Int, String, String)) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data: Data
        if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
        else { data = Data() }
        let index = lock.withLock { () -> Int in
            recorded.append((request, data))
            return recorded.count - 1
        }
        let (status, contentType, text) = handler(request, index)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = contentType
        return (response, HTTPBody(text))
    }
}

final class LiveTrashServiceTests: XCTestCase {
    func testUsesTrashCapabilityAndConfigThenSendsOnlyNonPermanentDelete() async throws {
        let transport = TrashRecordingTransport { request, _ in
            switch request.path {
            case "/server/features": (200, "application/json", Self.featuresJSON(trashEnabled: true))
            case "/server/config": (200, "application/json", Self.configJSON(trashDays: 30))
            case "/assets/a1": (200, "application/json", Self.assetJSON(id: "a1", trashed: false))
            case "/assets": (204, "application/json", "")
            default: (404, "application/json", "{}")
            }
        }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        let service = LiveImmichService(credentials: credentials, transport: transport)

        let result = try await service.moveToTrash(assetIDs: ["a1"])

        XCTAssertEqual(result.confirmedIDs, ["a1"])
        XCTAssertTrue(result.failedIDs.isEmpty)
        let requests = transport.requests
        let delete = try XCTUnwrap(requests.first { $0.0.method == .delete })
        XCTAssertEqual(delete.0.path, "/assets")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: delete.1) as? [String: Any])
        XCTAssertEqual(body["ids"] as? [String], ["a1"])
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertFalse(requests.contains { $0.0.path?.contains("permanent") == true })
    }

    func testUnavailableTrashCapabilityFailsClosedBeforeAnyDelete() async throws {
        let transport = TrashRecordingTransport { request, _ in
            request.path == "/server/features"
                ? (200, "application/json", Self.featuresJSON(trashEnabled: false))
                : (200, "application/json", Self.configJSON(trashDays: 30))
        }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        let service = LiveImmichService(credentials: credentials, transport: transport)

        do {
            _ = try await service.moveToTrash(assetIDs: ["a1"])
            XCTFail("Expected trash to be unavailable")
        } catch {
            XCTAssertEqual(error as? TrashError, .unavailable)
        }
        XCTAssertFalse(transport.requests.contains { $0.0.method == .delete })
    }

    func testAlreadyTrashedAssetIsConfirmedWithoutDelete() async throws {
        let transport = TrashRecordingTransport { request, _ in
            switch request.path {
            case "/server/features": (200, "application/json", Self.featuresJSON(trashEnabled: true))
            case "/server/config": (200, "application/json", Self.configJSON(trashDays: 30))
            case "/assets/a1": (200, "application/json", Self.assetJSON(id: "a1", trashed: true))
            default: (404, "application/json", "{}")
            }
        }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        let service = LiveImmichService(credentials: credentials, transport: transport)

        let result = try await service.moveToTrash(assetIDs: ["a1"])

        XCTAssertEqual(result.confirmedIDs, ["a1"])
        XCTAssertFalse(transport.requests.contains { $0.0.method == .delete })
    }

    func testNon204DeleteIsNotTreatedAsSuccessWithoutMatchingTrashReconciliation() async throws {
        let transport = TrashRecordingTransport { request, _ in
            switch request.path {
            case "/server/features": (200, "application/json", Self.featuresJSON(trashEnabled: true))
            case "/server/config": (200, "application/json", Self.configJSON(trashDays: 30))
            case "/assets/a1": (200, "application/json", Self.assetJSON(id: "a1", trashed: false))
            case "/assets": (200, "application/json", "{}") // Immich DELETE must return exactly 204.
            default: (404, "application/json", "{}")
            }
        }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        let service = LiveImmichService(credentials: credentials, transport: transport)

        let result = try await service.moveToTrash(assetIDs: ["a1"])

        XCTAssertTrue(result.confirmedIDs.isEmpty)
        XCTAssertEqual(result.failedIDs, ["a1"])
        XCTAssertEqual(transport.requests.filter { $0.0.method == .delete }.count, 1)
    }

    func testFailedDeleteReconcilesByReadingAssetWithoutRetryingDelete() async throws {
        let transport = TrashRecordingTransport { request, index in
            switch request.path {
            case "/server/features": (200, "application/json", Self.featuresJSON(trashEnabled: true))
            case "/server/config": (200, "application/json", #"{"trashDays":30}"#)
            case "/assets/a1": (200, "application/json", Self.assetJSON(id: "a1", trashed: index >= 4))
            case "/assets": (504, "application/json", "{}")
            default: (404, "application/json", "{}")
            }
        }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        let service = LiveImmichService(credentials: credentials, transport: transport)

        let result = try await service.moveToTrash(assetIDs: ["a1"])

        XCTAssertEqual(result.confirmedIDs, ["a1"], "The failed response is reconciled against current server state")
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertEqual(transport.requests.filter { $0.0.method == .delete }.count, 1)
        XCTAssertEqual(transport.requests.filter { $0.0.method == .get && $0.0.path == "/assets/a1" }.count, 2)
    }

    func testZeroOrMalformedTrashPolicyFailsClosed() async throws {
        for configBody in [Self.configJSON(trashDays: 0), "not-json"] {
            let transport = TrashRecordingTransport { request, _ in
                request.path == "/server/features"
                    ? (200, "application/json", Self.featuresJSON(trashEnabled: true))
                    : (200, "application/json", configBody)
            }
            let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
            let service = LiveImmichService(credentials: credentials, transport: transport)

            do {
                _ = try await service.moveToTrash(assetIDs: ["a1"])
                XCTFail("Expected invalid server trash policy to fail closed")
            } catch {
                XCTAssertEqual(error as? TrashError, .unavailable)
            }
            XCTAssertFalse(transport.requests.contains { $0.0.method == .delete })
        }
    }

    private static func assetJSON(id: String, trashed: Bool) -> String {
        """
        {"id":"\(id)","checksum":"abc=","type":"IMAGE","createdAt":"2024-06-02T08:00:00.000Z",
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

    private static func featuresJSON(trashEnabled: Bool) -> String {
        #"{"backups":false,"configFile":false,"duplicateDetection":false,"email":false,"facialRecognition":false,"importFaces":false,"map":false,"oauth":false,"oauthAutoLaunch":false,"ocr":false,"passwordLogin":true,"realtimeTranscoding":false,"reverseGeocoding":false,"search":false,"sidecar":false,"smartSearch":false,"trash":\#(trashEnabled)}"#
    }

    private static func configJSON(trashDays: Int) -> String {
        #"{"externalDomain":"","isInitialized":true,"isOnboarded":true,"loginPageMessage":"","maintenanceMode":false,"mapDarkStyleUrl":"","mapLightStyleUrl":"","minFaces":3,"oauthButtonText":"","publicUsers":false,"trashDays":\#(trashDays),"userDeleteDelay":0}"#
    }
}
