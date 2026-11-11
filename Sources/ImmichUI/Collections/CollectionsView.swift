import ImmichKit
import SwiftUI

/// The Collections tab, laid out like the iOS 26 Photos app: horizontal rows of Memories,
/// Pinned collections (Favorites, Map), Albums and People, each with a "Title ›" header that
/// opens the full list.
public struct CollectionsView: View {
    @State private var model: CollectionsModel
    @State private var openMemory: Memory?
    private let accessory: AnyView?

    public init(service: any ImmichService, loader: ImageLoader? = nil, accessory: AnyView? = nil) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
        self.accessory = accessory
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !model.memories.isEmpty { memoriesRow }
                pinnedRow
                albumsRow
                peopleRow
                if !model.places.isEmpty { placesRow }
                mediaTypesSection
                otherSection
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Collections")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let accessory { ToolbarItem(placement: .topBarTrailing) { accessory } }
        }
        .fullScreenCover(item: $openMemory) { memory in
            AssetViewer(assets: memory.assets, selectedID: memory.assets[0].id,
                        service: model.service, loader: model.loader)
        }
        #else
        .sheet(item: $openMemory) { memory in
            AssetViewer(assets: memory.assets, selectedID: memory.assets[0].id,
                        service: model.service, loader: model.loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .task { await loadAll() }
        .refreshable { await loadAll(force: true) }
    }

    private func loadAll(force: Bool = false) async {
        async let memories: Void = (force || !model.loadedMemories) ? model.loadMemories() : ()
        async let albums: Void = (force || !model.loadedAlbums) ? model.loadAlbums() : ()
        async let people: Void = (force || !model.loadedPeople) ? model.loadPeople() : ()
        async let places: Void = (force || !model.loadedPlaces) ? model.loadPlaces() : ()
        _ = await (memories, albums, people, places)
    }

    // MARK: Rows

    private var memoriesRow: some View {
        CollectionRow(title: "Memories") {
            ForEach(model.memories) { memory in
                Button { openMemory = memory } label: {
                    MemoryCard(memory: memory, loader: model.loader)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pinnedRow: some View {
        CollectionRow(title: "Pinned") {
            NavigationLink {
                FavoritesView(service: model.service, loader: model.loader)
            } label: {
                PinnedCard(title: "Favorites", systemImage: "heart.fill") {
                    LinearGradient(colors: [.pink.opacity(0.8), .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .buttonStyle(.plain)
            NavigationLink {
                PhotoMapView(service: model.service, loader: model.loader)
            } label: {
                PinnedCard(title: "Map", systemImage: "map.fill") {
                    LinearGradient(colors: [.teal.opacity(0.8), .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var albumsRow: some View {
        CollectionRow(title: "Albums", destination: AnyView(AlbumsView(service: model.service, loader: model.loader))) {
            if model.albums.isEmpty {
                placeholderCards(loading: model.loadingAlbums || !model.loadedAlbums,
                                 failed: model.albumsError != nil, empty: "No albums yet")
            }
            ForEach(model.albums.prefix(20)) { album in
                NavigationLink {
                    AlbumDetailView(album: album, service: model.service, loader: model.loader)
                } label: {
                    ImageCard(key: album.thumbnailAssetId.map { ImageKey(assetID: $0, size: .thumbnail) },
                              loader: model.loader, title: album.name, symbol: "rectangle.stack")
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var peopleRow: some View {
        CollectionRow(title: "People", destination: AnyView(PeopleView(service: model.service, loader: model.loader))) {
            if model.people.isEmpty {
                placeholderCards(loading: model.loadingPeople || !model.loadedPeople,
                                 failed: model.peopleError != nil, empty: "No people yet")
            }
            ForEach(model.people.filter(\.isNamed).prefix(20)) { person in
                NavigationLink {
                    PersonDetailView(person: person, service: model.service, loader: model.loader)
                } label: {
                    VStack(spacing: 8) {
                        CollectionThumbnail(key: .person(person.id), loader: model.loader, symbol: "person.fill")
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                        Text(person.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    .frame(width: 100)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var placesRow: some View {
        CollectionRow(title: "Places") {
            ForEach(model.places.prefix(30), id: \.self) { city in
                NavigationLink {
                    QueryGridView(title: city, query: Self.placeQuery(city), service: model.service, loader: model.loader)
                } label: {
                    PlaceCard(city: city, service: model.service, loader: model.loader)
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func placeQuery(_ city: String) -> MetadataSearchQuery {
        MetadataSearchQuery(filters: SearchFilters(city: city))
    }

    /// Media Types, like Photos: two columns of rows with an icon.
    private var mediaTypesSection: some View {
        CollectionListSection(title: "Media Types") {
            NavigationLink {
                QueryGridView(title: "Videos", query: MetadataSearchQuery(filters: SearchFilters(kind: .video)),
                              service: model.service, loader: model.loader, emptyMessage: "Videos you upload appear here.")
            } label: { CollectionListRow(title: "Videos", systemImage: "video") }
            NavigationLink {
                QueryGridView(title: "Live Photos", query: MetadataSearchQuery(filters: SearchFilters(isMotion: true)),
                              service: model.service, loader: model.loader, emptyMessage: "Live Photos you upload appear here.")
            } label: { CollectionListRow(title: "Live Photos", systemImage: "livephoto") }
        }
    }

    /// Other collections backed by the timeline: recently added, archive and trash.
    private var otherSection: some View {
        CollectionListSection(title: "Other") {
            NavigationLink {
                TimelineCollectionView(title: "Recently Added",
                                       options: TimelineOptions(newestFirst: false, sortsByDateAdded: true),
                                       service: model.service, loader: model.loader)
            } label: { CollectionListRow(title: "Recently Added", systemImage: "clock.arrow.circlepath") }
            NavigationLink {
                TimelineCollectionView(title: "Archive", options: TimelineOptions(visibility: .archive, newestFirst: false),
                                       service: model.service, loader: model.loader)
            } label: { CollectionListRow(title: "Archive", systemImage: "archivebox") }
            NavigationLink {
                TimelineCollectionView(title: "Recently Deleted",
                                       options: TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false),
                                       service: model.service, loader: model.loader)
            } label: { CollectionListRow(title: "Recently Deleted", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func placeholderCards(loading: Bool, failed: Bool, empty: String) -> some View {
        RoundedRectangle(cornerRadius: 22).fill(.quaternary)
            .frame(width: 160, height: 160)
            .overlay {
                if loading { ProgressView() }
                else { Text(failed ? "Couldn't load" : empty).font(.subheadline).foregroundStyle(.secondary) }
            }
    }
}

// MARK: - Building blocks

/// "Title ›" header (opening `destination` when given) above a horizontally scrolling row.
private struct CollectionRow<Content: View>: View {
    let title: String
    var destination: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let destination {
                    NavigationLink { destination } label: { header(chevron: true) }
                        .buttonStyle(.plain)
                } else {
                    header(chevron: false)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) { content }
                    .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func header(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            if chevron {
                Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded square image with its title over the bottom, like album cards in Photos.
private struct ImageCard: View {
    let key: ImageKey?
    let loader: ImageLoader
    let title: String
    var symbol = "photo"

    var body: some View {
        CollectionThumbnail(key: key, loader: loader, symbol: symbol)
            .frame(width: 160, height: 160)
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .padding(12)
            }
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// A pinned collection card: coloured background with a symbol and title.
private struct PinnedCard<Background: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let background: Background

    var body: some View {
        background
            .frame(width: 160, height: 160)
            .overlay(alignment: .topTrailing) {
                Image(systemName: systemImage).font(.title2).foregroundStyle(.white).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.headline).foregroundStyle(.white).padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// A tall memory card with its cover photo, title and year, like Photos' Memories row.
private struct MemoryCard: View {
    let memory: Memory
    let loader: ImageLoader
    @State private var image: CGImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .frame(width: 300, height: 380)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title()).font(.title2.weight(.bold))
                    Text(memory.memoryAt.formatted(.dateTime.month(.wide).year()).uppercased())
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(memory.title()), \(memory.assets.count) items")
            .task(id: memory.id) {
                guard let cover = memory.assets.first,
                      let data = try? await loader.data(for: ImageKey(assetID: cover.id, size: .preview)),
                      !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 900)
                if !Task.isCancelled { image = decoded }
            }
    }
}

/// "Title ›" header above two columns of rounded rows, like Media Types in Photos.
private struct CollectionListSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                content
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}

private struct CollectionListRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A place card: the newest photo taken there, with the city name over it.
private struct PlaceCard: View {
    let city: String
    let service: any ImmichService
    let loader: ImageLoader
    @State private var coverID: String?

    var body: some View {
        ImageCard(key: coverID.map { ImageKey(assetID: $0, size: .thumbnail) }, loader: loader, title: city, symbol: "mappin.and.ellipse")
            .task(id: city) {
                guard coverID == nil else { return }
                let results = try? await service.metadataSearch(CollectionsView.placeQuery(city), page: nil, size: 1)
                if !Task.isCancelled { coverID = results?.assets.first?.id }
            }
    }
}

/// A timeline-backed collection (Recently Added, Archive, Recently Deleted) in the library grid.
public struct TimelineCollectionView: View {
    @State private var model: LibraryGridModel
    private let title: String

    public init(title: String, options: TimelineOptions, service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: LibraryGridModel(service: service, options: options, loader: loader))
        self.title = title
    }

    public var body: some View { LibraryGridView(model: model, title: title) }
}

/// All favorite photos and videos in the library grid.
public struct FavoritesView: View {
    @State private var model: LibraryGridModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: LibraryGridModel(
            service: service, options: TimelineOptions(isFavorite: true, newestFirst: false), loader: loader))
    }

    public var body: some View { LibraryGridView(model: model, title: "Favorites") }
}

#Preview("Collections") {
    NavigationStack { CollectionsView(service: MockImmichService.preview) }
}

#Preview("Favorites") {
    NavigationStack { FavoritesView(service: MockImmichService.preview) }
}
