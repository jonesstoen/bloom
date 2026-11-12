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

    func testRecentSearchesAreExplicitDeduplicatedAndBounded() throws {
        let model = SearchModel(service: MockImmichService.preview)

        model.text = "   "
        model.rememberCurrentSearch()
        XCTAssertTrue(model.recentSearches.isEmpty)

        for index in 1...9 {
            model.text = "Search \(index)"
            model.rememberCurrentSearch()
        }

        XCTAssertEqual(model.recentSearches.count, 8)
        XCTAssertEqual(model.recentSearches.first?.text, "Search 9")
        XCTAssertFalse(model.recentSearches.contains { $0.text == "Search 1" })

        model.text = "  Search 5  "
        model.rememberCurrentSearch()
        XCTAssertEqual(model.recentSearches.count, 8)
        XCTAssertEqual(model.recentSearches.first?.text, "Search 5")
        XCTAssertEqual(model.recentSearches.filter { $0.text == "Search 5" }.count, 1)
    }

    func testRecentSearchReplayPreservesPersonAndCityFilters() async throws {
        let mock = MockImmichService.preview
        let model = SearchModel(service: mock)
        await model.loadSuggestions()
        let person = try XCTUnwrap(model.people.first, "Expected a named person in the mock suggestions")

        model.selectCity("Oslo")
        let citySearch = try XCTUnwrap(model.recentSearches.first)
        XCTAssertEqual(model.query, .city("Oslo"))
        await model.search()
        let expectedCity = try await mock.metadataSearch(
            MetadataSearchQuery(filters: SearchFilters(city: "Oslo"), withExif: true), page: nil, size: 100
        )
        XCTAssertEqual(model.assets.map(\.id), expectedCity.assets.map(\.id))

        model.selectPerson(person)
        let personSearch = try XCTUnwrap(model.recentSearches.first)
        XCTAssertEqual(model.query, .person(person.id))
        await model.search()
        let expectedPerson = try await mock.metadataSearch(
            MetadataSearchQuery(filters: SearchFilters(personIds: [person.id]), withExif: true), page: nil, size: 100
        )
        XCTAssertEqual(model.assets.map(\.id), expectedPerson.assets.map(\.id))

        model.selectRecent(citySearch)
        XCTAssertEqual(model.query, .city("Oslo"))
        XCTAssertEqual(model.recentSearches.first?.id, citySearch.id)
        await model.search()
        XCTAssertEqual(model.assets.map(\.id), expectedCity.assets.map(\.id))

        model.selectRecent(personSearch)
        XCTAssertEqual(model.query, .person(person.id))
        XCTAssertEqual(model.recentSearches.first?.id, personSearch.id)
        await model.search()
        XCTAssertEqual(model.assets.map(\.id), expectedPerson.assets.map(\.id))
    }

    func testClearRecentSearchesDoesNotClearCurrentQueryOrResults() async {
        let model = SearchModel(service: MockImmichService.preview, pageSize: 3)
        model.text = "Oslo"
        model.rememberCurrentSearch()
        await model.search()
        XCTAssertFalse(model.assets.isEmpty)

        let resultsBeforeClear = model.assets.map(\.id)
        model.clearRecentSearches()

        XCTAssertTrue(model.recentSearches.isEmpty)
        XCTAssertEqual(model.query, .smart("Oslo"))
        XCTAssertEqual(model.assets.map(\.id), resultsBeforeClear)
    }

    func testSearchingAfterTypingDoesNotImplicitlyRememberQuery() async {
        let model = SearchModel(service: MockImmichService.preview)
        model.text = "typed but not submitted"

        await model.search()

        XCTAssertTrue(model.recentSearches.isEmpty)
    }

    func testClearingHistoryDuringSearchDoesNotRestoreIt() async {
        let mock = MockImmichService(library: .standard, latency: .milliseconds(40))
        let model = SearchModel(service: mock)
        model.text = "Oslo"
        model.rememberCurrentSearch()

        let request = Task { await model.search() }
        while !model.isLoading { await Task.yield() }
        model.clearRecentSearches()
        await request.value

        XCTAssertTrue(model.recentSearches.isEmpty)
        XCTAssertTrue(model.hasSearched)
    }
}
