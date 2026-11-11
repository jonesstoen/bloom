import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testPagingAndNewQueryClearsResults() async {
        let model = SearchModel(service: MockImmichService.preview, pageSize: 3)
        model.text = "Oslo"
        await model.search()
        XCTAssertEqual(model.assets.count, 3)
        XCTAssertNotNil(model.next)
        let first = model.assets.map(\.id)
        await model.loadMore()
        XCTAssertEqual(model.assets.count, 6)
        XCTAssertEqual(Array(model.assets.prefix(3).map(\.id)), first)
        XCTAssertEqual(Set(model.assets.map(\.id)).count, 6)
        model.text = "   "
        XCTAssertTrue(model.assets.isEmpty)
        await model.search()
        XCTAssertFalse(model.hasSearched)
        XCTAssertNil(model.next)
    }

    func testSuggestionUsesExactMetadataFilterAndRetries() async {
        let mock = MockImmichService.preview
        let model = SearchModel(service: mock)
        await model.loadSuggestions()
        XCTAssertFalse(model.places.isEmpty)
        XCTAssertTrue(model.people.allSatisfy { $0.isNamed && !$0.isHidden })
        model.selectCity("Oslo")
        await mock.setFailure(.unauthorized)
        await model.search()
        XCTAssertNotNil(model.error)
        await mock.setFailure(nil)
        await model.search()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.assets.isEmpty)
        XCTAssertTrue(model.assets.allSatisfy { $0.exif?.city == "Oslo" })
    }

    func testOldSearchCannotRepopulateClearedQuery() async {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(40))
        let model = SearchModel(service: mock)
        model.text = "Oslo"
        let request = Task { await model.search() }
        while !model.isLoading { await Task.yield() }
        model.text = ""
        await request.value
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertFalse(model.hasSearched)
        XCTAssertFalse(model.isLoading)
    }
}
