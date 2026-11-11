import Foundation
import ImmichKit
import Observation

@MainActor @Observable
public final class SearchModel {
    enum Query: Hashable { case smart(String), city(String), person(String) }
    public var text = "" {
        didSet {
            guard oldValue != text else { return }
            selectedFilter = nil
            invalidate()
        }
    }
    public private(set) var assets: [Asset] = []
    public private(set) var next: SearchPageToken?
    public private(set) var isLoading = false
    public private(set) var hasSearched = false
    public private(set) var error: String?
    public private(set) var people: [Person] = []
    public private(set) var places: [String] = []
    public private(set) var suggestionsError: String?
    public private(set) var loadingSuggestions = false
    private var selectedFilter: Query?
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var generation = 0

    public init(service: any ImmichService, loader: ImageLoader? = nil, pageSize: Int = 100) {
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
        self.pageSize = min(1000, max(1, pageSize))
    }

    var query: Query? {
        if let selectedFilter { return selectedFilter }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .smart(trimmed)
    }

    public func selectCity(_ city: String) {
        text = city
        selectedFilter = .city(city)
        invalidate()
    }

    public func selectPerson(_ person: Person) {
        text = person.name
        selectedFilter = .person(person.id)
        invalidate()
    }

    public func search() async {
        invalidate()
        guard let query, !Task.isCancelled else { return }
        let started = generation
        isLoading = true
        defer { if generation == started { isLoading = false } }
        do {
            let result = try await fetch(query, page: nil)
            try Task.checkCancellation()
            guard started == generation else { return }
            var seen: Set<String> = []
            assets = result.assets.filter { seen.insert($0.id).inserted }
            next = result.next
            hasSearched = true
        } catch is CancellationError { return }
        catch {
            guard started == generation else { return }
            self.error = "Couldn't search your library. Please try again."
            hasSearched = true
        }
    }

    public func loadMore() async {
        guard !isLoading, let page = next, let query else { return }
        let started = generation
        isLoading = true
        error = nil
        defer { if generation == started { isLoading = false } }
        do {
            let result = try await fetch(query, page: page)
            try Task.checkCancellation()
            guard started == generation else { return }
            var seen = Set(assets.map(\.id))
            assets += result.assets.filter { seen.insert($0.id).inserted }
            next = result.next == page ? nil : result.next
        } catch is CancellationError { return }
        catch {
            guard started == generation else { return }
            self.error = "Couldn't load more results. Please try again."
        }
    }

    public func loadSuggestions() async {
        guard !loadingSuggestions else { return }
        loadingSuggestions = true
        suggestionsError = nil
        defer { loadingSuggestions = false }
        do {
            let result = try await service.people()
            try Task.checkCancellation()
            people = result.filter { $0.isNamed && !$0.isHidden }
        } catch is CancellationError { return }
        catch { suggestionsError = "Some suggestions couldn't be loaded." }
        do {
            let result = try await service.searchSuggestions(.city)
            try Task.checkCancellation()
            places = result
        } catch is CancellationError { return }
        catch { suggestionsError = "Some suggestions couldn't be loaded." }
    }

    private func invalidate() {
        generation += 1
        assets = []
        next = nil
        error = nil
        hasSearched = false
        isLoading = false
    }

    private func fetch(_ query: Query, page: SearchPageToken?) async throws -> SearchResults {
        switch query {
        case .smart(let text):
            return try await service.smartSearch(SmartSearchQuery(text: text), page: page, size: pageSize)
        case .city(let city):
            return try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(city: city), withExif: true), page: page, size: pageSize)
        case .person(let id):
            return try await service.metadataSearch(MetadataSearchQuery(filters: SearchFilters(personIds: [id]), withExif: true), page: page, size: pageSize)
        }
    }
}
