import Foundation
import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// An asset deleted on the server (the website, another device) while Bloom still lists it.
@MainActor
final class ViewerMissingAssetTests: XCTestCase {
    override func setUp() { super.setUp(); Localization.languageOverride = "en" }
    override func tearDown() { Localization.languageOverride = nil; super.tearDown() }

    private func asset(_ id: String, _ year: Int, _ month: Int, _ day: Int) -> Asset {
        let date = Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Asset(id: id, kind: .image, takenAt: date)
    }

    private func model(for asset: Asset, service: MockImmichService, missing: @escaping @MainActor (String) -> Void = { _ in })
        -> ViewerAssetModel {
        let model = ViewerAssetModel(asset: asset, service: service, loader: ImageLoader(service: service, disk: nil))
        model.onMissing = missing
        return model
    }

    func testAssetGoneFromServerSaysSoAndReportsIt() async throws {
        let gone = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let mock = MockImmichService(library: .standard)
        // The server answers 400 "Not found or no asset.read access" for a deleted asset.
        await mock.setAssets(MockLibrary.standard.assets.filter { $0.id != gone.id })
        var reported: [String] = []
        let model = model(for: gone, service: mock) { reported.append($0) }
        await model.load()
        XCTAssertTrue(model.isMissing)
        XCTAssertEqual(model.error, "This item is no longer on the server.")
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(reported, [gone.id])
    }

    func testNotFoundStatusIsMissing() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first)
        let mock = MockImmichService(library: .standard)
        await mock.setFailure(.unexpectedStatus(404))
        var reported: [String] = []
        let model = model(for: asset, service: mock) { reported.append($0) }
        await model.load()
        XCTAssertTrue(model.isMissing)
        XCTAssertEqual(model.error, "This item is no longer on the server.")
        XCTAssertEqual(reported, [asset.id])
    }

    func testOtherFailuresKeepTryAgainMessage() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first)
        for failure: ImmichServiceError in [.unexpectedStatus(500), .network("offline"), .unauthorized, .invalidResponse] {
            let mock = MockImmichService(library: .standard)
            await mock.setFailure(failure)
            var reported: [String] = []
            let model = model(for: asset, service: mock) { reported.append($0) }
            await model.load()
            XCTAssertFalse(model.isMissing, "\(failure)")
            XCTAssertEqual(model.error, "Couldn't load this item. Please try again.", "\(failure)")
            XCTAssertEqual(reported, [], "\(failure)")
        }
    }

    func testLoadAfterAssetIsBackClearsMissing() async throws {
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let mock = MockImmichService(library: .standard)
        await mock.setFailure(.unexpectedStatus(404))
        let model = model(for: asset, service: mock)
        await model.load()
        XCTAssertTrue(model.isMissing)
        await mock.setFailure(nil)
        await model.load()
        XCTAssertFalse(model.isMissing)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isLoaded)
    }

    func testViewerStoreForwardsMissingAssets() async throws {
        let gone = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let mock = MockImmichService(library: .standard)
        await mock.setAssets(MockLibrary.standard.assets.filter { $0.id != gone.id })
        var reported: [String] = []
        let store = ViewerStore(service: mock, loader: ImageLoader(service: mock, disk: nil),
                                onMissing: { reported.append($0) })
        await store.model(for: gone).load()
        XCTAssertEqual(reported, [gone.id])
    }

    // MARK: Library grid

    func testLibraryHidesAssetMissingOnServer() async {
        let mock = MockImmichService(assets: [asset("kept", 2026, 11, 2), asset("gone", 2026, 11, 3)])
        let model = LibraryGridModel(service: mock) // oldest first, like the Library tab
        await model.load()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept", "gone"])
        await mock.setAssets([asset("kept", 2026, 11, 2)])

        model.assetMissingOnServer("gone")
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept"])
        XCTAssertNil(model.gridIndex(ofAsset: "gone"))
        XCTAssertEqual(model.totalCount, 1)

        // A later month load or revalidation does not bring it back.
        await model.revalidate()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept"])
        model.stopPrefetching()
    }

    func testRecentlyDeletedHidesAssetMissingOnServer() async {
        let date = { (day: Int) in Asset.localCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))! }
        let mock = MockImmichService(assets: [
            Asset(id: "other", kind: .image, takenAt: date(2), isTrashed: true),
            Asset(id: "gone", kind: .image, takenAt: date(3), isTrashed: true),
        ])
        let model = LibraryGridModel(service: mock, options: TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false))
        await model.load()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["other", "gone"])
        model.assetMissingOnServer("gone")
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["other"])
        model.stopPrefetching()
    }

    func testMissingAssetDuringWriteIsHiddenAfterIt() async throws {
        let mock = MockImmichService(assets: [asset("kept", 2026, 11, 2), asset("gone", 2026, 11, 3)])
        let model = LibraryGridModel(service: mock) // oldest first, like the Library tab
        await model.load()
        await mock.setAssets([asset("kept", 2026, 11, 2)])
        model.isTrashing = true
        model.assetMissingOnServer("gone")
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept", "gone"])
        model.isTrashing = false
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept"])
        model.stopPrefetching()
    }

    // MARK: Preview errors

    func testPreviewNotFoundWhileAssetExistsIsNotMissing() async throws {
        // A photo uploaded a moment ago: Immich answers 404 "Asset media not found" until its
        // preview is generated, although the asset exists.
        let asset = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let mock = MockImmichService(library: .standard)
        await mock.setThumbnailFailure(.unexpectedStatus(404))
        var reported: [String] = []
        let model = model(for: asset, service: mock) { reported.append($0) }
        await model.load()
        XCTAssertFalse(model.isMissing)
        XCTAssertEqual(model.error, "Couldn't load this item. Please try again.")
        XCTAssertEqual(reported, [])
        let detailRequests = await mock.requestCount(.asset(asset.id))
        XCTAssertEqual(detailRequests, 1)
    }

    func testPreviewAndAssetBadRequestIsMissing() async throws {
        let gone = try XCTUnwrap(MockLibrary.standard.assets.first { !$0.isVideo })
        let mock = MockImmichService(library: .standard)
        await mock.setAssets(MockLibrary.standard.assets.filter { $0.id != gone.id })
        await mock.setThumbnailFailure(.unexpectedStatus(400))
        var reported: [String] = []
        let model = model(for: gone, service: mock) { reported.append($0) }
        await model.load()
        XCTAssertTrue(model.isMissing)
        XCTAssertEqual(model.error, "This item is no longer on the server.")
        XCTAssertEqual(reported, [gone.id])
    }

    // MARK: Open viewer

    func testMissingOpenPhotoLoadsOnceAndLeavesGridAloneUntilViewerCloses() async throws {
        let mock = MockImmichService(assets: [asset("kept", 2026, 11, 2), asset("gone", 2026, 11, 3)])
        let library = LibraryGridModel(service: mock)
        await library.load()
        await mock.setAssets([asset("kept", 2026, 11, 2)])
        library.viewerPresentationChanged(isOpen: true)
        let store = ViewerStore(service: mock, loader: library.loader, onMissing: library.assetMissingOnServer)
        let viewerAssets = library.viewerAssets(around: "gone")
        let page = store.model(for: try XCTUnwrap(viewerAssets.first { $0.id == "gone" }))
        await page.load()
        XCTAssertTrue(page.isMissing)
        // Nothing behind the open viewer changes, so it isn't rebuilt and doesn't reload.
        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), ["kept", "gone"])
        XCTAssertEqual(library.viewerAssets(around: "kept").map(\.id), viewerAssets.map(\.id))
        XCTAssertTrue(store.model(for: page.asset) === page)
        let detailRequests = await mock.requestCount(.asset("gone"))
        XCTAssertEqual(detailRequests, 1)

        library.viewerPresentationChanged(isOpen: false)
        XCTAssertEqual(library.months.flatMap(\.assets).map(\.id), ["kept"])
        library.stopPrefetching()
    }

    // MARK: Missing ids are confirmed by the server

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewerMissingAssetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMissingAssetDoesNotPushNextLoadOntoFreshTimeline() async throws {
        let assets = [asset("old", 2026, 6, 1), asset("gone", 2026, 6, 2), asset("mid", 2026, 8, 1),
                      asset("new", 2026, 10, 1), asset("newest", 2026, 11, 1)]
        let mock = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: mock, snapshotStore: TimelineSnapshotStore(directory: try directory()))
        await model.load()
        await model.loadAllMonths()
        await mock.setAssets(assets.filter { $0.id != "gone" })
        model.assetMissingOnServer("gone")
        XCTAssertFalse(model.edits.missingIDs.isEmpty)
        XCTAssertTrue(model.edits.trashedIDs.isEmpty)

        // The backup reload: a full `load()` keeps the loaded months (no placeholders).
        await model.load()
        XCTAssertTrue(model.allMonthsLoaded)
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["old", "mid", "new", "newest"])
        // The refreshed month confirmed it: nothing left to hide locally.
        XCTAssertTrue(model.edits.missingIDs.isEmpty)
        model.stopPrefetching()
    }

    func testRevalidationBringsBackAssetTheServerStillHas() async throws {
        let assets = [asset("a", 2026, 6, 1), asset("b", 2026, 6, 2), asset("c", 2026, 11, 1)]
        let mock = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: mock, snapshotStore: TimelineSnapshotStore(directory: try directory()))
        await model.load()
        await model.loadAllMonths()
        model.assetMissingOnServer("b") // e.g. a passing access error
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["a", "c"])
        await model.revalidate()
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["a", "b", "c"])
        XCTAssertTrue(model.edits.missingIDs.isEmpty)
        model.stopPrefetching()
    }
}
