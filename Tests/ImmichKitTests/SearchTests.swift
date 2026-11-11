import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit

/// Smart and metadata search through the mock service.
final class MockSearchTests: XCTestCase {
    private let library = MockLibrary.standard

    private var visibleAssets: [Asset] {
        library.assets.filter { !$0.isTrashed && !$0.isArchived }
    }

    func testSmartSearchMatchesPlace() async throws {
        let service = MockImmichService(library: library)
        let results = try await service.smartSearch("tokyo")
        let expected = visibleAssets.filter { $0.exif?.city == "Tokyo" }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(Set(results.assets.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(results.total, expected.count)
        XCTAssertEqual(results.assets.map(\.takenAt), results.assets.map(\.takenAt).sorted(by: >))
        let requests = await service.requests
        XCTAssertEqual(requests, [.smartSearch("tokyo")])
    }

    func testSmartSearchRanksAssetsMatchingMoreWordsFirst() async throws {
        let service = MockImmichService(library: library)
        let results = try await service.smartSearch(SmartSearchQuery(text: "Tokyo video"), page: nil, size: 1000)
        let both = visibleAssets.filter { $0.exif?.city == "Tokyo" && $0.isVideo }
        XCTAssertFalse(both.isEmpty, "fixture needs Tokyo videos")
        XCTAssertEqual(Set(results.assets.prefix(both.count).map(\.id)), Set(both.map(\.id)))
        XCTAssertGreaterThan(results.assets.count, both.count, "assets matching one word follow")
    }

    func testSmartSearchMatchesPeopleAndAlbumNames() async throws {
        let service = MockImmichService(library: library)
        let person = try XCTUnwrap(library.people.first { $0.isNamed && !$0.isHidden })
        let results = try await service.smartSearch(SmartSearchQuery(text: person.name), page: nil, size: 1000)
        let withPerson = Set(library.assets(withPerson: person.id).filter { !$0.isTrashed && !$0.isArchived }.map(\.id))
        XCTAssertFalse(withPerson.isEmpty)
        XCTAssertTrue(withPerson.isSubset(of: Set(results.assets.map(\.id))))
    }

    func testSmartSearchPagesByNumber() async throws {
        let service = MockImmichService(library: library)
        let query = SmartSearchQuery(text: "photo")
        let all = try await service.smartSearch(query, page: nil, size: 1000)
        XCTAssertGreaterThan(all.assets.count, 25)

        var collected: [Asset] = []
        var token: SearchPageToken?
        var pages = 0
        repeat {
            let page = try await service.smartSearch(query, page: token, size: 25)
            XCTAssertLessThanOrEqual(page.assets.count, 25)
            XCTAssertEqual(page.total, all.total)
            collected += page.assets
            token = page.next
            pages += 1
            if case .cursor? = token { XCTFail("smart search pages by number") }
        } while token != nil && pages < 100
        XCTAssertEqual(collected.map(\.id), all.assets.map(\.id))
        XCTAssertEqual(pages, (all.assets.count + 24) / 25)
    }

    func testSmartSearchAppliesFilters() async throws {
        let service = MockImmichService(library: library)
        let filters = SearchFilters(country: "Norway", kind: .video)
        let results = try await service.smartSearch(SmartSearchQuery(text: "video", filters: filters), page: nil, size: 1000)
        XCTAssertFalse(results.assets.isEmpty)
        XCTAssertTrue(results.assets.allSatisfy { $0.isVideo && $0.exif?.country == "Norway" })
    }

    func testSmartSearchWithoutWordsIsBadRequest() async throws {
        let service = MockImmichService(library: library)
        do {
            _ = try await service.smartSearch("  ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(400))
        }
    }

    func testMetadataSearchDateRange() async throws {
        let service = MockImmichService(library: library)
        let calendar = Asset.localCalendar
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2025, month: 7, day: 1))!
        let results = try await service.metadataSearch(
            MetadataSearchQuery(filters: .taken(in: start..<end)), page: nil, size: 1000
        )
        let expected = visibleAssets.filter { $0.takenAt >= start && $0.takenAt < end }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(results.assets.map(\.id), expected.sorted { $0.takenAt > $1.takenAt }.map(\.id))
        XCTAssertNil(results.next)
    }

    func testMetadataSearchCityAndCamera() async throws {
        let service = MockImmichService(library: library)
        let city = try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(city: "Bergen")), page: nil, size: 1000)
        XCTAssertFalse(city.assets.isEmpty)
        XCTAssertTrue(city.assets.allSatisfy { $0.exif?.city == "Bergen" })
        XCTAssertEqual(city.assets.count, visibleAssets.filter { $0.exif?.city == "Bergen" }.count)

        let camera = try await service.metadataSearch(
            MetadataSearchQuery(filters: SearchFilters(make: "SONY", model: "ILCE-7M3"), newestFirst: false), page: nil, size: 1000
        )
        XCTAssertFalse(camera.assets.isEmpty)
        XCTAssertTrue(camera.assets.allSatisfy { $0.exif?.make == "SONY" && $0.exif?.model == "ILCE-7M3" })
        XCTAssertEqual(camera.assets.map(\.takenAt), camera.assets.map(\.takenAt).sorted())

        let none = try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(city: "Atlantis")))
        XCTAssertTrue(none.assets.isEmpty)
        XCTAssertEqual(none.total, 0)
    }

    func testMetadataSearchVisibilityAndPeople() async throws {
        let service = MockImmichService(library: library)
        let archived = try await service.metadataSearch(
            MetadataSearchQuery(filters: SearchFilters(visibility: .archive)), page: nil, size: 1000
        )
        XCTAssertFalse(archived.assets.isEmpty)
        XCTAssertTrue(archived.assets.allSatisfy(\.isArchived))

        let person = try XCTUnwrap(library.people.first)
        let withPerson = try await service.metadataSearch(
            MetadataSearchQuery(filters: SearchFilters(personIds: [person.id])), page: nil, size: 1000
        )
        let expected = Set(library.assets(withPerson: person.id).filter { !$0.isTrashed && !$0.isArchived }.map(\.id))
        XCTAssertEqual(Set(withPerson.assets.map(\.id)), expected)
    }

    func testMetadataSearchFileName() async throws {
        let service = MockImmichService(library: library)
        let target = try XCTUnwrap(visibleAssets.first?.originalFileName)
        let results = try await service.metadataSearch(MetadataSearchQuery(originalFileName: target.lowercased()))
        XCTAssertEqual(results.assets.map(\.originalFileName), [target])
    }

    func testMetadataSearchPagesByCursor() async throws {
        let service = MockImmichService(library: library)
        let query = MetadataSearchQuery(filters: SearchFilters(country: "Norway"))
        let all = try await service.metadataSearch(query, page: nil, size: 1000)
        XCTAssertGreaterThan(all.assets.count, 30)

        var collected: [Asset] = []
        var token: SearchPageToken?
        var pages = 0
        repeat {
            let page = try await service.metadataSearch(query, page: token, size: 30)
            collected += page.assets
            token = page.next
            pages += 1
            if case .page? = token { XCTFail("metadata search pages by cursor") }
        } while token != nil && pages < 100
        XCTAssertEqual(collected.map(\.id), all.assets.map(\.id))
    }

    func testSuggestions() async throws {
        let service = MockImmichService(library: library)
        let countries = try await service.searchSuggestions(.country)
        XCTAssertEqual(countries, ["Denmark", "Japan", "Norway", "Portugal", "United States"])
        let norway = try await service.searchSuggestions(.city, context: SearchSuggestionContext(country: "Norway"))
        XCTAssertEqual(norway, ["Bergen", "Oslo", "Reine"])
        let apple = try await service.searchSuggestions(.cameraModel, context: SearchSuggestionContext(make: "Apple"))
        XCTAssertEqual(apple, ["iPhone 12 mini", "iPhone 15 Pro"])
        let requests = await service.requests
        XCTAssertEqual(requests, [.searchSuggestions(.country), .searchSuggestions(.city), .searchSuggestions(.cameraModel)])
    }

    func testSearchPropagatesFailure() async throws {
        let service = MockImmichService(library: .small)
        await service.setFailure(.unauthorized)
        do {
            _ = try await service.metadataSearch(MetadataSearchQuery())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }

    func testFiltersMatchSemantics() {
        let asset = Asset(
            id: "a", kind: .image, takenAt: Date(timeIntervalSince1970: 1000), isFavorite: true,
            exif: ExifInfo(make: "Apple", model: "iPhone 15 Pro", city: "Oslo", country: "Norway")
        )
        XCTAssertTrue(SearchFilters().matches(asset))
        XCTAssertTrue(SearchFilters(takenAfter: Date(timeIntervalSince1970: 1000), takenBefore: Date(timeIntervalSince1970: 1000)).matches(asset))
        XCTAssertFalse(SearchFilters(takenAfter: Date(timeIntervalSince1970: 1001)).matches(asset))
        XCTAssertFalse(SearchFilters.taken(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 1000)).matches(asset))
        XCTAssertTrue(SearchFilters(city: "Oslo", make: "Apple", isFavorite: true).matches(asset))
        XCTAssertFalse(SearchFilters(city: "Bergen").matches(asset))
        XCTAssertFalse(SearchFilters(kind: .video).matches(asset))
        XCTAssertFalse(SearchFilters(personIds: ["p"]).matches(asset))
        XCTAssertTrue(SearchFilters(personIds: ["p"]).matches(asset, personAssetIDs: ["p": ["a"]]))
        var archived = asset
        archived.isArchived = true
        XCTAssertFalse(SearchFilters().matches(archived))
        XCTAssertTrue(SearchFilters(visibility: nil).matches(archived))
    }
}

/// Records request bodies as well as requests. Returns canned responses per call.
private final class BodyRecordingTransport: ClientTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, Int) -> (Int, String)

    private let lock = NSLock()
    private var _requests: [(HTTPRequest, Data)] = []
    private let handler: Handler

    var requests: [(HTTPRequest, Data)] { lock.withLock { _requests } }

    init(handler: @escaping Handler) { self.handler = handler }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
        let index = lock.withLock { () -> Int in
            _requests.append((request, data))
            return _requests.count - 1
        }
        let (status, text) = handler(request, index)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }

    func jsonBody(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: requests[index].1) as? [String: Any])
    }
}

/// Search through `LiveImmichService` with a stub transport (no network).
final class LiveSearchTests: XCTestCase {
    private func service(_ handler: @escaping BodyRecordingTransport.Handler) throws -> (LiveImmichService, BodyRecordingTransport) {
        let transport = BodyRecordingTransport(handler: handler)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    /// An asset as the v3.4.0 spec describes it.
    private static func assetJSON(_ id: String, type: String = "IMAGE", duration: String = "null") -> String {
        """
        {"id": "\(id)", "checksum": "abc=", "type": "\(type)", "createdAt": "2024-06-02T08:00:00.000Z",
         "fileCreatedAt": "2024-06-01T18:30:00.000Z", "fileModifiedAt": "2024-06-01T18:30:00.000Z",
         "localDateTime": "2024-06-01T20:30:00.000Z", "updatedAt": "2024-06-02T08:00:00.000Z",
         "hasMetadata": true, "isArchived": false, "isEdited": false, "isFavorite": true, "isOffline": false,
         "isTrashed": false, "visibility": "timeline", "originalFileName": "IMG_0001.HEIC",
         "originalMimeType": "image/heic", "originalPath": "/upload/IMG_0001.HEIC", "ownerId": "u1",
         "width": 3024, "height": 4032, "duration": \(duration), "livePhotoVideoId": null, "thumbhash": null,
         "exifInfo": {"make": "Apple", "model": "iPhone 15 Pro", "city": "Oslo", "country": "Norway"}}
        """
    }

    private static func response(_ assets: [String], nextPage: String = "null", nextCursor: String = "null", total: Int? = nil) -> String {
        """
        {"albums": {"total": 0, "count": 0, "items": [], "facets": []},
         "assets": {"total": \(total ?? assets.count), "count": \(assets.count), "items": [\(assets.joined(separator: ","))],
                    "facets": [], "nextPage": \(nextPage), "nextCursor": \(nextCursor)}}
        """
    }

    func testSmartSearchRequestAndResponse() async throws {
        let (service, transport) = try service { _, _ in
            (200, Self.response([Self.assetJSON("a1"), Self.assetJSON("a2", type: "VIDEO", duration: "5000")], nextPage: "\"2\"", total: 250))
        }
        let after = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        let query = SmartSearchQuery(
            text: "dog on a beach",
            filters: SearchFilters(takenAfter: after, city: "Oslo", personIds: ["p1"], kind: .image),
            language: "en"
        )
        let results = try await service.smartSearch(query, page: nil, size: 50)

        XCTAssertEqual(results.assets.map(\.id), ["a1", "a2"])
        XCTAssertEqual(results.assets[1].kind, .video)
        XCTAssertEqual(results.assets[1].duration, 5)
        XCTAssertEqual(results.assets[0].exif?.city, "Oslo")
        XCTAssertEqual(results.total, 250)
        XCTAssertEqual(results.next, .page(2))

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first?.0)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/search/smart")
        XCTAssertEqual(request.headerFields[APIKeyMiddleware.headerName], "k")
        let body = try transport.jsonBody(0)
        XCTAssertEqual(body["query"] as? String, "dog on a beach")
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertEqual(body["size"] as? Int, 50)
        XCTAssertEqual(body["city"] as? String, "Oslo")
        XCTAssertEqual(body["personIds"] as? [String], ["p1"])
        XCTAssertEqual(body["type"] as? String, "IMAGE")
        XCTAssertEqual(body["visibility"] as? String, "timeline")
        let takenAfter = try XCTUnwrap(body["takenAfter"] as? String)
        XCTAssertEqual(ImmichDate.parse(takenAfter), after)
        XCTAssertNil(body["page"], "first page sends no page number")
        XCTAssertNil(body["country"], "unset filters are omitted")
        XCTAssertNil(body["filter"], "uses the flat fields older servers understand")
    }

    func testSmartSearchSendsPageNumber() async throws {
        let (service, transport) = try service { _, _ in (200, Self.response([])) }
        let results = try await service.smartSearch(SmartSearchQuery(text: "cat"), page: .page(3), size: 100)
        XCTAssertTrue(results.assets.isEmpty)
        XCTAssertNil(results.next)
        XCTAssertEqual(try transport.jsonBody(0)["page"] as? Int, 3)
    }

    func testMetadataSearchPrefersCursor() async throws {
        let (service, transport) = try service { _, _ in
            (200, Self.response([Self.assetJSON("a1")], nextPage: "\"2\"", nextCursor: "\"opaque-cursor\""))
        }
        let before = Date(timeIntervalSince1970: 1_719_792_000)
        let query = MetadataSearchQuery(
            filters: SearchFilters(takenBefore: before, make: "Apple", model: "iPhone 15 Pro", visibility: nil),
            originalFileName: "IMG", newestFirst: false, withExif: true
        )
        let results = try await service.metadataSearch(query, page: .cursor("previous"), size: 10)
        XCTAssertEqual(results.assets.map(\.id), ["a1"])
        XCTAssertEqual(results.next, .cursor("opaque-cursor"))

        let request = try XCTUnwrap(transport.requests.first?.0)
        XCTAssertEqual(request.path, "/search/metadata")
        let body = try transport.jsonBody(0)
        XCTAssertEqual(body["cursor"] as? String, "previous")
        XCTAssertNil(body["page"])
        XCTAssertEqual(body["make"] as? String, "Apple")
        XCTAssertEqual(body["model"] as? String, "iPhone 15 Pro")
        XCTAssertEqual(body["originalFileName"] as? String, "IMG")
        XCTAssertEqual(body["order"] as? String, "asc")
        XCTAssertEqual(body["withExif"] as? Bool, true)
        XCTAssertNil(body["visibility"])
        XCTAssertEqual((body["takenBefore"] as? String).flatMap(ImmichDate.parse), before)
    }

    func testMetadataSearchFallsBackToPageNumber() async throws {
        let (service, transport) = try service { _, _ in (200, Self.response([Self.assetJSON("a1")], nextPage: "\"2\"")) }
        let results = try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(city: "Oslo")), page: .page(1), size: 1)
        XCTAssertEqual(results.next, .page(2))
        XCTAssertEqual(try transport.jsonBody(0)["page"] as? Int, 1)
        XCTAssertEqual(try transport.jsonBody(0)["order"] as? String, "desc")
    }

    func testOlderServerResponseFallsBackToLenientDecoding() async throws {
        // An older server: no `isEdited`/`visibility`/`facets`/`nextCursor`, duration as a clock string.
        let old = """
        {"albums": {"total": 0, "count": 0, "items": []},
         "assets": {"total": 1, "count": 1, "nextPage": null, "items": [
           {"id": "v1", "type": "VIDEO", "fileCreatedAt": "2023-05-01T10:00:00.000Z",
            "localDateTime": "2023-05-01T12:00:00.000Z", "isFavorite": false, "isArchived": true,
            "isTrashed": false, "duration": "0:01:05.500", "livePhotoVideoId": null,
            "originalFileName": "MOV_1.MOV", "exifInfo": {"exifImageWidth": 1920, "exifImageHeight": 1080, "city": "Bergen"}}
         ]}}
        """
        let (service, transport) = try service { _, _ in (200, old) }
        let results = try await service.smartSearch(SmartSearchQuery(text: "boat"), page: nil, size: 10)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].0.path, "/search/smart")
        XCTAssertEqual(transport.requests[1].0.headerFields[APIKeyMiddleware.headerName], "k")
        XCTAssertEqual(
            try transport.jsonBody(0) as NSDictionary, try transport.jsonBody(1) as NSDictionary,
            "the fallback sends the same fields"
        )

        let asset = try XCTUnwrap(results.assets.first)
        XCTAssertEqual(asset.id, "v1")
        XCTAssertEqual(asset.kind, .video)
        XCTAssertTrue(asset.isArchived)
        XCTAssertEqual(asset.duration ?? 0, 65.5, accuracy: 0.001)
        XCTAssertEqual(asset.size, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(asset.exif?.city, "Bergen")
        XCTAssertEqual(asset.takenAt, Date(timeIntervalSince1970: 1_682_935_200))
        XCTAssertNil(results.next)
    }

    func testGarbageResponseIsInvalidResponse() async throws {
        let (service, _) = try service { _, _ in (200, #"{"unexpected": true}"#) }
        do {
            _ = try await service.metadataSearch(MetadataSearchQuery())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testSearchUnauthorized() async throws {
        let (service, transport) = try service { _, _ in (401, #"{"message":"Invalid API key"}"#) }
        do {
            _ = try await service.smartSearch("cat")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSuggestions() async throws {
        let (service, transport) = try service { _, _ in (200, #"["Oslo", "", "Bergen", "Oslo"]"#) }
        let cities = try await service.searchSuggestions(.city, context: SearchSuggestionContext(country: "Norway"))
        XCTAssertEqual(cities, ["Oslo", "Bergen"])
        let path = try XCTUnwrap(transport.requests.first?.0.path)
        XCTAssertTrue(path.hasPrefix("/search/suggestions?"), path)
        XCTAssertTrue(path.contains("type=city"), path)
        XCTAssertTrue(path.contains("country=Norway"), path)
        XCTAssertTrue(path.contains("includeNull=false"), path)
    }

    func testLensSuggestionsUseSpecType() async throws {
        let (service, transport) = try service { _, _ in (200, "[]") }
        _ = try await service.searchSuggestions(.lensModel)
        XCTAssertTrue(transport.requests.first?.0.path?.contains("type=camera-lens-model") == true)
    }

    func testClockDurationParsing() {
        XCTAssertEqual(LenientSearch.seconds(fromClock: "0:00:05.000"), 5)
        XCTAssertEqual(LenientSearch.seconds(fromClock: "1:02:03"), 3723)
        XCTAssertNil(LenientSearch.seconds(fromClock: "0:00:00.00000"))
        XCTAssertNil(LenientSearch.seconds(fromClock: "abc"))
    }

    func testNextTokenSelection() {
        XCTAssertEqual(SearchResults.nextToken(cursor: "c", page: "2"), .cursor("c"))
        XCTAssertEqual(SearchResults.nextToken(cursor: nil, page: "2"), .page(2))
        XCTAssertEqual(SearchResults.nextToken(cursor: "", page: nil), nil)
        XCTAssertEqual(SearchResults.nextToken(cursor: nil, page: "x"), nil)
    }
}

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
final class SearchIntegrationTests: XCTestCase {
    private func liveService() throws -> LiveImmichService {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        return LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
    }

    func testMetadataSearchAndSuggestions() async throws {
        let service = try liveService()
        let first = try await service.metadataSearch(MetadataSearchQuery(), page: nil, size: 5)
        XCTAssertLessThanOrEqual(first.assets.count, 5)
        if let next = first.next {
            let second = try await service.metadataSearch(MetadataSearchQuery(), page: next, size: 5)
            XCTAssertTrue(Set(first.assets.map(\.id)).isDisjoint(with: second.assets.map(\.id)))
        }
        let countries = try await service.searchSuggestions(.country)
        if let country = countries.first {
            let results = try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(country: country)), page: nil, size: 5)
            XCTAssertFalse(results.assets.isEmpty)
        }
    }

    func testSmartSearch() async throws {
        let service = try liveService()
        do {
            _ = try await service.smartSearch("photo")
        } catch ImmichServiceError.unexpectedStatus(let status) where status >= 400 && status < 600 && status != 401 && status != 403 {
            throw XCTSkip("smart search unavailable on this server (HTTP \(status)); machine learning may be disabled")
        }
    }
}
