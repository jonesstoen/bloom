import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ViewerRestoreTests: XCTestCase {
    private var trashedAsset: Asset {
        Asset(id: "viewer-restore", kind: .image,
              takenAt: Date(timeIntervalSince1970: 1_700_000_000), isTrashed: true)
    }

    func testRestoreModeCapturesTrashedAssetAndSuccessfulConfirmationCallsActionOnce() async {
        var received: [String] = []
        let model = ViewerTrashModel(mode: .restore) { asset in received.append(asset.id) }

        model.request(trashedAsset)
        let success = await model.confirm()

        XCTAssertTrue(success)
        XCTAssertEqual(received, [trashedAsset.id])
        XCTAssertNil(model.pendingAsset)
    }

    func testRestoreModeRejectsNonTrashedAssetsAndConsumesFailedConfirmation() async {
        var attempts = 0
        let model = ViewerTrashModel(mode: .restore) { _ in
            attempts += 1
            throw ImmichServiceError.network("fixture")
        }
        var active = trashedAsset
        active.isTrashed = false
        model.request(active)
        XCTAssertNil(model.pendingAsset)

        model.request(trashedAsset)
        let success = await model.confirm()

        XCTAssertFalse(success)
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(model.pendingAsset)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.error?.contains("fixture") ?? true)
    }

    func testCancelledRestoreConfirmationMakesNoCall() async {
        var calls = 0
        let model = ViewerTrashModel(mode: .restore) { _ in calls += 1 }
        model.request(trashedAsset)
        model.cancelConfirmation()

        let success = await model.confirm()
        XCTAssertFalse(success)
        XCTAssertEqual(calls, 0)
    }
}
