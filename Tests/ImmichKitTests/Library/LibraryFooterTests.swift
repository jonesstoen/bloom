import XCTest
import ImmichKit
@testable import ImmichUI

/// User-visible footer output for the Library grid.
@MainActor
final class LibraryFooterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Localization.languageOverride = "en"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        super.tearDown()
    }

    private func asset(_ id: String, kind: Asset.Kind = .image, day: Int = 1, favorite: Bool = false) -> Asset {
        let date = Asset.localCalendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 12))!
        return Asset(id: id, kind: kind, takenAt: date, isFavorite: favorite)
    }

    private func loadedModel(assets: [Asset]) async -> LibraryGridModel {
        let service = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: service, loader: ImageLoader(service: service, disk: nil))
        await model.load()
        await model.loadAllMonths()
        return model
    }

    func testPartiallyLoadedTimelineReportsTotalItemCount() async {
        let service = MockImmichService(library: .standard)
        let model = LibraryGridModel(service: service, loader: ImageLoader(service: service, disk: nil))
        await model.load()

        XCTAssertGreaterThan(model.months.filter { !$0.isLoaded }.count, 2)
        let expectedCount = model.totalCount.formatted(.number.locale(Localization.locale))
        XCTAssertEqual(model.footerText, "\(expectedCount) Items")
    }

    func testLoadedTimelineFormatsSingularAndPluralPhotosAndVideos() async {
        let photosAndVideo = await loadedModel(assets: [
            asset("photo-1"), asset("photo-2", day: 2), asset("video-1", kind: .video, day: 3)
        ])
        XCTAssertEqual(photosAndVideo.footerText, "2 Photos, 1 Video")

        let photoAndVideos = await loadedModel(assets: [
            asset("photo"), asset("video-1", kind: .video, day: 2), asset("video-2", kind: .video, day: 3)
        ])
        XCTAssertEqual(photoAndVideos.footerText, "1 Photo, 2 Videos")
    }

    func testFavoriteFilterAndRemovalUpdateLoadedFooterCount() async {
        let model = await loadedModel(assets: [asset("favorite", favorite: true), asset("ordinary", day: 2)])
        XCTAssertEqual(model.footerText, "2 Photos")

        var options = model.options
        options.isFavorite = true
        await model.setOptions(options)
        XCTAssertEqual(model.footerText, "1 Photo")

        guard var removedFavorite = model.months.flatMap(\.assets).first else {
            XCTFail("Favorite filter should contain the favorite asset")
            return
        }
        removedFavorite.isFavorite = false
        model.applyFavoriteUpdates([removedFavorite])
        XCTAssertEqual(model.footerText, "0 Photos")
    }

    func testEmptyLoadedTimelineShowsZeroPhotos() async {
        let model = await loadedModel(assets: [])
        XCTAssertEqual(model.footerText, "0 Photos")
    }

    func testFooterUsesCurrentLanguageWithoutReloadingModel() async {
        let model = await loadedModel(assets: [asset("photo")])
        XCTAssertEqual(model.footerText, "1 Photo")

        let previousLanguage = Localization.languageOverride
        defer { Localization.languageOverride = previousLanguage }
        Localization.languageOverride = "nb"
        XCTAssertEqual(model.footerText, "1 bilde")
    }

    func testRepeatedFooterAccessForLargeLoadedMonth() async {
        let date = Asset.localCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let assets = (0..<13_000).map { index in
            Asset(id: "asset-\(index)", kind: index.isMultiple(of: 10) ? .video : .image, takenAt: date)
        }
        let model = await loadedModel(assets: assets)
        XCTAssertEqual(model.months.count, 1)

        var footerSink = ""
        measure {
            for _ in 0..<100 { footerSink = model.footerText }
        }
        XCTAssertFalse(footerSink.isEmpty)
    }
}
