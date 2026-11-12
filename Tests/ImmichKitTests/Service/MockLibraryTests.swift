import CoreGraphics
import ImageIO
import XCTest
@testable import ImmichKit

final class MockLibraryTests: XCTestCase {
    private let library = MockLibrary.standard

    func testIsDeterministic() {
        let a = MockLibrary(seed: 7, assetCount: 120)
        let b = MockLibrary(seed: 7, assetCount: 120)
        XCTAssertEqual(a.assets, b.assets)
        XCTAssertEqual(a.albums, b.albums)
        XCTAssertEqual(a.people, b.people)
        XCTAssertEqual(a.memories, b.memories)
        XCTAssertEqual(a.albumAssetIDs, b.albumAssetIDs)
        XCTAssertEqual(a.personAssetIDs, b.personAssetIDs)

        let other = MockLibrary(seed: 8, assetCount: 120)
        XCTAssertNotEqual(a.assets.map(\.takenAt), other.assets.map(\.takenAt))
    }

    func testAssetsSpanSeveralYearsWithUniqueIDs() {
        XCTAssertEqual(library.assets.count, 400)
        XCTAssertEqual(Set(library.assets.map(\.id)).count, 400)
        XCTAssertTrue(library.assets.allSatisfy { UUID(uuidString: $0.id) != nil })
        let years = Set(library.assets.map { Asset.localCalendar.component(.year, from: $0.localDateTime) })
        XCTAssertGreaterThanOrEqual(years.count, 5)
        XCTAssertTrue(library.assets.allSatisfy { $0.takenAt <= library.referenceDate })
        XCTAssertEqual(library.assets, library.assets.sorted { $0.takenAt > $1.takenAt })
    }

    func testAssetsHaveVariety() {
        let assets = library.assets
        XCTAssertTrue(assets.contains { $0.kind == .video && ($0.duration ?? 0) > 0 })
        XCTAssertTrue(assets.contains { $0.isLivePhoto })
        XCTAssertTrue(assets.contains { $0.isFavorite })
        XCTAssertTrue(assets.contains { $0.isArchived })
        XCTAssertTrue(assets.contains { $0.size.map { $0.height > $0.width } ?? false })
        XCTAssertTrue(assets.contains { $0.size.map { $0.width > $0.height } ?? false })
        XCTAssertTrue(assets.allSatisfy { $0.exif?.cameraName != nil && $0.exif?.locationName != nil })
        XCTAssertTrue(assets.filter { $0.kind == .image }.allSatisfy { $0.duration == nil })
        XCTAssertGreaterThan(Set(assets.compactMap { $0.exif?.city }).count, 3)
        XCTAssertFalse(library.mapMarkers.isEmpty)
    }

    func testAlbumsMatchTheirAssets() {
        XCTAssertGreaterThanOrEqual(library.albums.count, 4)
        XCTAssertEqual(Set(library.albums.map(\.id)).count, library.albums.count)
        for album in library.albums {
            let assets = library.assets(inAlbum: album.id)
            XCTAssertEqual(album.assetCount, assets.count, album.name)
            XCTAssertEqual(album.thumbnailAssetId, assets.first?.id, album.name)
            XCTAssertEqual(album.startDate, assets.map(\.takenAt).min(), album.name)
            XCTAssertEqual(album.endDate, assets.map(\.takenAt).max(), album.name)
            XCTAssertFalse(assets.contains { $0.isTrashed }, album.name)
        }
        XCTAssertTrue(library.albums.contains { $0.assetCount == 0 })
        XCTAssertTrue(library.albums.contains { $0.isShared })
        let lofoten = library.albums.first { $0.name == "Summer in Lofoten" }!
        XCTAssertTrue(library.assets(inAlbum: lofoten.id).allSatisfy { $0.exif?.city == "Reine" })
        XCTAssertTrue(library.assets(inAlbum: "unknown").isEmpty)
    }

    func testPeople() {
        XCTAssertGreaterThanOrEqual(library.people.count, 5)
        XCTAssertTrue(library.people.contains { !$0.isNamed })
        XCTAssertTrue(library.people.contains { $0.isHidden })
        XCTAssertTrue(library.people.contains { $0.birthDate != nil })
        let counts = library.people.map { library.assets(withPerson: $0.id).count }
        XCTAssertEqual(counts, counts.sorted(by: >), "most photographed first")
        XCTAssertTrue(counts.allSatisfy { $0 > 0 })
    }

    func testOnThisDayMemories() {
        XCTAssertFalse(library.memories.isEmpty)
        let calendar = Asset.localCalendar
        let today = calendar.dateComponents([.year, .month, .day], from: library.referenceDate)
        for memory in library.memories {
            XCTAssertFalse(memory.assets.isEmpty)
            guard case .onThisDay(let year) = memory.kind else { return XCTFail("unexpected kind") }
            XCTAssertLessThan(year, today.year!)
            for asset in memory.assets {
                let parts = calendar.dateComponents([.year, .month, .day], from: asset.localDateTime)
                XCTAssertEqual([parts.year, parts.month, parts.day], [year, today.month, today.day])
            }
        }
        let years = library.memories.map(\.year)
        XCTAssertEqual(years, years.sorted(by: >))
    }

    func testPlaceholderIsDecodableJPEGShapedLikeTheAsset() throws {
        let data = PlaceholderImage.jpegData(assetID: "a1", size: .thumbnail, aspectRatio: 4.0 / 3.0)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG magic")
        let image = try XCTUnwrap(decode(data))
        XCTAssertEqual(image.width, 250)
        XCTAssertEqual(image.height, 188)

        let preview = try XCTUnwrap(decode(PlaceholderImage.jpegData(assetID: "a1", size: .preview, aspectRatio: 0.75)))
        XCTAssertEqual(preview.height, 1024)
        XCTAssertEqual(preview.width, 768)

        XCTAssertEqual(data, PlaceholderImage.jpegData(assetID: "a1", size: .thumbnail, aspectRatio: 4.0 / 3.0))
        XCTAssertNotEqual(data, PlaceholderImage.jpegData(assetID: "a2", size: .thumbnail, aspectRatio: 4.0 / 3.0))
    }

    func testServiceFiltersByAlbumAndPerson() async throws {
        let mock = MockImmichService(library: library)
        let album = library.albums.first { $0.assetCount > 0 }!
        let albumAssets = try await allAssets(mock, options: .album(album.id))
        XCTAssertEqual(Set(albumAssets.map(\.id)), Set(library.albumAssetIDs[album.id]!))

        let person = library.people[0]
        let personAssets = try await allAssets(mock, options: .person(person.id))
        let expected = library.assets(withPerson: person.id).filter { !$0.isArchived && !$0.isTrashed }
        XCTAssertEqual(Set(personAssets.map(\.id)), Set(expected.map(\.id)))

        let library = try await allAssets(mock, options: .library)
        XCTAssertEqual(library.count, self.library.assets.filter { !$0.isArchived && !$0.isTrashed }.count)
    }

    func testServiceThumbnailMatchesAssetShape() async throws {
        let mock = MockImmichService.preview
        let asset = library.assets.first { ($0.size?.height ?? 0) > ($0.size?.width ?? 0) }!
        let data = try await mock.thumbnail(assetID: asset.id, size: .thumbnail)
        let image = try XCTUnwrap(decode(data))
        XCTAssertGreaterThan(image.height, image.width)
    }

    func testTimelineOverPreviewLibrary() async throws {
        let timeline = Timeline(service: MockImmichService.preview)
        let months = try await timeline.loadBuckets()
        XCTAssertGreaterThan(months.count, 24)
        let first = try await timeline.loadMonth(months[0].id)
        XCTAssertFalse(first.isEmpty)
    }

    // MARK: Helpers

    private func allAssets(_ mock: MockImmichService, options: TimelineOptions) async throws -> [Asset] {
        var result: [Asset] = []
        for bucket in try await mock.timeBuckets(options: options) {
            let assets = try await mock.timeBucketAssets(bucketID: bucket.id, options: options)
            XCTAssertEqual(assets.count, bucket.count)
            result += assets
        }
        return result
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
