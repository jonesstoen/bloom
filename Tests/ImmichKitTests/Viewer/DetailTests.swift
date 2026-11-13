import Foundation
import HTTPTypes
import XCTest
@testable import ImmichKit

private var utcCalendar: Calendar { Asset.localCalendar }

/// Map markers, memories and asset detail against the mock library.
final class MockDetailTests: XCTestCase {
    // These tests check the English texts; the Mac running them may be set to Norwegian.
    override func setUp() { super.setUp(); Localization.languageOverride = "en" }
    override func tearDown() { Localization.languageOverride = nil; super.tearDown() }

    private let library = MockLibrary.standard

    // MARK: Asset detail

    func testAssetInfoIncludesExif() async throws {
        let service = MockImmichService(library: library)
        let expected = try XCTUnwrap(library.assets.first { $0.exif?.make != nil })
        let asset = try await service.asset(id: expected.id)
        XCTAssertEqual(asset, expected)
        XCTAssertNotNil(asset.exif?.cameraName)
        let requests = await service.requests
        XCTAssertEqual(requests, [.asset(expected.id)])
    }

    func testSetFavoriteUpdatesTheLibrary() async throws {
        let service = MockImmichService(library: library)
        let asset = try XCTUnwrap(library.assets.first { !$0.isFavorite })
        let updated = try await service.setFavorite(assetID: asset.id, isFavorite: true)
        XCTAssertTrue(updated.isFavorite)
        let fetched = try await service.asset(id: asset.id)
        XCTAssertTrue(fetched.isFavorite)
        let favorites = try await service.allAssets(options: TimelineOptions(isFavorite: true))
        XCTAssertTrue(favorites.contains { $0.id == asset.id })
        _ = try await service.setFavorite(assetID: asset.id, isFavorite: false)
        let reverted = try await service.asset(id: asset.id)
        XCTAssertFalse(reverted.isFavorite)
        await assertThrows(.unexpectedStatus(400)) { _ = try await service.setFavorite(assetID: "nope", isFavorite: true) }
    }

    func testUnknownAssetIsBadRequest() async throws {
        let service = MockImmichService(library: library)
        await assertThrows(.unexpectedStatus(400)) { _ = try await service.asset(id: "nope") }
        await assertThrows(.unexpectedStatus(400)) { _ = try await service.original(assetID: "nope") }
        await assertThrows(.unexpectedStatus(400)) { _ = try await service.mediaRequest(.original, assetID: "nope") }
    }

    func testOriginalIsJPEG() async throws {
        let service = MockImmichService(library: library)
        let asset = try XCTUnwrap(library.assets.first)
        let data = try await service.original(assetID: asset.id)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(data, MockImmichService.placeholderData(assetID: asset.id, size: .preview, aspectRatio: asset.aspectRatio))
    }

    func testMediaRequestsForVideoAndPhoto() async throws {
        let service = MockImmichService(library: library)
        let video = try XCTUnwrap(library.assets.first { $0.isVideo })
        let photo = try XCTUnwrap(library.assets.first { $0.kind == .image && !$0.isLivePhoto })

        let playback = try await service.mediaRequest(.videoPlayback, assetID: video.id)
        XCTAssertEqual(playback.kind, .videoPlayback)
        XCTAssertEqual(playback.assetID, video.id)
        XCTAssertTrue(playback.url.absoluteString.hasSuffix("/assets/\(video.id)/video/playback"))
        XCTAssertTrue(playback.headers.isEmpty)

        let original = try await service.mediaRequest(.original, assetID: photo.id)
        XCTAssertTrue(original.url.absoluteString.hasSuffix("/assets/\(photo.id)/original"))

        await assertThrows(.unexpectedStatus(400)) { _ = try await service.mediaRequest(.videoPlayback, assetID: photo.id) }

        let videoRequest = try await service.playbackRequest(for: video)
        XCTAssertEqual(videoRequest, playback)
        let photoRequest = try await service.playbackRequest(for: photo)
        XCTAssertNil(photoRequest)
    }

    func testLivePhotoPlaysItsMotionPart() async throws {
        let service = MockImmichService(library: library)
        let live = try XCTUnwrap(library.assets.first { $0.isLivePhoto })
        let request = try await service.playbackRequest(for: live)
        XCTAssertEqual(request?.assetID, live.livePhotoVideoId)
        XCTAssertEqual(request?.kind, .videoPlayback)
    }

    // MARK: Map

    func testMapMarkersMatchLibrary() async throws {
        let service = MockImmichService(library: library)
        let markers = try await service.mapMarkers()
        XCTAssertFalse(markers.isEmpty)
        XCTAssertEqual(markers, library.mapMarkers)
        for marker in markers {
            let asset = try XCTUnwrap(library.asset(id: marker.assetId))
            XCTAssertFalse(asset.isArchived || asset.isTrashed)
            XCTAssertEqual(asset.exif?.latitude, marker.latitude)
            XCTAssertEqual(asset.exif?.longitude, marker.longitude)
            XCTAssertEqual(asset.exif?.city, marker.city)
        }
        let requests = await service.requests
        XCTAssertEqual(requests, [.mapMarkers])
    }

    func testMapMarkerFilters() async throws {
        let service = MockImmichService(library: library)
        let all = try await service.mapMarkers()

        let favorites = try await service.mapMarkers(MapMarkerOptions(isFavorite: true))
        XCTAssertFalse(favorites.isEmpty)
        XCTAssertLessThan(favorites.count, all.count)
        XCTAssertTrue(favorites.allSatisfy { library.asset(id: $0.id)?.isFavorite == true })

        let after = utcCalendar.date(byAdding: .year, value: -1, to: library.referenceDate)!
        let recent = try await service.mapMarkers(MapMarkerOptions(takenAfter: after))
        XCTAssertFalse(recent.isEmpty)
        XCTAssertLessThan(recent.count, all.count)
        XCTAssertTrue(recent.allSatisfy { library.asset(id: $0.id)!.takenAt >= after })

        let withArchived = try await service.mapMarkers(MapMarkerOptions(includeArchived: true))
        XCTAssertTrue(Set(all.map(\.id)).isSubset(of: Set(withArchived.map(\.id))))
        XCTAssertTrue(withArchived.allSatisfy { library.asset(id: $0.id)?.isTrashed == false })
    }

    func testMapMarkerOptionsSemantics() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = Asset(id: "a", kind: .image, takenAt: now, isFavorite: true)
        XCTAssertTrue(MapMarkerOptions().matches(asset))
        XCTAssertFalse(MapMarkerOptions(isFavorite: false).matches(asset))
        XCTAssertFalse(MapMarkerOptions(takenAfter: now.addingTimeInterval(1)).matches(asset))
        XCTAssertFalse(MapMarkerOptions(takenBefore: now.addingTimeInterval(-1)).matches(asset))
        XCTAssertTrue(MapMarkerOptions(takenAfter: now, takenBefore: now).matches(asset))

        let archived = Asset(id: "b", kind: .image, takenAt: now, isArchived: true)
        XCTAssertFalse(MapMarkerOptions().matches(archived))
        XCTAssertTrue(MapMarkerOptions(includeArchived: true).matches(archived))
        let trashed = Asset(id: "c", kind: .image, takenAt: now, isTrashed: true)
        XCTAssertFalse(MapMarkerOptions(includeArchived: true).matches(trashed))
    }

    // MARK: Memories

    func testOnThisDayMemories() async throws {
        let service = MockImmichService(library: library)
        let memories = try await service.memories(on: library.referenceDate, calendar: utcCalendar)
        XCTAssertFalse(memories.isEmpty)
        XCTAssertEqual(memories.map(\.year), memories.map(\.year).sorted(by: >), "newest year first")
        let today = utcCalendar.dateComponents([.year, .month, .day], from: library.referenceDate)
        for memory in memories {
            XCTAssertEqual(memory.kind, .onThisDay(year: memory.year))
            XCTAssertLessThan(memory.year, today.year!)
            XCTAssertFalse(memory.assets.isEmpty)
            for asset in memory.assets {
                let day = utcCalendar.dateComponents([.year, .month, .day], from: asset.localDateTime)
                XCTAssertEqual(day, DateComponents(year: memory.year, month: today.month, day: today.day))
            }
        }
        XCTAssertEqual(memories.first?.title(now: library.referenceDate, calendar: utcCalendar), "1 year ago")
    }

    func testNoMemoriesOnOtherDays() async throws {
        let service = MockImmichService(library: library)
        let otherDay = utcCalendar.date(byAdding: .day, value: 3, to: library.referenceDate)!
        let memories = try await service.memories(on: otherDay, calendar: utcCalendar)
        XCTAssertTrue(memories.isEmpty)
    }

    func testMemoryQueryFilters() async throws {
        let service = MockImmichService(library: library)
        let all = try await service.memories(MemoryQuery())
        XCTAssertEqual(all.count, library.memories.count)
        let birthdays = try await service.memories(MemoryQuery(kind: .birthday))
        XCTAssertTrue(birthdays.isEmpty)
        let saved = try await service.memories(MemoryQuery(isSaved: true))
        XCTAssertTrue(saved.isEmpty)
        let onThisDay = try await service.memories(MemoryQuery(kind: .onThisDay))
        XCTAssertEqual(onThisDay.count, all.count)
    }

    func testMemoryQueryDay() {
        let query = MemoryQuery.shown(on: Date(timeIntervalSince1970: 1_781_524_800), calendar: utcCalendar)
        XCTAssertEqual(query.dayString, "2026-06-15")
        XCTAssertEqual(MemoryQuery(day: DateComponents(year: 999, month: 1, day: 2)).dayString, "0999-01-02")
        XCTAssertNil(MemoryQuery(day: DateComponents(year: 2026, month: 6)).dayString)
        XCTAssertNil(MemoryQuery().dayString)

        let start = Date(timeIntervalSince1970: 1_781_481_600) // 2026-06-15T00:00Z
        let memory = Memory(id: "m", kind: .onThisDay(year: 2020), memoryAt: start, showAt: start,
                            hideAt: start.addingTimeInterval(86_400), assets: [])
        XCTAssertTrue(MemoryQuery(day: DateComponents(year: 2026, month: 6, day: 15)).matches(memory))
        XCTAssertFalse(MemoryQuery(day: DateComponents(year: 2026, month: 6, day: 14)).matches(memory))
        XCTAssertFalse(MemoryQuery(day: DateComponents(year: 2026, month: 6, day: 16)).matches(memory))
    }

    func testMockWithoutLibraryHasNoMemories() async throws {
        let service = MockImmichService()
        let memories = try await service.memories(MemoryQuery())
        XCTAssertTrue(memories.isEmpty)
    }

    func testDetailPropagatesFailure() async throws {
        let service = MockImmichService(library: library)
        await service.setFailure(.unauthorized)
        await assertThrows(.unauthorized) { _ = try await service.mapMarkers() }
        await assertThrows(.unauthorized) { _ = try await service.memories(MemoryQuery()) }
        await assertThrows(.unauthorized) { _ = try await service.asset(id: self.library.assets[0].id) }
    }

    // MARK: MediaRequest

    func testMediaRequestRedactsHeaders() throws {
        let secret = "super-secret-key"
        let request = MediaRequest(
            kind: .original, assetID: "a1",
            url: URL(string: "https://photos.example.com/api/assets/a1/original")!,
            headers: ["x-api-key": secret]
        )
        XCTAssertFalse(request.description.contains(secret))
        XCTAssertFalse(String(reflecting: request).contains(secret))
        XCTAssertFalse("\(request)".contains(secret))
        XCTAssertTrue(request.description.contains("x-api-key"))
        XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "x-api-key"), secret)
        // Playback never hands the key or the real address to AVFoundation (GuardedMediaAsset).
        let asset = GuardedMediaAsset(request: request)
        XCTAssertEqual(asset.url.scheme, GuardedMediaAsset.scheme)
        XCTAssertFalse(asset.url.absoluteString.contains("photos.example.com"))
    }
}

/// Asset detail, map and memories through `LiveImmichService` with a stub transport (no network).
final class LiveDetailTests: XCTestCase {
    private func service(_ handler: @escaping RecordingTransport.Handler) throws -> (LiveImmichService, RecordingTransport) {
        let transport = RecordingTransport(handler: handler)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    func testSetFavoriteSendsPutThenReadsTheAsset() async throws {
        let (service, transport) = try service { _ in (200, "application/json", Self.assetJSON("a1")) }
        let asset = try await service.setFavorite(assetID: "a1", isFavorite: true)
        XCTAssertTrue(asset.isFavorite)
        let requests = transport.requests.map(\.0)
        XCTAssertEqual(requests.first?.method, .put)
        XCTAssertEqual(requests.first?.path, "/assets/a1")
        XCTAssertEqual(requests.first?.headerFields[.contentType], "application/json; charset=utf-8")
        XCTAssertEqual(requests.last?.method, .get)
    }

    func testSetFavoriteMapsUnauthorized() async throws {
        let (service, _) = try service { _ in (403, "application/json", "{}") }
        do {
            _ = try await service.setFavorite(assetID: "a1", isFavorite: true)
            XCTFail("Expected an error")
        } catch let error as ImmichServiceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    /// An asset as the v3.4.0 spec describes it.
    private static func assetJSON(_ id: String, type: String = "IMAGE", livePhoto: String = "null") -> String {
        """
        {"id": "\(id)", "checksum": "abc=", "type": "\(type)", "createdAt": "2024-06-02T08:00:00.000Z",
         "fileCreatedAt": "2024-06-01T18:30:00.000Z", "fileModifiedAt": "2024-06-01T18:30:00.000Z",
         "localDateTime": "2024-06-01T20:30:00.000Z", "updatedAt": "2024-06-02T08:00:00.000Z",
         "hasMetadata": true, "isArchived": false, "isEdited": false, "isFavorite": true, "isOffline": false,
         "isTrashed": false, "visibility": "timeline", "originalFileName": "IMG_0001.HEIC",
         "originalMimeType": "image/heic", "originalPath": "/upload/IMG_0001.HEIC", "ownerId": "u1",
         "width": 3024, "height": 4032, "duration": 0, "livePhotoVideoId": \(livePhoto), "thumbhash": null,
         "exifInfo": {"make": "Apple", "model": "iPhone 15 Pro", "fNumber": 1.78, "iso": 64,
                      "exposureTime": "1/250", "latitude": 59.91, "longitude": 10.75,
                      "city": "Oslo", "country": "Norway", "fileSizeInByte": 2456789}}
        """
    }

    func testAssetInfo() async throws {
        let (service, transport) = try service { _ in (200, "application/json", Self.assetJSON("a1", livePhoto: "\"v1\"")) }
        let asset = try await service.asset(id: "a1")
        XCTAssertEqual(asset.id, "a1")
        XCTAssertTrue(asset.isFavorite)
        XCTAssertEqual(asset.livePhotoVideoId, "v1")
        XCTAssertEqual(asset.exif?.cameraName, "Apple iPhone 15 Pro")
        XCTAssertEqual(asset.exif?.fNumber, 1.78)
        XCTAssertEqual(asset.exif?.exposureTime, "1/250")
        XCTAssertEqual(asset.exif?.fileSizeInBytes, 2_456_789)
        XCTAssertEqual(asset.exif?.locationName, "Oslo, Norway")
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first?.0)
        XCTAssertEqual(request.path, "/assets/a1")
        XCTAssertEqual(request.headerFields[APIKeyMiddleware.headerName], "k")
    }

    func testAssetInfoFromOlderServerFallsBackToLenientDecoding() async throws {
        let old = """
        {"id": "a1", "type": "VIDEO", "fileCreatedAt": "2023-05-01T10:00:00.000Z",
         "localDateTime": "2023-05-01T12:00:00.000Z", "isFavorite": false, "isArchived": false,
         "isTrashed": false, "duration": "0:00:12.000", "originalFileName": "MOV_1.MOV",
         "exifInfo": {"make": "Sony", "city": "Bergen"}}
        """
        let (service, transport) = try service { _ in (200, "application/json", old) }
        let asset = try await service.asset(id: "a1")
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.duration, 12)
        XCTAssertEqual(asset.exif?.city, "Bergen")
        XCTAssertEqual(transport.requests.map(\.0.path), ["/assets/a1", "/assets/a1"])
        XCTAssertEqual(transport.requests[1].0.headerFields[APIKeyMiddleware.headerName], "k")
    }

    func testAssetNotFound() async throws {
        let (service, _) = try service { _ in (400, "application/json", #"{"message":"Not found or no asset.read access"}"#) }
        do {
            _ = try await service.asset(id: "a1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(400))
        }
    }

    func testOriginalAcceptsRealMediaType() async throws {
        let (service, transport) = try service { _ in (200, "image/heic", "HEICBYTES") }
        let data = try await service.original(assetID: "a1")
        XCTAssertEqual(data, Data("HEICBYTES".utf8))
        XCTAssertEqual(transport.requests.first?.0.path, "/assets/a1/original")
    }

    func testThumbnailsAcceptRealMediaTypes() async throws {
        // The server labels thumbnails `image/jpeg`/`image/webp`, not the spec's `application/octet-stream`.
        let (service, _) = try service { request in
            (200, request.path?.contains("people") == true ? "image/jpeg" : "image/webp", "IMG")
        }
        let thumbnail = try await service.thumbnail(assetID: "a1", size: .thumbnail)
        XCTAssertEqual(thumbnail, Data("IMG".utf8))
        let face = try await service.personThumbnail(personID: "p1")
        XCTAssertEqual(face, Data("IMG".utf8))
    }

    func testHTMLInsteadOfImageIsInvalidResponse() async throws {
        let (service, _) = try service { _ in (200, "text/html; charset=utf-8", "<html></html>") }
        do {
            _ = try await service.thumbnail(assetID: "a1", size: .preview)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testBinaryContentTypeClassification() {
        XCTAssertTrue(BinaryContentTypeMiddleware.isMedia(nil))
        XCTAssertTrue(BinaryContentTypeMiddleware.isMedia("image/jpeg"))
        XCTAssertTrue(BinaryContentTypeMiddleware.isMedia("video/mp4"))
        XCTAssertTrue(BinaryContentTypeMiddleware.isMedia("application/octet-stream"))
        XCTAssertFalse(BinaryContentTypeMiddleware.isMedia("application/json; charset=utf-8"))
        XCTAssertFalse(BinaryContentTypeMiddleware.isMedia("text/html"))
        XCTAssertFalse(BinaryContentTypeMiddleware.isMedia("application/problem+json"))
    }

    func testMediaRequests() async throws {
        let (service, transport) = try service { _ in (500, "application/json", "{}") }
        let playback = try await service.mediaRequest(.videoPlayback, assetID: "v1")
        XCTAssertEqual(playback.url.absoluteString, "https://photos.example.com/api/assets/v1/video/playback")
        XCTAssertEqual(playback.headers, ["x-api-key": "k"])
        XCTAssertEqual(playback.urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        let original = try await service.mediaRequest(.original, assetID: "a1")
        XCTAssertEqual(original.url.absoluteString, "https://photos.example.com/api/assets/a1/original")
        XCTAssertFalse(original.description.contains("\"k\""))
        XCTAssertTrue(transport.requests.isEmpty, "building a media request does not contact the server")
        // IDs come from the server; they stay one escaped segment and can't reach another endpoint.
        let hostile = try await service.mediaRequest(.original, assetID: "x/../../users/me?y#z")
        XCTAssertEqual(hostile.url.absoluteString, "https://photos.example.com/api/assets/x%2F..%2F..%2Fusers%2Fme%3Fy%23z/original")
        let dots = try await service.mediaRequest(.videoPlayback, assetID: "..")
        XCTAssertEqual(dots.url.absoluteString, "https://photos.example.com/api/assets/%2E%2E/video/playback")
        XCTAssertEqual(LiveImmichService.pathComponent("."), "%2E")

        let live = Asset(id: "a1", kind: .image, takenAt: Date(), livePhotoVideoId: "motion")
        let liveRequest = try await service.playbackRequest(for: live)
        XCTAssertEqual(liveRequest?.url.lastPathComponent, "playback")
        XCTAssertEqual(liveRequest?.assetID, "motion")
    }

    func testMapMarkers() async throws {
        let body = """
        [{"id": "a1", "lat": 59.9139, "lon": 10.7522, "city": "Oslo", "state": null, "country": "Norway"}]
        """
        let (service, transport) = try service { _ in (200, "application/json", body) }
        let markers = try await service.mapMarkers(MapMarkerOptions(
            isFavorite: true, takenAfter: Date(timeIntervalSince1970: 1_704_067_200)
        ))
        XCTAssertEqual(markers, [MapMarker(id: "a1", latitude: 59.9139, longitude: 10.7522, city: "Oslo", country: "Norway")])
        let path = try XCTUnwrap(transport.requests.first?.0.path)
        XCTAssertTrue(path.hasPrefix("/map/markers?"), path)
        XCTAssertTrue(path.contains("isFavorite=true"), path)
        XCTAssertTrue(path.contains("fileCreatedAfter=2024-01-01"), path)
        XCTAssertFalse(path.contains("isArchived"), path)
    }

    func testMapMarkersWithoutOptionsSendNoQuery() async throws {
        let (service, transport) = try service { _ in (200, "application/json", "[]") }
        let markers = try await service.mapMarkers()
        XCTAssertTrue(markers.isEmpty)
        XCTAssertEqual(transport.requests.first?.0.path, "/map/markers")
    }

    private static func memoryJSON(_ id: String, type: String = "on_this_day", year: Int, assets: [String]) -> String {
        """
        {"id": "\(id)", "type": "\(type)", "data": {"year": \(year)},
         "memoryAt": "\(year)-06-15T00:00:00.000Z", "showAt": "2026-06-15T00:00:00.000Z",
         "hideAt": "2026-06-16T00:00:00.000Z", "createdAt": "2026-06-15T00:00:00.000Z",
         "updatedAt": "2026-06-15T00:00:00.000Z", "isSaved": false, "ownerId": "u1",
         "assets": [\(assets.joined(separator: ","))]}
        """
    }

    func testMemoriesOnDay() async throws {
        let body = "[" + [
            Self.memoryJSON("m1", year: 2022, assets: [Self.assetJSON("a1")]),
            Self.memoryJSON("m2", year: 2025, assets: [Self.assetJSON("a2")]),
            Self.memoryJSON("m3", year: 2024, assets: []),
        ].joined(separator: ",") + "]"
        let (service, transport) = try service { _ in (200, "application/json", body) }
        let memories = try await service.memories(on: Date(timeIntervalSince1970: 1_781_524_800), calendar: utcCalendar)
        XCTAssertEqual(memories.map(\.id), ["m2", "m1"], "newest year first, empty memories dropped")
        XCTAssertEqual(memories.first?.assets.map(\.id), ["a2"])
        XCTAssertEqual(transport.requests.first?.0.path, "/memories?for=2026-06-15")
    }

    func testMemoriesQueryParameters() async throws {
        let (service, transport) = try service { _ in (200, "application/json", "[]") }
        _ = try await service.memories(MemoryQuery(isSaved: true, kind: .birthday))
        let path = try XCTUnwrap(transport.requests.first?.0.path)
        XCTAssertTrue(path.contains("isSaved=true"), path)
        XCTAssertTrue(path.contains("type=birthday"), path)
        XCTAssertFalse(path.contains("for="), path)
    }

    func testMemoriesFromOlderOrNewerServerFallBackToLenientDecoding() async throws {
        // Old assets (no `isEdited`/`visibility`) and an unknown memory type from a newer server.
        let body = """
        [{"id": "m1", "type": "on_this_day", "data": {"year": 2021}, "memoryAt": "2021-06-15T00:00:00.000Z",
          "isSaved": false, "assets": [{"id": "a1", "type": "IMAGE", "fileCreatedAt": "2021-06-15T10:00:00.000Z",
          "isFavorite": false, "isTrashed": false}]},
         {"id": "m2", "type": "trip", "data": {"year": 2020}, "memoryAt": "2020-06-15T00:00:00.000Z",
          "isSaved": false, "assets": []}]
        """
        let (service, transport) = try service { _ in (200, "application/json", body) }
        let memories = try await service.memories(MemoryQuery(day: DateComponents(year: 2026, month: 6, day: 15)))
        XCTAssertEqual(memories.map(\.id), ["m1"])
        XCTAssertEqual(memories.first?.kind, .onThisDay(year: 2021))
        XCTAssertEqual(memories.first?.assets.map(\.id), ["a1"])
        XCTAssertEqual(transport.requests.map(\.0.path), ["/memories?for=2026-06-15", "/memories?for=2026-06-15"])
        XCTAssertEqual(transport.requests[1].0.headerFields[APIKeyMiddleware.headerName], "k")
    }

    func testMemoriesUnauthorized() async throws {
        let (service, _) = try service { _ in (401, "application/json", #"{"message":"Invalid API key"}"#) }
        do {
            _ = try await service.memories(MemoryQuery())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }
}

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
final class DetailIntegrationTests: XCTestCase {
    private func liveService() throws -> LiveImmichService {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        return LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
    }

    func testMapMarkersAndAssetDetail() async throws {
        let service = try liveService()
        let markers = try await service.mapMarkers()
        guard let marker = markers.first else { throw XCTSkip("server has no geotagged assets") }
        let asset = try await service.asset(id: marker.assetId)
        XCTAssertEqual(asset.id, marker.assetId)
        XCTAssertNotNil(asset.exif?.latitude)
        let preview = try await service.thumbnail(assetID: asset.id, size: .preview)
        XCTAssertFalse(preview.isEmpty)
    }

    func testMemories() async throws {
        let service = try liveService()
        let memories = try await service.memories(MemoryQuery())
        for memory in memories.prefix(3) {
            XCTAssertFalse(memory.id.isEmpty)
        }
        _ = try await service.memories(on: Date())
    }
}

private func assertThrows(
    _ expected: ImmichServiceError,
    file: StaticString = #filePath, line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ImmichServiceError, expected, file: file, line: line)
    }
}
