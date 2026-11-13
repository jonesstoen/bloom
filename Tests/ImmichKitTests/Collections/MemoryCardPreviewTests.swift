import CoreGraphics
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class MemoryCardPreviewTests: XCTestCase {
    func testPrepareDeduplicatesCapsCandidatesAndAdvanceWraps() async throws {
        let fixture = MockLibrary.small
        let ids = Array(fixture.assets.prefix(7).map(\.id))
        let service = MockImmichService(library: fixture)
        let loader = ImageLoader(service: service, disk: nil)
        let model = MemoryCardPreviewModel()

        await model.prepare(assetIDs: [ids[0], ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6]], loader: loader)

        XCTAssertEqual(model.candidateIDs, Array(ids.prefix(6)))
        XCTAssertEqual(model.assetID, ids[0])
        XCTAssertNotNil(model.image)
        XCTAssertTrue(model.canAdvance)
        let previewRequests = await service.requestCount(.thumbnail(ids[0], .preview))
        XCTAssertEqual(previewRequests, 1)

        for _ in 0..<6 { await model.advance(loader: loader) }
        XCTAssertEqual(model.assetID, ids[0], "Advancing past the last candidate wraps to the first")
        XCTAssertNotNil(model.image)
    }

    func testFailedNextKeepsCurrentPreviewAndLaterAdvanceRecovers() async throws {
        let fixture = MockLibrary.small
        let ids = Array(fixture.assets.prefix(3).map(\.id))
        let service = MockImmichService(library: fixture)
        let loader = ImageLoader(service: service, disk: nil)
        let model = MemoryCardPreviewModel()
        await model.prepare(assetIDs: ids, loader: loader)
        let initialImage = try XCTUnwrap(model.image)
        let initialRevision = model.revision

        await service.setFailure(.unauthorized)
        await model.advance(loader: loader)

        XCTAssertEqual(model.assetID, ids[0])
        XCTAssertTrue(model.image === initialImage)
        XCTAssertEqual(model.revision, initialRevision)

        await service.setFailure(nil)
        await model.advance(loader: loader)
        XCTAssertEqual(model.assetID, ids[2], "The failed candidate is skipped on the next attempt")
        XCTAssertNotNil(model.image)
        XCTAssertGreaterThan(model.revision, initialRevision)
    }

    func testPrepareKeepsCurrentPreviewWhenItsAssetRemainsACandidate() async throws {
        let fixture = MockLibrary.small
        let ids = Array(fixture.assets.prefix(3).map(\.id))
        let service = MockImmichService(library: fixture)
        let loader = ImageLoader(service: service, disk: nil)
        let model = MemoryCardPreviewModel()
        await model.prepare(assetIDs: ids, loader: loader)
        await model.advance(loader: loader)
        let currentImage = try XCTUnwrap(model.image)
        let currentRevision = model.revision

        await model.prepare(assetIDs: [ids[2], ids[1], ids[0]], loader: loader)

        XCTAssertEqual(model.assetID, ids[1])
        XCTAssertTrue(model.image === currentImage)
        XCTAssertEqual(model.revision, currentRevision)
    }

    func testCancelledPrepareDoesNotPublishPreview() async throws {
        let assetID = MockLibrary.small.assets[0].id
        let service = MockImmichService(library: .small)
        await service.setLatency(.seconds(30))
        let loader = ImageLoader(service: service, disk: nil)
        let model = MemoryCardPreviewModel()

        let prepare = Task { await model.prepare(assetIDs: [assetID], loader: loader) }
        let requestStarted = await waitUntil {
            await service.requestCount(.thumbnail(assetID, .preview)) == 1
        }
        XCTAssertTrue(requestStarted, "The preview request should be pending before cancellation")
        prepare.cancel()
        await prepare.value

        XCTAssertNil(model.image)
        XCTAssertNil(model.assetID)
        XCTAssertEqual(model.revision, 0)
    }

    func testOlderPrepareCannotReplaceNewerCandidates() async throws {
        let fixture = MockLibrary.small
        let oldID = fixture.assets[0].id
        let newID = fixture.assets[1].id
        let service = MockImmichService(library: fixture)
        await service.setLatency(.milliseconds(300))
        let loader = ImageLoader(service: service, disk: nil)
        let model = MemoryCardPreviewModel()

        let oldPrepare = Task { await model.prepare(assetIDs: [oldID], loader: loader) }
        let oldRequestStarted = await waitUntil {
            await service.requestCount(.thumbnail(oldID, .preview)) == 1
        }
        XCTAssertTrue(oldRequestStarted)

        await service.setLatency(.zero)
        await model.prepare(assetIDs: [newID], loader: loader)
        let newerRevision = model.revision
        XCTAssertEqual(model.assetID, newID)
        await oldPrepare.value

        XCTAssertEqual(model.candidateIDs, [newID])
        XCTAssertEqual(model.assetID, newID)
        XCTAssertEqual(model.revision, newerRevision)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        return await condition()
    }
}
