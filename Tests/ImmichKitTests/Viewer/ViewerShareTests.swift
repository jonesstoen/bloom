import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerShareTests: XCTestCase {
    func testPreparedOriginalLivesUntilFinishEvenWhenSheetBindingIsCleared() async throws {
        let asset = MockLibrary.standard.assets[0]
        let service = MockImmichService(assets: [asset])
        let model = ViewerShareModel(
            service: service,
            downloader: OriginalFileDownloader { _, destination in try Data([1, 2, 3]).write(to: destination) }
        )

        await model.prepare(asset: asset)
        let share = try XCTUnwrap(model.sharedFiles)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(share.urls.first)), Data([1, 2, 3]))
        XCTAssertTrue(model.isBusy)
        let originalRequests = await service.requestCount(.original(asset.id))
        let mediaRequests = await service.requestCount(.mediaRequest(.original, asset.id))
        XCTAssertEqual(originalRequests, 0, "Do not buffer an original in Data")
        XCTAssertEqual(mediaRequests, 1)

        model.sharedFiles = nil
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.directory.path))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(share.urls.first)), Data([1, 2, 3]))

        model.finishSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.directory.path))
        XCTAssertFalse(model.isBusy)
    }

    func testEachViewerShareOwnsItsDirectoryAndFinishingOneKeepsTheOther() async throws {
        let asset = MockLibrary.standard.assets[0]
        func makeModel(_ byte: UInt8) -> ViewerShareModel {
            ViewerShareModel(
                service: MockImmichService(assets: [asset]),
                downloader: OriginalFileDownloader { _, destination in try Data([byte]).write(to: destination) }
            )
        }
        let first = makeModel(4)
        let second = makeModel(5)

        await first.prepare(asset: asset)
        await second.prepare(asset: asset)
        let firstShare = try XCTUnwrap(first.sharedFiles)
        let secondShare = try XCTUnwrap(second.sharedFiles)
        XCTAssertNotEqual(firstShare.directory, secondShare.directory)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(firstShare.urls.first)), Data([4]))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(secondShare.urls.first)), Data([5]))

        first.finishSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstShare.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondShare.directory.path))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(secondShare.urls.first)), Data([5]))
        second.finishSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondShare.directory.path))
    }

    func testFailedDownloadPublishesNothingAndCleansPartialOutput() async throws {
        let asset = MockLibrary.standard.assets[0]
        let recorder = ViewerShareDestinationRecorder()
        let model = ViewerShareModel(
            service: MockImmichService(assets: [asset]),
            downloader: OriginalFileDownloader { _, destination in
                await recorder.record(destination)
                try Data([8]).write(to: destination)
                throw ImmichServiceError.unauthorized
            }
        )

        await model.prepare(asset: asset)

        XCTAssertNil(model.sharedFiles)
        XCTAssertTrue(model.failed)
        XCTAssertFalse(model.isBusy)
        let recordedDestination = await recorder.destination
        let destination = try XCTUnwrap(recordedDestination)
        let directory = destination.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMissingTimelineNameFetchesDetailAndPreservesHEICExtension() async throws {
        var gridAsset = MockLibrary.standard.assets[0]
        gridAsset.originalFileName = nil
        var detailedAsset = gridAsset
        detailedAsset.originalFileName = "IMG_2048.HEIC"
        detailedAsset.mimeType = "image/heic"
        let service = MockImmichService(assets: [detailedAsset])
        let model = ViewerShareModel(
            service: service,
            downloader: OriginalFileDownloader { _, destination in try Data([2]).write(to: destination) }
        )

        await model.prepare(asset: gridAsset)
        let share = try XCTUnwrap(model.sharedFiles)
        defer { model.finishSharing() }
        XCTAssertEqual(share.urls.first?.lastPathComponent, "IMG_2048.HEIC")
        let detailRequestCount = await service.requestCount(.asset(gridAsset.id))
        XCTAssertEqual(detailRequestCount, 1)
    }

    func testDuplicatePrepareWhileBusyIsIgnored() async throws {
        let asset = MockLibrary.standard.assets[0]
        let started = expectation(description: "original download started")
        let gate = ViewerShareGate(onStart: { started.fulfill() })
        let model = ViewerShareModel(
            service: MockImmichService(assets: [asset]),
            downloader: OriginalFileDownloader { _, destination in
                await gate.pause()
                try Data([9]).write(to: destination)
            }
        )

        let preparation = Task { await model.prepare(asset: asset) }
        await fulfillment(of: [started], timeout: 2)
        await model.prepare(asset: asset)
        XCTAssertTrue(model.isPreparing)
        let downloadCalls = await gate.calls
        XCTAssertEqual(downloadCalls, 1)
        await gate.release()
        await preparation.value

        XCTAssertNotNil(model.sharedFiles)
        model.finishSharing()
    }

    func testNewAttemptSurvivesLateCompletionOfCancelledAttempt() async throws {
        let asset = MockLibrary.standard.assets[0]
        let started = expectation(description: "first download waiting")
        let gate = ViewerShareGate(onStart: { started.fulfill() })
        let recorder = ViewerShareDestinationRecorder()
        let model = ViewerShareModel(service: MockImmichService(assets: [asset]), downloader: OriginalFileDownloader { _, destination in
            await recorder.record(destination)
            await gate.pause()
            try Data([6]).write(to: destination)
        })
        let first = Task { await model.prepare(asset: asset) }
        await fulfillment(of: [started], timeout: 2)
        let firstDestination = await recorder.destination
        let old = try XCTUnwrap(firstDestination)
        model.cancelPreparation()
        await model.prepare(asset: asset)
        let newer = try XCTUnwrap(model.sharedFiles)
        defer { model.finishSharing() }
        await gate.release()
        await first.value
        XCTAssertEqual(model.sharedFiles?.id, newer.id)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    func testCancellingCallerCleansAnUncooperativeDownload() async throws {
        let asset = MockLibrary.standard.assets[0]
        let started = expectation(description: "download waiting")
        let gate = ViewerShareGate(onStart: { started.fulfill() })
        let recorder = ViewerShareDestinationRecorder()
        let model = ViewerShareModel(service: MockImmichService(assets: [asset]), downloader: OriginalFileDownloader { _, destination in
            await recorder.record(destination)
            await gate.pause()
            try Data([3]).write(to: destination)
        })
        let preparation = Task { await model.prepare(asset: asset) }
        await fulfillment(of: [started], timeout: 2)
        preparation.cancel()
        await gate.release()
        await preparation.value
        XCTAssertNil(model.sharedFiles)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.failed)
        let recorded = await recorder.destination
        let destination = try XCTUnwrap(recorded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    func testOwnerDeinitializationRemovesPreparedFiles() async throws {
        let asset = MockLibrary.standard.assets[0]
        var model: ViewerShareModel? = ViewerShareModel(service: MockImmichService(assets: [asset]), downloader: OriginalFileDownloader { _, destination in
            try Data([1]).write(to: destination)
        })
        await model?.prepare(asset: asset)
        let share = try XCTUnwrap(model?.sharedFiles)
        weak var owner = model
        model = nil
        XCTAssertNil(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.directory.path))
    }

    func testCancelInvalidatesLateDownloaderResultAndCleansItsDirectory() async throws {
        let asset = MockLibrary.standard.assets[0]
        let started = expectation(description: "original download started")
        let gate = ViewerShareGate(onStart: { started.fulfill() })
        let model = ViewerShareModel(
            service: MockImmichService(assets: [asset]),
            downloader: OriginalFileDownloader { _, destination in
                await gate.pause() // Deliberately ignores task cancellation.
                try Data([6]).write(to: destination)
            }
        )

        let preparation = Task { await model.prepare(asset: asset) }
        await fulfillment(of: [started], timeout: 2)
        model.cancelPreparation()
        XCTAssertFalse(model.isBusy)
        await gate.release()
        await preparation.value

        XCTAssertNil(model.sharedFiles)
        XCTAssertFalse(model.isBusy)
    }
}

private actor ViewerShareGate {
    private let onStart: @Sendable () -> Void
    private(set) var calls = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }

    func pause() async {
        calls += 1
        guard calls == 1 else { return }
        onStart()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ViewerShareDestinationRecorder {
    private(set) var destination: URL?
    func record(_ destination: URL) { self.destination = destination }
}
