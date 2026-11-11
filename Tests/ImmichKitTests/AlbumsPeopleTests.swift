import Foundation
import HTTPTypes
import XCTest
@testable import ImmichKit

/// Albums and people through the mock service.
final class MockAlbumsPeopleTests: XCTestCase {
    private let library = MockLibrary.standard

    func testListAlbums() async throws {
        let service = MockImmichService(library: library)
        let albums = try await service.albums()
        XCTAssertEqual(albums, library.albums)
        XCTAssertFalse(albums.isEmpty)
        let requests = await service.requests
        XCTAssertEqual(requests, [.albums])
    }

    func testSharedFilter() async throws {
        let service = MockImmichService(library: library)
        let shared = try await service.albums(shared: true)
        let unshared = try await service.albums(shared: false)
        XCTAssertFalse(shared.isEmpty)
        XCTAssertTrue(shared.allSatisfy(\.isShared))
        XCTAssertTrue(unshared.allSatisfy { !$0.isShared })
        XCTAssertEqual(shared.count + unshared.count, library.albums.count)
    }

    func testAlbumByID() async throws {
        let service = MockImmichService(library: library)
        let expected = try XCTUnwrap(library.albums.first)
        let album = try await service.album(id: expected.id)
        XCTAssertEqual(album, expected)
        do {
            _ = try await service.album(id: "missing")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(400))
        }
    }

    func testAlbumAssetsMatchLibraryNewestFirst() async throws {
        let service = MockImmichService(library: library)
        for album in library.albums {
            let assets = try await service.albumAssets(albumID: album.id)
            let expected = library.assets(inAlbum: album.id).filter { !$0.isTrashed }
            XCTAssertEqual(Set(assets.map(\.id)), Set(expected.map(\.id)), album.name)
            XCTAssertEqual(assets.count, expected.count, album.name)
            XCTAssertEqual(assets.map(\.takenAt), assets.map(\.takenAt).sorted(by: >), album.name)
        }
    }

    func testAlbumAssetsOldestFirst() async throws {
        let service = MockImmichService(library: library)
        let album = try XCTUnwrap(library.albums.max { $0.assetCount < $1.assetCount })
        let assets = try await service.albumAssets(albumID: album.id, newestFirst: false)
        XCTAssertGreaterThan(assets.count, 1)
        XCTAssertEqual(assets.map(\.takenAt), assets.map(\.takenAt).sorted())
    }

    func testEmptyAlbumHasNoAssets() async throws {
        let service = MockImmichService(library: library)
        let empty = try XCTUnwrap(library.albums.first { $0.assetCount == 0 })
        let assets = try await service.albumAssets(albumID: empty.id)
        XCTAssertTrue(assets.isEmpty)
        let requests = await service.requests
        XCTAssertEqual(requests, [.timeBuckets], "no bucket requests for an empty album")
    }

    func testAllAssetsLoadsEveryBucketOnce() async throws {
        let service = MockImmichService(library: library)
        let assets = try await service.allAssets(options: .library)
        let expected = library.assets.filter { !$0.isTrashed && !$0.isArchived }
        XCTAssertEqual(assets.map(\.id), expected.map(\.id))
        let buckets = try await service.timeBuckets(options: .library)
        for bucket in buckets {
            let count = await service.requestCount(.timeBucket(bucket.id))
            XCTAssertEqual(count, 1, bucket.id)
        }
    }

    func testAllAssetsPropagatesFailure() async throws {
        let service = MockImmichService(library: .small)
        await service.setFailure(.unauthorized)
        do {
            _ = try await service.allAssets(options: .library)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }

    func testPeopleHidesHiddenByDefault() async throws {
        let service = MockImmichService(library: library)
        let visible = try await service.people()
        let all = try await service.people(withHidden: true)
        XCTAssertEqual(all, library.people)
        XCTAssertTrue(visible.allSatisfy { !$0.isHidden })
        XCTAssertEqual(visible.count, all.count - library.people.filter(\.isHidden).count)
        XCTAssertTrue(all.contains { $0.isHidden })
    }

    func testPersonByID() async throws {
        let service = MockImmichService(library: library)
        let expected = try XCTUnwrap(library.people.first)
        let person = try await service.person(id: expected.id)
        XCTAssertEqual(person, expected)
        do {
            _ = try await service.person(id: "missing")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(400))
        }
    }

    func testPersonAssetsMatchLibrary() async throws {
        let service = MockImmichService(library: library)
        for person in library.people {
            let assets = try await service.personAssets(personID: person.id)
            let expected = library.assets(withPerson: person.id).filter { !$0.isTrashed && !$0.isArchived }
            XCTAssertEqual(Set(assets.map(\.id)), Set(expected.map(\.id)), person.name)
            XCTAssertEqual(assets.count, expected.count, person.name)
            XCTAssertEqual(assets.map(\.takenAt), assets.map(\.takenAt).sorted(by: >), person.name)
        }
        let first = try XCTUnwrap(library.people.first)
        let firstAssets = try await service.personAssets(personID: first.id)
        XCTAssertFalse(firstAssets.isEmpty)
    }

    func testPersonThumbnailIsJPEG() async throws {
        let service = MockImmichService(library: library)
        let person = try XCTUnwrap(library.people.first)
        let data = try await service.personThumbnail(personID: person.id)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(data, MockImmichService.personPlaceholderData(personID: person.id))
        do {
            _ = try await service.personThumbnail(personID: "missing")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(404))
        }
    }

    func testMockWithoutLibraryHasNoAlbumsOrPeople() async throws {
        let service = MockImmichService()
        let albums = try await service.albums()
        let people = try await service.people(withHidden: true)
        XCTAssertTrue(albums.isEmpty)
        XCTAssertTrue(people.isEmpty)
    }

    func testImageLoaderCachesPersonThumbnails() async throws {
        let service = MockImmichService(library: library)
        let loader = ImageLoader(service: service, disk: nil)
        let person = try XCTUnwrap(library.people.first)
        let first = try await loader.personData(personID: person.id)
        let second = try await loader.personData(personID: person.id)
        XCTAssertEqual(first, second)
        let count = await service.requestCount(.personThumbnail(person.id))
        XCTAssertEqual(count, 1)
        let thumbnailCount = await service.requestCount(.thumbnail(person.id, .thumbnail))
        XCTAssertEqual(thumbnailCount, 0)
    }

    func testPersonImageKeyDiffersFromAssetKey() {
        let person = ImageKey.person("x")
        let asset = ImageKey(assetID: "x", size: .thumbnail)
        XCTAssertNotEqual(person, asset)
        XCTAssertNotEqual(person.description, asset.description)
        XCTAssertEqual(person.description, "person-x")
        XCTAssertEqual(asset.description, "x-thumbnail")
    }
}

/// Albums and people through `LiveImmichService` with a stub transport (no network).
final class LiveAlbumsPeopleTests: XCTestCase {
    private func service(_ handler: @escaping RecordingTransport.Handler) throws -> (LiveImmichService, RecordingTransport) {
        let transport = RecordingTransport(handler: handler)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    private static let albumJSON = """
    {
      "id": "al1", "albumName": "Summer", "description": "Holiday", "albumThumbnailAssetId": "a1",
      "albumUsers": [], "assetCount": 42, "createdAt": "2024-07-01T10:00:00.000Z",
      "updatedAt": "2024-07-02T10:00:00.000Z", "startDate": "2024-06-01T08:30:00.123Z",
      "endDate": "2024-06-20T18:00:00.000Z", "hasSharedLink": false, "isActivityEnabled": true,
      "shared": true, "order": "desc"
    }
    """

    private static func personJSON(_ id: String, name: String, hidden: Bool = false) -> String {
        """
        {"id": "\(id)", "name": "\(name)", "isHidden": \(hidden), "isFavorite": false,
         "birthDate": "1990-06-15", "thumbnailPath": "/t/\(id).jpeg", "updatedAt": "2024-01-01T00:00:00.000Z",
         "otherPeople": [], "sharedBy": [], "sharedWith": []}
        """
    }

    func testAlbumsDecodeFractionalSecondDates() async throws {
        let (service, transport) = try service { _ in (200, "application/json", "[\(Self.albumJSON)]") }
        let albums = try await service.albums()
        let album = try XCTUnwrap(albums.first)
        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.name, "Summer")
        XCTAssertEqual(album.assetCount, 42)
        XCTAssertTrue(album.isShared)
        XCTAssertEqual(album.createdAt, Date(timeIntervalSince1970: 1_719_828_000))
        let start = try XCTUnwrap(album.startDate)
        XCTAssertEqual(start.timeIntervalSince1970, 1_717_230_600.123, accuracy: 0.0005)
        XCTAssertEqual(transport.requests.first?.0.path, "/albums")
    }

    func testAlbumsSharedQuery() async throws {
        let (service, transport) = try service { _ in (200, "application/json", "[]") }
        let albums = try await service.albums(shared: true)
        XCTAssertTrue(albums.isEmpty)
        XCTAssertEqual(transport.requests.first?.0.path, "/albums?isShared=true")
    }

    func testAlbumByID() async throws {
        let (service, transport) = try service { _ in (200, "application/json", Self.albumJSON) }
        let album = try await service.album(id: "al1")
        XCTAssertEqual(album.name, "Summer")
        XCTAssertEqual(transport.requests.first?.0.path, "/albums/al1")
    }

    func testAlbumUnauthorized() async throws {
        let (service, _) = try service { _ in (401, "application/json", #"{"message":"Invalid API key"}"#) }
        do {
            _ = try await service.albums()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }

    func testPeoplePaginates() async throws {
        let (service, transport) = try service { request in
            let path = request.path ?? ""
            if path.contains("page=1") {
                let people = [Self.personJSON("p1", name: "Emma"), Self.personJSON("p2", name: "")].joined(separator: ",")
                return (200, "application/json", #"{"people":[\#(people)],"total":3,"hidden":0,"hasNextPage":true}"#)
            } else {
                // A duplicate across pages is dropped.
                let people = [Self.personJSON("p2", name: ""), Self.personJSON("p3", name: "Lars")].joined(separator: ",")
                return (200, "application/json", #"{"people":[\#(people)],"total":3,"hidden":0,"hasNextPage":false}"#)
            }
        }
        let people = try await service.people()
        XCTAssertEqual(people.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(people.first?.birthDate, DateComponents(year: 1990, month: 6, day: 15))
        XCTAssertEqual(people.first?.updatedAt, Date(timeIntervalSince1970: 1_704_067_200))
        XCTAssertEqual(transport.requests.count, 2)
        let firstPath = try XCTUnwrap(transport.requests.first?.0.path)
        XCTAssertTrue(firstPath.hasPrefix("/people?"), firstPath)
        XCTAssertTrue(firstPath.contains("withHidden=false"), firstPath)
        XCTAssertTrue(firstPath.contains("size=500"), firstPath)
        XCTAssertTrue(transport.requests.last?.0.path?.contains("page=2") == true)
    }

    func testPeopleFromOlderServerFallsBackToLenientDecoding() async throws {
        // Older servers omit `otherPeople`, `sharedBy`, `sharedWith` (required in the v3.4.0 spec).
        let body = """
        {"total": 1, "hidden": 1, "people": [
          {"id": "p1", "name": "Emma", "isHidden": true, "birthDate": null, "thumbnailPath": "/t.jpeg",
           "updatedAt": "2024-01-01T00:00:00.000Z"}
        ]}
        """
        let (service, transport) = try service { _ in (200, "application/json", body) }
        let people = try await service.people(withHidden: true)
        XCTAssertEqual(people, [Person(id: "p1", name: "Emma", isHidden: true, updatedAt: Date(timeIntervalSince1970: 1_704_067_200))])
        XCTAssertEqual(transport.requests.count, 2)
        let fallback = try XCTUnwrap(transport.requests.last?.0)
        XCTAssertEqual(fallback.path, "/people?page=1&size=500&withHidden=true")
        XCTAssertEqual(fallback.headerFields[APIKeyMiddleware.headerName], "k")
    }

    func testPersonByIDWithLenientFallback() async throws {
        let (service, transport) = try service { request in
            (200, "application/json", #"{"id":"p9","name":"Noah","isHidden":false}"#)
        }
        let person = try await service.person(id: "p9")
        XCTAssertEqual(person, Person(id: "p9", name: "Noah"))
        XCTAssertEqual(transport.requests.map(\.0.path), ["/people/p9", "/people/p9"])
    }

    func testPersonByID() async throws {
        let (service, transport) = try service { _ in (200, "application/json", Self.personJSON("p1", name: "Emma")) }
        let person = try await service.person(id: "p1")
        XCTAssertEqual(person.name, "Emma")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testPersonThumbnail() async throws {
        let (service, transport) = try service { _ in (200, "application/octet-stream", "JPEGBYTES") }
        let data = try await service.personThumbnail(personID: "p1")
        XCTAssertEqual(data, Data("JPEGBYTES".utf8))
        XCTAssertEqual(transport.requests.first?.0.path, "/people/p1/thumbnail")
    }

    func testPersonThumbnailNotFound() async throws {
        let (service, _) = try service { _ in (404, "application/json", "{}") }
        do {
            _ = try await service.personThumbnail(personID: "p1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(404))
        }
    }
}

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
final class AlbumsPeopleIntegrationTests: XCTestCase {
    private func liveService() throws -> LiveImmichService {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        return LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
    }

    func testListAlbumsAndFirstAlbumAssets() async throws {
        let service = try liveService()
        let albums = try await service.albums()
        guard let album = albums.first(where: { $0.assetCount > 0 }) else {
            throw XCTSkip("server has no non-empty albums")
        }
        let detail = try await service.album(id: album.id)
        XCTAssertEqual(detail.id, album.id)
        let assets = try await service.albumAssets(albumID: album.id)
        XCTAssertFalse(assets.isEmpty)
    }

    func testListPeopleAndThumbnail() async throws {
        let service = try liveService()
        let people = try await service.people()
        guard let person = people.first else { throw XCTSkip("server has no people") }
        let detail = try await service.person(id: person.id)
        XCTAssertEqual(detail.id, person.id)
        let thumbnail = try await service.personThumbnail(personID: person.id)
        XCTAssertFalse(thumbnail.isEmpty)
        _ = try await service.personAssets(personID: person.id)
    }
}
