import Foundation
import HTTPTypes
import ImmichAPI
import XCTest
@testable import ImmichKit

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func asset(
    _ id: String, _ date: Date, favorite: Bool = false, archived: Bool = false, trashed: Bool = false
) -> Asset {
    Asset(id: id, kind: .image, takenAt: date, isFavorite: favorite, isArchived: archived, isTrashed: trashed)
}

final class ImmichDateTests: XCTestCase {
    func testParsesServerTimestampVariants() throws {
        let base = utc(2024, 1, 15, 10, 30)
        let cases: [(String, TimeInterval)] = [
            ("2024-01-15T10:30:00Z", 0),
            ("2024-01-15T10:30:00.000Z", 0),
            ("2024-01-15T10:30:00.5Z", 0.5),
            ("2024-01-15T10:30:00.123+00:00", 0.123),
            ("2024-01-15T10:30:00.123456+00:00", 0.123456),
            ("2024-01-15T12:30:00+02:00", 0),
            ("2024-01-15T05:30:00.250-05:00", 0.25),
            ("2024-01-15T10:30:00", 0),
            ("2024-01-15 10:30:00+00:00", 0),
        ]
        for (text, fraction) in cases {
            let date = try XCTUnwrap(ImmichDate.parse(text), text)
            XCTAssertEqual(date.timeIntervalSince(base), fraction, accuracy: 0.000_01, text)
        }
    }

    func testRejectsGarbage() {
        for text in ["", "2024-01-15", "yesterday", "2024-13-45T99:99:99Z"] {
            XCTAssertNil(ImmichDate.parse(text), text)
        }
    }
}

final class TimeBucketMappingTests: XCTestCase {
    /// Shape of `GET /timeline/bucket` per `TimeBucketAssetResponseDto` in the v3.4.0 spec.
    static let bucketJSON = #"""
    {
      "id": ["a1", "a2", "a3"],
      "ownerId": ["u", "u", "u"],
      "fileCreatedAt": ["2024-03-07T22:30:00.000Z", "2024-03-07T08:00:00.000+00:00", "2024-03-01T12:00:00Z"],
      "localOffsetHours": [2, -5.5, 0],
      "createdAt": ["2024-03-08T00:00:00Z", "2024-03-08T00:00:00Z", "2024-03-08T00:00:00Z"],
      "duration": [null, 12500, 0],
      "isFavorite": [true, false, false],
      "isImage": [true, false, true],
      "isTrashed": [false, false, false],
      "livePhotoVideoId": ["lp1", null, ""],
      "projectionType": [null, null, "EQUIRECTANGULAR"],
      "ratio": [1.5, 0.5625, 1],
      "thumbhash": ["abc", null, "def"],
      "visibility": ["timeline", "archive", "timeline"],
      "city": ["Oslo", null, null],
      "country": ["Norway", null, null],
      "latitude": [59.91, null, null],
      "longitude": [10.75, null, null],
      "stack": [null, null, null]
    }
    """#

    func testMapsColumnsToAssets() throws {
        let dto = try JSONDecoder().decode(
            Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(Self.bucketJSON.utf8)
        )
        let assets = try Asset.assets(from: dto)
        XCTAssertEqual(assets.map(\.id), ["a1", "a2", "a3"])

        let a1 = assets[0]
        XCTAssertEqual(a1.kind, .image)
        XCTAssertEqual(a1.takenAt, utc(2024, 3, 7, 22, 30))
        XCTAssertEqual(a1.localDateTime, utc(2024, 3, 8, 0, 30), "offset +2h moves it to the next local day")
        XCTAssertTrue(a1.isFavorite)
        XCTAssertEqual(a1.livePhotoVideoId, "lp1")
        XCTAssertTrue(a1.isLivePhoto)
        XCTAssertEqual(a1.aspectRatio, 1.5)
        XCTAssertEqual(a1.thumbhash, "abc")
        XCTAssertEqual(a1.exif?.city, "Oslo")
        XCTAssertEqual(a1.exif?.locationName, "Oslo, Norway")
        XCTAssertEqual(a1.exif?.latitude, 59.91)
        XCTAssertNil(a1.duration)

        let a2 = assets[1]
        XCTAssertEqual(a2.kind, .video)
        XCTAssertEqual(a2.duration, 12.5)
        XCTAssertTrue(a2.isArchived)
        XCTAssertEqual(a2.localDateTime, utc(2024, 3, 7, 2, 30))
        XCTAssertNil(a2.exif)
        XCTAssertEqual(a2.aspectRatio, 0.5625)

        let a3 = assets[2]
        XCTAssertNil(a3.livePhotoVideoId, "empty string means no live photo")
        XCTAssertNil(a3.duration)
        XCTAssertEqual(a3.exif?.projectionType, "EQUIRECTANGULAR")
    }

    func testMismatchedColumnsAreInvalidResponse() throws {
        var dto = try JSONDecoder().decode(
            Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(Self.bucketJSON.utf8)
        )
        dto.ratio.removeLast()
        XCTAssertThrowsError(try Asset.assets(from: dto)) { error in
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testShortProjectionColumnIsInvalidResponseNotACrash() throws {
        var dto = try JSONDecoder().decode(
            Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(Self.bucketJSON.utf8)
        )
        dto.projectionType = []
        XCTAssertThrowsError(try Asset.assets(from: dto)) { error in
            XCTAssertEqual(error as? ImmichServiceError, .invalidResponse)
        }
    }

    func testBadTimestampIsInvalidResponse() throws {
        var dto = try JSONDecoder().decode(
            Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(Self.bucketJSON.utf8)
        )
        dto.fileCreatedAt[1] = "not a date"
        XCTAssertThrowsError(try Asset.assets(from: dto))
    }

    func testBucketKeyParsing() {
        XCTAssertEqual(TimeBucket(key: "2024-03-01", count: 4), TimeBucket(id: "2024-03-01", year: 2024, month: 3, count: 4))
        XCTAssertEqual(TimeBucket(key: "2023-12-01T00:00:00.000Z", count: 1)?.month, 12)
        XCTAssertNil(TimeBucket(key: "2024-13-01", count: 1))
        XCTAssertNil(TimeBucket(key: "garbage", count: 1))
        XCTAssertNil(TimeBucket(key: "2024-03-01", count: -1), "negative counts would break the grid index")
        XCTAssertNil(TimeBucket(key: "2024-03-01", count: Int.max), "huge counts would overflow sums")
        XCTAssertNil(TimeBucket(key: "0000-03-01", count: 1))
        XCTAssertNil(TimeBucket(key: "99999999-03-01", count: 1))
        XCTAssertNotNil(TimeBucket(key: "2024-03-01", count: TimeBucket.maxAssets))
        XCTAssertEqual(TimeBucket.key(year: 987, month: 7), "0987-07-01")
        XCTAssertEqual(TimeBucket(id: "x", year: 2024, month: 2, count: 0).startDate, utc(2024, 2, 1, 0))
    }
}

final class LiveTimelineRequestTests: XCTestCase {
    private func service(_ handler: @escaping RecordingTransport.Handler) throws -> (LiveImmichService, RecordingTransport) {
        let transport = RecordingTransport(handler: handler)
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        return (LiveImmichService(credentials: credentials, transport: transport), transport)
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let components = URLComponents(string: "https://x" + (request.path ?? ""))
        return Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testTimeBucketsRequestAndDecoding() async throws {
        let (service, transport) = try service { _ in
            (200, "application/json", #"[{"timeBucket":"2024-03-01","count":12},{"timeBucket":"2024-01-01","count":3}]"#)
        }
        let buckets = try await service.timeBuckets(options: .library)
        XCTAssertEqual(buckets, [
            TimeBucket(id: "2024-03-01", year: 2024, month: 3, count: 12),
            TimeBucket(id: "2024-01-01", year: 2024, month: 1, count: 3),
        ])
        let request = try XCTUnwrap(transport.requests.first?.0)
        XCTAssertTrue(request.path?.hasPrefix("/timeline/buckets") ?? false, request.path ?? "")
        let q = query(request)
        XCTAssertEqual(q["order"], "desc")
        XCTAssertEqual(q["visibility"], "timeline")
        XCTAssertEqual(q["withStacked"], "true")
        XCTAssertNil(q["albumId"])
    }

    func testHostileBucketCountsAreRejected() async throws {
        let half = Int.max / 2 + 1
        for body in [#"[{"timeBucket":"2024-03-01","count":\#(half)},{"timeBucket":"2024-01-01","count":\#(half)}]"#,
                     #"[{"timeBucket":"2024-03-01","count":-5}]"#,
                     #"[{"timeBucket":"2024-03-01","count":4000000},{"timeBucket":"2024-01-01","count":4000000}]"#] {
            let (service, _) = try service { _ in (200, "application/json", body) }
            do {
                _ = try await service.timeBuckets(options: .library)
                XCTFail("accepted \(body)")
            } catch {
                XCTAssertEqual(error as? ImmichServiceError, .invalidResponse, body)
            }
        }
    }

    func testTimeBucketRequestPassesKeyAndFilters() async throws {
        let (service, transport) = try service { _ in
            (200, "application/json", TimeBucketMappingTests.bucketJSON)
        }
        let options = TimelineOptions(albumId: "album-1", isFavorite: true, visibility: nil, newestFirst: false)
        let assets = try await service.timeBucketAssets(bucketID: "2024-03-01", options: options)
        XCTAssertEqual(assets.count, 3)
        let request = try XCTUnwrap(transport.requests.first?.0)
        XCTAssertTrue(request.path?.hasPrefix("/timeline/bucket?") ?? false, request.path ?? "")
        let q = query(request)
        XCTAssertEqual(q["timeBucket"], "2024-03-01")
        XCTAssertEqual(q["albumId"], "album-1")
        XCTAssertEqual(q["isFavorite"], "true")
        XCTAssertEqual(q["order"], "asc")
        XCTAssertNil(q["visibility"])
    }

    func testSortByDateAddedSendsOrderByCreatedAt() async throws {
        let (service, transport) = try service { request in
            request.path?.hasPrefix("/timeline/buckets") == true
                ? (200, "application/json", #"[{"timeBucket":"2024-03-01","count":3}]"#)
                : (200, "application/json", TimeBucketMappingTests.bucketJSON)
        }
        var options = TimelineOptions.library
        options.sortsByDateAdded = true
        _ = try await service.timeBuckets(options: options)
        _ = try await service.timeBucketAssets(bucketID: "2024-03-01", options: options)
        for request in transport.requests.map(\.0) {
            XCTAssertEqual(query(request)["orderBy"], "createdAt", request.path ?? "")
        }
        // By default the server's order (date taken) is used: no orderBy parameter.
        _ = try await service.timeBuckets(options: .library)
        XCTAssertNil(query(try XCTUnwrap(transport.requests.last?.0))["orderBy"])
    }

    func testTimeBucketsUnauthorized() async throws {
        let (service, _) = try service { _ in (401, "application/json", "{}") }
        do {
            _ = try await service.timeBuckets(options: .library)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unauthorized)
        }
    }
}

final class TimelineGroupingTests: XCTestCase {
    func testGroupsByLocalDayNewestFirst() {
        let assets = [
            asset("early", utc(2024, 3, 7, 8)),
            asset("other-day", utc(2024, 3, 2, 9)),
            asset("late", utc(2024, 3, 7, 20)),
            asset("midnight", utc(2024, 3, 7, 0, 0)),
        ]
        let days = TimelineGrouping.days(from: assets)
        XCTAssertEqual(days.map(\.id), ["2024-03-07", "2024-03-02"])
        XCTAssertEqual(days[0].assets.map(\.id), ["late", "early", "midnight"])
        XCTAssertEqual(days[0].date, utc(2024, 3, 7, 0))
    }

    func testOldestFirst() {
        let assets = [asset("b", utc(2024, 3, 7, 20)), asset("a", utc(2024, 3, 7, 8)), asset("c", utc(2024, 3, 9))]
        let days = TimelineGrouping.days(from: assets, newestFirst: false)
        XCTAssertEqual(days.map(\.id), ["2024-03-07", "2024-03-09"])
        XCTAssertEqual(days[0].assets.map(\.id), ["a", "b"])
    }

    func testUsesLocalDateTimeForDayButTakenAtForOrder() {
        // Taken at 23:00 UTC in UTC+2 → local day is the 8th.
        var travel = asset("travel", utc(2024, 3, 7, 23))
        travel.localDateTime = utc(2024, 3, 8, 1)
        let home = asset("home", utc(2024, 3, 8, 6))
        let days = TimelineGrouping.days(from: [travel, home])
        XCTAssertEqual(days.map(\.id), ["2024-03-08"])
        XCTAssertEqual(days[0].assets.map(\.id), ["home", "travel"])
    }

    func testEqualTimesKeepInputOrder() {
        let date = utc(2024, 3, 7)
        let days = TimelineGrouping.days(from: [asset("x", date), asset("y", date), asset("z", date)])
        XCTAssertEqual(days[0].assets.map(\.id), ["x", "y", "z"])
    }
}

final class TimelineTests: XCTestCase {
    private let library: [Asset] = [
        asset("2023-12-a", utc(2023, 12, 24, 18)),
        asset("2024-01-a", utc(2024, 1, 1, 0, 30)),
        asset("2024-01-b", utc(2024, 1, 1, 22), favorite: true),
        asset("2024-01-c", utc(2024, 1, 15)),
        asset("2024-03-a", utc(2024, 3, 3)),
        asset("archived", utc(2024, 3, 4), archived: true),
        asset("trashed", utc(2024, 3, 5), trashed: true),
    ]

    func testLoadBucketsIsLazy() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        let months = try await timeline.loadBuckets()
        XCTAssertEqual(months.map(\.id), ["2024-03-01", "2024-01-01", "2023-12-01"])
        XCTAssertEqual(months.map(\.bucket.count), [1, 3, 1], "archived and trashed are excluded")
        XCTAssertTrue(months.allSatisfy { !$0.isLoaded })
        let totalCount = await timeline.totalCount
        XCTAssertEqual(totalCount, 5)
        let requests = await mock.requests
        XCTAssertEqual(requests, [.timeBuckets])
        let loaded = await timeline.loadedAssets
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadMonthGroupsByDay() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        let days = try await timeline.loadMonth("2024-01-01")
        XCTAssertEqual(days.map(\.id), ["2024-01-15", "2024-01-01"])
        XCTAssertEqual(days[1].assets.map(\.id), ["2024-01-b", "2024-01-a"])
        let isLoaded = await timeline.isLoaded("2024-01-01")
        XCTAssertTrue(isLoaded)
        let otherLoaded = await timeline.isLoaded("2024-03-01")
        XCTAssertFalse(otherLoaded)
        let loaded = await timeline.loadedAssets
        XCTAssertEqual(loaded.map(\.id), ["2024-01-c", "2024-01-b", "2024-01-a"])
        let month = await timeline.month("2024-01-01")
        XCTAssertEqual(month?.assetCount, 3)
    }

    func testSecondLoadIsCached() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        try await timeline.loadMonth("2024-01-01")
        try await timeline.loadMonth("2024-01-01")
        let count = await mock.requestCount(.timeBucket("2024-01-01"))
        XCTAssertEqual(count, 1)
    }

    func testConcurrentLoadsShareOneRequest() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        await mock.setLatency(.milliseconds(100))
        let results = try await withThrowingTaskGroup(of: [TimelineDay].self) { group in
            for _ in 0..<10 {
                group.addTask { try await timeline.loadMonth("2024-01-01") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0 == results[0] })
        let count = await mock.requestCount(.timeBucket("2024-01-01"))
        XCTAssertEqual(count, 1)
    }

    func testLoadMonthsAtIndices() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        try await timeline.loadMonths(at: [0, 1, 7, -1])
        let months = await timeline.months
        XCTAssertEqual(months.map(\.isLoaded), [true, true, false])
    }

    func testUnknownBucketThrows() async throws {
        let timeline = Timeline(service: MockImmichService(assets: library))
        try await timeline.loadBuckets()
        do {
            try await timeline.loadMonth("1999-01-01")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TimelineError, .unknownBucket("1999-01-01"))
        }
    }

    func testFailureCanBeRetried() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        await mock.setFailure(.network("offline"))
        do {
            try await timeline.loadMonth("2024-03-01")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .network("offline"))
        }
        let isLoaded = await timeline.isLoaded("2024-03-01")
        XCTAssertFalse(isLoaded)
        await mock.setFailure(nil)
        let days = try await timeline.loadMonth("2024-03-01")
        XCTAssertEqual(days.flatMap(\.assets).map(\.id), ["2024-03-a"])
    }

    func testRefreshKeepsUnchangedMonthsAndDropsChangedOnes() async throws {
        let mock = MockImmichService(assets: library)
        let timeline = Timeline(service: mock)
        try await timeline.loadBuckets()
        try await timeline.loadMonths(at: 0..<3)

        await mock.setAssets(library + [asset("2024-03-new", utc(2024, 3, 20))])
        let months = try await timeline.loadBuckets()
        XCTAssertEqual(months.map(\.isLoaded), [false, true, true])
        XCTAssertEqual(months[0].bucket.count, 2)
        let days = try await timeline.loadMonth("2024-03-01")
        XCTAssertEqual(days.flatMap(\.assets).map(\.id), ["2024-03-new", "2024-03-a"])
    }

    func testOldestFirstAndFavoritesFilter() async throws {
        let mock = MockImmichService(assets: library)
        let oldestFirst = Timeline(service: mock, options: TimelineOptions(newestFirst: false))
        let months = try await oldestFirst.loadBuckets()
        XCTAssertEqual(months.map(\.id), ["2023-12-01", "2024-01-01", "2024-03-01"])
        let days = try await oldestFirst.loadMonth("2024-01-01")
        XCTAssertEqual(days.flatMap(\.assets).map(\.id), ["2024-01-a", "2024-01-b", "2024-01-c"])

        let favorites = Timeline(service: mock, options: TimelineOptions(isFavorite: true))
        let favoriteMonths = try await favorites.loadBuckets()
        XCTAssertEqual(favoriteMonths.map(\.id), ["2024-01-01"])
        XCTAssertEqual(favoriteMonths.first?.bucket.count, 1)
    }

    func testReset() async throws {
        let timeline = Timeline(service: MockImmichService(assets: library))
        try await timeline.loadBuckets()
        await timeline.reset()
        let months = await timeline.months
        let hasLoaded = await timeline.hasLoadedBuckets
        XCTAssertTrue(months.isEmpty)
        XCTAssertFalse(hasLoaded)
    }
}

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
final class TimelineIntegrationTests: XCTestCase {
    func testLoadBucketsAndNewestMonth() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        let service = LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
        let timeline = Timeline(service: service)
        let months = try await timeline.loadBuckets()
        guard let newest = months.first else { throw XCTSkip("The library is empty") }
        let days = try await timeline.loadMonth(newest.id)
        let assets = days.flatMap(\.assets)
        XCTAssertEqual(assets.count, newest.bucket.count)
        let calendar = Asset.localCalendar
        for asset in assets {
            let parts = calendar.dateComponents([.year, .month], from: asset.localDateTime)
            XCTAssertEqual(parts.year, newest.bucket.year, asset.id)
            XCTAssertEqual(parts.month, newest.bucket.month, asset.id)
        }
        print("Timeline: \(months.count) months, newest \(newest.id) has \(assets.count) assets")
    }
}
