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
    /// The newest favorite photo, shown on the pinned Favorites card.
    public private(set) var favoritesCoverID: String?
    /// Where most photos were taken, shown on the pinned Map card.
    public private(set) var mapCoverRegion: MapCoverRegion?
    public private(set) var loadedPinnedCovers = false
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored private var reloadAlbumsAfterLoad = false

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
    }

    public func loadAlbums() async {
        guard !loadingAlbums else {
            reloadAlbumsAfterLoad = true
            return
        }
        loadingAlbums = true
        defer { loadingAlbums = false }
        repeat {
            // Changes during a request must refresh its potentially stale response.
            reloadAlbumsAfterLoad = false
            albumsError = nil
            do {
                let result = try await service.albums()
                try Task.checkCancellation()
                albums = result
                loadedAlbums = true
            } catch is CancellationError {
                if reloadAlbumsAfterLoad {
                    // A separate change notification outlives the cancelled caller.
                    // Start after this call releases loadingAlbums; a newer load wins.
                    Task {
                        guard self.reloadAlbumsAfterLoad else { return }
                        await self.loadAlbums()
                    }
                }
                return
            }
            catch { albumsError = tr("Couldn't load albums. Please try again.") }
        } while reloadAlbumsAfterLoad && !Task.isCancelled
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
        catch { peopleError = tr("Couldn't load people. Please try again.") }
    }

    /// Memories are a bonus row: a failure just leaves the row out.
    public func loadMemories() async {
        do {
            let result = try await service.memories(MemoryQuery())
            try Task.checkCancellation()
            memories = Self.sortedMemories(result)
            loadedMemories = true
        } catch is CancellationError {
            return
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
        } catch is CancellationError { return }
        catch {}
        loadedPlaces = true
    }

    /// Previews for the pinned cards. A bonus: a failure keeps the coloured cards.
    public func loadPinnedCovers() async {
        async let favorite = newestFavoriteID()
        async let markers = try? service.mapMarkers()
        let (favoriteID, mapMarkers) = await (favorite, markers)
        guard !Task.isCancelled else { return }
        favoritesCoverID = favoriteID
        mapCoverRegion = mapMarkers.flatMap { MapCoverRegion(markers: $0) }
        loadedPinnedCovers = true
    }

    /// The newest month with favorites, then its newest photo (same filter as the Favorites grid).
    private func newestFavoriteID() async -> String? {
        let options = TimelineOptions(isFavorite: true, newestFirst: true)
        guard let buckets = try? await service.timeBuckets(options: options),
              let newest = buckets.filter({ $0.count > 0 }).max(by: { ($0.year, $0.month) < ($1.year, $1.month) }),
              let assets = try? await service.timeBucketAssets(bucketID: newest.id, options: options)
        else { return nil }
        return assets.max { $0.localDateTime < $1.localDateTime }?.id
    }

    static func sortedMemories(_ memories: [Memory]) -> [Memory] {
        memories.filter { !$0.assets.isEmpty }.sorted { $0.memoryAt > $1.memoryAt }
    }
}
