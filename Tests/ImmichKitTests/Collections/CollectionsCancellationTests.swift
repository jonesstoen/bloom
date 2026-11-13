import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class CollectionsCancellationTests: XCTestCase {
    func testCancelledMemoriesRemainRetryable() async {
        let model = CollectionsModel(service: MockImmichService(library: .standard))
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadMemories()
        }.value
        XCTAssertFalse(model.loadedMemories)
        XCTAssertTrue(model.memories.isEmpty)
        await model.loadMemories()
        XCTAssertTrue(model.loadedMemories)
        XCTAssertFalse(model.memories.isEmpty)
    }

    func testCancelledPlacesRemainRetryable() async {
        let model = CollectionsModel(service: MockImmichService(library: .standard))
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadPlaces()
        }.value
        XCTAssertFalse(model.loadedPlaces)
        XCTAssertTrue(model.places.isEmpty)
        await model.loadPlaces()
        XCTAssertTrue(model.loadedPlaces)
        XCTAssertFalse(model.places.isEmpty)
    }
}
