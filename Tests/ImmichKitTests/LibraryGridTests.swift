import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class LibraryGridTests: XCTestCase {
    func testLoadsMonthsAndVisibleRangeClearsWhenLastCellLeaves() async throws {
        let mock = MockImmichService.preview
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertGreaterThan(model.totalCount, 0)
        XCTAssertTrue(model.months.last!.isLoaded)
        XCTAssertFalse(model.months.first!.isLoaded)
        let id = try XCTUnwrap(model.months.last?.assets.last?.id)
        model.assetAppeared(id)
        XCTAssertNotNil(model.lastVisibleRange)
        model.assetDisappeared(id)
        XCTAssertNil(model.lastVisibleRange)
        model.stopPrefetching()
    }

    func testEmptyAndFailureCanRetry() async {
        let mock = MockImmichService()
        let model = LibraryGridModel(service: mock)
        await mock.setFailure(.unauthorized)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("Expected failure") }
        await mock.setFailure(nil)
        await model.load()
        XCTAssertTrue(model.isEmpty)
    }

    func testVisibilityIgnoresUnknownIDsAndIncludesLastIndex() {
        XCTAssertEqual(LibraryGridModel.visibleRange(of: ["a", "c", "missing"], in: ["a": 2, "c": 5]), 2..<6)
        XCTAssertNil(LibraryGridModel.visibleRange(of: ["missing"], in: ["a": 2]))
    }

    func testDurationFormatting() {
        XCTAssertEqual(LibraryGridModel.durationText(65), "1:05")
        XCTAssertEqual(LibraryGridModel.durationText(3723), "1:02:03")
        XCTAssertEqual(LibraryGridModel.durationText(-5), "0:00")
    }

    func testThumbnailDecodeAndCache() async throws {
        let data = try await MockImmichService.preview.thumbnail(assetID: MockLibrary.standard.assets[0].id, size: .thumbnail)
        let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 80)
        let image = try XCTUnwrap(decoded)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 80)
        let cache = ThumbnailImageCache()
        let key = ImageKey(assetID: "a", size: .thumbnail)
        cache.insert(image, for: key)
        XCTAssertNotNil(cache.image(for: key))
        cache.removeAll()
        XCTAssertNil(cache.image(for: key))
    }
}
