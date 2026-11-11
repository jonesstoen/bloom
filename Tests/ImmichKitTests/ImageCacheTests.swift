import Foundation
import XCTest
@testable import ImmichKit

final class DiskImageCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data { Data(repeating: value, count: count) }

    func testStoreAndRead() async {
        let cache = DiskImageCache(directory: directory, byteLimit: 1000)
        await cache.store(bytes(10, 7), for: "a-thumbnail")
        let data = await cache.data(for: "a-thumbnail")
        XCTAssertEqual(data, bytes(10, 7))
        let missing = await cache.data(for: "b-thumbnail")
        XCTAssertNil(missing)
    }

    func testEvictsLeastRecentlyUsedOverLimit() async {
        let cache = DiskImageCache(directory: directory, byteLimit: 250)
        await cache.store(bytes(100), for: "a")
        await cache.store(bytes(100), for: "b")
        _ = await cache.data(for: "a")          // a is now more recent than b
        await cache.store(bytes(100), for: "c") // 300 > 250: evict b

        let hasA = await cache.contains("a")
        let hasB = await cache.contains("b")
        let hasC = await cache.contains("c")
        XCTAssertTrue(hasA)
        XCTAssertFalse(hasB)
        XCTAssertTrue(hasC)
        let total = await cache.totalBytes
        XCTAssertEqual(total, 200)
        let bFile = directory.appendingPathComponent(DiskImageCache.fileName(for: "b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bFile.path))
    }

    func testDataLargerThanLimitIsNotStored() async {
        let cache = DiskImageCache(directory: directory, byteLimit: 50)
        await cache.store(bytes(51), for: "big")
        let hasBig = await cache.contains("big")
        XCTAssertFalse(hasBig)
    }

    func testIndexSurvivesNewInstance() async {
        let first = DiskImageCache(directory: directory, byteLimit: 1000)
        await first.store(bytes(10, 3), for: "id/with:odd chars-preview")
        let second = DiskImageCache(directory: directory, byteLimit: 1000)
        let data = await second.data(for: "id/with:odd chars-preview")
        XCTAssertEqual(data, bytes(10, 3))
        let total = await second.totalBytes
        XCTAssertEqual(total, 10)
    }

    func testRemoveAll() async {
        let cache = DiskImageCache(directory: directory, byteLimit: 1000)
        await cache.store(bytes(10), for: "a")
        await cache.removeAll()
        let hasA = await cache.contains("a")
        XCTAssertFalse(hasA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await cache.store(bytes(10), for: "b") // directory is recreated
        let hasB = await cache.contains("b")
        XCTAssertTrue(hasB)
    }

    func testFileNameRoundTrip() {
        let key = "a/b:c d-ü"
        XCTAssertEqual(DiskImageCache.key(forFileName: DiskImageCache.fileName(for: key)), key)
        XCTAssertFalse(DiskImageCache.fileName(for: key).contains("/"))
    }
}

final class ImageLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLoader(
        latency: Duration = .zero,
        diskLimit: Int = 10_000
    ) -> (ImageLoader, MockImmichService, DiskImageCache) {
        let mock = MockImmichService(latency: latency)
        let disk = DiskImageCache(directory: directory, byteLimit: diskLimit)
        return (ImageLoader(service: mock, disk: disk), mock, disk)
    }

    func testLoadsFromServiceThenMemoryHit() async throws {
        let (loader, mock, _) = makeLoader()
        let key = ImageKey(assetID: "a1", size: .thumbnail)

        let first = try await loader.data(for: key)
        XCTAssertEqual(first, MockImmichService.placeholderData(assetID: "a1", size: .thumbnail))
        let cached = await loader.memoryData(for: key)
        XCTAssertEqual(cached, first)

        let second = try await loader.data(for: key)
        XCTAssertEqual(second, first)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 1)
    }

    func testSizesAreCachedSeparately() async throws {
        let (loader, mock, _) = makeLoader()
        let thumb = try await loader.data(assetID: "a1", size: .thumbnail)
        let preview = try await loader.data(assetID: "a1", size: .preview)
        XCTAssertNotEqual(thumb, preview)
        let requests = await mock.requests
        XCTAssertEqual(requests, [.thumbnail("a1", .thumbnail), .thumbnail("a1", .preview)])
    }

    func testDiskHitAfterMemoryCleared() async throws {
        let (loader, mock, disk) = makeLoader()
        let key = ImageKey(assetID: "a1", size: .preview)
        let first = try await loader.data(for: key)
        let onDisk = await disk.contains(key.description)
        XCTAssertTrue(onDisk)

        await loader.clearMemory()
        let memory = await loader.memoryData(for: key)
        XCTAssertNil(memory)
        let second = try await loader.data(for: key)
        XCTAssertEqual(second, first)
        let count = await mock.requestCount(.thumbnail("a1", .preview))
        XCTAssertEqual(count, 1)
    }

    func testDiskHitInNewLoader() async throws {
        let (loader, mock, _) = makeLoader()
        _ = try await loader.data(assetID: "a1", size: .thumbnail)

        // Simulates an app relaunch: new memory cache, same directory.
        let relaunched = ImageLoader(service: mock, disk: DiskImageCache(directory: directory, byteLimit: 10_000))
        _ = try await relaunched.data(assetID: "a1", size: .thumbnail)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 1)
    }

    func testConcurrentRequestsShareOneFetch() async throws {
        let (loader, mock, _) = makeLoader(latency: .milliseconds(100))
        let key = ImageKey(assetID: "a1", size: .thumbnail)

        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<10 { group.addTask { try await loader.data(for: key) } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(Set(results).count, 1)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 1)
        let loading = await loader.isLoading(key)
        XCTAssertFalse(loading)
    }

    func testFailureIsNotCachedAndRetries() async throws {
        let (loader, mock, disk) = makeLoader()
        let key = ImageKey(assetID: "a1", size: .thumbnail)
        await mock.setFailure(.network("offline"))
        do {
            _ = try await loader.data(for: key)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .network("offline"))
        }
        let memory = await loader.memoryData(for: key)
        XCTAssertNil(memory)
        let onDisk = await disk.contains(key.description)
        XCTAssertFalse(onDisk)

        await mock.setFailure(nil)
        _ = try await loader.data(for: key)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 2)
    }

    func testDiskEvictionForcesRefetch() async throws {
        let size = MockImmichService.placeholderData(assetID: "a1", size: .thumbnail).count
        // Room for two images on disk.
        let (loader, mock, disk) = makeLoader(diskLimit: size * 2 + size / 2)
        _ = try await loader.data(assetID: "a1", size: .thumbnail)
        _ = try await loader.data(assetID: "a2", size: .thumbnail)
        _ = try await loader.data(assetID: "a3", size: .thumbnail)
        let hasA1 = await disk.contains(ImageKey(assetID: "a1", size: .thumbnail).description)
        XCTAssertFalse(hasA1)

        await loader.clearMemory()
        _ = try await loader.data(assetID: "a1", size: .thumbnail) // evicted: network again
        _ = try await loader.data(assetID: "a3", size: .thumbnail) // still on disk
        let a1 = await mock.requestCount(.thumbnail("a1", .thumbnail))
        let a3 = await mock.requestCount(.thumbnail("a3", .thumbnail))
        XCTAssertEqual(a1, 2)
        XCTAssertEqual(a3, 1)
    }

    func testRemoveAllClearsBothLevels() async throws {
        let (loader, mock, _) = makeLoader()
        _ = try await loader.data(assetID: "a1", size: .thumbnail)
        await loader.removeAll()
        _ = try await loader.data(assetID: "a1", size: .thumbnail)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 2)
    }

    func testMemoryOnlyLoader() async throws {
        let mock = MockImmichService()
        let loader = ImageLoader(service: mock, disk: nil)
        _ = try await loader.data(assetID: "a1", size: .thumbnail)
        _ = try await loader.data(assetID: "a1", size: .thumbnail)
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 1)
    }
}

final class LiveThumbnailTests: XCTestCase {
    func testThumbnailRequestsSizeAndReturnsBytes() async throws {
        let transport = RecordingTransport { _ in (200, "application/octet-stream", "JPEGBYTES") }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        let id = "3fa85f64-5717-4562-b3fc-2c963f66afa6"

        let data = try await service.thumbnail(assetID: id, size: .preview)
        XCTAssertEqual(data, Data("JPEGBYTES".utf8))
        let (request, _) = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/assets/\(id)/thumbnail?size=preview")
        XCTAssertEqual(request.headerFields[APIKeyMiddleware.headerName], "k")
    }

    func testThumbnailNotFound() async throws {
        let transport = RecordingTransport { _ in (404, "application/json", "{}") }
        let credentials = try ServerCredentials(server: "https://photos.example.com", apiKey: "k")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        do {
            _ = try await service.thumbnail(assetID: "x", size: .thumbnail)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .unexpectedStatus(404))
        }
    }
}
