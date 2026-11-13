import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerPreviewReuseTests: XCTestCase {
    func testDetailReloadRefreshesMetadataWithoutReplacingPreview() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo && !$0.isLivePhoto })
        let mock = MockImmichService(library: .standard)
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        let preview = try XCTUnwrap(model.image)
        _ = try await mock.setFavorite(assetID: asset.id, isFavorite: !asset.isFavorite)
        await model.load()
        XCTAssertTrue(model.image === preview)
        XCTAssertEqual(model.asset.isFavorite, !asset.isFavorite)
        let details = await mock.requestCount(.asset(asset.id))
        let previews = await mock.requestCount(.thumbnail(asset.id, .preview))
        XCTAssertEqual(details, 2, "An explicit reload must still refresh asset details")
        XCTAssertEqual(previews, 1)
        XCTAssertTrue(model.isLoaded)
    }

    func testCancelledDetailRetryKeepsPreviewAndLoadsPlayback() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isVideo })
        let mock = MockImmichService(library: .standard, latency: .milliseconds(30))
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        let first = Task { await model.load() }
        await waitForDetail(mock, id: asset.id)
        let preview = try XCTUnwrap(model.image)
        first.cancel()
        await first.value
        XCTAssertFalse(model.isLoaded)
        await model.load()
        XCTAssertTrue(model.image === preview)
        XCTAssertTrue(model.isLoaded)
        XCTAssertNotNil(model.playback)
    }

    func testOverlappingDetailReloadKeepsAlreadyVisiblePreview() async throws {
        let asset = MockLibrary.standard.assets[0]
        let mock = MockImmichService(library: .standard, latency: .milliseconds(30))
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        let first = Task { await model.load() }
        await waitForDetail(mock, id: asset.id)
        let preview = try XCTUnwrap(model.image)
        await model.load()
        await first.value
        XCTAssertTrue(model.image === preview)
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testEvictedPreviewIsDecodedAgainOnReturn() async throws {
        let asset = MockLibrary.standard.assets[0]
        let mock = MockImmichService(library: .standard)
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        let preview = try XCTUnwrap(model.image)
        model.setPreviewRetained(false)
        XCTAssertNil(model.image)
        model.setPreviewRetained(true)
        await model.load()
        XCTAssertNotNil(model.image)
        XCTAssertFalse(model.image === preview)
        XCTAssertTrue(model.isLoaded)
    }

    private func waitForDetail(_ mock: MockImmichService, id: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mock.requestCount(.asset(id)) == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let count = await mock.requestCount(.asset(id))
        XCTAssertGreaterThan(count, 0, "The preview must arrive before testing detail retry")
    }
}
