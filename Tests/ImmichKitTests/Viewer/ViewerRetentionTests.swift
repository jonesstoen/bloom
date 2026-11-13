import CoreGraphics
import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerRetentionTests: XCTestCase {
    func testLongWalkBoundsDecodedImagesAndKeepsNearbyBackSwipeReady() async throws {
        let mock = MockImmichService(library: .standard)
        let assets = Array(MockLibrary.standard.assets.filter { !$0.isVideo }.prefix(12))
        let store = ViewerStore(service: mock, loader: ImageLoader(service: mock, disk: nil))
        for (index, asset) in assets.enumerated() {
            store.updateSelection(index: index, assets: assets)
            await store.model(for: asset).load()
            let count = assets.compactMap { store.model(for: $0).image }.count
            XCTAssertLessThanOrEqual(count, 5)
        }
        let previous = store.model(for: assets[10])
        let image = try XCTUnwrap(previous.image)
        store.updateSelection(index: 10, assets: assets)
        XCTAssertTrue(store.model(for: assets[10]) === previous)
        XCTAssertTrue(previous.image === image)
        XCTAssertTrue(previous.isLoaded)
        XCTAssertNil(store.model(for: assets[0]).displayImage)
    }

    func testFarJumpPreservesFavoriteAndDetailStateAndReloadsPreview() async throws {
        let mock = MockImmichService(library: .standard)
        let assets = Array(MockLibrary.standard.assets.filter { !$0.isVideo }.prefix(8))
        let store = ViewerStore(service: mock, loader: ImageLoader(service: mock, disk: nil))
        store.updateSelection(index: 0, assets: assets)
        let first = store.model(for: assets[0])
        await first.load()
        await first.toggleFavorite()
        let saved = first.asset
        XCTAssertNotNil(first.image)
        store.updateSelection(index: 7, assets: assets)
        XCTAssertNil(first.displayImage)
        XCTAssertFalse(first.isLoaded)
        XCTAssertEqual(first.asset, saved)
        // A far-away lazy page must not start another request.
        let before = await mock.requests.count
        await first.load()
        let after = await mock.requests.count
        XCTAssertEqual(after, before)
        store.updateSelection(index: 0, assets: assets)
        XCTAssertTrue(store.model(for: assets[0]) === first)
        await first.load()
        XCTAssertNotNil(first.image)
        XCTAssertTrue(first.isLoaded)
        XCTAssertEqual(first.asset.isFavorite, saved.isFavorite)
        XCTAssertEqual(first.asset.exif, saved.exif)
    }

    func testEvictionStopsLivePhotoAndReturningCanPlayAgain() async throws {
        let mock = MockImmichService(library: .standard)
        let live = try XCTUnwrap(MockLibrary.standard.assets.first { $0.isLivePhoto })
        let assets = [live] + Array(MockLibrary.standard.assets.filter { $0.id != live.id }.prefix(7))
        let store = ViewerStore(service: mock, loader: ImageLoader(service: mock, disk: nil))
        store.updateSelection(index: 0, assets: assets)
        let model = store.model(for: live)
        await model.load()
        model.startLivePhotoPlayback()
        XCTAssertTrue(model.isLivePhotoPlaying)
        store.updateSelection(index: 7, assets: assets)
        XCTAssertFalse(model.isLivePhotoPlaying)
        XCTAssertNil(model.playback)
        XCTAssertNil(model.displayImage)
        store.updateSelection(index: 0, assets: assets)
        await model.load()
        model.startLivePhotoPlayback()
        XCTAssertTrue(model.isLivePhotoPlaying)
        model.stopLivePhotoPlayback()
    }

    func testLateDetailsCannotOverwriteEvictedStateOrRestorePlayback() async throws {
        let assets = Array(MockLibrary.standard.assets.prefix(8))
        let started = expectation(description: "Details waiting")
        let transport = PausedViewerPreview(started: started, pauseDetails: true, assetID: assets[0].id)
        let credentials = try ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        let store = ViewerStore(service: service, loader: ImageLoader(service: service, disk: nil))
        store.updateSelection(index: 0, assets: assets)
        let model = store.model(for: assets[0])
        let original = model.asset
        let load = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(model.image)
        store.updateSelection(index: 7, assets: assets)
        await transport.release()
        await load.value
        XCTAssertNil(model.displayImage)
        XCTAssertNil(model.playback)
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.asset, original)
    }

    func testLatePreviewCannotRepopulateAnEvictedModel() async throws {
        let assets = Array(MockLibrary.standard.assets.prefix(8))
        let started = expectation(description: "Preview waiting")
        let transport = PausedViewerPreview(started: started)
        let credentials = try ServerCredentials(server: "https://example.invalid", apiKey: "test-placeholder")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        let store = ViewerStore(service: service, loader: ImageLoader(service: service, disk: nil))
        store.updateSelection(index: 0, assets: assets)
        let old = store.model(for: assets[0])
        let load = Task { await old.load() }
        await fulfillment(of: [started], timeout: 2)
        store.updateSelection(index: 7, assets: assets)
        await transport.release()
        await load.value
        XCTAssertNil(old.image)
        XCTAssertNil(old.placeholder)
        XCTAssertNil(old.playback)
        XCTAssertFalse(old.isLoaded)
        XCTAssertFalse(old.isLoading)
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 1, "An evicted preview must not start loading details/playback")
    }
}

private actor PausedViewerPreview: ClientTransport {
    let started: XCTestExpectation
    let pauseDetails: Bool
    let assetID: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []
    init(started: XCTestExpectation, pauseDetails: Bool = false, assetID: String = "") {
        self.started = started
        self.pauseDetails = pauseDetails
        self.assetID = assetID
    }
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        paths.append(request.path ?? "")
        let isPreview = request.path?.contains("/thumbnail") == true
        if paths.count == (pauseDetails ? 2 : 1) {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        var response = HTTPResponse(status: .ok)
        if isPreview {
            response.headerFields[.contentType] = "image/jpeg"
            return (response, HTTPBody(PlaceholderImage.jpegData(assetID: "late", size: .preview)))
        }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody("""
        {"id":"\(assetID)","type":"IMAGE","fileCreatedAt":"2024-01-01T00:00:00Z",
         "localDateTime":"2024-01-01T00:00:00Z","isFavorite":true,"livePhotoVideoId":"late-motion"}
        """))
    }
}
