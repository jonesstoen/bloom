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
}
