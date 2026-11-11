import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerTests: XCTestCase {
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
