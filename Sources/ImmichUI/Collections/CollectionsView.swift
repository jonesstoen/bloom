import ImmichKit
import MapKit
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
        async let memories: Void = (force || !model.loadedMemories) ? model.loadMemories() : ()
        async let albums: Void = (force || !model.loadedAlbums) ? model.loadAlbums() : ()
        async let people: Void = (force || !model.loadedPeople) ? model.loadPeople() : ()
        async let places: Void = (force || !model.loadedPlaces) ? model.loadPlaces() : ()
        async let pinned: Void = (force || !model.loadedPinnedCovers) ? model.loadPinnedCovers() : ()
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

// MARK: - Building blocks

/// Capture the whole sequence at opening so refreshes cannot change story positions.
private struct MemoryStorySelection: Identifiable {
    let id = UUID()
    let years: [MemoryStoryYear]
    let startingYear: Int
}

/// "Title ›" header (opening `destination` when given) above a horizontally scrolling row.
private struct CollectionRow<Content: View>: View {
    let title: String
    var destination: AnyView?
    var fold: SectionFold?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let destination {
                    NavigationLink { destination } label: { header(chevron: true) }
                        .buttonStyle(.plain)
                } else {
                    header(chevron: false)
                }
                Spacer()
                if let fold { SectionFoldButton(title: title, fold: fold) }
            }
            .padding(.horizontal, 20)
            if fold?.isCollapsed != true {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) { content }
                        .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

/// A pinned collection card: a preview (or a coloured background) with a symbol and title.
private struct PinnedCard<Background: View>: View {
    let title: String
    let systemImage: String?
    @ViewBuilder let background: Background

    var body: some View {
        background
            .frame(width: 160, height: 160)
            .overlay {
                // Keeps the white title readable on light photos and maps.
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .topTrailing) {
                if let systemImage {
                    Image(systemName: systemImage).font(.title2).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3).padding(12)
                }
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
struct MemoryCard: View {
    let year: MemoryStoryYear
    let loader: ImageLoader
    /// Fixed 300 × 380 in the Collections row; `nil` fills the width (Memories list) at that ratio.
    var width: CGFloat? = 300
    @State private var image: CGImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(300.0 / 380.0, contentMode: .fit)
            .frame(width: width)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(year.year)).font(.title2.weight(.bold))
                    Text(tr("%lld items", Int64(year.assets.count)))
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
            .accessibilityLabel(tr("%@, %lld items", String(year.year), Int64(year.assets.count)))
            .task(id: year.assets.first?.id) {
                image = nil
                guard let cover = year.assets.first,
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
    var fold: SectionFold?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let fold { SectionFoldButton(title: title, fold: fold) }
            }
            if fold?.isCollapsed != true {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    content
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Whether a section is folded, and how to fold or open it.
private struct SectionFold {
    let isCollapsed: Bool
    let toggle: () -> Void
}

/// Photos' round chevron next to a section title: points down while open, right when folded.
private struct SectionFoldButton: View {
    let title: String
    let fold: SectionFold

    var body: some View {
        Button(action: fold.toggle) {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(fold.isCollapsed ? -90 : 0))
                .frame(width: 30, height: 30)
                .photosGlass(in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CollectionSection.toggleLabel(title: title, isCollapsed: fold.isCollapsed))
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

    private let allowsRestore: Bool
    private let onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)?

    public init(title: String, options: TimelineOptions, service: any ImmichService, loader: ImageLoader? = nil,
                allowsRestore: Bool = false, onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil) {
        _model = State(initialValue: LibraryGridModel(service: service, options: options, loader: loader))
        self.title = title
        self.allowsRestore = allowsRestore
        self.onRestore = onRestore
    }

    public var body: some View { LibraryGridView(model: model, title: title, allowsRestore: allowsRestore, onRestore: onRestore) }
}

/// All favorite photos and videos in the library grid.
public struct FavoritesView: View {
    @State private var model: LibraryGridModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: LibraryGridModel(
            service: service, options: TimelineOptions(isFavorite: true, newestFirst: false), loader: loader))
    }

    public var body: some View { LibraryGridView(model: model, title: tr("Favorites")) }
}

#Preview("Collections") {
    NavigationStack { CollectionsView(service: MockImmichService.preview) }
}

#Preview("Favorites") {
    NavigationStack { FavoritesView(service: MockImmichService.preview) }
}

/// The pinned Map card's preview: a still map of where most photos were taken.
private struct MapCoverView: View {
    let region: MapCoverRegion

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta))),
            interactionModes: [])
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // MapKit's required logo and Legal link sit at the bottom: lift them above the title.
            .safeAreaPadding(.bottom, 34)
            .allowsHitTesting(false)
            // A new region (after a refresh) needs a new map: initialPosition is read once.
            .id(region)
    }
}

/// All memories, like Photos' Memories screen: one large card per year, newest first. Tapping a
/// card plays that year's story.
struct MemoriesView: View {
    let years: [MemoryStoryYear]
    let service: any ImmichService
    let loader: ImageLoader
    @State private var openYear: MemoryStorySelection?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(years) { year in
                    Button { openYear = MemoryStorySelection(years: years, startingYear: year.year) } label: {
                        MemoryCard(year: year, loader: loader, width: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .overlay {
            if years.isEmpty {
                ContentUnavailableView(tr("No Memories"), systemImage: "sparkles.rectangle.stack",
                                       description: Text(tr("Photos from this day in earlier years appear here.")))
            }
        }
        .navigationTitle(tr("Memories"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $openYear) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear, service: service, loader: loader)
        }
        #else
        .sheet(item: $openYear) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear, service: service, loader: loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
    }
}

#Preview("Memories") {
    let mock = MockImmichService.preview
    NavigationStack {
        MemoriesView(years: MemoryStoryModel.groupedYears(from: MockLibrary.standard.memories),
                     service: mock, loader: ImageLoader(service: mock, disk: nil))
    }
}
