import ImmichKit
import Observation

@MainActor @Observable
public final class CollectionsModel {
    public private(set) var albums: [Album] = []
    public private(set) var people: [Person] = []
    public private(set) var albumsError: String?
    public private(set) var peopleError: String?
    public private(set) var loadingAlbums = false
    public private(set) var loadingPeople = false
    public private(set) var loadedAlbums = false
    public private(set) var loadedPeople = false
    /// Memories, newest first, without empty ones.
    public private(set) var memories: [Memory] = []
    public private(set) var loadedMemories = false
    /// Cities with photos, for the Places row.
    public private(set) var places: [String] = []
    public private(set) var loadedPlaces = false
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
    }

    public func loadAlbums() async {
        guard !loadingAlbums else { return }
        loadingAlbums = true
        albumsError = nil
        defer { loadingAlbums = false }
        do {
            let result = try await service.albums()
            try Task.checkCancellation()
            albums = result
            loadedAlbums = true
        } catch is CancellationError { return }
        catch { albumsError = "Couldn't load albums. Please try again." }
    }

    public func loadPeople() async {
        guard !loadingPeople else { return }
        loadingPeople = true
        peopleError = nil
        defer { loadingPeople = false }
        do {
            let result = try await service.people()
            try Task.checkCancellation()
            people = result.filter { !$0.isHidden }
            loadedPeople = true
        } catch is CancellationError { return }
        catch { peopleError = "Couldn't load people. Please try again." }
    }

    /// Memories are a bonus row: a failure just leaves the row out.
    public func loadMemories() async {
        do {
            let result = try await service.memories(MemoryQuery())
            try Task.checkCancellation()
            memories = Self.sortedMemories(result)
            loadedMemories = true
        } catch {
            loadedMemories = true
        }
    }

    /// Places are a bonus row too: a failure leaves it out.
    public func loadPlaces() async {
        do {
            let result = try await service.searchSuggestions(.city)
            try Task.checkCancellation()
            places = result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } catch {}
        loadedPlaces = true
    }

    static func sortedMemories(_ memories: [Memory]) -> [Memory] {
        memories.filter { !$0.assets.isEmpty }.sorted { $0.memoryAt > $1.memoryAt }
    }
}
