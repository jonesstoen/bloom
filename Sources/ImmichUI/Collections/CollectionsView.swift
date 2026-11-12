import ImmichKit
import SwiftUI

/// The Collections tab, laid out like the iOS 26 Photos app: horizontal rows of Memories,
/// Pinned collections (Favorites, Map), Albums and People, each with a "Title ›" header that
/// opens the full list.
public struct CollectionsView: View {
    @State private var model: CollectionsModel
    @State private var openMemory: MemoryStorySelection?
    /// Sections folded with their chevron button, remembered between launches.
    @AppStorage("collections.collapsed") private var collapsedRaw = ""
    private let accessory: AnyView?
    private let onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)?
    private let refreshRevision: Int

    public init(service: any ImmichService, loader: ImageLoader? = nil, accessory: AnyView? = nil,
                onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil, refreshRevision: Int = 0) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
        self.accessory = accessory
        self.onRestore = onRestore
        self.refreshRevision = refreshRevision
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
        // Still the back button's title in pushed screens.
        .navigationTitle(tr("Collections"))
        #if os(iOS)
        // Photos' own header: the large title with its buttons on the same line, the content
        // scrolling under it. Pushed screens keep their navigation bar.
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .fullScreenCover(item: $openMemory) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear,
                            service: model.service, loader: model.loader)
        }
        #else
        .sheet(item: $openMemory) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear,
                            service: model.service, loader: model.loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .task(id: refreshRevision) { await loadAll(force: refreshRevision > 0) }
        .refreshable { await loadAll(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: .bloomAlbumsDidChange)) { _ in
            Task { await model.loadAlbums() }
        }
    }

    #if os(iOS)
    private var header: some View {
        HStack(alignment: .center) {
            Text(tr("Collections"))
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let accessory { accessory }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background {
            // Same fade as the Library's header.
            Rectangle()
                .fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
    #endif

    private func fold(_ section: CollectionSection) -> SectionFold {
        SectionFold(isCollapsed: CollapsedSections(rawValue: collapsedRaw).contains(section)) {
            var sections = CollapsedSections(rawValue: collapsedRaw)
            sections.toggle(section)
            withAnimation(.snappy(duration: 0.3)) { collapsedRaw = sections.rawValue }
        }
    }

    private func loadAll(force: Bool = false) async {
        let model = model
        let shouldLoadMemories = force || !model.loadedMemories
        let shouldLoadAlbums = force || !model.loadedAlbums
        let shouldLoadPeople = force || !model.loadedPeople
        let shouldLoadPlaces = force || !model.loadedPlaces
        let shouldLoadPinnedCovers = force || !model.loadedPinnedCovers

        async let memories: Void = shouldLoadMemories ? model.loadMemories() : ()
        async let albums: Void = shouldLoadAlbums ? model.loadAlbums() : ()
        async let people: Void = shouldLoadPeople ? model.loadPeople() : ()
        async let places: Void = shouldLoadPlaces ? model.loadPlaces() : ()
        async let pinned: Void = shouldLoadPinnedCovers ? model.loadPinnedCovers() : ()
        _ = await (memories, albums, people, places, pinned)
    }

    // MARK: Rows

    private var memoriesRow: some View {
        let years = MemoryStoryModel.groupedYears(from: model.memories)
        return CollectionRow(title: tr("Memories"),
                             destination: AnyView(MemoriesView(years: years, service: model.service, loader: model.loader)),
                             fold: fold(.memories)) {
            ForEach(years) { year in
                Button { openMemory = MemoryStorySelection(years: years, startingYear: year.year) } label: {
                    MemoryCard(year: year, loader: model.loader)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pinnedRow: some View {
        CollectionRow(title: tr("Pinned"), fold: fold(.pinned)) {
            NavigationLink {
                FavoritesView(service: model.service, loader: model.loader)
            } label: {
                PinnedCard(title: tr("Favorites"), systemImage: "heart.fill") {
                    if let id = model.favoritesCoverID {
                        CollectionThumbnail(key: ImageKey(assetID: id, size: .thumbnail), loader: model.loader, symbol: "heart")
                    } else {
                        LinearGradient(colors: [.pink.opacity(0.8), .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
            .buttonStyle(.plain)
            NavigationLink {
                PhotoMapView(service: model.service, loader: model.loader)
            } label: {
                PinnedCard(title: tr("Map"), systemImage: model.mapCoverRegion == nil ? "map.fill" : nil) {
                    if let region = model.mapCoverRegion {
                        MapCoverView(region: region)
                    } else {
                        LinearGradient(colors: [.teal.opacity(0.8), .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var albumsRow: some View {
        CollectionRow(title: tr("Albums"), destination: AnyView(AlbumsView(service: model.service, loader: model.loader)),
                      fold: fold(.albums)) {
            if model.albums.isEmpty {
                placeholderCards(loading: model.loadingAlbums || !model.loadedAlbums,
                                 failed: model.albumsError != nil, empty: tr("No albums yet"))
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
        CollectionRow(title: tr("People"), destination: AnyView(PeopleView(service: model.service, loader: model.loader)),
                      fold: fold(.people)) {
            if model.people.isEmpty {
                placeholderCards(loading: model.loadingPeople || !model.loadedPeople,
                                 failed: model.peopleError != nil, empty: tr("No people yet"))
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
        CollectionRow(title: tr("Places"), fold: fold(.places)) {
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
        CollectionListSection(title: tr("Media Types"), fold: fold(.mediaTypes)) {
            NavigationLink {
                QueryGridView(title: tr("Videos"), query: MetadataSearchQuery(filters: SearchFilters(kind: .video)),
                              service: model.service, loader: model.loader, emptyMessage: tr("Videos you upload appear here."))
            } label: { CollectionListRow(title: tr("Videos"), systemImage: "video") }
            NavigationLink {
                QueryGridView(title: tr("Live Photos"), query: MetadataSearchQuery(filters: SearchFilters(isMotion: true)),
                              service: model.service, loader: model.loader, emptyMessage: tr("Live Photos you upload appear here."))
            } label: { CollectionListRow(title: tr("Live Photos"), systemImage: "livephoto") }
        }
    }

    /// Other collections backed by the timeline: recently added, archive and trash.
    private var otherSection: some View {
        CollectionListSection(title: tr("Other"), fold: fold(.other)) {
            NavigationLink {
                TimelineCollectionView(title: tr("Recently Added"),
                                       options: TimelineOptions(newestFirst: false, sortsByDateAdded: true),
                                       service: model.service, loader: model.loader)
            } label: { CollectionListRow(title: tr("Recently Added"), systemImage: "clock.arrow.circlepath") }
            NavigationLink {
                TimelineCollectionView(title: tr("Archive"), options: TimelineOptions(visibility: .archive, newestFirst: false),
                                       service: model.service, loader: model.loader)
            } label: { CollectionListRow(title: tr("Archive"), systemImage: "archivebox") }
            NavigationLink {
                TimelineCollectionView(title: tr("Recently Deleted"),
                                       options: TimelineOptions(isTrashed: true, visibility: nil, newestFirst: false),
                                       service: model.service, loader: model.loader, allowsRestore: true, onRestore: onRestore)
            } label: { CollectionListRow(title: tr("Recently Deleted"), systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func placeholderCards(loading: Bool, failed: Bool, empty: String) -> some View {
        RoundedRectangle(cornerRadius: 22).fill(.quaternary)
            .frame(width: 160, height: 160)
            .overlay {
                if loading { ProgressView() }
                else { Text(failed ? tr("Couldn't load") : empty).font(.subheadline).foregroundStyle(.secondary) }
            }
    }
}

#Preview("Collections") {
    NavigationStack { CollectionsView(service: MockImmichService.preview) }
}
