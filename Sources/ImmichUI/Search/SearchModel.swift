import Foundation
import ImmichKit
import Observation

@MainActor @Observable
public final class SearchModel {
    enum Query: Hashable { case smart(String), city(String), person(String) }

    struct RecentSearch: Identifiable, Hashable {
        let id: Query
        let text: String

        var systemImage: String {
            switch id {
            case .smart: "magnifyingglass"
            case .city: "mappin.and.ellipse"
            case .person: "person.crop.circle"
            }
        }
    }

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
    private(set) var recentSearches: [RecentSearch] = []
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
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return }
        text = city
        selectedFilter = .city(city)
        invalidate()
        rememberCurrentSearch()
    }

    public func selectPerson(_ person: Person) {
        text = person.name
        selectedFilter = .person(person.id)
        invalidate()
        rememberCurrentSearch()
    }

    func selectSuggestion(_ suggestion: String) {
        let suggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return }
        text = suggestion
        selectedFilter = nil
        invalidate()
        rememberCurrentSearch()
    }

    /// History belongs to this search session. Debounced requests never record partial text.
    func rememberCurrentSearch() {
        guard let query else { return }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        recentSearches.removeAll { $0.id == query }
        recentSearches.insert(RecentSearch(id: query, text: title), at: 0)
        if recentSearches.count > 8 { recentSearches.removeLast(recentSearches.count - 8) }
    }

    func selectRecent(_ recent: RecentSearch) {
        text = recent.text
        switch recent.id {
        case .smart: selectedFilter = nil
        case .city, .person: selectedFilter = recent.id
        }
        invalidate()
        rememberCurrentSearch()
    }

    func clearRecentSearches() {
        recentSearches = []
    }

    /// A library write invalidates result pages and late responses, while preserving the
    /// person's query, exact metadata filter and recent-search history.
    public func invalidateAfterLibraryMutation() {
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
            self.error = tr("Couldn't search your library. Please try again.")
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
            self.error = tr("Couldn't load more results. Please try again.")
        }
    }

    public func loadSuggestions() async {
        guard !loadingSuggestions else { return }
        loadingSuggestions = true
        suggestionsError = nil
        defer { loadingSuggestions = false }
        // Each row can appear as soon as its own request finishes, including on partial failure.
        async let people: Void = loadPeopleSuggestions()
        async let places: Void = loadPlaceSuggestions()
        _ = await (people, places)
    }

    private func loadPeopleSuggestions() async {
        do {
            let result = try await service.people()
            try Task.checkCancellation()
            people = result.filter { $0.isNamed && !$0.isHidden }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            suggestionsError = tr("Some suggestions couldn't be loaded.")
        }
    }

    private func loadPlaceSuggestions() async {
        do {
            let result = try await service.searchSuggestions(.city)
            try Task.checkCancellation()
            var seen: Set<String> = []
            places = result.compactMap {
                let city = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !city.isEmpty && seen.insert(city).inserted ? city : nil
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            suggestionsError = tr("Some suggestions couldn't be loaded.")
        }
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
