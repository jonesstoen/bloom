import XCTest
import ImmichKit
@testable import ImmichUI

/// Logic behind the Photos-style viewer, collections and map.
@MainActor
final class PhotosLookTests: XCTestCase {
    // MARK: Map clusters

    func testMapClustersGroupNearbyMarkersAtTheirMeanPosition() {
        let markers = [
            MapMarker(id: "a", latitude: 59.91, longitude: 10.75),
            MapMarker(id: "b", latitude: 59.93, longitude: 10.77),
            MapMarker(id: "c", latitude: 60.39, longitude: 5.32),
        ]
        let clusters = MapCluster.make(markers, cellSize: 0.5)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].assetIDs, ["a", "b"])
        XCTAssertEqual(clusters[0].latitude, 59.92, accuracy: 0.0001)
        XCTAssertEqual(clusters[0].longitude, 10.76, accuracy: 0.0001)
        XCTAssertEqual(clusters[1].assetIDs, ["c"])
        // Zoomed in far enough, every marker is its own pin.
        XCTAssertEqual(MapCluster.make(markers, cellSize: 0.001).count, 3)
    }

    func testMapClustersIgnoreInvalidInput() {
        let markers = [MapMarker(id: "a", latitude: .nan, longitude: 10), MapMarker(id: "b", latitude: 1, longitude: 1)]
        XCTAssertEqual(MapCluster.make(markers, cellSize: 1).map(\.assetIDs), [["b"]])
        XCTAssertTrue(MapCluster.make(markers, cellSize: 0).isEmpty)
        XCTAssertTrue(MapCluster.make(markers, cellSize: .infinity).isEmpty)
    }

    func testMapClustersFromMockLibraryKeepEveryMarker() async throws {
        let markers = try await MockImmichService.preview.mapMarkers()
        XCTAssertFalse(markers.isEmpty)
        let clusters = MapCluster.make(markers, cellSize: 1)
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.assetIDs.count }, markers.count)
        XCTAssertEqual(Set(clusters.map(\.id)).count, clusters.count)
    }

    // MARK: Memories

    func testMemoriesAreNewestFirstWithoutEmptyOnes() async {
        let model = CollectionsModel(service: MockImmichService(library: .standard))
        await model.loadMemories()
        XCTAssertTrue(model.loadedMemories)
        XCTAssertFalse(model.memories.isEmpty)
        XCTAssertTrue(model.memories.allSatisfy { !$0.assets.isEmpty })
        XCTAssertEqual(model.memories.map(\.memoryAt), model.memories.map(\.memoryAt).sorted(by: >))

        let empty = Memory(id: "e", kind: .onThisDay(year: 2020), memoryAt: .now, assets: [])
        XCTAssertTrue(CollectionsModel.sortedMemories([empty]).isEmpty)
    }

    func testMemoriesFailureLeavesTheRowOut() async {
        let mock = MockImmichService(library: .standard)
        await mock.setFailure(.network("Offline"))
        let model = CollectionsModel(service: mock)
        await model.loadMemories()
        XCTAssertTrue(model.loadedMemories)
        XCTAssertTrue(model.memories.isEmpty)
    }

    // MARK: Viewer

    func testToggleFavoriteUpdatesRightAwayAndOnTheServer() async throws {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(150))
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isFavorite })
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        let toggle = Task { await model.toggleFavorite() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !model.asset.isFavorite && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.asset.isFavorite, "Photos flips the heart before the server answers")
        let notYetOnServer = await mock.assets.first { $0.id == asset.id }?.isFavorite
        XCTAssertEqual(notYetOnServer, false)
        await toggle.value
        XCTAssertTrue(model.asset.isFavorite)
        let onServer = try await mock.asset(id: asset.id)
        XCTAssertTrue(onServer.isFavorite)
        await model.toggleFavorite()
        XCTAssertFalse(model.asset.isFavorite)
    }

    func testToggleFavoriteRollsBackWhenTheServerRefuses() async throws {
        let mock = MockImmichService(library: .standard)
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isFavorite })
        let model = ViewerAssetModel(asset: asset, service: mock, loader: ImageLoader(service: mock, disk: nil))
        await mock.setFailure(.unauthorized)
        await model.toggleFavorite()
        XCTAssertFalse(model.asset.isFavorite)
        XCTAssertNotNil(model.error)
    }

    func testPlaceTitleUsesTheMostSpecificLocation() async throws {
        let mock = MockImmichService(library: .standard)
        let withCity = try XCTUnwrap(MockLibrary.standard.assets.first { $0.exif?.city != nil })
        let model = ViewerAssetModel(asset: withCity, service: mock, loader: ImageLoader(service: mock, disk: nil))
        XCTAssertEqual(model.placeTitle, withCity.exif?.city)
        let noExif = try XCTUnwrap(MockLibrary.standard.assets.first { $0.exif == nil } ?? {
            var copy = MockLibrary.standard.assets[0]
            copy.exif = nil
            return copy
        }())
        XCTAssertNil(ViewerAssetModel(asset: noExif, service: mock, loader: ImageLoader(service: mock, disk: nil)).placeTitle)
    }

    func testViewerStoreReusesModelsPerAsset() {
        let mock = MockImmichService.preview
        let store = ViewerStore(service: mock, loader: ImageLoader(service: mock, disk: nil))
        let assets = MockLibrary.standard.assets
        XCTAssertTrue(store.model(for: assets[0]) === store.model(for: assets[0]))
        XCTAssertFalse(store.model(for: assets[0]) === store.model(for: assets[1]))
    }

    func testSharedFileKeepsTheOriginalNameAndReplacesEarlierShares() throws {
        var asset = MockLibrary.standard.assets[0]
        asset.originalFileName = "IMG_0001.HEIC"
        let first = try SharedFile.write(Data([1, 2, 3]), for: asset)
        XCTAssertEqual(first.lastPathComponent, "IMG_0001.HEIC")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))

        asset.originalFileName = "a/b.jpg"
        let second = try SharedFile.write(Data([4]), for: asset)
        XCTAssertEqual(second.lastPathComponent, "a_b.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        asset.originalFileName = "  "
        XCTAssertEqual(SharedFile.fileName(for: asset), asset.id + (asset.isVideo ? ".mov" : ".jpg"))
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    func testThumbnailStripShowsAStableWindowAroundTheCurrentItem() {
        let assets = MockLibrary.standard.assets
        XCTAssertGreaterThan(assets.count, 300)
        let window = ThumbnailStrip.window(of: assets, around: 200)
        XCTAssertTrue(window.contains { $0.id == assets[200].id })
        XCTAssertLessThanOrEqual(window.count, 240)
        // Swiping within the same step keeps the window (the strip doesn't jump).
        XCTAssertEqual(ThumbnailStrip.window(of: assets, around: 201).indices, window.indices)
        // Edges are clamped and the current item is always inside.
        XCTAssertEqual(ThumbnailStrip.window(of: assets, around: 0).startIndex, 0)
        let last = ThumbnailStrip.window(of: assets, around: assets.count - 1)
        XCTAssertEqual(last.endIndex, assets.count)
        for index in [0, 59, 60, 119, assets.count / 2, assets.count - 1] {
            XCTAssertTrue(ThumbnailStrip.window(of: assets, around: index).indices.contains(index), "index \(index)")
        }
        XCTAssertTrue(ThumbnailStrip.window(of: [], around: 5).isEmpty)
    }

    func testViewerKeepsTheGridMonthLoaded() async throws {
        let mock = MockImmichService.preview
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        // The two newest months load first; showing a photo of the older one loads its neighbour.
        let shownMonth = model.months[model.months.count - 2]
        XCTAssertTrue(shownMonth.isLoaded)
        let asset = try XCTUnwrap(shownMonth.assets.first)
        let previous = model.months.count - 3
        XCTAssertFalse(model.months[previous].isLoaded)
        model.assetShownInViewer(asset.id)
        model.assetShownInViewer("unknown")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.months[previous].isLoaded && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.months[previous].isLoaded, "the neighbour month of the shown photo loads")
    }

    // MARK: Library header

    func testHeaderSubtitleFollowsTheMonthOnScreen() async throws {
        let mock = MockImmichService.preview
        let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await model.load()
        XCTAssertNil(model.visibleMonthTitle)
        let last = try XCTUnwrap(model.months.last)
        let asset = try XCTUnwrap(last.assets.first)
        model.assetAppeared(asset.id)
        XCTAssertEqual(model.visibleMonthTitle, LibraryGridModel.monthTitle(for: last.bucket))
        model.stopPrefetching()
    }
}
