import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

final class RestoreServiceTests: XCTestCase {
    func testMissingTrashFlagNeverConfirmsRestoration() async throws {
        for missingInPreflight in [true, false] {
            let transport = RestoreRecordingTransport { request, index in
                if request.path == "/trash/restore/assets" { return (200, #"{"count":1}"#) }
                if request.path == "/assets/a1" {
                    if index == 0 && !missingInPreflight {
                        return (200, Self.assetJSON(id: "a1", trashed: true))
                    }
                    let incomplete = Self.assetJSON(id: "a1", trashed: false)
                        .replacingOccurrences(of: "\"isTrashed\":false,", with: "")
                    return (200, incomplete)
                }
                return (404, "{}")
            }
            let result = try await Self.service(transport).restoreAssets(assetIDs: ["a1"])
            XCTAssertTrue(result.confirmedIDs.isEmpty, "An omitted state is not proof of restoration")
            XCTAssertEqual(result.failedIDs, ["a1"])
            XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, missingInPreflight ? 0 : 1)
        }
    }

    func testLiveRestorePostsOnlyRequestedIDsAndVerifiesEachIDInsteadOfTrustingCount() async throws {
        let transport = RestoreRecordingTransport { request, index in
            switch request.path {
            case "/assets/a1": (200, Self.assetJSON(id: "a1", trashed: false))
            case "/assets/a2": (200, Self.assetJSON(id: "a2", trashed: index != 3))
            case "/trash/restore/assets": (200, #"{"count":0}"#)
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let result = try await service.restoreAssets(assetIDs: ["a1", "a2"])

        XCTAssertEqual(result.confirmedIDs, ["a1", "a2"])
        XCTAssertTrue(result.failedIDs.isEmpty)
        let requests = transport.requests
        let posts = requests.filter { $0.0.method == .post }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.0.path, "/trash/restore/assets")
        let body = try XCTUnwrap(posts.first?.1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: [String]],
                       ["ids": ["a2"]])
        XCTAssertEqual(requests.filter { $0.0.method == .get && $0.0.path == "/assets/a1" }.count, 1)
        XCTAssertEqual(requests.filter { $0.0.method == .get && $0.0.path == "/assets/a2" }.count, 2)
        XCTAssertFalse(requests.contains { $0.0.method == .delete || $0.0.path == "/trash/empty" || $0.0.path == "/trash/restore" })
    }

    func testLiveRestoreDoesNotRetryPostAndUsesFollowupStateWhenResponseIsMalformed() async throws {
        let transport = RestoreRecordingTransport { request, index in
            switch request.path {
            case "/assets/a1": (200, Self.assetJSON(id: "a1", trashed: index == 0))
            case "/trash/restore/assets": (200, "not-json")
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let result = try await service.restoreAssets(assetIDs: ["a1"])

        XCTAssertEqual(result.confirmedIDs, ["a1"])
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
        XCTAssertEqual(transport.requests.filter { $0.0.method == .get && $0.0.path == "/assets/a1" }.count, 2)
    }

    func testPositiveCountCannotConfirmAnIDThatIsStillTrashed() async throws {
        let transport = RestoreRecordingTransport { request, _ in
            switch request.path {
            case "/assets/a1": (200, Self.assetJSON(id: "a1", trashed: true))
            case "/trash/restore/assets": (200, #"{"count":1}"#)
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let result = try await service.restoreAssets(assetIDs: ["a1"])

        XCTAssertTrue(result.confirmedIDs.isEmpty)
        XCTAssertEqual(result.failedIDs, ["a1"])
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
        XCTAssertEqual(transport.requests.filter { $0.0.method == .get && $0.0.path == "/assets/a1" }.count, 2)
    }

    func testFollowupAssetWithDifferentIDCannotConfirmRestore() async throws {
        let transport = RestoreRecordingTransport { request, index in
            switch request.path {
            case "/assets/a1":
                (200, Self.assetJSON(id: index == 0 ? "a1" : "other", trashed: index == 0))
            case "/trash/restore/assets": (200, #"{"count":100}"#)
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let result = try await service.restoreAssets(assetIDs: ["a1"])

        XCTAssertTrue(result.confirmedIDs.isEmpty)
        XCTAssertEqual(result.failedIDs, ["a1"])
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
    }

    func testLiveRestoreRetainsFailedIDsWhenPostIsUnconfirmedAndPreflightIsNotTrashed() async throws {
        let transport = RestoreRecordingTransport { request, index in
            switch request.path {
            case "/assets/a1": (200, Self.assetJSON(id: "a1", trashed: true))
            case "/assets/a2": (200, Self.assetJSON(id: "a2", trashed: false))
            case "/trash/restore/assets": (503, "{}")
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let result = try await service.restoreAssets(assetIDs: ["a1", "a2"])

        XCTAssertEqual(result.confirmedIDs, ["a2"], "A matching preflight already proves that this ID is restored")
        XCTAssertEqual(result.failedIDs, ["a1"])
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
        XCTAssertFalse(transport.requests.contains { $0.0.method == .delete })
    }

    func testEmptyAndDuplicateIDsAreHandledWithoutExtraWrites() async throws {
        let transport = RestoreRecordingTransport { request, index in
            switch request.path {
            case "/assets/a1": (200, Self.assetJSON(id: "a1", trashed: index == 0))
            case "/trash/restore/assets": (200, #"{"count":1}"#)
            default: (404, "{}")
            }
        }
        let service = try Self.service(transport)

        let empty = try await service.restoreAssets(assetIDs: [])
        let result = try await service.restoreAssets(assetIDs: ["a1", "a1"])

        XCTAssertTrue(empty.confirmedIDs.isEmpty)
        XCTAssertTrue(empty.failedIDs.isEmpty)
        XCTAssertEqual(result.confirmedIDs, ["a1"])
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
        do {
            _ = try await service.restoreAssets(assetIDs: ["a1", ""])
            XCTFail("Expected invalid asset ID")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
        XCTAssertEqual(transport.requests.filter { $0.0.method == .post }.count, 1)
    }

    func testMockRestoresOnlyRequestedIDsAndDeduplicatesAlreadyRestoredAssets() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockImmichService(assets: [
            Asset(id: "already-restored", kind: .image, takenAt: now),
            Asset(id: "target", kind: .image, takenAt: now, isTrashed: true),
            Asset(id: "untouched", kind: .image, takenAt: now, isTrashed: true),
        ])

        let result = try await mock.restoreAssets(assetIDs: ["already-restored", "target", "target"])

        XCTAssertEqual(result.confirmedIDs, ["already-restored", "target"])
        XCTAssertTrue(result.failedIDs.isEmpty)
        let target = try await mock.asset(id: "target")
        let untouched = try await mock.asset(id: "untouched")
        let alreadyRequests = await mock.requestCount(.restoreAssets("already-restored"))
        let targetRequests = await mock.requestCount(.restoreAssets("target"))
        let untouchedRequests = await mock.requestCount(.restoreAssets("untouched"))
        XCTAssertFalse(target.isTrashed)
        XCTAssertTrue(untouched.isTrashed)
        XCTAssertEqual(alreadyRequests, 0)
        XCTAssertEqual(targetRequests, 1)
        XCTAssertEqual(untouchedRequests, 0)
    }

    func testMockCancellationKeepsEarlierConfirmationAndReportsPendingIDFailed() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockImmichService(assets: [
            Asset(id: "first", kind: .image, takenAt: now, isTrashed: true),
            Asset(id: "second", kind: .image, takenAt: now, isTrashed: true),
        ])
        await mock.setLatency(.milliseconds(100))

        let restore = Task { try await mock.restoreAssets(assetIDs: ["first", "second"]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await mock.requestCount(.restoreAssets("second")) == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        restore.cancel()
        let result = try await restore.value

        XCTAssertEqual(result.confirmedIDs, ["first"])
        XCTAssertEqual(result.failedIDs, ["second"])
        let first = try await mock.asset(id: "first")
        let second = try await mock.asset(id: "second")
        XCTAssertFalse(first.isTrashed)
        XCTAssertTrue(second.isTrashed)
    }

    private static func service(_ transport: RestoreRecordingTransport) throws -> LiveImmichService {
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "test-key")
        return LiveImmichService(credentials: credentials, transport: transport)
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
}

private final class RestoreRecordingTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(HTTPRequest, Data)] = []
    private let handler: @Sendable (HTTPRequest, Int) -> (Int, String)

    var requests: [(HTTPRequest, Data)] { lock.withLock { recorded } }

    init(handler: @escaping @Sendable (HTTPRequest, Int) -> (Int, String)) {
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
        let (status, text) = handler(request, index)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }
}
