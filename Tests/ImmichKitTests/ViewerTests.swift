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

    func testLivePhotoLoadsMotionRequestWithoutDownloadingOriginals() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto && !$0.isVideo })
        let motionID = try XCTUnwrap(asset.livePhotoVideoId)
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertNotNil(model.image)
        XCTAssertEqual(model.playback?.assetID, motionID)
        XCTAssertEqual(model.playback?.kind, .videoPlayback)
        let motionRequests = await mock.requestCount(.mediaRequest(.videoPlayback, motionID))
        XCTAssertEqual(motionRequests, 1)
        let originalRequests = await mock.requests.filter { if case .original = $0 { true } else { false } }
        XCTAssertTrue(originalRequests.isEmpty)
    }

    func testOrdinaryPhotoDoesNotRequestMotionPlayback() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo && !$0.isLivePhoto })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.playback)
        let mediaRequests = await mock.requests.filter { if case .mediaRequest = $0 { true } else { false } }
        XCTAssertTrue(mediaRequests.isEmpty)
    }

    func testLivePhotoPlaybackCanStopAndRestartWithoutStaleCompletionStoppingNewSession() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto && !$0.isVideo })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()

        model.startLivePhotoPlayback()
        let firstSession = model.livePhotoPlaybackGeneration
        XCTAssertTrue(model.isLivePhotoPlaying)
        model.stopLivePhotoPlayback()
        XCTAssertFalse(model.isLivePhotoPlaying)
        model.startLivePhotoPlayback()
        let secondSession = model.livePhotoPlaybackGeneration
        XCTAssertGreaterThan(secondSession, firstSession)

        model.finishLivePhotoPlayback(generation: firstSession)
        XCTAssertTrue(model.isLivePhotoPlaying, "An old playback completion must not stop the current session")
        model.finishLivePhotoPlayback(generation: firstSession, failed: true)
        XCTAssertTrue(model.isLivePhotoPlaying, "An old failure must not stop the current session")
        XCTAssertNil(model.livePhotoPlaybackError)

        model.finishLivePhotoPlayback(generation: secondSession)
        XCTAssertFalse(model.isLivePhotoPlaying)
    }

    func testZoomStopsPlaybackAndPreventsStartingUntilZoomEnds() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto && !$0.isVideo })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        model.startLivePhotoPlayback()
        let session = model.livePhotoPlaybackGeneration

        model.setLivePhotoZoomed(true)
        XCTAssertFalse(model.isLivePhotoPlaying)
        XCTAssertGreaterThan(model.livePhotoPlaybackGeneration, session)
        model.startLivePhotoPlayback()
        XCTAssertFalse(model.isLivePhotoPlaying)

        model.setLivePhotoZoomed(false)
        model.startLivePhotoPlayback()
        XCTAssertTrue(model.isLivePhotoPlaying)
    }

    func testLivePhotoFailureKeepsStillImageAndRetryClearsPlaybackError() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto && !$0.isVideo })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        let stillImage = try XCTUnwrap(model.image)

        model.startLivePhotoPlayback()
        let failedSession = model.livePhotoPlaybackGeneration
        model.finishLivePhotoPlayback(generation: failedSession, failed: true)
        XCTAssertFalse(model.isLivePhotoPlaying)
        XCTAssertEqual(model.image, stillImage)
        XCTAssertNotNil(model.livePhotoPlaybackError)

        model.startLivePhotoPlayback()
        XCTAssertTrue(model.isLivePhotoPlaying)
        XCTAssertNil(model.livePhotoPlaybackError)
    }

    func testVideoCannotStartLivePhotoPlayback() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isVideo })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()

        model.startLivePhotoPlayback()
        XCTAssertFalse(model.isLivePhotoPlaying)
    }

    func testLivePhotoCannotStartFromStalePlaybackWhileReloading() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto && !$0.isVideo })
        let mock = MockImmichService.preview
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertNotNil(model.playback)

        await mock.setLatency(.milliseconds(30))
        let reload = Task { await model.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.isLoaded)
        XCTAssertNotNil(model.playback, "The previous request may remain cached until the reload finishes")

        model.startLivePhotoPlayback()
        XCTAssertFalse(model.isLivePhotoPlaying)
        reload.cancel()
        await reload.value
    }

    func testDismissRequiresDownwardVerticalDragAtNormalZoom() {
        XCTAssertTrue(ViewerGesture.shouldDismiss(x: 20, y: 130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 160, y: 130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 0, y: -130, zoom: 1))
        XCTAssertFalse(ViewerGesture.shouldDismiss(x: 0, y: 130, zoom: 2.5))
    }
}
