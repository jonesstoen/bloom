import XCTest
import ImmichKit
@testable import ImmichUI

/// Without a working machine-learning service Immich's smart search fails. Text search then
/// matches file names instead and says so, so nobody mistakes it for a content search.
@MainActor
final class SmartSearchFallbackTests: XCTestCase {
    private func fallbackModel(status: Int, pageSize: Int = 100) async -> (SearchModel, MockImmichService) {
        let mock = MockImmichService(library: .standard)
        await mock.setSmartSearchFailure(.unexpectedStatus(status))
        return (SearchModel(service: mock, pageSize: pageSize), mock)
    }

    func testServerErrorFallsBackToFileNamesAndSaysSo() async {
        let (model, mock) = await fallbackModel(status: 500)
        model.text = " IMG_100 "
        await model.search()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.usingFileNameSearch)
        XCTAssertFalse(model.assets.isEmpty)
        XCTAssertTrue(model.assets.allSatisfy { $0.originalFileName?.contains("IMG_100") == true })
        let requests = await mock.requests
        XCTAssertEqual(requests, [.smartSearch("IMG_100"), .metadataSearch])
    }

    func testSmartSearchTurnedOffFallsBackToFileNames() async {
        let (model, _) = await fallbackModel(status: 400)
        model.text = "IMG_1001"
        await model.search()
        XCTAssertTrue(model.usingFileNameSearch)
        XCTAssertFalse(model.assets.isEmpty)
        XCTAssertTrue(model.assets.allSatisfy { $0.originalFileName?.contains("IMG_1001") == true })
    }

    func testNoFileNameMatchIsStillMarkedAsFallback() async {
        let (model, _) = await fallbackModel(status: 503)
        model.text = "dog"
        await model.search()
        XCTAssertTrue(model.hasSearched)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertTrue(model.usingFileNameSearch, "the empty state must say smart search is unavailable")
        XCTAssertNil(model.error)
    }

    func testRealFailuresAreNotHiddenByTheFallback() async {
        for failure: ImmichServiceError in [.network("offline"), .unauthorized, .unexpectedStatus(404), .invalidResponse] {
            let mock = MockImmichService(library: .standard)
            await mock.setSmartSearchFailure(failure)
            let model = SearchModel(service: mock)
            model.text = "IMG_100"
            await model.search()
            XCTAssertNotNil(model.error, "\(failure)")
            XCTAssertFalse(model.usingFileNameSearch, "\(failure)")
            let requests = await mock.requests
            XCTAssertEqual(requests, [.smartSearch("IMG_100")], "\(failure)")
        }
    }

    func testLaterPagesStayFileNameMatches() async {
        let (model, mock) = await fallbackModel(status: 500, pageSize: 3)
        model.text = "IMG_1"
        await model.search()
        XCTAssertEqual(model.assets.count, 3)
        XCTAssertNotNil(model.next)
        await model.loadMore()
        XCTAssertEqual(model.assets.count, 6)
        XCTAssertTrue(model.usingFileNameSearch)
        let requests = await mock.requests
        XCTAssertEqual(requests, [.smartSearch("IMG_1"), .metadataSearch, .metadataSearch])
    }

    func testWorkingSmartSearchClearsTheFallback() async {
        let (model, mock) = await fallbackModel(status: 500)
        model.text = "IMG_100"
        await model.search()
        XCTAssertTrue(model.usingFileNameSearch)
        await mock.setSmartSearchFailure(nil)
        model.text = "Oslo"
        XCTAssertFalse(model.usingFileNameSearch, "a new query starts without the notice")
        await model.search()
        XCTAssertFalse(model.usingFileNameSearch)
        XCTAssertFalse(model.assets.isEmpty)
    }
}
