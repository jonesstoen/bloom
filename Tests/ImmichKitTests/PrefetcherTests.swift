import Foundation
import XCTest
@testable import ImmichKit

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

final class PrefetcherTests: XCTestCase {
    private let ids = (0..<200).map { "a\($0)" }

    private func makePrefetcher(
        latency: Duration = .zero,
        configuration: Prefetcher.Configuration
    ) async -> (Prefetcher, MockImmichService, ImageLoader) {
        let mock = MockImmichService(latency: latency)
        let loader = ImageLoader(service: mock, disk: nil)
        let prefetcher = Prefetcher(loader: loader, size: .thumbnail, configuration: configuration)
        await prefetcher.setAssets(ids)
        return (prefetcher, mock, loader)
    }

    private func requestedIndices(_ mock: MockImmichService) async -> [Int] {
        await mock.requests.compactMap { request -> Int? in
            guard case let .thumbnail(id, .thumbnail) = request else { return nil }
            return Int(id.dropFirst())
        }
    }

    // MARK: Target selection

    func testTargetIndicesForward() {
        let config = Prefetcher.Configuration(ahead: 4, behind: 2, cancelDistance: 10)
        let result = Prefetcher.targetIndices(visible: 10..<20, direction: .forward, count: 100, configuration: config)
        XCTAssertEqual(result, [20, 21, 22, 23, 9, 8])
    }

    func testTargetIndicesBackward() {
        let config = Prefetcher.Configuration(ahead: 4, behind: 2, cancelDistance: 10)
        let result = Prefetcher.targetIndices(visible: 10..<20, direction: .backward, count: 100, configuration: config)
        XCTAssertEqual(result, [9, 8, 7, 6, 20, 21])
    }

    func testTargetIndicesClampedAtEdges() {
        let config = Prefetcher.Configuration(ahead: 4, behind: 2, cancelDistance: 10)
        XCTAssertEqual(
            Prefetcher.targetIndices(visible: 0..<10, direction: .forward, count: 12, configuration: config),
            [10, 11]
        )
        XCTAssertEqual(
            Prefetcher.targetIndices(visible: 1..<12, direction: .backward, count: 12, configuration: config),
            [0]
        )
    }

    func testConfigurationKeepsCancelDistanceAtLeastWindow() {
        let config = Prefetcher.Configuration(ahead: 30, behind: 5, cancelDistance: 10, maxConcurrent: 0)
        XCTAssertEqual(config.cancelDistance, 30)
        XCTAssertEqual(config.maxConcurrent, 1)
    }

    // MARK: Loading

    func testPrefetchesAheadIntoLoaderCache() async {
        let (prefetcher, mock, loader) = await makePrefetcher(
            configuration: .init(ahead: 5, behind: 2, cancelDistance: 20)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        let idle = await eventually { await prefetcher.isIdle }
        XCTAssertTrue(idle)

        let requested = await requestedIndices(mock)
        XCTAssertEqual(Set(requested), Set(10..<15))
        let cached = await loader.memoryData(for: ImageKey(assetID: "a12", size: .thumbnail))
        XCTAssertEqual(cached, MockImmichService.placeholderData(assetID: "a12", size: .thumbnail))
    }

    func testDetectsScrollDirection() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            configuration: .init(ahead: 5, behind: 2, cancelDistance: 20)
        )
        await prefetcher.visibleRangeChanged(100..<110)
        var direction = await prefetcher.direction
        XCTAssertEqual(direction, .forward)
        _ = await eventually { await prefetcher.isIdle }

        await prefetcher.visibleRangeChanged(90..<100) // scrolling up
        direction = await prefetcher.direction
        XCTAssertEqual(direction, .backward)
        _ = await eventually { await prefetcher.isIdle }

        let requested = Set(await requestedIndices(mock))
        // First pass: 110..<115 ahead, 99, 98 behind. Second pass (backward): 89...85 ahead, 100, 101 behind.
        XCTAssertTrue(Set(85..<90).isSubset(of: requested))
        XCTAssertTrue(Set(110..<115).isSubset(of: requested))
        XCTAssertFalse(requested.contains(84))
        XCTAssertFalse(requested.contains(115))
    }

    func testDoesNotRefetchCompletedItems() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            configuration: .init(ahead: 5, behind: 0, cancelDistance: 20)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        _ = await eventually { await prefetcher.isIdle }
        await prefetcher.visibleRangeChanged(1..<11)
        _ = await eventually { await prefetcher.isIdle }

        let requested = await requestedIndices(mock)
        XCTAssertEqual(requested.sorted(), Array(10..<16))
        XCTAssertEqual(requested.count, Set(requested).count)
    }

    func testLimitsConcurrencyAndQueuesNearestFirst() async {
        let (prefetcher, _, _) = await makePrefetcher(
            latency: .seconds(10),
            configuration: .init(ahead: 6, behind: 0, cancelDistance: 20, maxConcurrent: 2)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        let running = await prefetcher.runningIDs
        let queued = await prefetcher.queuedIDs
        XCTAssertEqual(running, ["a10", "a11"])
        XCTAssertEqual(queued, ["a12", "a13", "a14", "a15"])
        await prefetcher.cancelAll()
    }

    func testCancelsRequestsThatScrolledFarAway() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            latency: .seconds(10),
            configuration: .init(ahead: 3, behind: 0, cancelDistance: 10, maxConcurrent: 10)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        let started = await eventually { await mock.requests.count == 3 }
        XCTAssertTrue(started)

        await prefetcher.visibleRangeChanged(100..<110) // jumped far away
        let running = await prefetcher.runningIDs
        XCTAssertEqual(running, ["a110", "a111", "a112"])

        let cancelled = await eventually { await mock.cancelledRequests.count == 3 }
        XCTAssertTrue(cancelled)
        let cancelledIDs = await Set(mock.cancelledRequests)
        XCTAssertEqual(cancelledIDs, Set((10..<13).map { MockImmichService.Request.thumbnail("a\($0)", .thumbnail) }))
        await prefetcher.cancelAll()
    }

    func testKeepsRequestsWithinCancelDistance() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            latency: .seconds(10),
            configuration: .init(ahead: 3, behind: 0, cancelDistance: 10, maxConcurrent: 10)
        )
        await prefetcher.visibleRangeChanged(20..<30)
        _ = await eventually { await mock.requests.count == 3 } // 30, 31, 32
        await prefetcher.visibleRangeChanged(15..<25) // backward, 30..32 are still within 10 items
        let running = await prefetcher.runningIDs
        XCTAssertTrue(Set(["a30", "a31", "a32"]).isSubset(of: running))
        XCTAssertTrue(Set(["a14", "a13", "a12"]).isSubset(of: running))
        try? await Task.sleep(for: .milliseconds(50))
        let cancelled = await mock.cancelledRequests
        XCTAssertEqual(cancelled, [])
        await prefetcher.cancelAll()
    }

    func testSetAssetsCancelsRemovedIDs() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            latency: .seconds(10),
            configuration: .init(ahead: 3, behind: 0, cancelDistance: 10, maxConcurrent: 10)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        _ = await eventually { await mock.requests.count == 3 }
        // a11 disappears (e.g. deleted); the others shift down by one.
        await prefetcher.setAssets(ids.filter { $0 != "a11" })
        let running = await prefetcher.runningIDs
        XCTAssertEqual(running, ["a10", "a12", "a13"])
        let cancelled = await eventually { await mock.cancelledRequests == [.thumbnail("a11", .thumbnail)] }
        XCTAssertTrue(cancelled)
        await prefetcher.cancelAll()
    }

    func testCancelAllCancelsEverything() async {
        let (prefetcher, mock, _) = await makePrefetcher(
            latency: .seconds(10),
            configuration: .init(ahead: 4, behind: 0, cancelDistance: 10, maxConcurrent: 10)
        )
        await prefetcher.visibleRangeChanged(0..<10)
        _ = await eventually { await mock.requests.count == 4 }
        await prefetcher.cancelAll()
        let idle = await prefetcher.isIdle
        XCTAssertTrue(idle)
        let cancelled = await eventually { await mock.cancelledRequests.count == 4 }
        XCTAssertTrue(cancelled)
    }
}

final class ImageLoaderCancellationTests: XCTestCase {
    func testCancellingOnlyCallerCancelsFetch() async {
        let mock = MockImmichService(latency: .seconds(10))
        let loader = ImageLoader(service: mock, disk: nil)
        let key = ImageKey(assetID: "a1", size: .thumbnail)

        let task = Task { try await loader.data(for: key) }
        _ = await eventually { await mock.requests.count == 1 }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
        let cancelled = await mock.cancelledRequests
        XCTAssertEqual(cancelled, [.thumbnail("a1", .thumbnail)])
        let loading = await loader.isLoading(key)
        XCTAssertFalse(loading)
    }

    func testCancellingOneOfTwoCallersKeepsFetch() async throws {
        let mock = MockImmichService(latency: .milliseconds(200))
        let loader = ImageLoader(service: mock, disk: nil)
        let key = ImageKey(assetID: "a1", size: .thumbnail)

        let prefetch = Task { try await loader.data(for: key) }
        _ = await eventually { await mock.requests.count == 1 }
        let cell = Task { try await loader.data(for: key) }
        _ = await eventually { await loader.isLoading(key) }
        try? await Task.sleep(for: .milliseconds(20)) // let the cell join the shared fetch
        prefetch.cancel()

        let data = try await cell.value
        XCTAssertEqual(data, MockImmichService.placeholderData(assetID: "a1", size: .thumbnail))
        let cancelled = await mock.cancelledRequests
        XCTAssertEqual(cancelled, [])
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 1)
    }

    func testNewCallerAfterCancelStartsFreshFetch() async throws {
        let mock = MockImmichService(latency: .milliseconds(100))
        let loader = ImageLoader(service: mock, disk: nil)
        let key = ImageKey(assetID: "a1", size: .thumbnail)

        let first = Task { try await loader.data(for: key) }
        _ = await eventually { await mock.requests.count == 1 }
        first.cancel()
        _ = await first.result

        let data = try await loader.data(for: key)
        XCTAssertEqual(data, MockImmichService.placeholderData(assetID: "a1", size: .thumbnail))
        let count = await mock.requestCount(.thumbnail("a1", .thumbnail))
        XCTAssertEqual(count, 2)
    }
}
