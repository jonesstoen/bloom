import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerTrashTests: XCTestCase {
    private var asset: Asset {
        Asset(id: "viewer-photo", kind: .image, takenAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testRequestCapturesFirstAssetUntilCancelled() {
        let model = ViewerTrashModel(action: { _ in })

        model.request(asset)
        model.request(Asset(id: "another", kind: .image, takenAt: asset.takenAt))

        XCTAssertEqual(model.pendingAsset?.id, asset.id)
        model.cancelConfirmation()
        XCTAssertNil(model.pendingAsset)
    }

    func testMissingActionAndAlreadyTrashedAssetsCannotRequestConfirmation() {
        let withoutAction = ViewerTrashModel()
        withoutAction.request(asset)
        XCTAssertNil(withoutAction.pendingAsset)

        let action = ViewerTrashModel(action: { _ in })
        var trashed = asset
        trashed.isTrashed = true
        action.request(trashed)
        XCTAssertNil(action.pendingAsset)
    }

    func testCancellationMakesNoWriteAndConfirmSuccessUsesCapturedAssetOnce() async {
        var receivedIDs: [String] = []
        let model = ViewerTrashModel { asset in receivedIDs.append(asset.id) }
        model.request(asset)
        model.cancelConfirmation()
        let cancelledConfirmation = await model.confirm()
        XCTAssertFalse(cancelledConfirmation)
        XCTAssertTrue(receivedIDs.isEmpty)

        model.request(asset)
        let succeeded = await model.confirm()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(receivedIDs, [asset.id])
        XCTAssertNil(model.pendingAsset)
    }

    func testDuplicateConfirmWhileBusyDoesNotSendSecondAction() async {
        var receivedIDs: [String] = []
        let model = ViewerTrashModel { asset in
            try await Task.sleep(for: .milliseconds(60))
            receivedIDs.append(asset.id)
        }
        model.request(asset)
        let first = Task { await model.confirm() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.isBusy)
        let duplicateSucceeded = await model.confirm()
        let firstSucceeded = await first.value
        XCTAssertFalse(duplicateSucceeded)
        XCTAssertTrue(firstSucceeded)
        XCTAssertEqual(receivedIDs, [asset.id])
    }

    func testFailureUsesGenericMessageAndCanBeRetriedIncludingUnavailableServer() async {
        var attempts = 0
        let model = ViewerTrashModel { _ in
            attempts += 1
            throw TrashError.unavailable
        }
        model.request(asset)

        let firstAttempt = await model.confirm()
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(model.error, TrashError.unavailable.localizedDescription)
        XCTAssertNil(model.pendingAsset, "A failed confirmation is consumed; another write needs a new explicit request")
        model.dismissError()
        XCTAssertNil(model.error)
        model.request(asset)
        let retry = await model.confirm()
        XCTAssertFalse(retry)
        XCTAssertEqual(attempts, 2)
    }

    func testTransportDiagnosticsAreNotDisplayed() async {
        let model = ViewerTrashModel { _ in
            throw ImmichServiceError.network("sensitive-transport-diagnostic")
        }
        model.request(asset)
        let result = await model.confirm()
        XCTAssertFalse(result)
        XCTAssertEqual(model.error, ImmichUI.tr("Couldn't move this item to Trash. Please try again."))
        XCTAssertFalse(model.error?.contains("sensitive-transport-diagnostic") ?? true)
    }
}
