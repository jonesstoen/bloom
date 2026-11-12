import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class SelectionShareTests: XCTestCase {
    func testSharesOriginalsWithUniqueSafeNamesAndCleansUpAfterDismissal() async throws {
        let (library, _, assets) = await selectionFixture()
        let downloader = OriginalFileDownloader { request, destination in
            try Data(request.assetID.utf8).write(to: destination)
        }
        let selection = LibrarySelectionModel(library: library, downloader: downloader)
        selection.start()
        assets.forEach(selection.toggle)
        await selection.prepareShare()
        let share = try XCTUnwrap(selection.sharedFiles)
        defer { selection.finishSharing() }
        XCTAssertEqual(share.urls.count, assets.count)
        XCTAssertEqual(Set(share.urls).count, assets.count)
        XCTAssertEqual(share.urls[0].lastPathComponent, "photo.jpg")
        XCTAssertEqual(share.urls[1].lastPathComponent, "photo.jpg")
        for (url, asset) in zip(share.urls, assets) {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(share.directory.standardizedFileURL.path + "/"))
            XCTAssertEqual(try Data(contentsOf: url), Data(asset.id.utf8))
        }
        selection.finishSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.directory.path))
        XCTAssertNil(selection.sharedFiles)
        XCTAssertFalse(selection.isBusy)
    }

    func testDotNamesCannotEscapeBatchDirectory() async throws {
        let (library, _, assets) = await selectionFixture(names: [".", "..", "/\\"])
        let selection = LibrarySelectionModel(library: library, downloader: OriginalFileDownloader { _, destination in
            try Data([7]).write(to: destination)
        })
        selection.start()
        assets.forEach(selection.toggle)
        await selection.prepareShare()
        let share = try XCTUnwrap(selection.sharedFiles)
        defer { selection.finishSharing() }
        XCTAssertEqual(share.urls.count, 3)
        for url in share.urls {
            XCTAssertFalse([".", "..", ""].contains(url.lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: url), Data([7]))
        }
    }

    func testFailedDownloadPublishesNoPartialShareAndRemovesBatchDirectory() async throws {
        let (library, _, assets) = await selectionFixture()
        let recorder = ShareDestinationRecorder()
        let selection = LibrarySelectionModel(library: library, downloader: OriginalFileDownloader { request, destination in
            await recorder.record(destination)
            if request.assetID == assets[1].id { throw ImmichServiceError.unauthorized }
            try Data([1]).write(to: destination)
        })
        selection.start()
        assets.forEach(selection.toggle)
        await selection.prepareShare()
        XCTAssertNil(selection.sharedFiles)
        XCTAssertNotNil(selection.error)
        XCTAssertFalse(selection.isBusy)
        XCTAssertEqual(selection.selectedCount, assets.count)
        let paths = await recorder.destinations
        XCTAssertEqual(paths.count, 2)
        for path in paths {
            let batchDirectory = path.deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: batchDirectory.path))
        }
    }

    func testCancellationDoesNotPublishOrLeaveBatchDirectory() async throws {
        let (library, _, assets) = await selectionFixture()
        let recorder = ShareDestinationRecorder()
        let selection = LibrarySelectionModel(library: library, downloader: OriginalFileDownloader { _, destination in
            await recorder.record(destination)
            try await Task.sleep(for: .seconds(30))
            try Data([1]).write(to: destination)
        })
        selection.start()
        selection.toggle(assets[0])
        let request = Task { await selection.prepareShare() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.destinations.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        selection.cancelSharePreparation()
        await request.value
        XCTAssertNil(selection.sharedFiles)
        XCTAssertNil(selection.error)
        XCTAssertFalse(selection.isBusy)
        XCTAssertEqual(selection.selectedCount, 1)
        let paths = await recorder.destinations
        XCTAssertFalse(paths.isEmpty)
        for path in paths {
            let batchDirectory = path.deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: batchDirectory.path))
        }
    }

    func testExternalTaskCancellationCleansBatchDirectory() async throws {
        let (library, _, assets) = await selectionFixture()
        let recorder = ShareDestinationRecorder()
        let selection = LibrarySelectionModel(library: library, downloader: OriginalFileDownloader { _, destination in
            await recorder.record(destination)
            try await Task.sleep(for: .seconds(30))
            try Data([1]).write(to: destination)
        })
        selection.start()
        selection.toggle(assets[0])
        let request = Task { await selection.prepareShare() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.destinations.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        request.cancel()
        await request.value
        XCTAssertNil(selection.sharedFiles)
        XCTAssertNil(selection.error)
        XCTAssertFalse(selection.isBusy)
        let paths = await recorder.destinations
        XCTAssertFalse(paths.isEmpty)
        for path in paths {
            let batchDirectory = path.deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: batchDirectory.path))
        }
    }

    func testMissingTimelineFilenameUsesFetchedOriginalMetadataAndKeepsExtension() async throws {
        let gridAsset = Asset(id: "nameless-grid", kind: .image,
                              takenAt: ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!)
        var detailedAsset = gridAsset
        detailedAsset.originalFileName = "IMG_2048.HEIC"
        detailedAsset.mimeType = "image/heic"
        let mock = MockImmichService(assets: [gridAsset])
        let library = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
        await library.load()
        await library.loadAllMonths()
        XCTAssertNil(library.gridAsset(atGridIndex: 0)?.originalFileName)
        await mock.setAssets([detailedAsset])
        let downloader = OriginalFileDownloader { _, destination in try Data([42]).write(to: destination) }
        let selection = LibrarySelectionModel(library: library, downloader: downloader)
        selection.start()
        selection.toggle(try XCTUnwrap(library.gridAsset(atGridIndex: 0)))
        await selection.prepareShare()
        let share = try XCTUnwrap(selection.sharedFiles)
        defer { selection.finishSharing() }
        XCTAssertEqual(share.urls.first?.lastPathComponent, "IMG_2048.HEIC")
        let metadataRequestsBeforeCheck = await mock.requestCount(.asset(gridAsset.id))
        XCTAssertEqual(metadataRequestsBeforeCheck, 1)
        let fetched = try await mock.asset(id: gridAsset.id)
        XCTAssertEqual(fetched.originalFileName, "IMG_2048.HEIC")
    }
}

private actor ShareDestinationRecorder {
    var destinations: [URL] = []
    func record(_ url: URL) { destinations.append(url) }
}
