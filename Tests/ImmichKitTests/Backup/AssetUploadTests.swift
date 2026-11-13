import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

/// Transport that answers 200 with a fixed body and keeps the request bodies. No network.
private final class LinkRecordingTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(HTTPRequest, Data)] = []
    var requests: [(HTTPRequest, Data)] { lock.withLock { _requests } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { for try await chunk in body { data.append(contentsOf: chunk) } }
        lock.withLock { _requests.append((request, data)) }
        var response = HTTPResponse(status: .init(code: 200))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody("{}"))
    }
}

final class AssetUploadTests: XCTestCase {
    private var directory: URL!
    private let key = "test-key-123"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssetUploadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let resource = Data([0x01, 0xFF, 0x42])

    private func request(
        duration: TimeInterval? = nil, livePhotoVideoID: String? = nil, isFavorite: Bool = true,
        allowsCellular: Bool = true, filename: String = "IMG_0001.HEIC", checksum: String = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
    ) throws -> AssetUploadRequest {
        let file = directory.appendingPathComponent("resource.bin")
        try resource.write(to: file)
        return AssetUploadRequest(
            fileURL: file, filename: filename, mimeType: "image/heic", checksum: checksum,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100.5),
            isFavorite: isFavorite, duration: duration, livePhotoVideoID: livePhotoVideoID, allowsCellular: allowsCellular)
    }

    private func body(of request: AssetUploadRequest, boundary: String = "XBOUNDARYX") throws -> Data {
        let url = directory.appendingPathComponent("body-\(UUID().uuidString)")
        try MultipartBody.write(request, boundary: boundary, to: url)
        return try Data(contentsOf: url)
    }

    private func text(_ string: String) -> Data { Data(string.utf8) }

    // MARK: Multipart body

    func testMultipartBodyMatchesFixture() throws {
        let actual = try body(of: request(duration: 12.4, livePhotoVideoID: "11111111-2222-4333-8444-555555555555"))
        func field(_ name: String, _ value: String) -> String {
            "--XBOUNDARYX\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        var expected = Data()
        expected.append(text(field("fileCreatedAt", "2023-11-14T22:13:20.000Z")))
        expected.append(text(field("fileModifiedAt", "2023-11-14T22:15:00.500Z")))
        expected.append(text(field("filename", "IMG_0001.HEIC")))
        expected.append(text(field("isFavorite", "true")))
        expected.append(text(field("duration", "12")))
        expected.append(text(field("livePhotoVideoId", "11111111-2222-4333-8444-555555555555")))
        expected.append(text("--XBOUNDARYX\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"IMG_0001.HEIC\"\r\n"
            + "Content-Type: image/heic\r\n\r\n"))
        expected.append(resource)
        expected.append(text("\r\n--XBOUNDARYX--\r\n"))
        XCTAssertEqual(actual, expected)
    }

    func testMultipartOmitsDurationAndLivePhotoWhenNil() throws {
        let actual = try body(of: request(isFavorite: false))
        let string = String(decoding: actual, as: UTF8.self)
        XCTAssertFalse(string.contains("name=\"duration\""))
        XCTAssertFalse(string.contains("name=\"livePhotoVideoId\""))
        XCTAssertTrue(string.contains("name=\"isFavorite\"\r\n\r\nfalse\r\n"))
        // None of the fields the spec says we never send.
        for name in ["visibility", "metadata", "sidecarData", "deviceAssetId"] {
            XCTAssertFalse(string.contains("name=\"\(name)\""), name)
        }
    }

    func testMultipartFilenameCannotBreakOutOfTheHeader() throws {
        let actual = try body(of: request(filename: "a\"b\r\nX-Evil: 1.jpg"))
        let string = String(decoding: actual, as: UTF8.self)
        // The part header is a single line; the `filename` form field is data and keeps the raw text.
        let header = try XCTUnwrap(string.range(of: "name=\"assetData\"")).lowerBound
        XCTAssertFalse(string[header...].prefix(80).contains("X-Evil\r\n"))
        XCTAssertEqual(string[header...].components(separatedBy: "\r\n").first,
                       "name=\"assetData\"; filename=\"a%22bX-Evil: 1.jpg\"")
        XCTAssertTrue(string.contains("name=\"assetData\"; filename=\"a%22bX-Evil: 1.jpg\""))
    }

    func testMultipartStreamsLargeResource() throws {
        let file = directory.appendingPathComponent("big.bin")
        let chunk = Data((0..<255).map { UInt8($0) })
        let handle = try { FileManager.default.createFile(atPath: file.path, contents: nil); return try FileHandle(forWritingTo: file) }()
        for _ in 0..<(3 * 1024) { try handle.write(contentsOf: chunk) } // ~780 KB: more than one read chunk
        try handle.close()
        var upload = try request()
        upload = AssetUploadRequest(
            fileURL: file, filename: upload.filename, mimeType: upload.mimeType, checksum: upload.checksum,
            createdAt: upload.createdAt, modifiedAt: upload.modifiedAt, isFavorite: upload.isFavorite,
            duration: nil, livePhotoVideoID: nil, allowsCellular: true)
        let actual = try body(of: upload)
        let resourceData = try Data(contentsOf: file)
        XCTAssertNotNil(actual.range(of: resourceData))
        XCTAssertEqual(actual.suffix(text("\r\n--XBOUNDARYX--\r\n").count), text("\r\n--XBOUNDARYX--\r\n"))
    }

    func testDurationFieldIsWholeSecondsAndNeverNegative() {
        XCTAssertEqual(MultipartBody.durationField(0), "0")
        XCTAssertEqual(MultipartBody.durationField(12.4), "12")
        XCTAssertEqual(MultipartBody.durationField(12.5), "13")
        XCTAssertEqual(MultipartBody.durationField(-3), "0")
    }

    // MARK: Request

    private func service(server: String = "https://photos.example.com", transport: (any ClientTransport)? = nil) throws -> LiveImmichService {
        let credentials = try ServerCredentials(server: server, apiKey: key)
        if let transport { return LiveImmichService(credentials: credentials, transport: transport) }
        return LiveImmichService(credentials: credentials)
    }

    func testUploadRequestHeaders() throws {
        let service = try service()
        let bodyFile = directory.appendingPathComponent("body")
        let urlRequest = service.makeUploadRequest(try request(allowsCellular: false), boundary: "XBOUNDARYX", bodyFile: bodyFile)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://photos.example.com/api/assets")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-immich-checksum"), "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=XBOUNDARYX")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(urlRequest.allowsCellularAccess)
        XCTAssertNil(urlRequest.url?.query)
        XCTAssertFalse(urlRequest.url?.absoluteString.contains(key) ?? true)
        let cellular = service.makeUploadRequest(try request(allowsCellular: true), boundary: "B", bodyFile: bodyFile)
        XCTAssertTrue(cellular.allowsCellularAccess)
    }

    func testUploadRefusesInsecureServerBeforeTouchingFiles() async throws {
        let service = try service(server: "http://photos.example.com")
        let upload = try request()
        do {
            _ = try await service.uploadAsset(upload)
            XCTFail("expected insecureConnection")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .insecureConnection)
        }
        // Nothing was written next to the resource.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["resource.bin"])
    }

    // MARK: Status mapping

    func testStatusMapping() throws {
        let id = "11111111-2222-4333-8444-555555555555"
        func result(_ status: Int, _ json: String = "") throws -> AssetUploadResult {
            try LiveImmichService.result(status: status, data: Data(json.utf8))
        }
        XCTAssertEqual(try result(201, #"{"id":"\#(id)","status":"created"}"#), AssetUploadResult(id: id, status: .created))
        XCTAssertEqual(try result(200, #"{"id":"\#(id)","status":"duplicate"}"#), AssetUploadResult(id: id, status: .duplicate))
        for status in [401, 403] {
            XCTAssertThrowsError(try result(status)) { XCTAssertEqual($0 as? ImmichServiceError, .unauthorized) }
        }
        XCTAssertThrowsError(try result(400, #"{"message":"Unsupported file type","statusCode":400}"#)) {
            XCTAssertEqual($0 as? BackupUploadError, .rejected(status: 400, message: "Unsupported file type"))
        }
        XCTAssertThrowsError(try result(400, #"{"message":["duration must be an integer","x"]}"#)) {
            XCTAssertEqual($0 as? BackupUploadError, .rejected(status: 400, message: "duration must be an integer; x"))
        }
        XCTAssertThrowsError(try result(413, "not json")) {
            XCTAssertEqual($0 as? BackupUploadError, .rejected(status: 413, message: ""))
        }
        for status in [429, 500, 502, 503] {
            XCTAssertThrowsError(try result(status)) { XCTAssertEqual($0 as? ImmichServiceError, .unexpectedStatus(status)) }
        }
        // A success without a usable body is not a success.
        XCTAssertThrowsError(try result(201, "{}")) { XCTAssertEqual($0 as? ImmichServiceError, .invalidResponse) }
        XCTAssertThrowsError(try result(201, #"{"id":"x","status":"weird"}"#)) {
            XCTAssertEqual($0 as? ImmichServiceError, .invalidResponse)
        }
    }

    // MARK: Linking

    func testLinkLivePhotoBody() async throws {
        let transport = LinkRecordingTransport()
        let service = try service(transport: transport)
        try await service.linkLivePhoto(photoID: "photo-1", motionID: "motion-1")
        let (request, data) = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.path, "/assets/photo-1")
        XCTAssertEqual(request.headerFields[APIKeyMiddleware.headerName], key)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json, ["livePhotoVideoId": "motion-1"])
    }

    // MARK: Mock

    func testMockRecordsUploadsAndLearnsTheChecksum() async throws {
        let mock = MockImmichService()
        let upload = try request()
        let result = try await mock.uploadAsset(upload)
        XCTAssertEqual(result.status, .created)
        XCTAssertNotNil(UUID(uuidString: result.id))
        let uploads = await mock.uploads
        XCTAssertEqual(uploads.map(\.checksum), [upload.checksum])
        let check = try await mock.checkBulkUpload([BulkUploadCheckItem(id: "a", checksum: upload.checksum)])
        XCTAssertEqual(check.first?.isDuplicate, true)
        // The same file again is a duplicate with the same ID, like the server.
        let again = try await mock.uploadAsset(upload)
        XCTAssertEqual(again, AssetUploadResult(id: result.id, status: .duplicate))
    }

    func testMockQueuedResultsAndFailures() async throws {
        let mock = MockImmichService()
        let queued = AssetUploadResult(id: "queued-1", status: .duplicate)
        await mock.setUploadResults([queued])
        let first = try await mock.uploadAsset(try request())
        XCTAssertEqual(first, queued)
        await mock.setUploadFailure(BackupUploadError.rejected(status: 400, message: "no"), afterCalls: 1)
        let ok = try await mock.uploadAsset(try request(checksum: "second"))
        XCTAssertEqual(ok.status, .created)
        do {
            _ = try await mock.uploadAsset(try request(checksum: "third"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? BackupUploadError, .rejected(status: 400, message: "no"))
        }
        await mock.setLinkFailure(ImmichServiceError.unauthorized)
        try? await mock.linkLivePhoto(photoID: "p", motionID: "m")
        let links = await mock.links
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.photoID, "p")
        XCTAssertEqual(links.first?.motionID, "m")
    }

    func testEditGuardForwardsUploadsEvenWhenChangesAreOff() async throws {
        let mock = MockImmichService()
        let guarded = EditGuardedService(base: mock, permission: EditingPermission(isAllowed: false))
        let upload = try request()
        let result = try await guarded.uploadAsset(upload)
        XCTAssertEqual(result.status, .created)
        try await guarded.linkLivePhoto(photoID: "p", motionID: "m")
        let uploads = await mock.uploads
        let links = await mock.links
        XCTAssertEqual(uploads.map(\.checksum), [upload.checksum])
        XCTAssertEqual(links.map(\.photoID), ["p"])
        // Restoring from trash still needs Allow Changes.
        do {
            _ = try await guarded.restoreAssets(assetIDs: ["x"])
            XCTFail("expected editingOff")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .editingOff)
        }
    }
}
