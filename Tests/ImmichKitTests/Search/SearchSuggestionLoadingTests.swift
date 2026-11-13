import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class SearchSuggestionLoadingTests: XCTestCase {
    func testIndependentRequestsStartTogetherAndPlacesCanAppearFirst() async throws {
        let transport = SuggestionTransport(blocked: [.people, .cities])
        let model = try model(transport)
        let request = Task { await model.loadSuggestions() }
        let started = await waitUntil { await transport.bothStarted }
        XCTAssertTrue(started, "Both requests must start without waiting for the other response")
        guard started else { await transport.releaseAll(); await request.value; return }
        await model.loadSuggestions()
        let count = await transport.count
        XCTAssertEqual(count, 2, "An overlapping load must not create another request pair")
        await transport.release(.cities)
        let placesReady = await waitUntil { !model.places.isEmpty }
        XCTAssertTrue(placesReady)
        XCTAssertEqual(model.places, ["Oslo", "Bergen"])
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.loadingSuggestions)
        await transport.release(.people)
        await request.value
        XCTAssertEqual(model.people.map(\.name), ["Anna"])
        XCTAssertFalse(model.loadingSuggestions)
        XCTAssertNil(model.suggestionsError)
    }

    func testPeopleFailureKeepsPlacesAndCanRetry() async throws {
        try await checkPartialFailure(.people)
    }

    func testPlacesFailureKeepsPeopleAndCanRetry() async throws {
        try await checkPartialFailure(.cities)
    }

    func testCancellationDiscardsLateResponsesAndAllowsRetry() async throws {
        let transport = SuggestionTransport(blocked: [.people, .cities], failures: [.cities])
        let model = try model(transport)
        let request = Task { await model.loadSuggestions() }
        let started = await waitUntil { await transport.bothStarted }
        XCTAssertTrue(started)
        request.cancel()
        await transport.releaseAll()
        await request.value
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.places.isEmpty)
        XCTAssertNil(model.suggestionsError)
        XCTAssertFalse(model.loadingSuggestions)
        await transport.clearFailures()
        await model.loadSuggestions()
        XCTAssertEqual(model.people.map(\.name), ["Anna"])
        XCTAssertEqual(model.places, ["Oslo", "Bergen"])
        XCTAssertNil(model.suggestionsError)
    }

    private func checkPartialFailure(_ endpoint: SuggestionTransport.Endpoint) async throws {
        let transport = SuggestionTransport(failures: [endpoint])
        let model = try model(transport)
        await model.loadSuggestions()
        XCTAssertNotNil(model.suggestionsError)
        XCTAssertFalse(model.loadingSuggestions)
        XCTAssertEqual(model.people.isEmpty, endpoint == .people)
        XCTAssertEqual(model.places.isEmpty, endpoint == .cities)
        await transport.clearFailures()
        await model.loadSuggestions()
        XCTAssertEqual(model.people.map(\.name), ["Anna"])
        XCTAssertEqual(model.places, ["Oslo", "Bergen"])
        XCTAssertNil(model.suggestionsError)
    }

    private func model(_ transport: SuggestionTransport) throws -> SearchModel {
        let credentials = try ServerCredentials(server: "https://example.invalid", apiKey: "unit-test-placeholder")
        let service = LiveImmichService(credentials: credentials, transport: transport)
        return SearchModel(service: service, loader: ImageLoader(service: service, disk: nil))
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        return await condition()
    }
}

/// A deliberately non-cooperative transport: releasing a cancelled response tests publish guards.
private actor SuggestionTransport: ClientTransport {
    enum Endpoint: Hashable { case people, cities }
    private var blocked: Set<Endpoint>
    private var failures: Set<Endpoint>
    private var waiters: [Endpoint: CheckedContinuation<Void, Never>] = [:]
    private var started: [Endpoint] = []
    var bothStarted: Bool { Set(started) == [.people, .cities] }
    var count: Int { started.count }

    init(blocked: Set<Endpoint> = [], failures: Set<Endpoint> = []) {
        self.blocked = blocked
        self.failures = failures
    }

    func clearFailures() { failures = [] }
    func release(_ endpoint: Endpoint) {
        blocked.remove(endpoint)
        waiters.removeValue(forKey: endpoint)?.resume()
    }
    func releaseAll() { release(.people); release(.cities) }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let endpoint: Endpoint = request.path?.hasPrefix("/people?") == true ? .people : .cities
        started.append(endpoint)
        if blocked.contains(endpoint) { await withCheckedContinuation { waiters[endpoint] = $0 } }
        var response = HTTPResponse(status: failures.contains(endpoint) ? .serviceUnavailable : .ok)
        response.headerFields[.contentType] = "application/json"
        if failures.contains(endpoint) { return (response, HTTPBody("{}")) }
        let json: String
        switch endpoint {
        case .cities: json = #"[" Oslo ","Oslo","","  ","Bergen"]"#
        case .people:
            let people = [("p1", "Anna", false), ("p2", "", false), ("p3", "Hidden", true)].map { id, name, hidden in
                """
                {"id":"\(id)","name":"\(name)","isHidden":\(hidden),"isFavorite":false,
                "birthDate":"1990-06-15","thumbnailPath":"/t.jpeg","updatedAt":"2024-01-01T00:00:00.000Z",
                "otherPeople":[],"sharedBy":[],"sharedWith":[]}
                """
            }.joined(separator: ",")
            json = #"{"people":[\#(people)],"total":3,"hidden":1,"hasNextPage":false}"#
        }
        return (response, HTTPBody(json))
    }
}
