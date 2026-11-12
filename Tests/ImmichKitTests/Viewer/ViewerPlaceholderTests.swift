import XCTest
import ImmichKit
@testable import ImmichUI

/// Opening a photo shows its thumbnail at once and sharpens when the preview arrives, like Photos.
/// (The viewer used to show a spinner until the large preview had downloaded, which felt slow,
/// especially right after scrolling, when thumbnails compete for the network.)
@MainActor
final class ViewerPlaceholderTests: XCTestCase {
    private let asset = MockLibrary.standard.assets[0]
    private var thumbnailKey: ImageKey { ImageKey(assetID: asset.id, size: .thumbnail) }

    func testGridThumbnailShowsBeforeThePreview() async throws {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(200))
        let loader = ImageLoader(service: mock, disk: nil)
        let thumbnails = ThumbnailImageCache()
        let data = try await ImageLoader(service: MockImmichService(library: .standard), disk: nil).data(for: thumbnailKey)
        let thumbnail = try XCTUnwrap(ThumbnailDecoder.decodeNow(data, maxPixelSize: 512))
        thumbnails.insert(thumbnail, for: thumbnailKey)

        let store = ViewerStore(service: mock, loader: loader, thumbnails: thumbnails)
        let model = store.model(for: asset)
        XCTAssertTrue(model.displayImage === thumbnail, "shown at once, before any request")
        XCTAssertNil(model.image)
        await model.load()
        let preview = try XCTUnwrap(model.image)
        XCTAssertTrue(model.displayImage === preview, "the preview replaces the thumbnail")
    }

    func testLoadedThumbnailBytesShowWhileThePreviewLoads() async throws {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(300))
        let loader = ImageLoader(service: mock, disk: nil)
        _ = try await loader.data(for: thumbnailKey)
        let model = ViewerAssetModel(asset: asset, service: mock, loader: loader)
        let load = Task { await model.load() }
        let deadline = ContinuousClock.now + .milliseconds(250)
        while model.displayImage == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(model.displayImage, "the thumbnail in memory shows while the preview downloads")
        XCTAssertNil(model.image)
        await load.value
        XCTAssertNotNil(model.image)
    }
}
