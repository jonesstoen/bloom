import Foundation
import XCTest
@testable import ImmichKit

final class TimelineSnapshotTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sampleMonths() -> [TimelineMonth] {
        let date = Asset.localCalendar.date(from: DateComponents(year: 2024, month: 3, day: 4))!
        let photo = Asset(id: "photo-1", kind: .image, takenAt: date, isFavorite: true)
        let day = TimelineDay(year: 2024, month: 3, day: 4, assets: [photo])
        return [TimelineMonth(bucket: TimeBucket(id: "2024-03-01", year: 2024, month: 3, count: 2), days: [day])]
    }

    func testPersistsLoadedMonthsAcrossFreshStoreAndPreservesBucketCountMismatch() async throws {
        let directory = try temporaryDirectory()
        let options = TimelineOptions.library
        let writer = TimelineSnapshotStore(directory: directory)
        await writer.save(months: sampleMonths(), options: options)

        let reopened = TimelineSnapshotStore(directory: directory)
        let restored = await reopened.load(options: options)
        XCTAssertEqual(restored, sampleMonths())
        XCTAssertEqual(restored?.first?.bucket.count, 2)
        XCTAssertEqual(restored?.first?.assetCount, 1, "stacked timeline results may be fewer than the bucket count")
    }

    func testOptionsArePartitioned() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: sampleMonths(), options: .library)
        let favorites = await store.load(options: TimelineOptions(isFavorite: true))
        XCTAssertNil(favorites)

        var recentlyAdded = TimelineOptions.library
        recentlyAdded.sortsByDateAdded = true
        let sorted = await store.load(options: recentlyAdded)
        XCTAssertNil(sorted)
    }

    func testMissingCorruptAndIncompatibleSnapshotsAreSafeMisses() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        let missing = await store.load(options: .library)
        XCTAssertNil(missing)
        await store.save(months: sampleMonths(), options: .library)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("not-json".utf8).write(to: file)
        let corrupt = await TimelineSnapshotStore(directory: directory).load(options: .library)
        XCTAssertNil(corrupt)
    }

    func testIncompatibleVersionIsASafeMiss() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: sampleMonths(), options: .library)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        let incompatible = await TimelineSnapshotStore(directory: directory).load(options: .library)
        XCTAssertNil(incompatible)
    }

    func testDuplicateBucketsAndAssetsAreSafeMisses() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: sampleMonths(), options: .library)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var months = try XCTUnwrap(envelope["months"] as? [[String: Any]])
        months.append(months[0])
        envelope["months"] = months
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        let duplicateBuckets = await TimelineSnapshotStore(directory: directory).load(options: .library)
        XCTAssertNil(duplicateBuckets)

        await store.save(months: sampleMonths(), options: .library)
        envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        months = try XCTUnwrap(envelope["months"] as? [[String: Any]])
        var month = try XCTUnwrap(months.first)
        var days = try XCTUnwrap(month["days"] as? [[String: Any]])
        var day = try XCTUnwrap(days.first)
        var assets = try XCTUnwrap(day["assets"] as? [[String: Any]])
        assets.append(assets[0])
        day["assets"] = assets
        days[0] = day
        month["days"] = days
        months[0] = month
        envelope["months"] = months
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        let duplicateAssets = await TimelineSnapshotStore(directory: directory).load(options: .library)
        XCTAssertNil(duplicateAssets)
    }

    func testOversizedSnapshotIsNotRestored() async throws {
        let directory = try temporaryDirectory()
        let writer = TimelineSnapshotStore(directory: directory)
        await writer.save(months: sampleMonths(), options: .library)
        let oversized = await TimelineSnapshotStore(directory: directory, byteLimit: 1).load(options: .library)
        XCTAssertNil(oversized)
    }

    func testInvalidationPreventsLaterWritesFromRecreatingSnapshot() async throws {
        let directory = try temporaryDirectory()
        let store = TimelineSnapshotStore(directory: directory)
        await store.save(months: sampleMonths(), options: .library)
        await store.invalidate()
        await store.save(months: sampleMonths(), options: .library)
        let afterInvalidation = await store.load(options: .library)
        XCTAssertNil(afterInvalidation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
