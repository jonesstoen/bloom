import Foundation
import XCTest
import ImmichKit
@testable import ImmichUI

final class ThumbnailDecoderTests: XCTestCase {
    func testAlreadyCancelledDecodeReturnsNoImage() async {
        let bytes = PlaceholderImage.jpegData(assetID: "cancelled", size: .preview)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ThumbnailDecoder.decode(bytes)
        }.value
        XCTAssertNil(result)
    }

    func testNormalDecodeStillDownsamplesAndInvalidDataStillFails() async throws {
        let bytes = PlaceholderImage.jpegData(assetID: "normal", size: .preview, aspectRatio: 0.75)
        let decoded = await ThumbnailDecoder.decode(bytes, maxPixelSize: 120)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(max(image.width, image.height), 120)
        XCTAssertLessThan(image.width, image.height)
        let invalid = await ThumbnailDecoder.decode(Data("invalid image".utf8))
        XCTAssertNil(invalid)
    }

    @MainActor
    func testCancelledViewerLoadDoesNotPublishCachedThumbnail() async throws {
        let mock = MockImmichService(library: .standard)
        let asset = MockLibrary.standard.assets[0]
        let loader = ImageLoader(service: mock, disk: nil)
        _ = try await loader.data(assetID: asset.id, size: .thumbnail)
        let model = ViewerAssetModel(asset: asset, service: mock, loader: loader)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load()
        }.value
        XCTAssertNil(model.displayImage)
        XCTAssertFalse(model.isLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }
}
