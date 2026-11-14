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

    func testMissingAssetIsIgnoredDuringWrite() async {
        let mock = MockImmichService(assets: [asset("kept", 2026, 11, 2), asset("gone", 2026, 11, 3)])
        let model = LibraryGridModel(service: mock) // oldest first, like the Library tab
        await model.load()
        model.isTrashing = true
        model.assetMissingOnServer("gone")
        model.isTrashing = false
        XCTAssertEqual(model.months.flatMap(\.assets).map(\.id), ["kept", "gone"])
        model.stopPrefetching()
    }
}
