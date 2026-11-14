import Foundation
import SwiftUI
import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Coming back to Bloom after a while in the background revalidates the Library, like Photos.
@MainActor
final class LibraryForegroundRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func asset(_ id: String, _ year: Int, _ month: Int, _ day: Int) -> Asset {
        let date = Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Asset(id: id, kind: .image, takenAt: date)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryForegroundRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var ids: (LibraryGridModel) -> [String] { { $0.months.flatMap(\.assets).map(\.id) } }

    // MARK: Trigger decision

    func testThresholdIsThirtySeconds() {
        XCTAssertEqual(LibraryForegroundRefresh.minimumBackgroundDuration, 30)
    }

    func testReturningAfterThirtyOneSecondsInBackgroundRevalidates() {
        var refresh = LibraryForegroundRefresh()
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start))
        XCTAssertFalse(refresh.phaseChanged(to: .inactive, at: start))
        XCTAssertFalse(refresh.phaseChanged(to: .background, at: start))
        // Coming back goes background → inactive → active.
        XCTAssertFalse(refresh.phaseChanged(to: .inactive, at: start.addingTimeInterval(30.5)))
        XCTAssertTrue(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(31)))
        // Only once per return.
        XCTAssertFalse(refresh.phaseChanged(to: .inactive, at: start.addingTimeInterval(40)))
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(41)))
    }

    func testShortStayInBackgroundDoesNotRevalidate() {
        var refresh = LibraryForegroundRefresh()
        _ = refresh.phaseChanged(to: .active, at: start)
        _ = refresh.phaseChanged(to: .inactive, at: start)
        XCTAssertFalse(refresh.phaseChanged(to: .background, at: start))
        XCTAssertFalse(refresh.phaseChanged(to: .inactive, at: start.addingTimeInterval(4)))
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(5)))
        // The short stay does not count toward a later one.
        _ = refresh.phaseChanged(to: .background, at: start.addingTimeInterval(100))
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(110)))
    }

    func testInactiveToActiveDoesNotRevalidate() {
        // Control Center, Face ID or a system prompt: never in the background.
        var refresh = LibraryForegroundRefresh()
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start))
        XCTAssertFalse(refresh.phaseChanged(to: .inactive, at: start.addingTimeInterval(1)))
        XCTAssertFalse(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(120)))
    }

    func testBackgroundTimeCountsFromFirstBackgroundPhase() {
        var refresh = LibraryForegroundRefresh()
        _ = refresh.phaseChanged(to: .background, at: start)
        _ = refresh.phaseChanged(to: .background, at: start.addingTimeInterval(25))
        XCTAssertTrue(refresh.phaseChanged(to: .active, at: start.addingTimeInterval(31)))
    }

    // MARK: Session wiring

    func testSessionRevalidatesLibraryAfterLongBackgroundAndDropsAssetDeletedElsewhere() async throws {
        let mock = MockImmichService(assets: [asset("kept", 2026, 10, 2), asset("deleted", 2026, 11, 3)])
        let session = ImmichSession(service: mock, disk: nil)
        _ = session.scenePhaseChanged(.active, at: start)
        await session.library.load()
        XCTAssertEqual(ids(session.library), ["kept", "deleted"])

        await mock.setAssets([asset("kept", 2026, 10, 2)]) // deleted on the Immich website
        XCTAssertNil(session.scenePhaseChanged(.inactive, at: start))
        XCTAssertNil(session.scenePhaseChanged(.background, at: start))
        XCTAssertNil(session.scenePhaseChanged(.inactive, at: start.addingTimeInterval(31)))
        let task = try XCTUnwrap(session.scenePhaseChanged(.active, at: start.addingTimeInterval(31)))
        await task.value
        XCTAssertEqual(ids(session.library), ["kept"])
        session.library.stopPrefetching()
    }

    func testSessionDoesNotRevalidateAfterShortBackground() async {
        let mock = MockImmichService(assets: [asset("a", 2026, 11, 3)])
        let session = ImmichSession(service: mock, disk: nil)
        _ = session.scenePhaseChanged(.active, at: start)
        await session.library.load()
        let before = await mock.requestCount(.timeBuckets)
        _ = session.scenePhaseChanged(.background, at: start)
        XCTAssertNil(session.scenePhaseChanged(.active, at: start.addingTimeInterval(5)))
        let after = await mock.requestCount(.timeBuckets)
        XCTAssertEqual(after, before)
        session.library.stopPrefetching()
    }

    // MARK: Model revalidation

    func testRevalidationRefreshesLoadedMonthsInPlace() async throws {
        let directory = try temporaryDirectory()
        let assets = [
            asset("old-kept", 2026, 6, 1), asset("old-deleted", 2026, 6, 2),
            asset("mid", 2026, 8, 1), asset("new", 2026, 10, 1), asset("newest", 2026, 11, 1),
        ]
        let mock = MockImmichService(assets: assets)
        let model = LibraryGridModel(service: mock, options: .library,
                                     snapshotStore: TimelineSnapshotStore(directory: directory))
        await model.load()
        await model.loadAllMonths()
        XCTAssertTrue(model.allMonthsLoaded)

        await mock.setAssets(assets.filter { $0.id != "old-deleted" } + [asset("added", 2026, 8, 2)])
        await model.revalidate()
        XCTAssertEqual(Set(ids(model)), ["old-kept", "mid", "added", "new", "newest"])
        // Months already on screen stay loaded (no placeholders that could move the grid).
        XCTAssertTrue(model.allMonthsLoaded)
        model.stopPrefetching()
    }

    func testRevalidationWaitsWhileViewerIsOpen() async throws {
        let mock = MockImmichService(assets: [asset("kept", 2026, 10, 2), asset("deleted", 2026, 11, 3)])
        let model = LibraryGridModel(service: mock, options: .library)
        await model.load()
        await mock.setAssets([asset("kept", 2026, 10, 2)])
        let before = await mock.requestCount(.timeBuckets)

        XCTAssertNil(model.viewerPresentationChanged(isOpen: true))
        await model.revalidate()
        let during = await mock.requestCount(.timeBuckets)
        XCTAssertEqual(during, before)
        XCTAssertEqual(Set(ids(model)), ["kept", "deleted"])

        let task = try XCTUnwrap(model.viewerPresentationChanged(isOpen: false))
        await task.value
        XCTAssertEqual(ids(model), ["kept"])
        // Closing again without a pending revalidation does nothing.
        XCTAssertNil(model.viewerPresentationChanged(isOpen: false))
        model.stopPrefetching()
    }

    func testRevalidationSkipsWhileMutating() async {
        let mock = MockImmichService(assets: [asset("a", 2026, 11, 3)])
        let model = LibraryGridModel(service: mock, options: .library)
        await model.load()
        let before = await mock.requestCount(.timeBuckets)
        model.isTrashing = true
        await model.revalidate()
        model.isTrashing = false
        let after = await mock.requestCount(.timeBuckets)
        XCTAssertEqual(after, before)
        model.stopPrefetching()
    }
}
