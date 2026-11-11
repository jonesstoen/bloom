import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerTests: XCTestCase {
    func testImmediateReturnToCancelledPageRestartsLoad() async {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(60))
        let asset = MockLibrary.standard.assets[0]
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        let first = Task { await model.load() }
        while !model.isLoading { await Task.yield() }
        first.cancel()
        await model.load()
        await first.value
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledDetailLoadRemainsRetryableAfterPreviewArrives() async throws {
        let asset = MockLibrary.standard.assets.first { $0.isVideo }!
        let mock = MockImmichService(library: .standard, latency: .milliseconds(60))
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        let request = Task { await model.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.image == nil && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(model.image)
        request.cancel()
        await request.value
        XCTAssertFalse(model.isLoaded)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertNotNil(model.playback)
    }

    func testLoadsFullDetailAndPreview() async throws {
        let asset = MockLibrary.standard.assets.first { !$0.isVideo }!
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertEqual(model.asset.id, asset.id)
        XCTAssertNotNil(model.asset.exif)
        XCTAssertNotNil(model.image)
        XCTAssertNil(model.error)
    }

    func testVideoRequestAndRetryAfterFailure() async {
        let asset = MockLibrary.standard.assets.first { $0.isVideo }!
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await mock.setFailure(.unauthorized)
        await model.load()
        XCTAssertNotNil(model.error)
        await mock.setFailure(nil)
        await model.load()
        XCTAssertNotNil(model.playback)
        XCTAssertNil(model.error)
    }

    func testDismissRequiresDownwardVerticalDragAtNormalZoom() {
        XCTAssertTrue(ViewerGesture.shouldDismiss(x: 20, y: 130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 160, y: 130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 0, y: -130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 0, y: 130, zoom: 2.5))
    }
}
